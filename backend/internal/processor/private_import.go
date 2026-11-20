package processor

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"strings"
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

type privateAnalyzerInfoClient interface {
	Info(context.Context) (analyzer.Info, error)
}

const privateImportAnalysisBatchLimit = 16

// DrainPrivateImportAnalysis queues a bounded batch of unclaimed intents on
// the ordinary FIFO. The committed obligation remains recoverable on a full
// queue, under shutdown, or after process loss before a worker starts.
func (p *Processor) DrainPrivateImportAnalysis(ctx context.Context) (int, error) {
	_, canClaim := p.analysisRepo.(privateImportAnalysisClaimer)
	client, canReadIdentity := p.analyzerClient.(privateAnalyzerInfoClient)
	if !canClaim || !canReadIdentity || p.trackRepo == nil || p.storage == nil {
		return 0, nil
	}
	// The cached identity is only a startup readiness gate, never a private
	// request's identity. In particular, don't reuse it when health is down.
	if name, version := p.analyzerIdentity(); name == "" || version == "" {
		return 0, nil
	}
	ctx, cancel := context.WithTimeout(ctx, postStoreDispatchTimeout)
	defer cancel()
	name, version, err := readPrivateAnalyzerIdentity(ctx, client)
	if err != nil {
		return 0, err
	}
	candidates, err := p.trackRepo.GetPrivateImportAnalysisCandidates(ctx, name, version, privateImportAnalysisBatchLimit)
	if err != nil {
		return 0, fmt.Errorf("select private analysis obligations: %w", err)
	}
	var queued int
	for _, source := range candidates {
		admitted, err := p.schedulePrivateAnalysis(ctx, source)
		if err != nil {
			return queued, fmt.Errorf("schedule private analysis: %w", err)
		}
		if admitted {
			queued++
		}
	}
	return queued, nil
}

func readPrivateAnalyzerIdentity(ctx context.Context, client privateAnalyzerInfoClient) (string, string, error) {
	info, err := client.Info(ctx)
	if err != nil {
		return "", "", fmt.Errorf("read live private analyzer identity: %w", err)
	}
	name, version := strings.TrimSpace(info.Analyzer), strings.TrimSpace(info.AnalyzerVersion)
	if name == "" || version == "" {
		return "", "", errors.New("private analyzer identity is incomplete")
	}
	return name, version, nil
}

func (p *Processor) schedulePrivateAnalysis(ctx context.Context, source db.PrivateImportSource) (bool, error) {
	p.analysisMu.Lock()
	defer p.analysisMu.Unlock()
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if p.analysisQueue == nil || p.analysisStopping {
		return false, errors.New("audio analysis queue is unavailable")
	}
	if _, pending := p.privateAnalysisPending[source.TrackID]; pending || len(p.privateAnalysisPending) >= privateImportAnalysisBatchLimit {
		return false, nil
	}
	task := analysisTask{id: p.analysisNextTaskID + 1, privateSource: &source}
	select {
	case p.analysisQueue <- task:
		p.analysisNextTaskID = task.id
		p.analysisTasks.Add(1)
		p.privateAnalysisPending[source.TrackID] = task.id
		return true, nil
	default:
		return false, nil
	}
}

func (p *Processor) runPrivateImportAnalysis(task analysisTask) {
	ctx, cancel := context.WithTimeout(p.analysisCtx, postStoreDispatchTimeout)
	req, admitted, err := p.claimPrivateAnalysisAtStart(ctx, task)
	cancel()
	if err != nil && p.analysisCtx.Err() == nil {
		log.Printf("Warning: private import analysis admission: %v", err)
	}
	if admitted {
		p.runAnalysis(req)
	}
}

func (p *Processor) claimPrivateAnalysisAtStart(ctx context.Context, task analysisTask) (analyzer.Request, bool, error) {
	// Only DrainPrivateImportAnalysis creates this variant, after checking both
	// immutable processor collaborators implement the private capabilities.
	name, version, err := readPrivateAnalyzerIdentity(ctx, p.analyzerClient.(privateAnalyzerInfoClient))
	if err != nil {
		return analyzer.Request{}, false, err
	}
	source, claim := *task.privateSource, uuid.New()
	req := analyzer.Request{
		TrackID: source.TrackID, StorageKey: source.Key, DurationMs: int(source.DurationMs), SchemaVersion: analyzer.SchemaVersion,
		ExpectedAnalyzer: name, ExpectedAnalyzerVersion: version,
		PrivateSource: &analyzer.PrivateSourceProof{SHA256: source.SHA256, ByteLength: source.ByteLength, Claim: claim.String()},
	}
	// Publish the exact possible claim before the SQL call so shutdown can
	// retire it by token. Queued hints never participate in terminal writes.
	p.analysisMu.Lock()
	if err := ctx.Err(); err != nil {
		p.analysisMu.Unlock()
		return analyzer.Request{}, false, err
	}
	p.analysisOutstanding[task.id] = req
	p.analysisMu.Unlock()
	admitted, err := p.analysisRepo.(privateImportAnalysisClaimer).ClaimPrivateImportAnalysis(ctx, source, claim, name, version)
	if err != nil {
		return analyzer.Request{}, false, fmt.Errorf("claim private analysis: %w", err)
	}
	return req, admitted, nil
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
