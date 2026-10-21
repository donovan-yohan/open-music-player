package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/db"
)

func TestSmartReorderRejectsLossyOrTrailingRequestBeforeWriting(t *testing.T) {
	for _, body := range []string{`{} {}`, `{}null`, `{}garbage`, `{} ` + strings.Repeat(" ", mixPlanMaxRequestBodyBytes), `{"stemEdits":{}}`, `{"deckId":"a"}`} {
		t.Run(body[:min(len(body), 24)], func(t *testing.T) {
			userID := uuid.New()
			playlist := autoBlendPlaylist(userID, 7, []db.Track{mixTrack(1, 1000, true), mixTrack(2, 1000, true)})
			store, order := &fakeMixPlanStore{}, &fakePlaylistOrderWriter{}
			h := NewPlaylistSmartReorderHandlers(&fakePlaylistMixReader{playlist: playlist}, order, store, true)
			w := httptest.NewRecorder()
			h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, body))
			if w.Code != http.StatusBadRequest || len(order.orders) != 0 || store.updated != nil || store.created != nil {
				t.Fatalf("request must fail before any write, status=%d orders=%v body=%s", w.Code, order.orders, w.Body.String())
			}
		})
	}
}

func TestSmartReorderRejectsInvalidPersistedPlanBeforeWriting(t *testing.T) {
	for _, problem := range []string{"fifth instance", "out-of-clip fade", "unsupported schema", "trailing JSON"} {
		t.Run(problem, func(t *testing.T) {
			userID := uuid.New()
			tracks := []db.Track{mixTrack(42, 1000, true), mixTrack(42, 1000, true), mixTrack(42, 1000, true), mixTrack(42, 1000, true), mixTrack(42, 1000, true)}
			playlist := autoBlendPlaylist(userID, 7, tracks)
			clips := buildPlaylistMixRequest(playlist).Clips
			if problem == "fifth instance" {
				for i := range clips {
					clips[i].TimelineStartMs = 0
				}
			}
			if problem == "out-of-clip fade" {
				fade := int64(1001)
				clips[0].FadeInMs = &fade
			}
			plan := smartReorderPlan(t, userID, playlist.Name, clips)
			if problem == "unsupported schema" {
				plan.Payload = []byte(strings.Replace(string(plan.Payload), `"schemaVersion":1`, `"schemaVersion":2`, 1))
			}
			if problem == "trailing JSON" {
				plan.Payload = append(plan.Payload, []byte(`{}`)...)
			}
			store, order := &fakeMixPlanStore{getPlan: plan}, &fakePlaylistOrderWriter{}
			h := NewPlaylistSmartReorderHandlers(&fakePlaylistMixReader{playlist: playlist}, order, store, true)
			w := httptest.NewRecorder()
			h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, `{"mixPlanId":"`+plan.ID.String()+`"}`))
			if w.Code != http.StatusBadRequest || len(order.orders) != 0 || store.updated != nil {
				t.Fatalf("invalid input plan must fail before writes, status=%d orders=%v body=%s", w.Code, order.orders, w.Body.String())
			}
		})
	}
}

func TestSmartReorderSharedValidationAcceptsRegeneratedPlans(t *testing.T) {
	for _, edited := range []bool{false, true} {
		t.Run(map[bool]string{false: "generated", true: "edited seam"}[edited], func(t *testing.T) {
			userID := uuid.New()
			tracks := []db.Track{
				autoBlendTrack(1, 3000, 120, true, "8A"), autoBlendTrack(2, 1000, 120, true, "8A"),
				autoBlendTrack(3, 2500, 120, true, "8A"), autoBlendTrack(4, 500, 120, true, "8A"),
				autoBlendTrack(5, 2000, 120, true, "8A"), autoBlendTrack(6, 4000, 120, true, "8A"),
			}
			facts := make([]autoBlendTrackFacts, len(tracks))
			for i := range tracks {
				facts[i] = autoBlendTrackFactsFromAnalysis(tracks[i])
			}
			clips, _ := buildAutoBlendMix(7, facts)
			if edited {
				seams := computeAutoBlendTransitions(facts)
				overlaps := make([]int64, len(seams))
				for i := range seams {
					overlaps[i] = seams[i].OverlapMs
				}
				overlaps[0] /= 2
				clips = layoutAutoBlendClips(7, facts, overlaps)
			}
			plan := smartReorderPlan(t, userID, autoBlendMixName("Autoblend"), clips)
			store, order := &fakeMixPlanStore{getPlan: plan}, &fakePlaylistOrderWriter{}
			h := NewPlaylistSmartReorderHandlers(&fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}, order, store, true)
			w := httptest.NewRecorder()
			h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, `{"mixPlanId":"`+plan.ID.String()+`"}`))
			if w.Code != http.StatusOK || len(order.orders) != 1 {
				t.Fatalf("status=%d orders=%v body=%s", w.Code, order.orders, w.Body.String())
			}
			payload := assertPersistedMixValid(t, store.updated, len(tracks))
			if store.updatedVersion != 3 || store.updated.Version != 4 {
				t.Fatal("regeneration lost optimistic version contract")
			}
			for i, clip := range payload.Clips {
				if clip.TrackID != order.orders[0][i] || clip.SourceEndMs != facts[i].DurationMs {
					t.Fatalf("regenerated instance[%d] changed: %+v", i, clip)
				}
			}
			if edited && smartReorderPlacementOverlap(payload.Clips[0], payload.Clips[1]) != smartReorderPlacementOverlap(clips[0], clips[1]) {
				t.Fatal("valid edited seam was not preserved")
			}
		})
	}
}

func TestSmartReorderRejectsUnsupportedPersistedFieldsBeforeWriting(t *testing.T) {
	for _, field := range []string{`"stemEdits":{"schemaVersion":1,"events":[]}`, `"deckId":"deck-a"`, `"futureAutomation":null`} {
		t.Run(field, func(t *testing.T) {
			userID := uuid.New()
			playlist := autoBlendPlaylist(userID, 7, []db.Track{
				autoBlendTrack(1, 200000, 120, true, "8A"),
				autoBlendTrack(2, 200000, 121, true, "8A"),
			})
			clips := buildPlaylistMixRequest(playlist).Clips
			plan := smartReorderPlan(t, userID, playlist.Name, clips)
			plan.Payload = []byte(strings.Replace(string(plan.Payload), `"gainDb":0`, `"gainDb":0,`+field, 1))
			before := string(plan.Payload)
			store := &fakeMixPlanStore{getPlan: plan}
			order := &fakePlaylistOrderWriter{}
			h := NewPlaylistSmartReorderHandlers(&fakePlaylistMixReader{playlist: playlist}, order, store, true)
			w := httptest.NewRecorder()
			h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, `{"mixPlanId":"`+plan.ID.String()+`"}`))
			if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "unsupported") {
				t.Fatalf("want explicit unsupported-plan rejection, status=%d body=%s", w.Code, w.Body.String())
			}
			if len(order.orders) != 0 || store.updated != nil || store.created != nil {
				t.Fatal("unsupported persisted authoring fields must not be erased by regeneration")
			}
			if string(store.getPlan.Payload) != before || store.getPlan.Version != 3 {
				t.Fatal("rejected regeneration changed accepted plan")
			}
		})
	}
}
