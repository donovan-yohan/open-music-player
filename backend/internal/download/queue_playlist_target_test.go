package download

import (
	"context"
	"testing"
)

func playlistTargetCandidate() SourceCandidate {
	return SourceCandidate{
		CandidateID: "youtube:target",
		Provider:    "youtube",
		SourceID:    "target",
		SourceURL:   "https://www.youtube.com/watch?v=target",
		Title:       "Target track",
	}
}

func TestEnqueueCandidateForPlaylistCarriesTheTargetAndLeavesImportFieldsEmpty(t *testing.T) {
	queue := newTestQueue(t)
	ctx := context.Background()

	job, err := queue.EnqueueCandidateForPlaylistWithID(ctx, "00000000-0000-4000-8000-0000000000a1", "user-target", playlistTargetCandidate(), nil, 42)
	if err != nil {
		t.Fatalf("enqueue for playlist: %v", err)
	}
	if job.PlaylistID != 42 || job.PlaylistPosition != 0 {
		t.Fatalf("job placement = (%d, %d), want playlist 42 at position 0", job.PlaylistID, job.PlaylistPosition)
	}
	// A playlist pick is not an import, so it must not look like one to the
	// processor or to import bookkeeping.
	if job.PlaylistImportItemID != 0 || job.PlaylistImportJobID != "" {
		t.Fatalf("job carries import metadata: item=%d job=%q", job.PlaylistImportItemID, job.PlaylistImportJobID)
	}

	stored, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("reload job: %v", err)
	}
	if stored.PlaylistID != 42 {
		t.Fatalf("stored playlist target = %d, want 42", stored.PlaylistID)
	}
}

func TestEnqueueCandidateWithIDStillHasNoPlaylistTarget(t *testing.T) {
	queue := newTestQueue(t)

	job, err := queue.EnqueueCandidateWithID(context.Background(), "00000000-0000-4000-8000-0000000000a2", "user-target", playlistTargetCandidate(), nil)
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if job.PlaylistID != 0 {
		t.Fatalf("generic enqueue playlist target = %d, want 0", job.PlaylistID)
	}
}

func TestEnsureCandidateForPlaylistAdoptsAnUnsetTargetAndKeepsAnExistingOne(t *testing.T) {
	queue := newTestQueue(t)
	ctx := context.Background()
	jobID := "00000000-0000-4000-8000-0000000000a3"

	if _, err := queue.EnqueueCandidateWithID(ctx, jobID, "user-target", playlistTargetCandidate(), nil); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	adopted, err := queue.EnsureCandidateForPlaylistWithID(ctx, jobID, "user-target", playlistTargetCandidate(), nil, 7)
	if err != nil {
		t.Fatalf("adopt playlist target: %v", err)
	}
	if adopted.PlaylistID != 7 {
		t.Fatalf("adopted playlist target = %d, want 7", adopted.PlaylistID)
	}
	stored, err := queue.GetJob(ctx, jobID)
	if err != nil || stored.PlaylistID != 7 {
		t.Fatalf("stored job = (%#v, %v), want playlist 7", stored, err)
	}

	// One download lands in one playlist: a later submission naming a different
	// playlist must not redirect a download that is already aimed somewhere.
	kept, err := queue.EnsureCandidateForPlaylistWithID(ctx, jobID, "user-target", playlistTargetCandidate(), nil, 9)
	if err != nil {
		t.Fatalf("re-ensure: %v", err)
	}
	if kept.PlaylistID != 7 {
		t.Fatalf("playlist target after second submission = %d, want the original 7", kept.PlaylistID)
	}
}

func TestEnsureCandidateForPlaylistRejectsAnotherUsersJob(t *testing.T) {
	queue := newTestQueue(t)
	ctx := context.Background()
	jobID := "00000000-0000-4000-8000-0000000000a4"

	if _, err := queue.EnqueueCandidateWithID(ctx, jobID, "user-owner", playlistTargetCandidate(), nil); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if _, err := queue.EnsureCandidateForPlaylistWithID(ctx, jobID, "user-intruder", playlistTargetCandidate(), nil, 7); err == nil {
		t.Fatal("ensure for another user's job = nil error, want rejection")
	}
	stored, err := queue.GetJob(ctx, jobID)
	if err != nil || stored.PlaylistID != 0 {
		t.Fatalf("stored job = (%#v, %v), want an untouched job", stored, err)
	}
}
