package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/db"
)

// Exercise the same handlers against migrated JSONB storage, including stale
// writer rejection. The guarded helper only accepts a disposable test database.
func TestStemEditsPostgresRoundTripAndVersionConflict(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	userID := seedMixUser(t, database, "stem-mix-owner@example.test")
	otherID := seedMixUser(t, database, "stem-mix-other@example.test")
	trackID := seedMixTrack(t, db.NewTrackRepository(database), ctx, "Stem source", 20000)
	if _, err := db.NewLibraryRepository(database).AddTrackToLibrary(ctx, userID, trackID); err != nil {
		t.Fatal(err)
	}
	repository := db.NewMixPlanRepository(database)
	handlers := NewMixPlanHandlers(repository)
	edits := stemContractDocument()
	clip := stemContractClip("instance-a", edits)
	clip["trackId"] = trackID
	clip["tempoPolicy"] = "constantTempoLock"
	body := map[string]any{"schemaVersion": 1, "name": "Recorded mix", "clips": []any{clip}}
	response := httptest.NewRecorder()
	handlers.CreateMixPlan(response, authedRequest(userID, http.MethodPost, "/mix-plans", stemContractJSON(t, body)))
	if response.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", response.Code, response.Body.String())
	}
	var created MixPlanResponse
	if err := json.Unmarshal(response.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.ID == uuid.Nil || created.Version != 1 {
		t.Fatalf("created identity/version: %+v", created)
	}
	stored, err := repository.GetByIDForUser(ctx, userID, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"instance-a": edits}
	assertStemContractClips(t, stored.Payload, want)
	assertPolicy := func(payload []byte, expected string) {
		t.Helper()
		got := stemContractObject(t, payload)["clips"].([]any)[0].(map[string]any)["tempoPolicy"]
		if got != expected {
			t.Fatalf("persisted tempo policy = %v, want %s", got, expected)
		}
	}
	assertPolicy(stored.Payload, "constantTempoLock")

	// Moving and retrimming the instance does not rewrite source-time events.
	clip["sourceStartMs"], clip["sourceEndMs"], clip["timelineStartMs"] = 4000, 10000, 30000
	clip["tempoPolicy"] = "volumeOnly"
	body["version"] = 1
	update := authedRequest(userID, http.MethodPut, "/mix-plans/"+created.ID.String(), stemContractJSON(t, body))
	update.SetPathValue("id", created.ID.String())
	response = httptest.NewRecorder()
	handlers.UpdateMixPlan(response, update)
	if response.Code != http.StatusOK {
		t.Fatalf("update: %d %s", response.Code, response.Body.String())
	}
	assertStemContractClips(t, response.Body.Bytes(), want)
	assertPolicy(response.Body.Bytes(), "volumeOnly")

	// A stale client must not erase the performance saved by the accepted edit.
	clip["stemEdits"] = stemContractDocument()
	clip["stemEdits"].(map[string]any)["events"] = []any{}
	clip["tempoPolicy"] = "constantTempoLock"
	stale := authedRequest(userID, http.MethodPut, "/mix-plans/"+created.ID.String(), stemContractJSON(t, body))
	stale.SetPathValue("id", created.ID.String())
	response = httptest.NewRecorder()
	handlers.UpdateMixPlan(response, stale)
	if response.Code != http.StatusConflict {
		t.Fatalf("stale update: %d %s", response.Code, response.Body.String())
	}
	stored, err = repository.GetByIDForUser(ctx, userID, created.ID)
	if err != nil || stored.Version != 2 {
		t.Fatalf("stored version after conflict: %+v %v", stored, err)
	}
	assertStemContractClips(t, stored.Payload, want)
	assertPolicy(stored.Payload, "volumeOnly")

	read := authedRequest(userID, http.MethodGet, "/mix-plans/"+created.ID.String(), nil)
	read.SetPathValue("id", created.ID.String())
	response = httptest.NewRecorder()
	handlers.GetMixPlan(response, read)
	if response.Code != http.StatusOK {
		t.Fatalf("read: %d %s", response.Code, response.Body.String())
	}
	assertStemContractClips(t, response.Body.Bytes(), want)
	assertPolicy(response.Body.Bytes(), "volumeOnly")

	other := authedRequest(otherID, http.MethodGet, "/mix-plans/"+created.ID.String(), nil)
	other.SetPathValue("id", created.ID.String())
	response = httptest.NewRecorder()
	handlers.GetMixPlan(response, other)
	if response.Code != http.StatusNotFound {
		t.Fatalf("unshared owner isolation: %d %s", response.Code, response.Body.String())
	}
}
