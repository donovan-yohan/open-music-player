package processor

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

var (
	ErrPrivateIntakeSize     = errors.New("private intake byte limit or declared length exceeded")
	ErrPrivateIntakeBytes    = errors.New("private intake bytes do not match the accepted manifest")
	ErrPrivateIntakeProbe    = errors.New("private intake requires bounded self-contained MP3 audio")
	ErrPrivateIntakeCapacity = db.ErrPrivateImportStageCapacity
)

const privateMP3ContentType = "audio/mpeg"

var privateIntakeWorkers = make(chan struct{}, 4)

type privateIntakeObjects interface {
	ObjectStorage
	PutPrivateImportObject(context.Context, string, io.Reader, int64) error
	StatObject(context.Context, string) (*storage.ObjectInfo, error)
	VerifyPrivateImportObjectAbsent(context.Context, string) bool
	DeleteObject(context.Context, string) error
}

// PrivateImportIntake is an unwired service for already-authorized calls.
// Only this producer may Put its attempt keys. The bucket must be private,
// unversioned and free of lifecycle deletion on this keyspace.
type PrivateImportIntake struct {
	tracks              *db.TrackRepository
	objects             privateIntakeObjects
	scratchRoot, ffmpeg string
}

func NewPrivateImportIntake(tracks *db.TrackRepository, objects privateIntakeObjects, scratchRoot, ffmpeg string) (*PrivateImportIntake, error) {
	if tracks == nil || objects == nil || !filepath.IsAbs(scratchRoot) || !filepath.IsAbs(ffmpeg) {
		return nil, errors.New("invalid private intake dependencies")
	}
	return &PrivateImportIntake{tracks: tracks, objects: objects, scratchRoot: scratchRoot, ffmpeg: ffmpeg}, nil
}

