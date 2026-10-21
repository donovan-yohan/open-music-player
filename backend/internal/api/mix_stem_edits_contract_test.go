package api

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/db"
)

// These are the actual StemEdits.toJson / MixPlanClip.toJson wire names, not a
// second ranges-based authoring format. atMs remains in source-file time.
func stemContractDocument() map[string]any {
	return map[string]any{
		"schemaVersion":    1,
		"channelSet":       "stems5-hybrid-v1",
		"stemModelVersion": "audio-separator-htdemucs-ft-4s-v1+lr4-180",
		"sourceFileHash":   "sha256:" + strings.Repeat("a", 64),
		"beatGridRef":      map[string]any{"analysisRef": "track-42-analysis", "analysisVersion": "beat-this-v1"},
		"events": []any{
			map[string]any{"channel": "kick", "atMs": 0, "gain": 0.0, "rampMs": 1, "beatIndex": 0},
			map[string]any{"channel": "perc", "atMs": 8000, "gain": 0.25, "rampMs": 250, "beatIndex": 16},
			map[string]any{"channel": "kick", "atMs": 16000, "gain": 1.0, "rampMs": 8},
		},
	}
}

func stemContractClip(id string, edits any) map[string]any {
	return map[string]any{
		"clipId": id, "queueItemId": "queue-" + id, "trackId": 42,
		"sourceStartMs": 2000, "sourceEndMs": 6000, "timelineStartMs": 0, "gainDb": -3.5,
		"stemEdits": edits,
	}
}

