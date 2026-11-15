package api

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/weekly"
)

func TestWeeklyDecodeExactMutationFields(t *testing.T) {
	permission, enabled, id, interested, blocked := "externalCatalogQueries", true, weeklyExportID(0, 2), true, false
	for _, family := range []struct {
		name     string
		input    any
		required []string
	}{
		{"feedback", weekly.FeedbackWrite{Vote: "up", MutationID: weeklyExportID(0, 4)}, []string{"vote", "mutationId", "expectedRevision", "profileEpoch", "batchId"}},
		{"preference", weekly.PreferenceWrite{Resource: "permission", MutationID: weeklyExportID(0, 4), Permission: &permission, Enabled: &enabled, ArtistMbid: &id, Interested: &interested, Blocked: &blocked}, []string{"resource", "mutationId", "expectedRevision", "profileEpoch"}},
		{"reset", weekly.ResetWrite{MutationID: weeklyExportID(0, 4), Scope: "discovery_preferences"}, []string{"mutationId", "expectedRevision", "profileEpoch", "scope"}},
	} {
		t.Run(family.name, func(t *testing.T) {
			raw, err := json.Marshal(family.input)
			if err != nil {
				t.Fatal(err)
			}
			var fields map[string]json.RawMessage
			if err = json.Unmarshal(raw, &fields); err != nil {
				t.Fatal(err)
			}
			decode := func(body []byte, query string) bool {
				t.Helper()
				w := httptest.NewRecorder()
				req := httptest.NewRequest("PUT", weeklyRoot+"preferences"+query, bytes.NewReader(body))
				var out any
				switch family.input.(type) {
				case weekly.FeedbackWrite:
					out = &weekly.FeedbackWrite{}
				case weekly.PreferenceWrite:
					out = &weekly.PreferenceWrite{}
				case weekly.ResetWrite:
					out = &weekly.ResetWrite{}
				}
				ok := weeklyDecode(w, req, out, family.required...)
				if !ok && w.Code != 400 {
					t.Fatalf("refusal status=%d", w.Code)
				}
				return ok
			}
			if !decode(raw, "") {
				t.Fatal("ordinary exact names refused")
			}
			for key, value := range fields {
				t.Run(key, func(t *testing.T) {
					alias := strings.ToUpper(key[:1]) + key[1:]
					body := append(append([]byte{}, raw[:len(raw)-1]...), []byte(",\""+alias+"\":"+string(value)+"}")...)
					if decode(body, "") {
						t.Errorf("accepted case alias %q after %q", alias, key)
					}
					duplicate := append(append([]byte{}, raw[:len(raw)-1]...), []byte(",\""+key+"\":"+string(value)+"}")...)
					if decode(duplicate, "") {
						t.Error("accepted exact duplicate")
					}
				})
			}
			for _, body := range []string{"null", "[]", string(raw) + "{}", `{"unknown":true}`, strings.Repeat(" ", 8193)} {
				if decode([]byte(body), "") {
					t.Error("accepted invalid object/body")
				}
			}
			unknown := append(append([]byte{}, raw[:len(raw)-1]...), []byte(`,"unknown":true}`)...)
			if decode(unknown, "") || decode(raw, "?unexpected=1") {
				t.Fatal("unknown field/query accepted")
			}
			for _, key := range family.required {
				if key == "batchId" {
					continue
				}
				changed := map[string]json.RawMessage{}
				for k, v := range fields {
					changed[k] = v
				}
				changed[key] = json.RawMessage("null")
				body, _ := json.Marshal(changed)
				if decode(body, "") {
					t.Error("required null accepted", key)
				}
			}
		})
	}
}

func TestWeeklyFeedbackCaseAliasAuthenticatedRoute(t *testing.T) {
	for _, alias := range []bool{false, true} {
		t.Run(map[bool]string{false: "ordinary", true: "case-alias"}[alias], func(t *testing.T) {
			store := &weeklyExportStore{state: weekly.NewState()}
			user := uuid.New()
			id, batch := weeklyExportID(0, 1), weeklyExportID(0, 3)
			store.state.Batches = []weekly.Page{{BatchID: &batch, Items: []weekly.Item{{RecordingMbid: id, Title: "T", Artist: "A", ArtistMbids: []string{weeklyExportID(0, 2)}, PrimaryArtistMbid: weeklyExportID(0, 2)}}}}
			before, _ := json.Marshal(store.state)
			raw, _ := json.Marshal(weekly.FeedbackWrite{Vote: "up", MutationID: weeklyExportID(0, 4), BatchID: &batch})
			if alias {
				raw = append(raw[:len(raw)-1], []byte(`,"Vote":"down"}`)...)
			}
			router, token := weeklyExportRouter(t, store, user)
			req := httptest.NewRequest("PUT", weeklyRoot+"feedback/"+id, bytes.NewReader(raw))
			req.Header.Set("Authorization", "Bearer "+token)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)
			t.Logf("status=%d storedVote=%q", w.Code, store.state.Feedback[id].Vote)
			if alias {
				after, _ := json.Marshal(store.state)
				if w.Code != 400 || !bytes.Equal(before, after) {
					t.Fatalf("ambiguous request mutated state: status=%d vote=%q", w.Code, store.state.Feedback[id].Vote)
				}
			} else if w.Code != 200 || store.state.Feedback[id].Vote != "up" {
				t.Fatalf("ordinary write failed: %d %s", w.Code, w.Body.String())
			}
		})
	}
}
