package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/weekly"
)

func weeklyStoredState(t *testing.T, f *weeklyFixture) string {
	t.Helper()
	var raw string
	if err := f.database.QueryRow(`SELECT state::text FROM weekly_profiles WHERE user_id=$1`, f.user).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	return raw
}

func weeklyLimit(t *testing.T, code int, got map[string]any, epoch, revision, filter int64, current any) {
	t.Helper()
	want, err := json.Marshal(current)
	if err != nil {
		t.Fatal(err)
	}
	var expected any
	if err = json.Unmarshal(want, &expected); err != nil {
		t.Fatal(err)
	}
	actual, _ := json.Marshal(got["current"])
	canonical, _ := json.Marshal(expected)
	if code != 409 || got["code"] != "RESOURCE_LIMIT" || got["detail"] == nil || got["message"] != nil || got["profileEpoch"] != float64(epoch) || got["preferenceRevision"] != float64(revision) || got["filterRevision"] != float64(filter) || string(actual) != string(canonical) {
		t.Fatalf("not an authoritative pre-write conflict: %#v, current want %s", got, canonical)
	}
}

func TestWeeklyArtistCapAllowsCorrectionReplayAndReset(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	repo := db.NewWeeklyRepository(f.database)
	if err := repo.Update(context.Background(), f.user, func(st *weekly.State) error {
		for n := 0; len(st.Artists) < weekly.MaxArtists; n++ {
			id := fmt.Sprintf("%08x-0000-4000-8000-000000000002", n)
			st.Artists[id] = weekly.Artist{ArtistMbid: id, Name: "Synthetic neutral retained artist", Revision: 1}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	before := weeklyStoredState(t, f)
	body := map[string]any{"resource": "artist", "artistMbid": weeklyArtistB, "interested": true, "blocked": false, "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": 0}
	code, got := f.request("PUT", "preferences", body, "artist-resource-limit")
	weeklyLimit(t, code, got, 0, 1, 1, weekly.Artist{ArtistMbid: weeklyArtistB})
	if weeklyStoredState(t, f) != before {
		t.Fatal("artist capacity refusal persisted state")
	}
	body["artistMbid"], body["expectedRevision"], body["interested"] = weeklyArtistA, 1, false
	ack := f.ok("PUT", "preferences", body, "artist-cap-correction")
	if ack["resourceRevision"] != float64(2) || ack["artist"].(map[string]any)["interested"] != false {
		t.Fatal(ack)
	}
	if f.ok("PUT", "preferences", body, "artist-cap-replay")["replayed"] != true {
		t.Fatal("accepted correction not replayable at cap")
	}
	body["mutationId"] = uuid.NewString()
	code, stale := f.request("PUT", "preferences", body, "")
	if code != 409 || stale["code"] != "REVISION_CONFLICT" {
		t.Fatal(stale)
	}
	f.ok("POST", "preferences/reset", map[string]any{"scope": "discovery_preferences", "mutationId": uuid.NewString(), "expectedRevision": ack["preferenceRevision"], "profileEpoch": 0}, "")
	f.artist(weeklyArtistB)
}

// Fill with bounded metadata and neutral tombstones, not a huge invalid field.
// This reaches the actual JSON byte ceiling well below the resource-count cap.
func weeklyNearByteCeiling(t *testing.T, f *weeklyFixture) {
	t.Helper()
	err := db.NewWeeklyRepository(f.database).Update(context.Background(), f.user, func(st *weekly.State) error {
		const target = 1799950
		raw, err := json.Marshal(st)
		if err != nil {
			return err
		}
		size := len(raw)
		for n := 0; ; n++ {
			id := fmt.Sprintf("%08x-0000-4000-8000-000000000003", n)
			entry := weekly.FeedbackEntry{Feedback: weekly.Feedback{RecordingMbid: id, Vote: "none", Revision: 1, ProfileEpoch: st.Epoch}, Artist: strings.Repeat("A", 500), ArtistMbids: []string{weeklyArtistA}, PrimaryArtistMbid: weeklyArtistA}
			encoded, err := json.Marshal(entry)
			if err != nil {
				return err
			}
			cost := len(encoded) + len(id) + 3
			if len(st.Feedback) > 0 {
				cost++
			}
			if size+cost > target {
				previousID := fmt.Sprintf("%08x-0000-4000-8000-000000000003", n-1)
				previous := st.Feedback[previousID]
				trim := size + cost - target
				previous.Title = previous.Title[:len(previous.Title)-trim]
				st.Feedback[previousID] = previous
				size -= trim
			}
			entry.Title = strings.Repeat("T", min(2000, target-size-cost))
			st.Feedback[id] = entry
			size += cost + len(entry.Title)
			if size == target {
				break
			}
		}
		raw, err = json.Marshal(st)
		if err != nil {
			return err
		}
		if len(raw) != target || len(st.Feedback) >= weekly.MaxFeedback {
			return fmt.Errorf("fixture did not isolate bytes: %d bytes, %d resources", len(raw), len(st.Feedback))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestWeeklyByteCeilingRollsBackResourceAndReplay(t *testing.T) {
	for _, kind := range []string{"feedback", "permission", "artist"} {
		t.Run(kind, func(t *testing.T) {
			f := newWeeklyFixture(t)
			f.artist(weeklyArtistA)
			f.permission("externalCatalogQueries", true)
			page := f.ok("GET", "weekly", nil, "")
			weeklyNearByteCeiling(t, f)
			before := weeklyStoredState(t, f)
			path := "preferences"
			body := map[string]any{"resource": kind, "mutationId": uuid.NewString(), "expectedRevision": 1, "profileEpoch": 0}
			var current any
			switch kind {
			case "feedback":
				path = "feedback/" + weeklyRecordingA
				body = map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": 0, "batchId": page["batchId"]}
				current = weekly.Feedback{RecordingMbid: weeklyRecordingA, Vote: "none"}
			case "permission":
				body["permission"] = "externalCatalogQueries"
				// Same value avoids removing the batch and freeing space.
				body["enabled"] = true
				current = weekly.PermissionResource{Permission: "externalCatalogQueries", Enabled: true, Revision: 1}
			case "artist":
				body["artistMbid"], body["interested"], body["blocked"] = weeklyArtistA, false, true
				current = weekly.Artist{ArtistMbid: weeklyArtistA, Name: "Artist A", Revision: 1, Interested: true}
			}
			for attempt := 0; attempt < 2; attempt++ {
				code, got := f.request("PUT", path, body, fmt.Sprintf("%s-byte-limit-%d", kind, attempt))
				weeklyLimit(t, code, got, 0, 2, 2, current)
				if weeklyStoredState(t, f) != before {
					t.Fatal("byte refusal persisted speculative state or replay")
				}
			}
			// The same operation succeeds after space is available, then exactly
			// replays. Refusal never reserved its UUID or consumed its revision.
			if err := db.NewWeeklyRepository(f.database).Update(context.Background(), f.user, func(st *weekly.State) error {
				for id, entry := range st.Feedback {
					if len(entry.Title) == 2000 {
						delete(st.Feedback, id)
						break
					}
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			if f.ok("PUT", path, body, "")["replayed"] != false || f.ok("PUT", path, body, "")["replayed"] != true {
				t.Fatal("refusal poisoned later accepted operation/replay")
			}
		})
	}
}

func TestWeeklyByteCeilingUsesLockedPreWriteEpoch(t *testing.T) {
	f := newWeeklyFixture(t)
	f.ok("GET", "preferences", nil, "")
	before := weeklyStoredState(t, f)
	err := db.NewWeeklyRepository(f.database).Update(context.Background(), f.user, func(st *weekly.State) error {
		st.Epoch, st.Revision, st.FilterRevision = 7, 11, 13
		st.Artists[weeklyArtistA] = weekly.Artist{ArtistMbid: weeklyArtistA, Name: strings.Repeat("x", 1800000)}
		return nil
	})
	var c *weekly.Conflict
	if !errors.As(err, &c) || c.Code != "RESOURCE_LIMIT" || c.ProfileEpoch != 0 || c.PreferenceRevision != 0 || c.FilterRevision != 0 || c.Current != nil {
		t.Fatalf("repository leaked speculative metadata: %#v", err)
	}
	if weeklyStoredState(t, f) != before {
		t.Fatal("oversized speculative epoch persisted")
	}
}