func stemContractJSON(t *testing.T, value any) []byte {
	t.Helper()
	b, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func stemContractObject(t *testing.T, data []byte) map[string]any {
	t.Helper()
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	return object
}

func assertStemContractClips(t *testing.T, data []byte, want map[string]any) {
	t.Helper()
	object := stemContractObject(t, data)
	clips, ok := object["clips"].([]any)
	if !ok || len(clips) != len(want) {
		t.Fatalf("unexpected clips: %s", data)
	}
	for _, raw := range clips {
		clip := raw.(map[string]any)
		id := clip["clipId"].(string)
		expected, exists := want[id]
		if !exists {
			t.Fatalf("unexpected clip identity %q", id)
		}
		var normalized any
		if err := json.Unmarshal(stemContractJSON(t, expected), &normalized); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(clip["stemEdits"], normalized) {
			t.Fatalf("clip %s stemEdits changed: got=%v want=%v", id, clip["stemEdits"], normalized)
		}
	}
}

func TestStemEditsCreateReadListUpdateLosslessSourceTimeContract(t *testing.T) {
	userID := uuid.New()
	store := &fakeMixPlanStore{}
	h := NewMixPlanHandlers(store)
	first, second := stemContractDocument(), stemContractDocument()
	second["events"] = []any{map[string]any{"channel": "vocals", "atMs": 3000, "gain": 0.0, "rampMs": 8}}
	clipA, clipB := stemContractClip("a", first), stemContractClip("b", second)
	clipB["timelineStartMs"] = 10000
	body := map[string]any{"schemaVersion": 1, "name": "Stem contract", "clips": []any{clipA, clipB}}
	want := map[string]any{"a": first, "b": second}

	w := httptest.NewRecorder()
	h.CreateMixPlan(w, authedRequest(userID, http.MethodPost, "/mix-plans", stemContractJSON(t, body)))
	if w.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", w.Code, w.Body.String())
	}
	if store.created == nil {
		t.Fatal("create did not persist")
	}
	assertStemContractClips(t, store.created.Payload, want)
	assertStemContractClips(t, w.Body.Bytes(), want)

	store.getPlan = cloneMixPlan(store.created)
	id := store.created.ID.String()
	read := authedRequest(userID, http.MethodGet, "/mix-plans/"+id, nil)
	read.SetPathValue("id", id)
	w = httptest.NewRecorder()
	h.GetMixPlan(w, read)
	if w.Code != http.StatusOK {
		t.Fatalf("read: %d %s", w.Code, w.Body.String())
	}
	assertStemContractClips(t, w.Body.Bytes(), want)
	t.Logf("GET stemEdits contract response: %s", w.Body.String())

	w = httptest.NewRecorder()
	h.ListMixPlans(w, authedRequest(userID, http.MethodGet, "/mix-plans", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("list: %d %s", w.Code, w.Body.String())
	}
	listed := stemContractObject(t, w.Body.Bytes())["data"].([]any)
	if len(listed) != 1 {
		t.Fatalf("list count=%d", len(listed))
	}
	assertStemContractClips(t, stemContractJSON(t, listed[0]), want)

	// The edit at 16000ms is deliberately outside both old and new trim
	// windows: saving a moved/retrimmed clip must never shift or delete it.
	clipA["sourceStartMs"], clipA["sourceEndMs"], clipA["timelineStartMs"] = 4000, 5000, 20000
	body["version"] = 1
	update := authedRequest(userID, http.MethodPut, "/mix-plans/"+id, stemContractJSON(t, body))
	update.SetPathValue("id", id)
	w = httptest.NewRecorder()
	h.UpdateMixPlan(w, update)
	if w.Code != http.StatusOK {
		t.Fatalf("update: %d %s", w.Code, w.Body.String())
	}
	if store.updated == nil || store.updatedVersion != 1 || store.updated.Version != 2 {
		t.Fatal("optimistic update contract lost")
	}
	assertStemContractClips(t, store.updated.Payload, want)
	assertStemContractClips(t, w.Body.Bytes(), want)
	store.getPlan = cloneMixPlan(store.updated)
	w = httptest.NewRecorder()
	h.GetMixPlan(w, read)
	if w.Code != http.StatusOK {
		t.Fatalf("updated read: %d %s", w.Code, w.Body.String())
	}
	assertStemContractClips(t, w.Body.Bytes(), want)
}

func TestStemEditsStrictValidationBeforeAnySave(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"missing version", func(d map[string]any) { delete(d, "schemaVersion") }},
		{"future version", func(d map[string]any) { d["schemaVersion"] = 2 }},
		{"fractional version", func(d map[string]any) { d["schemaVersion"] = 1.5 }},
		{"null version", func(d map[string]any) { d["schemaVersion"] = nil }},
		{"unknown set", func(d map[string]any) { d["channelSet"] = "four_stem" }},
		{"missing set", func(d map[string]any) { delete(d, "channelSet") }},
		{"missing model", func(d map[string]any) { delete(d, "stemModelVersion") }},
		{"wrong model", func(d map[string]any) { d["stemModelVersion"] = "demucs-old" }},
		{"missing hash", func(d map[string]any) { delete(d, "sourceFileHash") }},
		{"malformed hash", func(d map[string]any) { d["sourceFileHash"] = "sha256:abc" }},
		{"uppercase hash", func(d map[string]any) { d["sourceFileHash"] = "sha256:" + strings.Repeat("A", 64) }},
		{"wrong hash algorithm", func(d map[string]any) { d["sourceFileHash"] = "md5:" + strings.Repeat("a", 64) }},
		{"missing events", func(d map[string]any) { delete(d, "events") }},
		{"null events", func(d map[string]any) { d["events"] = nil }},
		{"unknown document field", func(d map[string]any) { d["future"] = 1 }},
		{"null grid", func(d map[string]any) { d["beatGridRef"] = nil }},
		{"empty grid", func(d map[string]any) { d["beatGridRef"] = map[string]any{} }},
		{"blank grid ref", func(d map[string]any) { d["beatGridRef"].(map[string]any)["analysisRef"] = " " }},
		{"unknown grid field", func(d map[string]any) { d["beatGridRef"].(map[string]any)["future"] = true }},
		{"too many events", func(d map[string]any) {
			events := make([]any, 2049)
			for i := range events {
				events[i] = map[string]any{"channel": "kick", "atMs": i, "gain": 0, "rampMs": 8}
			}
			d["events"] = events
		}},
		{"noncanonical order", func(d map[string]any) {
			e := d["events"].([]any)
			e[0], e[1] = e[1], e[0]
		}},
		{"duplicate change point", func(d map[string]any) {
			e := d["events"].([]any)
			d["events"] = []any{e[0], e[0]}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			doc := stemContractDocument()
			tc.mutate(doc)
			assertStemContractRejectedSave(t, doc)
		})
	}
	for _, tc := range []struct {
		name, key string
		value     any
		remove    bool
	}{
		{"missing channel", "channel", nil, true}, {"wrong channel", "channel", "hihat", false},
		{"other set channel", "channel", "drums", false},
		{"missing atMs", "atMs", nil, true}, {"null atMs", "atMs", nil, false},
		{"negative atMs", "atMs", -1, false}, {"fractional atMs", "atMs", 1.5, false},
		{"unsafe atMs", "atMs", int64(9007199254740992), false},
		{"missing gain", "gain", nil, true}, {"null gain", "gain", nil, false},
		{"negative gain", "gain", -0.01, false}, {"large gain", "gain", 1.01, false},
		{"string gain", "gain", "NaN", false},
		{"missing ramp", "rampMs", nil, true}, {"null ramp", "rampMs", nil, false},
		{"zero ramp", "rampMs", 0, false}, {"large ramp", "rampMs", 251, false},
		{"fractional ramp", "rampMs", 1.5, false},
		{"negative beat", "beatIndex", -1, false}, {"fractional beat", "beatIndex", 0.5, false},
		{"null beat", "beatIndex", nil, false}, {"unknown event field", "future", 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			doc := stemContractDocument()
			event := doc["events"].([]any)[0].(map[string]any)
			if tc.remove {
				delete(event, tc.key)
			} else {
				event[tc.key] = tc.value
			}
			assertStemContractRejectedSave(t, doc)
		})
	}
	for _, doc := range []any{nil, map[string]any{}, []any{}, "invalid"} {
		t.Run("invalid document shape", func(t *testing.T) { assertStemContractRejectedSave(t, doc) })
	}
}

