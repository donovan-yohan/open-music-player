package db

import (
	"encoding/json"
	"testing"
)

func TestTrackAnalysisProjectsIntoSongListingsAgainstPostgres(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	playlistRepo := NewPlaylistRepository(database)
	playEventRepo := NewPlayEventRepository(database)

	userID := seedPlayUser(t, database, "analysis-projection@example.test")
	trackID := seedPlayTrack(t, trackRepo, ctx, "Projection Artist", "Projection Song")
	if err := analysisRepo.StoreResult(ctx, trackID, AnalysisResult{
		SchemaVersion: 1,
		SummaryJSON: json.RawMessage(`{
			"bpm":{"value":120},
			"key":{"value":"Gm"},
			"camelot":{"value":"6A"}
		}`),
	}); err != nil {
		t.Fatalf("store analysis: %v", err)
	}
	if _, err := analysisRepo.SetOverrides(ctx, trackID, json.RawMessage(`{
		"bpm":{"value":128},
		"key":{"value":"Am"},
		"camelot":{"value":"8A"}
	}`)); err != nil {
		t.Fatalf("set analysis overrides: %v", err)
	}

	searchTracks, _, err := trackRepo.SearchRecordings(ctx, "Projection", 20, 0)
	if err != nil {
		t.Fatalf("search recordings: %v", err)
	}
	if len(searchTracks) != 1 {
		t.Fatalf("search tracks = %d, want 1", len(searchTracks))
	}
	assertProjectedTrackAnalysis(t, searchTracks[0])

	playlist := &Playlist{UserID: userID, Name: "Projection Playlist"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	if _, err := playlistRepo.AddTracks(ctx, playlist.ID, []int64{trackID}); err != nil {
		t.Fatalf("add playlist track: %v", err)
	}
	withTracks, err := playlistRepo.GetByIDWithTracks(ctx, playlist.ID)
	if err != nil {
		t.Fatalf("get playlist with tracks: %v", err)
	}
	if len(withTracks.Tracks) != 1 {
		t.Fatalf("playlist tracks = %d, want 1", len(withTracks.Tracks))
	}
	assertProjectedTrackAnalysis(t, withTracks.Tracks[0])

	if err := playEventRepo.RecordPlay(ctx, userID, trackID, "playlist", "projection"); err != nil {
		t.Fatalf("record play: %v", err)
	}
	recent, err := playEventRepo.RecentlyPlayed(ctx, userID, 10, 0)
	if err != nil {
		t.Fatalf("recently played: %v", err)
	}
	history, err := playEventRepo.PlayHistory(ctx, userID, 10, 0)
	if err != nil {
		t.Fatalf("play history: %v", err)
	}
	top, err := playEventRepo.TopTracks(ctx, userID, 30, 10)
	if err != nil {
		t.Fatalf("top tracks: %v", err)
	}
	if len(recent) != 1 || len(history) != 1 || len(top) != 1 {
		t.Fatalf(
			"play listing lengths recent=%d history=%d top=%d, want 1 each",
			len(recent),
			len(history),
			len(top),
		)
	}
	assertProjectedTrackAnalysis(t, recent[0].Track)
	assertProjectedTrackAnalysis(t, history[0].Track)
	assertProjectedTrackAnalysis(t, top[0].Track)
}

func assertProjectedTrackAnalysis(t *testing.T, track Track) {
	t.Helper()
	if !track.AnalysisStatus.Valid || track.AnalysisStatus.String != AnalysisStatusAnalyzed {
		t.Fatalf("analysis status = %#v, want %q", track.AnalysisStatus, AnalysisStatusAnalyzed)
	}

	var summary map[string]map[string]any
	if err := json.Unmarshal(track.AnalysisSummary, &summary); err != nil {
		t.Fatalf("decode analysis summary: %v", err)
	}
	if got := summary["bpm"]["value"]; got != float64(128) {
		t.Fatalf("projected bpm = %#v, want 128 override", got)
	}
	if got := summary["key"]["value"]; got != "Am" {
		t.Fatalf("projected key = %#v, want Am override", got)
	}
	if got := summary["camelot"]["value"]; got != "8A" {
		t.Fatalf("projected Camelot key = %#v, want 8A override", got)
	}
}
