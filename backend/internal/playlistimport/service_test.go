package playlistimport

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
)

func TestStartImportReusesExistingTracksQueuesNewTracksAndPreservesSourceOrder(t *testing.T) {
	ctx := context.Background()
	userID := uuid.MustParse("11111111-1111-1111-1111-111111111111")
	store := newFakeStore()
	playlists := &fakePlaylists{}
	tracks := &fakeTrackSources{bySourceID: map[string]*db.Track{"known": {ID: 42, Title: "Known"}}}
	library := &fakeLibrary{}
	downloader := &fakeDownloader{}
	selections := &fakeSourceSelections{}
	ingestion := &fakeTrustedIngestion{}
	enumerator := &fakeEnumerator{entries: []Entry{
		{SourceID: "known", SourceURL: "https://www.youtube.com/watch?v=known", Title: "Known"},
		{SourceID: "new", SourceURL: "https://www.youtube.com/watch?v=new", Title: "New"},
		{SourceID: "gone", SourceURL: "https://www.youtube.com/watch?v=gone", Title: "Gone", Unavailable: true, Error: "private video"},
	}}
	service := NewService(Config{Store: store, Playlists: playlists, Tracks: tracks, Library: library, Downloader: downloader, Selections: selections, Ingestion: ingestion, Enumerator: enumerator, MaxItems: 10})

	result, err := service.StartImport(ctx, userID, ImportRequest{URL: "https://music.youtube.com/playlist?list=PLfixture", Name: "mix"})
	if err != nil {
		t.Fatalf("StartImport returned error: %v", err)
	}

	if result.Job.PlaylistID != 1001 {
		t.Fatalf("PlaylistID = %d, want created playlist 1001", result.Job.PlaylistID)
	}
	if result.Job.TotalItems != 3 || result.Job.ImportedItems != 1 || result.Job.QueuedItems != 1 || result.Job.FailedItems != 1 || result.Job.Status != JobStatusImporting {
		t.Fatalf("unexpected job counts/status: %+v", result.Job)
	}
	if len(playlists.added) != 1 || playlists.added[0].trackID != 42 || playlists.added[0].position != 0 {
		t.Fatalf("existing track was not inserted at source position 0: %+v", playlists.added)
	}
	if got := library.added[42]; got != userID {
		t.Fatalf("existing track was not added/reused in user library; got %s", got)
	}
	if len(downloader.jobs) != 1 {
		t.Fatalf("queued downloads = %d, want 1", len(downloader.jobs))
	}
	job := downloader.jobs[0]
	if job.SourceID != "new" || job.PlaylistImportJobID != result.Job.ID.String() || job.PlaylistID != 1001 || job.PlaylistPosition != 1 {
		t.Fatalf("queued job missing playlist import metadata: %+v", job)
	}
	itemsBySource := map[string]ImportItem{}
	for _, item := range result.Items {
		itemsBySource[item.SourceID] = item
	}
	if itemsBySource["known"].Status != ItemStatusImported || !itemsBySource["known"].TrackID.Valid || itemsBySource["known"].TrackID.Int64 != 42 {
		t.Fatalf("known item not imported/reused: %+v", itemsBySource["known"])
	}
	if itemsBySource["new"].Status != ItemStatusQueued || !itemsBySource["new"].DownloadJobID.Valid {
		t.Fatalf("new item not queued: %+v", itemsBySource["new"])
	}
	if itemsBySource["gone"].Status != ItemStatusFailed || itemsBySource["gone"].Error.String != "private video" {
		t.Fatalf("unavailable item not tracked as failed: %+v", itemsBySource["gone"])
	}
	if len(selections.created) != 2 || len(selections.attachedTracks) != 1 || len(ingestion.persisted) != 1 {
		t.Fatalf("trusted decisions/persistence = %d/%d/%d, want 2/1/1", len(selections.created), len(selections.attachedTracks), len(ingestion.persisted))
	}
}

func TestStartImportRejectsPlaylistsOverLimitBeforeQueueing(t *testing.T) {
	ctx := context.Background()
	store := newFakeStore()
	dl := &fakeDownloader{}
	service := NewService(Config{
		Store:      store,
		Playlists:  &fakePlaylists{},
		Tracks:     &fakeTrackSources{bySourceID: map[string]*db.Track{}},
		Downloader: dl,
		Enumerator: &fakeEnumerator{entries: []Entry{{SourceID: "1", SourceURL: "https://youtu.be/1"}, {SourceID: "2", SourceURL: "https://youtu.be/2"}}},
		MaxItems:   1,
	})

	_, err := service.StartImport(ctx, uuid.New(), ImportRequest{URL: "https://www.youtube.com/playlist?list=PLfixture"})
	if !errors.Is(err, ErrLimitExceeded) {
		t.Fatalf("StartImport error = %v, want ErrLimitExceeded", err)
	}
	if len(dl.jobs) != 0 {
		t.Fatalf("downloads queued despite limit failure: %d", len(dl.jobs))
	}
}