// Import accepts exactly one audio stream and never replays a Put. A caller
// must supply a reader whose blocked Read can be interrupted by a deadline
// or close (as for a bounded HTTP request body). A Go io.Reader cannot be
// forcibly interrupted here; we do not spawn detached reader goroutines.
func (s *PrivateImportIntake) Import(ctx context.Context, m db.PrivateImportManifest, audio io.Reader) (*db.PrivateImportReceipt, error) {
	if m.ByteLength <= 0 || m.ByteLength > db.PrivateImportMaxBytes {
		return nil, ErrPrivateIntakeSize
	}
	if audio == nil {
		return nil, ErrPrivateIntakeBytes
	}
	select {
	case privateIntakeWorkers <- struct{}{}:
		defer func() { <-privateIntakeWorkers }()
	default:
		return nil, ErrPrivateIntakeCapacity
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	reservation, receipt, err := s.tracks.ReservePrivateImportStage(ctx, m)
	if err != nil || receipt != nil {
		return receipt, err
	}
	in := reservation.Intent()
	spool, err := privateIntakeSpool(ctx, s.scratchRoot, audio, in)
	if err == nil {
		defer spool.Close()
		in.DurationMs, err = probePrivateMP3(ctx, s.ffmpeg, spool)
	}
	if err != nil {
		// No Put barrier was crossed. On IO/DB loss the same exact row can
		// also be expired without touching storage.
		settle, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
		defer cancel()
		return nil, errors.Join(err, s.tracks.RefusePrivateImportStage(settle, in))
	}
	in, err = reservation.AuthorizePut(ctx, in.DurationMs)
	if err != nil {
		return nil, err
	}
	if err := s.objects.PutPrivateImportObject(ctx, in.ObjectKey(), spool, in.ByteLength); err != nil {
		return nil, db.ErrPrivateImportStagePending // No ACK, no delete, no Put retry.
	}
	settle, stop := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	err = s.tracks.AcknowledgePrivateImportPut(settle, in)
	stop()
	if err != nil {
		return nil, err // Exact readback can still recover the uncertain stage.
	}
	return s.Recover(ctx, in.OwnerID, in.OperationID)
}

// Recover never reads the original or issues a Put. It can commit the exact
// verified staged bytes before expiry or return the canonical receipt after
// commit. An observed (unacknowledged) Put still cannot authorize deletion.
func (s *PrivateImportIntake) Recover(ctx context.Context, owner, operation uuid.UUID) (*db.PrivateImportReceipt, error) {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	stage, receipt, err := s.tracks.LoadPrivateImportStage(ctx, owner, operation)
	if err != nil || receipt != nil {
		return receipt, err
	}
	receipt, err = s.recoverStage(ctx, stage)
	if err == nil {
		return receipt, nil
	}
	// Another recovery can seal a receipt and remove the deduped losing
	// key after Load but before Stat/GET (or before this attempt updates
	// its phase). Only the exact canonical historical receipt beats the
	// original error; do not retry object IO or return a different receipt.
	if historical, readErr := s.tracks.ReadPrivateImportStageReceipt(ctx, stage.Intent); readErr == nil && historical != nil {
		return historical, nil
	}
	return nil, err
}

func (s *PrivateImportIntake) recoverStage(ctx context.Context, stage db.PrivateImportStage) (*db.PrivateImportReceipt, error) {
	in := stage.Intent
	info, err := s.objects.StatObject(ctx, in.ObjectKey())
	if stage.NeedsReadback && storage.IsObjectNotFound(err) && s.objects.VerifyPrivateImportObjectAbsent(ctx, in.ObjectKey()) {
		return nil, db.ErrPrivateImportStagePending
	}
	if err != nil || info == nil || info.ContentType != privateMP3ContentType || info.Size != in.ByteLength {
		return nil, ErrPrivateImportBytes
	}
	if stage.NeedsReadback {
		if err := verifyStoredPrivateImportBytes(ctx, s.objects, in.ObjectKey(), in.SHA256, in.ByteLength); err != nil {
			return nil, err
		}
		if err := s.tracks.ObservePrivateImportPut(ctx, in); err != nil {
			return nil, err
		}
	}
	return CommitStoredPrivateImport(ctx, s.tracks, s.objects, in)
}

// Collect performs one bounded pass over SQL-owned keys, not a bucket scan.
// Counts only verified removals (including an already absent exact object).
func (s *PrivateImportIntake) Collect(ctx context.Context, limit int) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := s.tracks.ExpirePrivateImportStages(ctx, limit); err != nil {
		return 0, err
	}
	var removed int
	var failures error
	for i := 0; i < limit; i++ {
		if err := ctx.Err(); err != nil {
			return removed, errors.Join(failures, err)
		}
		attempted, collected, err := s.tracks.CollectPrivateImportStage(ctx, s.deleteExact)
		failures = errors.Join(failures, err)
		if !attempted {
			break
		}
		if collected {
			removed++
		}
	}
	return removed, failures
}

func (s *PrivateImportIntake) deleteExact(ctx context.Context, key string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := s.objects.DeleteObject(ctx, key); err != nil {
		return errors.New("private intake delete not acknowledged")
	}
	if !s.objects.VerifyPrivateImportObjectAbsent(ctx, key) {
		return errors.New("private intake object absence not verified")
	}
	return nil
}

type contextIntakeReader struct {
	ctx context.Context
	r   io.Reader
}

func (r contextIntakeReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(p)
}

func privateIntakeSpool(ctx context.Context, root string, audio io.Reader, in db.PrivateImportIntent) (*os.File, error) {
	file, err := os.CreateTemp(root, ".private-intake-*") // exclusive, 0600
	if err != nil {
		return nil, errors.New("private intake scratch unavailable")
	}
	// On POSIX this descriptor has no name during all byte IO, and process
	// loss closes it. Do not give the probe a path to reopen or traverse.
	if err := os.Remove(file.Name()); err != nil {
		_ = file.Close()
		return nil, errors.New("private intake scratch could not be unlinked")
	}
	fail := func(err error) (*os.File, error) { _ = file.Close(); return nil, err }
	digest := sha256.New()
	n, err := io.Copy(io.MultiWriter(file, digest), io.LimitReader(contextIntakeReader{ctx, audio}, in.ByteLength+1))
	if n > in.ByteLength {
		return fail(ErrPrivateIntakeSize)
	}
	if err != nil || n != in.ByteLength || in.SHA256 != "sha256:"+hex.EncodeToString(digest.Sum(nil)) {
		return fail(ErrPrivateIntakeBytes)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return fail(ErrPrivateIntakeBytes)
	}
	return file, nil
}
