package playlistsync

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type fakeAdapter struct {
	calls     int
	requested string
	snapshot  Snapshot
	err       error
}

func (a *fakeAdapter) Resolve(_ context.Context, sourceURL string) (Snapshot, error) {
	a.calls++
	a.requested = sourceURL
	return a.snapshot, a.err
}

type fakeStore struct {
	listCalls  int
	applyCalls int
	playlistID int64
	source     Source
	mappings   []SourceEntryMapping
	plan       ReconciliationPlan
	listErr    error
	applyErr   error
}

func (s *fakeStore) ListSourceEntryMappings(_ context.Context, playlistID int64, source Source) ([]SourceEntryMapping, error) {
	s.listCalls++
	s.playlistID = playlistID
	s.source = source
	return s.mappings, s.listErr
}

func (s *fakeStore) ApplyReconciliation(_ context.Context, playlistID int64, plan ReconciliationPlan) error {
	s.applyCalls++
	s.playlistID = playlistID
	s.plan = plan
	return s.applyErr
}

func validSnapshot(entries ...Entry) Snapshot {
	return Snapshot{
		Source: Source{
			Provider:     "youtube",
			PlaylistID:   "PL123",
			CanonicalURL: "https://www.youtube.com/playlist?list=PL123",
			Metadata:     SourceMetadata{Title: "Source playlist"},
		},
		Complete: true,
		Entries:  entries,
	}
}

func entry(stableID, title string) Entry {
	return Entry{
		StableID:  stableID,
		SourceURL: "https://www.youtube.com/watch?v=" + stableID,
		Metadata:  EntryMetadata{Title: title},
	}
}

func TestReconcilerUsesResolvedSourceIdentityAndCanonicalURL(t *testing.T) {
	snapshot := validSnapshot(entry("video-1", "First"))
	adapter := &fakeAdapter{snapshot: snapshot}
	store := &fakeStore{}

	result, err := NewReconciler(adapter, store).Reconcile(context.Background(), 42, "https://m.youtube.com/playlist?list=PL123")
	if err != nil {
		t.Fatal(err)
	}
	if adapter.requested != "https://m.youtube.com/playlist?list=PL123" || adapter.calls != 1 {
		t.Fatalf("adapter request/calls = %q/%d", adapter.requested, adapter.calls)
	}
	if store.source != snapshot.Source {
		t.Fatalf("store source = %#v, want %#v", store.source, snapshot.Source)
	}
	if result.Added != 1 || store.plan.Source != snapshot.Source {
		t.Fatalf("result/plan = %#v/%#v", result, store.plan)
	}
}

func TestReconcilerRejectsIncompleteSnapshotBeforeStore(t *testing.T) {
	adapter := &fakeAdapter{snapshot: Snapshot{Source: validSnapshot().Source}}
	store := &fakeStore{}
	_, err := NewReconciler(adapter, store).Reconcile(context.Background(), 42, "https://example.test/playlist")
	if !errors.Is(err, ErrIncompleteSnapshot) {
		t.Fatalf("Reconcile error = %v, want ErrIncompleteSnapshot", err)
	}
	if store.listCalls != 0 || store.applyCalls != 0 {
		t.Fatalf("store calls = list %d apply %d, want 0/0", store.listCalls, store.applyCalls)
	}
}

func TestReconcilerNoopSkipsMutation(t *testing.T) {
	snapshot := validSnapshot(entry("video-1", "First"), entry("video-2", "Second"))
	store := &fakeStore{mappings: []SourceEntryMapping{
		{StableEntryID: "video-1", Position: 0},
		{StableEntryID: "video-2", Position: 1},
	}}

	result, err := NewReconciler(&fakeAdapter{snapshot: snapshot}, store).Reconcile(context.Background(), 42, snapshot.Source.CanonicalURL)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Noop || result.Reused != 2 || store.applyCalls != 0 {
		t.Fatalf("result/apply calls = %#v/%d", result, store.applyCalls)
	}
}

func TestPlanReconciliationPlansProviderReorder(t *testing.T) {
	snapshot := validSnapshot(entry("video-2", "Second"), entry("video-1", "First"))
	plan, err := PlanReconciliation(snapshot, []SourceEntryMapping{
		{StableEntryID: "video-1", Position: 0},
		{StableEntryID: "video-2", Position: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Reordered || plan.Noop || len(plan.Additions) != 0 || len(plan.MembershipRemovals) != 0 {
		t.Fatalf("plan = %#v", plan)
	}
	if want := []string{"video-2", "video-1"}; !reflect.DeepEqual(plan.OrderedEntryIDs, want) {
		t.Fatalf("ordered IDs = %#v, want %#v", plan.OrderedEntryIDs, want)
	}
}

func TestPlanReconciliationPlansMembershipRemovalOnly(t *testing.T) {
	trackID := int64(77)
	snapshot := validSnapshot(entry("video-1", "First"))
	plan, err := PlanReconciliation(snapshot, []SourceEntryMapping{
		{StableEntryID: "video-1", Position: 0},
		{StableEntryID: "video-2", TrackID: &trackID, Position: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Noop || plan.Reordered || len(plan.Additions) != 0 || len(plan.MembershipRemovals) != 1 {
		t.Fatalf("plan = %#v", plan)
	}
	removal := plan.MembershipRemovals[0]
	if removal.StableEntryID != "video-2" || removal.TrackID == nil || *removal.TrackID != trackID {
		t.Fatalf("membership removal = %#v", removal)
	}
}

func TestPlanReconciliationPreservesFirstDuplicateAndReportsLaterEntry(t *testing.T) {
	snapshot := validSnapshot(
		entry("video-1", "First occurrence"),
		entry("video-2", "Second"),
		entry("video-1", "Later occurrence"),
	)
	plan, err := PlanReconciliation(snapshot, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Additions) != 2 || plan.Additions[0].Metadata.Title != "First occurrence" || len(plan.SkippedDuplicates) != 1 {
		t.Fatalf("plan = %#v", plan)
	}
	if duplicate := plan.SkippedDuplicates[0]; duplicate.StableEntryID != "video-1" || duplicate.FirstPosition != 0 || duplicate.DuplicatePosition != 2 {
		t.Fatalf("duplicate = %#v", duplicate)
	}
}