func TestValidatePlaylistURLRejectsCousinHosts(t *testing.T) {
	tests := []struct {
		name    string
		rawURL  string
		wantErr bool
	}{
		{name: "youtube exact", rawURL: "https://youtube.com/playlist?list=PLfixture"},
		{name: "youtube subdomain", rawURL: "https://www.youtube.com/playlist?list=PLfixture"},
		{name: "music youtube", rawURL: "https://music.youtube.com/playlist?list=PLfixture"},
		{name: "youtu be exact", rawURL: "https://youtu.be/fixture"},
		{name: "youtu be subdomain", rawURL: "https://m.youtu.be/fixture"},
		{name: "youtube substring attacker", rawURL: "https://youtube.com.attacker.example/playlist?list=PLfixture", wantErr: true},
		{name: "youtu be substring attacker", rawURL: "https://youtu.be.attacker.example/fixture", wantErr: true},
		{name: "youtube cousin", rawURL: "https://evil-youtube.com/playlist?list=PLfixture", wantErr: true},
		{name: "non youtube", rawURL: "https://example.com/playlist?list=PLfixture", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validatePlaylistURL(tt.rawURL)
			if tt.wantErr && !errors.Is(err, ErrInvalidURL) {
				t.Fatalf("validatePlaylistURL(%q) error = %v, want ErrInvalidURL", tt.rawURL, err)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("validatePlaylistURL(%q) returned error: %v", tt.rawURL, err)
			}
		})
	}
}

func TestStartImportMarksJobFailedWhenCreateItemFails(t *testing.T) {
	ctx := context.Background()
	store := newFakeStore()
	store.createItemErr = errors.New("insert import item failed")
	service := NewService(Config{
		Store:      store,
		Playlists:  &fakePlaylists{},
		Tracks:     &fakeTrackSources{bySourceID: map[string]*db.Track{}},
		Downloader: &fakeDownloader{},
		Enumerator: &fakeEnumerator{entries: []Entry{{SourceID: "new", SourceURL: "https://www.youtube.com/watch?v=new", Title: "New"}}},
		MaxItems:   10,
	})

	_, err := service.StartImport(ctx, uuid.MustParse("11111111-1111-1111-1111-111111111111"), ImportRequest{URL: "https://www.youtube.com/playlist?list=PLfixture"})
	if err == nil || !strings.Contains(err.Error(), "create playlist import item") {
		t.Fatalf("StartImport error = %v, want create item failure", err)
	}
	if len(store.jobs) != 1 {
		t.Fatalf("jobs created = %d, want 1", len(store.jobs))
	}
	for _, job := range store.jobs {
		if job.Status != JobStatusFailed {
			t.Fatalf("job status = %q, want %q", job.Status, JobStatusFailed)
		}
		if !job.Error.Valid || !strings.Contains(job.Error.String, "create playlist import item") {
			t.Fatalf("job error = %+v, want create item failure", job.Error)
		}
	}
}

func TestStartImportFailsItemBeforeEnqueueWhenTrustedJobPersistenceFails(t *testing.T) {
	store := newFakeStore()
	downloader := &fakeDownloader{}
	selections := &fakeSourceSelections{}
	ingestion := &fakeTrustedIngestion{createErr: errors.New("persist durable job")}
	service := NewService(Config{Store: store, Playlists: &fakePlaylists{}, Tracks: &fakeTrackSources{bySourceID: map[string]*db.Track{}}, Downloader: downloader, Selections: selections, Ingestion: ingestion, Enumerator: &fakeEnumerator{entries: []Entry{{SourceID: "new", SourceURL: "https://www.youtube.com/watch?v=new", Title: "New"}}}})
	result, err := service.StartImport(context.Background(), uuid.MustParse("11111111-1111-1111-1111-111111111111"), ImportRequest{URL: "https://www.youtube.com/playlist?list=PLfixture"})
	if err != nil {
		t.Fatal(err)
	}
	if len(downloader.jobs) != 0 || len(selections.created) != 1 || result.Items[0].Status != ItemStatusFailed {
		t.Fatalf("download/decision/item = %d/%d/%+v", len(downloader.jobs), len(selections.created), result.Items[0])
	}
}

