package api

import (
	"context"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

type qualitySelectionStore struct {
	quality      []db.Track
	other        []db.Track
	qualityLimit int
	otherLimit   int
}

func (s *qualitySelectionStore) GetByID(context.Context, int64) (*db.Track, error) {
	return nil, db.ErrTrackNotFound
}

func (s *qualitySelectionStore) GetAudioQualityMaintenanceCandidates(_ context.Context, limit int) ([]db.Track, error) {
	s.qualityLimit = limit
	return s.quality[:min(limit, len(s.quality))], nil
}

func (s *qualitySelectionStore) GetMaintenanceCandidates(_ context.Context, _, _ bool, _ time.Duration, limit int) ([]db.Track, error) {
	s.otherLimit = limit
	return s.other[:min(limit, len(s.other))], nil
}

func TestCombinedMaintenanceReservesBoundedProgressForBothCandidateClasses(t *testing.T) {
	store := &qualitySelectionStore{
		quality: []db.Track{{ID: 1}, {ID: 2}, {ID: 3}},
		other:   []db.Track{{ID: 1}, {ID: 2}, {ID: 10}, {ID: 11}, {ID: 12}},
	}
	handler := &MaintenanceHandlers{tracks: store}
	tracks, err := handler.selectRepairTracks(context.Background(), nil, true, true, true, time.Minute, 4)
	if err != nil {
		t.Fatalf("selectRepairTracks: %v", err)
	}
	if len(tracks) != 4 || tracks[0].ID != 1 || tracks[1].ID != 2 ||
		tracks[2].ID != 10 || tracks[3].ID != 11 {
		t.Fatalf("combined tracks = %+v, want two quality and two normal candidates", tracks)
	}
	if store.qualityLimit != 2 || store.otherLimit != 4 {
		t.Fatalf("candidate limits = quality:%d other:%d, want 2/4", store.qualityLimit, store.otherLimit)
	}
}

func TestCombinedMaintenanceRejectsLimitTooSmallForFairProgress(t *testing.T) {
	handler := &MaintenanceHandlers{tracks: &qualitySelectionStore{}}
	_, err := handler.selectRepairTracks(context.Background(), nil, true, false, true, time.Minute, 1)
	if err == nil {
		t.Fatal("combined limit=1 was accepted despite being unable to reserve both candidate classes")
	}
}