func assertStemContractRejectedSave(t *testing.T, document any) {
	t.Helper()
	for _, method := range []string{http.MethodPost, http.MethodPut} {
		id, userID := uuid.New(), uuid.New()
		store := &fakeMixPlanStore{}
		h := NewMixPlanHandlers(store)
		body := stemContractJSON(t, map[string]any{"schemaVersion": 1, "name": "Strict edits", "version": 3, "clips": []any{stemContractClip("a", document)}})
		r := authedRequest(userID, method, "/mix-plans/"+id.String(), body)
		r.SetPathValue("id", id.String())
		w := httptest.NewRecorder()
		if method == http.MethodPost {
			h.CreateMixPlan(w, r)
		} else {
			h.UpdateMixPlan(w, r)
		}
		if w.Code != http.StatusBadRequest || (!strings.Contains(w.Body.String(), "stemEdits") && !strings.Contains(w.Body.String(), "request body too large")) {
			t.Fatalf("%s must reject invalid edits, status=%d body=%s", method, w.Code, w.Body.String())
		}
		if store.created != nil || store.updated != nil {
			t.Fatal("invalid edits reached persistence")
		}
	}
}

func TestStemEditsNonFiniteGainRejectedBySharedBuilder(t *testing.T) {
	for _, gain := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		var edits MixPlanStemEdits
		if err := json.Unmarshal(stemContractJSON(t, stemContractDocument()), &edits); err != nil {
			t.Fatal(err)
		}
		edits.Events[0].Gain = gain
		_, _, _, err := buildMixPlanPayload(&SaveMixPlanRequest{SchemaVersion: 1, Name: "Finite gains", Clips: []MixPlanClip{{ClipID: "a", QueueItemID: "q", TrackID: 42, SourceEndMs: 1000, StemEdits: &edits}}})
		if err == nil || !strings.Contains(err.Error(), "gain must be finite") {
			t.Fatalf("nonfinite gain accepted: %v", err)
		}
	}
}

func TestStemEditsBodyCapAppliesToKnownFields(t *testing.T) {
	doc := stemContractDocument()
	doc["beatGridRef"].(map[string]any)["analysisRef"] = strings.Repeat("x", mixPlanMaxRequestBodyBytes)
	assertStemContractRejectedSave(t, doc)
}