func TestStartImportNormalizesURLOnlyEntriesAndKeepsPlaylistIntentQualityHonest(t *testing.T) {
	store := newFakeStore()
	selections := &fakeSourceSelections{}
	service := NewService(Config{Store: store, Playlists: &fakePlaylists{}, Tracks: &fakeTrackSources{bySourceID: map[string]*db.Track{}}, Downloader: &fakeDownloader{}, Selections: selections, Ingestion: &fakeTrustedIngestion{}, Enumerator: &fakeEnumerator{entries: []Entry{{SourceURL: "https://youtu.be/dQw4w9WgXcQ", Title: "URL only"}}}})
	result, err := service.StartImport(context.Background(), uuid.New(), ImportRequest{URL: "https://www.youtube.com/playlist?list=PLfixture"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Items[0].SourceID != "dQw4w9WgXcQ" || len(selections.candidates) != 1 {
		t.Fatalf("url-only item = %#v candidates=%#v", result.Items[0], selections.candidates)
	}
	quality := selections.candidates[0].SourceQuality
	if selections.created[0].Origin != db.SourceSelectionOriginPlaylistExplicit || quality.Score != 0 || quality.Confidence != 0 || quality.Classification != "unknown" || quality.Recommendation != "review" {
		t.Fatalf("playlist quality = %#v decision=%#v", quality, selections.created[0])
	}
}

func TestStartImportRejectsUnresolvableURLOnlyEntryBeforeTrustedDecision(t *testing.T) {
	store := newFakeStore()
	selections := &fakeSourceSelections{}
	service := NewService(Config{Store: store, Playlists: &fakePlaylists{}, Tracks: &fakeTrackSources{bySourceID: map[string]*db.Track{}}, Downloader: &fakeDownloader{}, Selections: selections, Ingestion: &fakeTrustedIngestion{}, Enumerator: &fakeEnumerator{entries: []Entry{{SourceURL: "https://www.youtube.com/watch", Title: "Broken"}}}})
	result, err := service.StartImport(context.Background(), uuid.New(), ImportRequest{URL: "https://www.youtube.com/playlist?list=PLfixture"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Items[0].Status != ItemStatusFailed || !strings.Contains(result.Items[0].Error.String, "does not resolve") || len(selections.created) != 0 {
		t.Fatalf("url-only rejection = %#v decisions=%d", result.Items[0], len(selections.created))
	}
}

func TestStartImportRetriesQueuedItemPersistenceWithoutDuplicateDownload(t *testing.T) {
	store := newFakeStore()
	store.markQueuedErrs = []error{errors.New("temporary item store failure")}
	downloader := &fakeDownloader{}
	service := NewService(Config{Store: store, Playlists: &fakePlaylists{}, Tracks: &fakeTrackSources{bySourceID: map[string]*db.Track{}}, Downloader: downloader, Selections: &fakeSourceSelections{}, Ingestion: &fakeTrustedIngestion{}, Enumerator: &fakeEnumerator{entries: []Entry{{SourceID: "new", SourceURL: "https://www.youtube.com/watch?v=new", Title: "New"}}}})
	result, err := service.StartImport(context.Background(), uuid.New(), ImportRequest{URL: "https://www.youtube.com/playlist?list=PLfixture"})
	if err != nil || result.Items[0].Status != ItemStatusQueued || len(downloader.jobs) != 1 || store.markQueuedCalls != 2 {
		t.Fatalf("queued retry result=%#v err=%v downloads=%d calls=%d", result, err, len(downloader.jobs), store.markQueuedCalls)
	}
}

func TestStartImportPropagatesPersistentQueuedItemStoreFailure(t *testing.T) {
	store := newFakeStore()
	store.markQueuedErrs = []error{errors.New("first failure"), errors.New("retry failure")}
	downloader := &fakeDownloader{}
	service := NewService(Config{Store: store, Playlists: &fakePlaylists{}, Tracks: &fakeTrackSources{bySourceID: map[string]*db.Track{}}, Downloader: downloader, Selections: &fakeSourceSelections{}, Ingestion: &fakeTrustedIngestion{}, Enumerator: &fakeEnumerator{entries: []Entry{{SourceID: "new", SourceURL: "https://www.youtube.com/watch?v=new", Title: "New"}}}})
	_, err := service.StartImport(context.Background(), uuid.New(), ImportRequest{URL: "https://www.youtube.com/playlist?list=PLfixture"})
	if err == nil || !strings.Contains(err.Error(), "mark playlist import item queued") || len(downloader.jobs) != 1 || store.markQueuedCalls != 2 {
		t.Fatalf("persistent queue-item error=%v downloads=%d calls=%d", err, len(downloader.jobs), store.markQueuedCalls)
	}
}

type fakeStore struct {
	jobs            map[uuid.UUID]*ImportJob
	items           map[int64]*ImportItem
	next            int64
	createItemErr   error
	markQueuedErrs  []error
	markQueuedCalls int
}

func newFakeStore() *fakeStore {
	return &fakeStore{jobs: map[uuid.UUID]*ImportJob{}, items: map[int64]*ImportItem{}, next: 1}
}

func (s *fakeStore) CreateJob(_ context.Context, job *ImportJob) error {
	now := time.Now()
	job.CreatedAt = now
	job.UpdatedAt = now
	copy := *job
	s.jobs[job.ID] = &copy
	return nil
}

func (s *fakeStore) GetJob(_ context.Context, id uuid.UUID) (*ImportJob, error) {
	job := s.jobs[id]
	if job == nil {
		return nil, ErrNotFound
	}
	copy := *job
	return &copy, nil
}

func (s *fakeStore) ListItems(_ context.Context, jobID uuid.UUID) ([]ImportItem, error) {
	out := []ImportItem{}
	for _, item := range s.items {
		if item.ImportJobID == jobID {
			out = append(out, *item)
		}
	}
	return out, nil
}

func (s *fakeStore) CreateItem(_ context.Context, item *ImportItem) error {
	if s.createItemErr != nil {
		return s.createItemErr
	}
	item.ID = s.next
	s.next++
	copy := *item
	s.items[item.ID] = &copy
	return nil
}
func (s *fakeStore) MarkItemQueued(_ context.Context, itemID int64, downloadJobID string) error {
	s.markQueuedCalls++
	if len(s.markQueuedErrs) > 0 {
		err := s.markQueuedErrs[0]
		s.markQueuedErrs = s.markQueuedErrs[1:]
		return err
	}
	item := s.items[itemID]
	item.Status = ItemStatusQueued
	item.DownloadJobID = sql.NullString{String: downloadJobID, Valid: true}
	return nil
}
func (s *fakeStore) MarkItemImported(_ context.Context, itemID int64, trackID int64) error {
	item := s.items[itemID]
	item.Status = ItemStatusImported
	item.TrackID = sql.NullInt64{Int64: trackID, Valid: true}
	return nil
}
func (s *fakeStore) MarkItemFailed(_ context.Context, itemID int64, message string) error {
	item := s.items[itemID]
	item.Status = ItemStatusFailed
	item.Error = sql.NullString{String: message, Valid: true}
	return nil
}
func (s *fakeStore) MarkJobFailed(_ context.Context, jobID uuid.UUID, message string) error {
	job := s.jobs[jobID]
	job.Status = JobStatusFailed
	job.Error = sql.NullString{String: message, Valid: true}
	return nil
}
func (s *fakeStore) RefreshJobCounts(_ context.Context, jobID uuid.UUID) error {
	job := s.jobs[jobID]
	job.TotalItems, job.ImportedItems, job.QueuedItems, job.FailedItems, job.SkippedItems = 0, 0, 0, 0, 0
	for _, item := range s.items {
		if item.ImportJobID != jobID {
			continue
		}
		job.TotalItems++
		switch item.Status {
		case ItemStatusImported:
			job.ImportedItems++
		case ItemStatusQueued, ItemStatusPending:
			job.QueuedItems++
		case ItemStatusFailed:
			job.FailedItems++
		case ItemStatusSkippedDuplicate:
			job.SkippedItems++
		}
	}
	if job.QueuedItems > 0 {
		job.Status = JobStatusImporting
	} else if job.FailedItems > 0 && job.ImportedItems+job.SkippedItems == 0 {
		job.Status = JobStatusFailed
	} else if job.FailedItems > 0 {
		job.Status = JobStatusPartialFailure
	} else {
		job.Status = JobStatusComplete
	}
	return nil
}

type fakePlaylists struct {
	added []struct {
		trackID  int64
		position int
	}
}

func (p *fakePlaylists) Create(_ context.Context, playlist *db.Playlist) error {
	playlist.ID = 1001
	return nil
}
func (p *fakePlaylists) GetByID(_ context.Context, id int64) (*db.Playlist, error) {
	return &db.Playlist{ID: id, UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111")}, nil
}
func (p *fakePlaylists) AddTrackAtPosition(_ context.Context, _ int64, trackID int64, position int) error {
	p.added = append(p.added, struct {
		trackID  int64
		position int
	}{trackID: trackID, position: position})
	return nil
}

type fakeTrackSources struct{ bySourceID map[string]*db.Track }

func (s *fakeTrackSources) FindTrackBySource(_ context.Context, _, sourceID, _ string) (*db.Track, error) {
	if t := s.bySourceID[sourceID]; t != nil {
		return t, nil
	}
	return nil, db.ErrTrackNotFound
}

type fakeLibrary struct{ added map[int64]uuid.UUID }

func (l *fakeLibrary) AddTrackToLibrary(_ context.Context, userID uuid.UUID, trackID int64) (*db.LibraryEntry, error) {
	if l.added == nil {
		l.added = map[int64]uuid.UUID{}
	}
	l.added[trackID] = userID
	return &db.LibraryEntry{UserID: userID, TrackID: trackID}, nil
}

type fakeDownloader struct{ jobs []*download.DownloadJob }

func (d *fakeDownloader) EnqueuePlaylistImportItemWithID(_ context.Context, jobID, userID string, candidate download.SourceCandidate, importJobID string, importItemID int64, playlistID int64, playlistPosition int) (*download.DownloadJob, error) {
	job := &download.DownloadJob{ID: jobID, UserID: userID, URL: candidate.SourceURL, SourceType: candidate.Provider, SourceID: candidate.SourceID, Title: candidate.Title, PlaylistImportJobID: importJobID, PlaylistImportItemID: importItemID, PlaylistID: playlistID, PlaylistPosition: playlistPosition}
	d.jobs = append(d.jobs, job)
	return job, nil
}

type fakeSourceSelections struct {
	created        []*db.SourceSelectionDecision
	attachedTracks []int64
	candidates     []db.TrustedSourceSelectionCandidate
}

func (s *fakeSourceSelections) CreateTrustedSourceSelectionDecision(_ context.Context, userID uuid.UUID, origin string, candidate db.TrustedSourceSelectionCandidate, _ string) (*db.SourceSelectionDecision, error) {
	decision := &db.SourceSelectionDecision{ID: uuid.New(), UserID: userID, Origin: origin, SelectedCandidateID: candidate.CandidateID}
	s.created = append(s.created, decision)
	s.candidates = append(s.candidates, candidate)
	return decision, nil
}
func (s *fakeSourceSelections) AttachTrackForUser(_ context.Context, _ uuid.UUID, _ uuid.UUID, trackID int64) error {
	s.attachedTracks = append(s.attachedTracks, trackID)
	return nil
}

type fakeTrustedIngestion struct {
	persisted []*db.SourceSelectionDownload
	createErr error
}

func (s *fakeTrustedIngestion) CreateDownloadForDecision(_ context.Context, userID uuid.UUID, decision *db.SourceSelectionDecision, candidate download.SourceCandidate) (*db.SourceSelectionDownload, error) {
	if s.createErr != nil {
		return nil, s.createErr
	}
	persisted := &db.SourceSelectionDownload{Decision: decision, Job: &download.DownloadJob{ID: uuid.NewString(), UserID: userID.String(), Status: download.StatusQueued}, Candidate: candidate}
	s.persisted = append(s.persisted, persisted)
	return persisted, nil
}
func (s *fakeTrustedIngestion) EnqueueTrustedPlaylistDownload(ctx context.Context, persisted *db.SourceSelectionDownload, enqueuer db.SourceSelectionPlaylistDownloadEnqueuer, importJobID string, importItemID, playlistID int64, playlistPosition int) (*download.DownloadJob, error) {
	return enqueuer.EnqueuePlaylistImportItemWithID(ctx, persisted.Job.ID, persisted.Job.UserID, persisted.Candidate, importJobID, importItemID, playlistID, playlistPosition)
}

type fakeEnumerator struct{ entries []Entry }

func (e *fakeEnumerator) Enumerate(_ context.Context, _ string, _ int) (PlaylistMetadata, []Entry, error) {
	return PlaylistMetadata{Title: "Fixture"}, e.entries, nil
}
