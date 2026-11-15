package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

const weeklyArtistC = "88888888-8888-4888-8888-888888888888"
const weeklyRecordingB2 = "66666666-6666-4666-8666-666666666666"
const weeklyRecordingC = "77777777-7777-4777-8777-777777777777"

func testComponent(p map[string]any, recording, code string) float64 {
	for _, raw := range p["items"].([]any) {
		item := raw.(map[string]any)
		if item["recordingMbid"] == recording {
			for _, raw := range item["components"].([]any) {
				c := raw.(map[string]any)
				if c["code"] == code {
					return c["value"].(float64)
				}
			}
		}
	}
	return -999
}
func TestWeeklyNeighborCounterfactualEvaluationHTTP(t *testing.T) {
	f := newWeeklyFixture(t)
	// Frozen external metadata universe, with an independent third artist. No
	// MusicBrainz relevance score or release chronology enters the taste score.
	f.body = `{"count":4,"recordings":[
 {"id":"` + weeklyRecordingA + `","title":"Synthetic A","first-release-date":"2020","score":1,"artist-credit":[{"artist":{"id":"` + weeklyArtistA + `","name":"Artist A"}}]},
 {"id":"` + weeklyRecordingB + `","title":"Synthetic B","first-release-date":"2025","score":100,"artist-credit":[{"artist":{"id":"` + weeklyArtistB + `","name":"Artist B"}}]},
 {"id":"` + weeklyRecordingB2 + `","title":"Synthetic B neighbor","first-release-date":"2022","score":100,"artist-credit":[{"artist":{"id":"` + weeklyArtistB + `","name":"Artist B"}}]},
 {"id":"` + weeklyRecordingC + `","title":"Synthetic C","first-release-date":"2023","score":100,"artist-credit":[{"artist":{"id":"` + weeklyArtistC + `","name":"Artist C"}}]}]}`
	var seed int64
	if e := f.database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_artist_id,mb_recording_id,mb_verified) VALUES($1,'Synthetic seed C','Artist C',$2,$3,true) RETURNING id`, uuid.NewString(), weeklyArtistC, uuid.New()).Scan(&seed); e != nil {
		t.Fatal(e)
	}
	f.sql(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, f.user, seed)
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	f.artist(weeklyArtistC)
	f.permission("externalCatalogQueries", true)
	started := time.Now()
	neutral := f.ok("GET", "weekly", nil, "eval-neutral")
	neutralLatency := time.Since(started)
	expectedNeutral := strings.Join([]string{weeklyRecordingA, weeklyRecordingB, weeklyRecordingC, weeklyRecordingB2}, ",")
	if strings.Join(weeklyIDs(neutral), ",") != expectedNeutral {
		t.Fatal("neutral universe changed")
	}
	f.vote(weeklyRecordingB, "up", neutral["batchId"], "")
	f.now = f.now.AddDate(0, 0, 7)
	started = time.Now()
	up := f.ok("GET", "weekly", nil, "eval-next-up")
	upLatency := time.Since(started)
	if weeklyIDs(up)[0] != weeklyRecordingB || weeklyIDs(up)[2] != weeklyRecordingB2 || testComponent(up, weeklyRecordingB2, "current_recording_vote_affinity") != 1 {
		t.Fatal("positive neighbor effect did not reach actual HTTP sequence")
	}
	f.vote(weeklyRecordingB, "down", up["batchId"], "")
	f.now = f.now.AddDate(0, 0, 7)
	down := f.ok("GET", "weekly", nil, "eval-next-down")
	if strings.Join(weeklyIDs(down), ",") != strings.Join([]string{weeklyRecordingA, weeklyRecordingC, weeklyRecordingB2}, ",") || testComponent(down, weeklyRecordingB2, "current_recording_vote_affinity") != -1 {
		t.Fatal("negative neighbor sequence/component absent")
	}
	// Neutral counterfactual with identical excluded exact recording, independently
	// owned by a second account. This isolates soft negative from exact exclusion.
	actor := f.user
	control := uuid.New()
	f.sql(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'counterfactual','x')`, control, control.String()+"@example.test")
	f.sql(`INSERT INTO user_library(user_id,track_id) SELECT $1,track_id FROM user_library WHERE user_id=$2`, control, actor)
	var owned int64
	if e := f.database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_recording_id) VALUES($1,'Synthetic neutral exclusion','Artist B',$2) RETURNING id`, uuid.NewString(), weeklyRecordingB).Scan(&owned); e != nil {
		t.Fatal(e)
	}
	f.sql(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, control, owned)
	f.user = control
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	f.artist(weeklyArtistC)
	f.permission("externalCatalogQueries", true)
	excludedNeutral := f.ok("GET", "weekly", nil, "eval-neutral-same-exclusion")
	if strings.Join(weeklyIDs(excludedNeutral), ",") != strings.Join([]string{weeklyRecordingA, weeklyRecordingB2, weeklyRecordingC}, ",") {
		t.Fatal("soft negative counterfactual control not distinguished")
	}
	f.user = actor
	f.vote(weeklyRecordingB, "none", nil, "")
	f.now = f.now.AddDate(0, 0, 7)
	clear := f.ok("GET", "weekly", nil, "eval-next-clear")
	if strings.Join(weeklyIDs(clear), ",") != expectedNeutral || testComponent(clear, weeklyRecordingB2, "current_recording_vote_affinity") != 0 {
		t.Fatal("clear retained signed influence")
	}
	// Explicit synthetic holdout labels make this a finite regression evaluation,
	// not an estimate of personal or production recommendation quality.
	relevance := func(ids []string) float64 {
		if len(ids) > 0 && (ids[0] == weeklyRecordingB || ids[0] == weeklyRecordingB2) {
			return 1
		}
		return 0
	}
	sameArtist := []string{weeklyRecordingA}
	chronological := []string{weeklyRecordingB, weeklyRecordingC, weeklyRecordingB2, weeklyRecordingA}
	counts := map[string]int{}
	seen := map[string]bool{}
	duplicates := 0
	maxArtist := 0
	for _, raw := range neutral["items"].([]any) {
		item := raw.(map[string]any)
		id := item["recordingMbid"].(string)
		if seen[id] {
			duplicates++
		}
		seen[id] = true
		artist := item["primaryArtistMbid"].(string)
		counts[artist]++
		if counts[artist] > maxArtist {
			maxArtist = counts[artist]
		}
	}
	n := float64(len(weeklyIDs(neutral)))
	excluded := neutral["coverage"].(map[string]any)["excluded"].(map[string]any)
	if excluded["owned"] != float64(0) || excluded["recent"] != float64(0) {
		t.Fatal("evaluation admission contains owned/recent fixture rows")
	}
	evaluation := map[string]any{"policy": "signed-artists-v1", "providerPolicy": "weekly-mb-v1", "candidateUniverse": []string{weeklyRecordingA, weeklyRecordingB, weeklyRecordingB2, weeklyRecordingC}, "neutralOrder": weeklyIDs(neutral), "upOrder": weeklyIDs(up), "downOrder": weeklyIDs(down), "clearOrder": weeklyIDs(clear), "neutralSameExactExclusionOrder": weeklyIDs(excludedNeutral), "sameArtistControl": sameArtist, "chronologicalControl": chronological, "syntheticPrecisionAt1": map[string]float64{"neutral": relevance(weeklyIDs(neutral)), "up": relevance(weeklyIDs(up)), "sameArtist": relevance(sameArtist), "chronological": relevance(chronological)}, "unownedUnfamiliarCoverage": n / 4, "duplicateRate": float64(duplicates) / n, "recentRate": excluded["recent"].(float64) / n, "maxPrimaryArtistCount": maxArtist, "maxArtistShare": float64(maxArtist) / n, "sourceResolution": "unavailable_metadata_only", "audioFeatures": "unavailable_not_scored", "latencyMilliseconds": map[string]float64{"neutral": float64(neutralLatency.Microseconds()) / 1000, "up": float64(upLatency.Microseconds()) / 1000}, "limits": "One frozen synthetic cohort; no statistical tuning, personal usefulness, provider activation or audio availability claim. Time-split history and sparse/missing identity cohorts execute separately."}
	b, e := json.MarshalIndent(evaluation, "", "  ")
	if e != nil {
		t.Fatal(e)
	}
	if dir := os.Getenv("SOUNDQ_WEEKLY_WIRE_DIR"); dir != "" {
		if e = os.WriteFile(filepath.Join(dir, "evaluation.json"), b, 0600); e != nil {
			t.Fatal(e)
		}
	}
}
