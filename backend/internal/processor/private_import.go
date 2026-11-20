package processor

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/db"
)

var ErrPrivateImportBytes = errors.New("canonical private import bytes unavailable or unverified")

const privateImportCommitTimeout = 15 * time.Second

// CommitStoredPrivateImport is deliberately unwired to upload/receipt HTTP
// routes. It consumes *already stored and measured* owner/attempt-scoped MP3s.
// The upstream owner must reserve the operation and attempt, attest measured
// facts and guarantee no overwrite/delete once published. We verify the exact
// winning object's bytes, but do not own staging, cleanup, or probe admission.
// Analysis dispatch is separate: the existing maintenance owner drains the
// durable obligation even if the request or first processor disappears.
func CommitStoredPrivateImport(ctx context.Context, tracks *db.TrackRepository, objects ObjectStorage, intent db.PrivateImportIntent) (*db.PrivateImportReceipt, error) {
	ctx, cancel := context.WithTimeout(ctx, privateImportCommitTimeout)
	defer cancel()
	for i := 0; i < 2; i++ {
		receipt, source, err := tracks.ResolvePrivateImportCommit(ctx, intent)
		if err != nil || receipt != nil {
			return receipt, err
		}
		if err := verifyStoredPrivateImportBytes(ctx, objects, source.Key, source.SHA256, source.ByteLength); err != nil {
			return nil, err
		}
		receipt, err = tracks.CommitVerifiedPrivateImport(ctx, intent, source)
		if !errors.Is(err, db.ErrPrivateImportSourceChanged) {
			return receipt, err
		}
	}
	return nil, db.ErrPrivateImportSourceChanged
}

func verifyStoredPrivateImportBytes(ctx context.Context, objects ObjectStorage, key, hash string, size int64) error {
	if objects == nil || key == "" || size <= 0 || size > db.PrivateImportMaxBytes {
		return ErrPrivateImportBytes
	}
	body, info, err := objects.GetObject(ctx, key)
	if err != nil {
		return ErrPrivateImportBytes
	}
	defer body.Close()
	if info == nil || info.Size != size {
		return ErrPrivateImportBytes
	}
	digest := sha256.New()
	n, err := io.Copy(digest, io.LimitReader(body, size+1))
	if err != nil || n != size || hash != "sha256:"+hex.EncodeToString(digest.Sum(nil)) {
		return ErrPrivateImportBytes
	}
	return ctx.Err()
}

type privateImportAnalysisClaimer interface {
	ClaimPrivateImportAnalysis(ctx context.Context, source db.PrivateImportSource, claim uuid.UUID, name, version string) (bool, error)
}

// DrainPrivateImportAnalysis performs one bounded pass. It never waits for
// results or retries the same row in a loop, and shares the ordinary worker
// queue, terminal writes and result path. The persisted claim arbitrates
// different process instances; the local queue itself is not durable.
func (p *Processor) DrainPrivateImportAnalysis(ctx context.Context) (int, error) {
	claimer, ok := p.analysisRepo.(privateImportAnalysisClaimer)
	if !ok || p.trackRepo == nil || p.analyzerClient == nil || p.storage == nil {
		return 0, nil
	}
	name, version := p.analyzerIdentity()
	if name == "" || version == "" {
		return 0, nil
	}
	ctx, cancel := context.WithTimeout(ctx, postStoreDispatchTimeout)
	defer cancel()
	const batchLimit = 16
	candidates, err := p.trackRepo.GetPrivateImportAnalysisCandidates(ctx, batchLimit)
	if err != nil {
		return 0, fmt.Errorf("select private analysis obligations: %w", err)
	}
	var queued int
	var failed error
	for _, source := range candidates {
		if err := ctx.Err(); err != nil {
			return queued, errors.Join(failed, err)
		}
		claim := uuid.New()
		admitted, err := claimer.ClaimPrivateImportAnalysis(ctx, source, claim, name, version)
		if err != nil {
			failed = errors.Join(failed, fmt.Errorf("claim private analysis: %w", err))
			continue
		}
		if !admitted {
			continue
		}
		req := analyzer.Request{
			TrackID: source.TrackID, StorageKey: source.Key, DurationMs: int(source.DurationMs), SchemaVersion: analyzer.SchemaVersion,
			ExpectedAnalyzer: name, ExpectedAnalyzerVersion: version,
			PrivateSource: &analyzer.PrivateSourceProof{SHA256: source.SHA256, ByteLength: source.ByteLength, Claim: claim.String()},
		}
		if err := p.scheduleAnalysis(ctx, req); err != nil {
			p.markAnalysisSchedulingFailed(req, err)
			return queued, errors.Join(failed, fmt.Errorf("schedule private analysis: %w", err))
		}
		queued++
	}
	return queued, failed
}

func analysisWorkProvenance(req analyzer.Request, trigger string) map[string]any {
	p := map[string]any{
		"trigger": trigger, "expected_analyzer": req.ExpectedAnalyzer, "expected_analyzer_version": req.ExpectedAnalyzerVersion,
	}
	if req.PrivateSource != nil {
		// Keep private provenance on the single durable origin. Only the
		// minimal key/duration travels over the allowlisted analyzer wire.
		delete(p, "trigger")
		p["dispatch_token"] = req.PrivateSource.Claim
	}
	return p
}
