package httpjson

import (
	"bytes"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type embeddedFields struct {
	Position string `json:"position"`
}

type decodeTarget struct {
	embeddedFields
	TrackID    *int64 `json:"trackId,omitempty"`
	PlaylistID *int64 `json:"playlistId"`
	Untagged   string
	Secret     string `json:"-"`
}

// captureLog redirects the standard logger for the duration of fn. The package
// logs through log.Printf like the rest of the backend, so the only way to
// assert the warning exists is to read the writer it lands in.
func captureLog(t *testing.T, fn func()) string {
	t.Helper()
	var buf bytes.Buffer
	previous := log.Writer()
	previousFlags := log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	defer func() {
		log.SetOutput(previous)
		log.SetFlags(previousFlags)
	}()
	fn()
	return buf.String()
}

// TestDecodeRequestIgnoresUnknownFieldsAndLogsThem is the version-skew case: a
// client build sends a field this server predates and the request still binds.
func TestDecodeRequestIgnoresUnknownFieldsAndLogsThem(t *testing.T) {
	var target decodeTarget
	body := `{"position":"end","trackId":7,"shuffleSeed":42,"crossfadeMs":250}`

	logged := captureLog(t, func() {
		if err := DecodeRequest("/api/v1/queue/items", strings.NewReader(body), &target); err != nil {
			t.Fatalf("DecodeRequest() = %v, want nil", err)
		}
	})

	if target.Position != "end" || target.TrackID == nil || *target.TrackID != 7 {
		t.Fatalf("known fields did not bind: %+v", target)
	}
	want := "Warning: ignoring unknown JSON fields in request body for /api/v1/queue/items: crossfadeMs, shuffleSeed\n"
	if logged != want {
		t.Fatalf("log = %q, want %q", logged, want)
	}
}

// TestDecodeRequestStaysQuietOnFieldsThatBind guards against crying wolf: every
// shape encoding/json actually accepts must stay out of the warning.
func TestDecodeRequestStaysQuietOnFieldsThatBind(t *testing.T) {
	for name, body := range map[string]string{
		"tag with options":  `{"trackId":1}`,
		"promoted embedded": `{"position":"end"}`,
		"untagged field":    `{"Untagged":"x"}`,
		"case insensitive":  `{"playlistID":3}`,
		"empty object":      `{}`,
	} {
		t.Run(name, func(t *testing.T) {
			var target decodeTarget
			logged := captureLog(t, func() {
				if err := DecodeRequest("/api/v1/queue/items", strings.NewReader(body), &target); err != nil {
					t.Fatalf("DecodeRequest() = %v, want nil", err)
				}
			})
			if logged != "" {
				t.Fatalf("log = %q, want no warning", logged)
			}
		})
	}
	t.Run("case insensitive key still binds", func(t *testing.T) {
		var target decodeTarget
		if err := DecodeRequest("/api/v1/queue/items", strings.NewReader(`{"playlistID":3}`), &target); err != nil {
			t.Fatalf("DecodeRequest() = %v, want nil", err)
		}
		if target.PlaylistID == nil || *target.PlaylistID != 3 {
			t.Fatalf("playlistID did not bind: %+v", target)
		}
	})
}

// TestDecodeRequestReportsFieldsExcludedFromTheWire covers `json:"-"`: the key
// binds to nothing, so a client sending it deserves the same warning as a
// wholly unknown name.
func TestDecodeRequestReportsFieldsExcludedFromTheWire(t *testing.T) {
	var target decodeTarget
	logged := captureLog(t, func() {
		if err := DecodeRequest("/api/v1/queue/items", strings.NewReader(`{"Secret":"smuggled"}`), &target); err != nil {
			t.Fatalf("DecodeRequest() = %v, want nil", err)
		}
	})
	if target.Secret != "" {
		t.Fatalf("json:\"-\" field bound: %+v", target)
	}
	if !strings.Contains(logged, "Secret") {
		t.Fatalf("log = %q, want the excluded field reported", logged)
	}
}

// TestDecodeRequestKeepsTheOtherGuards confirms only unknown-field rejection was
// relaxed; nothing else about the body got more forgiving.
func TestDecodeRequestKeepsTheOtherGuards(t *testing.T) {
	for name, body := range map[string]string{
		"malformed json":         `{"position":`,
		"multiple json values":   `{"position":"end"} {"position":"start"}`,
		"trailing garbage":       `{"position":"end"} not-json`,
		"wrong type known field": `{"trackId":"seven"}`,
		"empty body":             ``,
	} {
		t.Run(name, func(t *testing.T) {
			var target decodeTarget
			if err := DecodeRequest("/api/v1/queue/items", strings.NewReader(body), &target); err == nil {
				t.Fatalf("DecodeRequest() = nil, want an error for %s", name)
			}
		})
	}
}

// TestDecodeRequestPropagatesMaxBytesError keeps the body-size guard reachable:
// handlers branch on *http.MaxBytesError to answer 413 instead of 400.
func TestDecodeRequestPropagatesMaxBytesError(t *testing.T) {
	recorder := httptest.NewRecorder()
	oversized := `{"position":"` + strings.Repeat("x", 128) + `"}`
	body := http.MaxBytesReader(recorder, io.NopCloser(strings.NewReader(oversized)), 16)

	var target decodeTarget
	err := DecodeRequest("/api/v1/queue/items", body, &target)
	if err == nil {
		t.Fatal("DecodeRequest() = nil, want a size error")
	}
	var maxBytesError *http.MaxBytesError
	if !errors.As(err, &maxBytesError) {
		t.Fatalf("DecodeRequest() = %v, want it to unwrap to *http.MaxBytesError", err)
	}
}

// TestDecodeRequestToleratesNonStructTargets: the unknown-field diff only makes
// sense against a struct, and anything else must decode without panicking.
func TestDecodeRequestToleratesNonStructTargets(t *testing.T) {
	var target map[string]any
	logged := captureLog(t, func() {
		if err := DecodeRequest("/api/v1/anything", strings.NewReader(`{"whatever":1}`), &target); err != nil {
			t.Fatalf("DecodeRequest() = %v, want nil", err)
		}
	})
	if logged != "" {
		t.Fatalf("log = %q, want no warning for a map target", logged)
	}
	if target["whatever"] != float64(1) {
		t.Fatalf("map target did not bind: %+v", target)
	}
}