func TestStemEditsCanonicalSetsAndEventLimits(t *testing.T) {
	for _, tc := range []struct {
		name                   string
		countA, countB, countC int
		valid                  bool
	}{
		{"empty document", 0, 0, 0, true},
		{"per clip boundary", 2048, 0, 0, true},
		{"aggregate boundary", 2048, 2048, 0, true},
		{"aggregate overflow", 2048, 2048, 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			clips := []MixPlanClip{}
			for i, count := range []int{tc.countA, tc.countB, tc.countC} {
				doc := stemContractDocument()
				doc["channelSet"] = "stems4-demucs-v1"
				doc["stemModelVersion"] = "audio-separator-htdemucs-ft-4s-v1"
				delete(doc, "beatGridRef")
				events := []any{}
				for e := 0; e < count; e++ {
					events = append(events, map[string]any{"channel": "drums", "atMs": e, "gain": 0.5, "rampMs": 8})
				}
				doc["events"] = events
				var edits MixPlanStemEdits
				if err := json.Unmarshal(stemContractJSON(t, doc), &edits); err != nil {
					t.Fatal(err)
				}
				clips = append(clips, MixPlanClip{ClipID: string(rune('a' + i)), QueueItemID: "queue", TrackID: 42, SourceEndMs: 6000, TimelineStartMs: int64(i) * 6000, StemEdits: &edits})
			}
			// Exercise the shared builder independently of the body cap: the
			// aggregate max also protects persisted-plan regeneration.
			_, _, _, err := buildMixPlanPayload(&SaveMixPlanRequest{SchemaVersion: 1, Name: "Limits", Clips: clips})
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v err=%v", tc.valid, err)
			}
			store := &fakeMixPlanStore{}
			w := httptest.NewRecorder()
			request := SaveMixPlanRequest{SchemaVersion: 1, Name: "Known edits", Clips: clips}
			NewMixPlanHandlers(store).CreateMixPlan(w, authedRequest(uuid.New(), http.MethodPost, "/mix-plans", stemContractJSON(t, request)))
			if !tc.valid {
				if w.Code != http.StatusBadRequest || store.created != nil {
					t.Fatalf("aggregate overflow reached save: %d %s", w.Code, w.Body.String())
				}
				return
			}
			if w.Code != http.StatusCreated {
				t.Fatalf("known edits: %d %s", w.Code, w.Body.String())
			}
			var got MixPlanPayload
			if err := json.Unmarshal(store.created.Payload, &got); err != nil {
				t.Fatal(err)
			}
			if got.Clips[0].StemEdits == nil || got.Clips[0].StemEdits.Events == nil || len(got.Clips[0].StemEdits.Events) != tc.countA {
				t.Fatal("events must remain unchanged, including [] rather than null/absent")
			}
		})
	}
}

