package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
)

func TestTempoPolicySaveReadUpdateContract(t *testing.T) {
	for _, policy := range []string{"", "volumeOnly", "constantTempoLock"} {
		t.Run("policy="+policy, func(t *testing.T) {
			store := &fakeMixPlanStore{}
			h := NewMixPlanHandlers(store)
			userID := uuid.New()
			clip := map[string]any{"clipId": "a", "queueItemId": "q", "trackId": 42, "sourceStartMs": 0, "sourceEndMs": 40000, "timelineStartMs": 0}
			if policy != "" {
				clip["tempoPolicy"] = policy
			}
			body := map[string]any{"schemaVersion": 1, "name": "policy", "clips": []any{clip}}
			w := httptest.NewRecorder()
			h.CreateMixPlan(w, authedRequest(userID, http.MethodPost, "/mix-plans", stemContractJSON(t, body)))
			if w.Code != http.StatusCreated {
				t.Fatalf("create %d: %s", w.Code, w.Body)
			}
			want := policy
			if want == "" {
				want = "volumeOnly"
			}
			assertTempoPolicy := func(data []byte) {
				t.Helper()
				got := stemContractObject(t, data)["clips"].([]any)[0].(map[string]any)["tempoPolicy"]
				if got != want {
					t.Fatalf("policy got %v want %s", got, want)
				}
			}
			assertTempoPolicy(store.created.Payload)
			store.getPlan = cloneMixPlan(store.created)
			id := store.created.ID.String()
			read := authedRequest(userID, http.MethodGet, "/mix-plans/"+id, nil)
			read.SetPathValue("id", id)
			w = httptest.NewRecorder()
			h.GetMixPlan(w, read)
			if w.Code != http.StatusOK {
				t.Fatalf("get %d: %s", w.Code, w.Body)
			}
			assertTempoPolicy(w.Body.Bytes())
			body["version"] = 1
			update := authedRequest(userID, http.MethodPut, "/mix-plans/"+id, stemContractJSON(t, body))
			update.SetPathValue("id", id)
			w = httptest.NewRecorder()
			h.UpdateMixPlan(w, update)
			if w.Code != http.StatusOK {
				t.Fatalf("update %d: %s", w.Code, w.Body)
			}
			assertTempoPolicy(store.updated.Payload)
			store.getPlan = cloneMixPlan(store.updated)
			w = httptest.NewRecorder()
			h.GetMixPlan(w, read)
			if w.Code != http.StatusOK {
				t.Fatalf("updated get %d: %s", w.Code, w.Body)
			}
			assertTempoPolicy(w.Body.Bytes())
		})
	}
}

func TestTempoPolicyAutoBlendIntentAndReorderPreservation(t *testing.T) {
	facts := []autoBlendTrackFacts{
		{TrackID: 1, DurationMs: 60000, BPM: 120, HasBPM: true, TempoEligible: true, BarEligible: true, BeatsPerBar: 4, Downbeats: []int64{0, 2000, 44000, 46000, 58000}},
		{TrackID: 2, DurationMs: 60000, BPM: 120, HasBPM: true, TempoEligible: true, BarEligible: true, BeatsPerBar: 4, Downbeats: []int64{0, 2000, 44000, 46000, 58000}},
	}
	clips, transitions := buildAutoBlendMix(1, facts)
	if transitions[0].Confidence.SimpleFade {
		t.Fatal("fixture must admit numeric seam")
	}
	for _, clip := range clips {
		object := stemContractObject(t, stemContractJSON(t, clip))
		if object["tempoPolicy"] != "constantTempoLock" {
			t.Fatalf("trusted seam lost explicit lock: %v", object)
		}
	}
	facts[1].BarEligible = false
	fallback, _ := buildAutoBlendMix(1, facts)
	for _, clip := range fallback {
		object := stemContractObject(t, stemContractJSON(t, clip))
		if object["tempoPolicy"] != "volumeOnly" {
			t.Fatalf("fallback acquired lock: %v", object)
		}
	}
	// Load through the actual wire DTO; repeated occurrences must keep intent.
	jsonClips := []map[string]any{}
	for i, policy := range []string{"constantTempoLock", "volumeOnly"} {
		object := stemContractObject(t, stemContractJSON(t, clips[i]))
		object["tempoPolicy"] = policy
		jsonClips = append(jsonClips, object)
	}
	var previous []MixPlanClip
	if err := json.Unmarshal(stemContractJSON(t, jsonClips), &previous); err != nil {
		t.Fatal(err)
	}
	regenerated, _, _ := smartReorderRegeneratePlan(1, previous, facts, []autoBlendTrackFacts{facts[1], facts[0]})
	for _, clip := range regenerated {
		object := stemContractObject(t, stemContractJSON(t, clip))
		want := "constantTempoLock"
		if clip.TrackID == 2 {
			want = "volumeOnly"
		}
		if object["tempoPolicy"] != want {
			t.Fatalf("reorder lost instance intent: %v", object)
		}
	}
}

func TestTempoPolicyRejectsAliasesAndDuplicateFields(t *testing.T) {
	for _, field := range []string{`"TempoPolicy":"volumeOnly"`, `"tempoPolicy":"volumeOnly","tempoPolicy":"constantTempoLock"`} {
		store := &fakeMixPlanStore{}
		body := []byte(`{"schemaVersion":1,"name":"strict","clips":[{"clipId":"a","queueItemId":"q","trackId":42,"sourceStartMs":0,"sourceEndMs":40000,"timelineStartMs":0,` + field + `}]}`)
		w := httptest.NewRecorder()
		NewMixPlanHandlers(store).CreateMixPlan(w, authedRequest(uuid.New(), http.MethodPost, "/mix-plans", body))
		if w.Code != http.StatusBadRequest || store.created != nil {
			t.Fatalf("accepted ambiguous policy: %d %s", w.Code, w.Body)
		}
	}
}

func TestTempoPolicyRejectsInvalidBeforeSave(t *testing.T) {
	for _, value := range []any{nil, "tempoSweep", "unknown", "", 1} {
		store := &fakeMixPlanStore{}
		clip := map[string]any{"clipId": "a", "queueItemId": "q", "trackId": 42, "sourceStartMs": 0, "sourceEndMs": 40000, "timelineStartMs": 0, "tempoPolicy": value}
		body := map[string]any{"schemaVersion": 1, "name": "policy", "clips": []any{clip}}
		w := httptest.NewRecorder()
		NewMixPlanHandlers(store).CreateMixPlan(w, authedRequest(uuid.New(), http.MethodPost, "/mix-plans", stemContractJSON(t, body)))
		if w.Code != http.StatusBadRequest || store.created != nil {
			t.Fatalf("accepted %v: %d %s", value, w.Code, w.Body)
		}
	}
}
