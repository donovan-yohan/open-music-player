package api

import (
	"context"
	"fmt"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/weekly"
)

func TestWeeklyResourceLimitUsesContractConflictEnvelope(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	page := f.ok("GET", "weekly", nil, "")
	repo := db.NewWeeklyRepository(f.database)
	if e := repo.Update(context.Background(), f.user, func(st *weekly.State) error {
		for n := 0; n < weekly.MaxFeedback; n++ {
			id := fmt.Sprintf("%08x-0000-4000-8000-000000000001", n)
			st.Feedback[id] = weekly.FeedbackEntry{Feedback: weekly.Feedback{RecordingMbid: id, Vote: "none", ProfileEpoch: st.Epoch}, Title: "Synthetic retained tombstone", Artist: "Artist A", ArtistMbids: []string{weeklyArtistA}, PrimaryArtistMbid: weeklyArtistA}
		}
		return nil
	}); e != nil {
		t.Fatal(e)
	}
	code, conflict := f.request("PUT", "feedback/"+weeklyRecordingA, map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": page["profileEpoch"], "batchId": page["batchId"]}, "feedback-resource-limit")
	if code != 409 || conflict["code"] != "RESOURCE_LIMIT" || conflict["detail"] == nil || conflict["current"] == nil || conflict["profileEpoch"] != page["profileEpoch"] {
		t.Fatal("resource bound returned a different 409 wire shape", conflict)
	}
	current := f.ok("GET", "feedback/"+weeklyRecordingA, nil, "")
	if current["revision"] != float64(0) || current["vote"] != "none" {
		t.Fatal("resource refusal mutated feedback")
	}
}