func TestStemEditsSmartReorderRejectsInvalidDocumentBeforeWrites(t *testing.T) {
	for _, broken := range []string{"schema", "model", "event channel", "unknown field", "deck field"} {
		t.Run(broken, func(t *testing.T) {
			userID := uuid.New()
			playlist := autoBlendPlaylist(userID, 7, []db.Track{autoBlendTrack(1, 200000, 120, true, "8A"), autoBlendTrack(2, 200000, 121, true, "8B")})
			plan := smartReorderPlan(t, userID, playlist.Name, buildPlaylistMixRequest(playlist).Clips)
			payload := stemContractObject(t, plan.Payload)
			clip := payload["clips"].([]any)[0].(map[string]any)
			doc := stemContractDocument()
			clip["stemEdits"] = doc
			switch broken {
			case "schema":
				doc["schemaVersion"] = 2
			case "model":
				doc["stemModelVersion"] = "unknown"
			case "event channel":
				doc["events"].([]any)[0].(map[string]any)["channel"] = "hihat"
			case "unknown field":
				doc["future"] = true
			case "deck field":
				clip["deckId"] = "a"
			}
			plan.Payload = stemContractJSON(t, payload)
			before := string(plan.Payload)
			store, order := &fakeMixPlanStore{getPlan: plan}, &fakePlaylistOrderWriter{}
			w := httptest.NewRecorder()
			NewPlaylistSmartReorderHandlers(&fakePlaylistMixReader{playlist: playlist}, order, store, true).SmartReorderPlaylist(w, smartReorderRequest(userID, 7, `{"mixPlanId":"`+plan.ID.String()+`"}`))
			if w.Code != http.StatusBadRequest || len(order.orders) != 0 || store.updated != nil || string(store.getPlan.Payload) != before {
				t.Fatalf("invalid reorder wrote state: %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestStemEditsRejectsNoncanonicalJSONKeysBeforeWrite(t *testing.T) {
	valid := string(stemContractJSON(t, stemContractDocument()))
	for _, document := range []string{
		strings.Replace(valid, `"schemaVersion":1`, `"schemaVersion":1,"schemaVersion":2`, 1),
		strings.Replace(valid, `"atMs":0`, `"atMs":0,"atMs":1`, 1),
		strings.Replace(valid, `"analysisRef":"track-42-analysis"`, `"analysisRef":"old","analysisRef":"new"`, 1),
		strings.Replace(valid, `"schemaVersion"`, `"SchemaVersion"`, 1),
		strings.Replace(valid, `"beatIndex"`, `"BeatIndex"`, 1),
		strings.Replace(valid, `"beatGridRef"`, `"BeatGridRef"`, 1),
	} {
		t.Run(document[:min(len(document), 40)], func(t *testing.T) {
			assertStemContractRejectedSave(t, json.RawMessage(document))
		})
	}
}

func TestStemEditsSmartReorderPreservesPerClipIdentityAndReadResponse(t *testing.T) {
	userID := uuid.New()
	tracks := []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 128, true, "2A"),
		autoBlendTrack(3, 200000, 121, true, "8B"),
	}
	playlist := autoBlendPlaylist(userID, 7, tracks)
	clips := buildPlaylistMixRequest(playlist).Clips
	want := map[string]any{}
	queueByClip := map[string]string{}
	for i := range clips {
		doc := stemContractDocument()
		doc["sourceFileHash"] = "sha256:" + strings.Repeat(string(rune('a'+i)), 64)
		var edits MixPlanStemEdits
		if err := json.Unmarshal(stemContractJSON(t, doc), &edits); err != nil {
			t.Fatal(err)
		}
		clips[i].ClipID = "authored-" + string(rune('a'+i))
		clips[i].QueueItemID = "original-queue-" + clips[i].ClipID
		clips[i].StemEdits = &edits
		want[clips[i].ClipID] = doc
		queueByClip[clips[i].ClipID] = clips[i].QueueItemID
	}
	plan := smartReorderPlan(t, userID, playlist.Name, clips)
	store, order := &fakeMixPlanStore{getPlan: plan}, &fakePlaylistOrderWriter{}
	h := NewPlaylistSmartReorderHandlers(&fakePlaylistMixReader{playlist: playlist}, order, store, true)
	w := httptest.NewRecorder()
	h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, `{"mixPlanId":"`+plan.ID.String()+`"}`))
	if w.Code != http.StatusOK {
		t.Fatalf("reorder: %d %s", w.Code, w.Body.String())
	}
	if len(order.orders) != 1 || !reflect.DeepEqual(order.orders[0], []int64{1, 3, 2}) {
		t.Fatalf("persisted order=%v", order.orders)
	}
	if store.updated == nil || store.updatedVersion != 3 || store.updated.Version != 4 {
		t.Fatal("reorder update/version missing")
	}
	assertStemContractClips(t, store.updated.Payload, want)
	response := stemContractObject(t, w.Body.Bytes())["mixPlan"]
	assertStemContractClips(t, stemContractJSON(t, response), want)
	var saved MixPlanPayload
	if err := json.Unmarshal(store.updated.Payload, &saved); err != nil {
		t.Fatal(err)
	}
	for _, clip := range saved.Clips {
		if clip.QueueItemID != queueByClip[clip.ClipID] {
			t.Fatal("reorder reassigned authored queue identity")
		}
	}
	store.getPlan = cloneMixPlan(store.updated)
	read := authedRequest(userID, http.MethodGet, "/mix-plans/"+plan.ID.String(), nil)
	read.SetPathValue("id", plan.ID.String())
	w = httptest.NewRecorder()
	NewMixPlanHandlers(store).GetMixPlan(w, read)
	if w.Code != http.StatusOK {
		t.Fatalf("reorder read: %d %s", w.Code, w.Body.String())
	}
	assertStemContractClips(t, w.Body.Bytes(), want)
}

func TestStemEditsSmartReorderRepeatedTracksDoNotShareDocuments(t *testing.T) {
	docA, docB := stemContractDocument(), stemContractDocument()
	docB["events"] = []any{map[string]any{"channel": "vocals", "atMs": 500, "gain": 0.5, "rampMs": 8}}
	var a, b MixPlanStemEdits
	if err := json.Unmarshal(stemContractJSON(t, docA), &a); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(stemContractJSON(t, docB), &b); err != nil {
		t.Fatal(err)
	}
	facts := []autoBlendTrackFacts{{TrackID: 42, DurationMs: 20000}, {TrackID: 43, DurationMs: 20000}, {TrackID: 42, DurationMs: 20000}}
	clips := layoutAutoBlendClips(7, facts, []int64{0, 0})
	clips[0].ClipID, clips[0].QueueItemID, clips[0].StemEdits = "repeat-a", "queue-a", &a
	clips[1].ClipID = "unedited"
	clips[2].ClipID, clips[2].QueueItemID, clips[2].StemEdits = "repeat-b", "queue-b", &b
	newClips, _, _ := smartReorderRegeneratePlan(7, clips, facts, []autoBlendTrackFacts{facts[0], facts[2], facts[1]})
	payload := MixPlanPayload{SchemaVersion: 1, Name: "Repeated", Clips: newClips}
	assertStemContractClips(t, stemContractJSON(t, payload), map[string]any{"repeat-a": docA, "repeat-b": docB, "unedited": nil})
}
