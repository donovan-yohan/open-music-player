package analyzer

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestNewServiceClientDisabledWithoutBaseURL(t *testing.T) {
	client, err := NewServiceClient(ServiceConfig{})
	if err != nil {
		t.Fatalf("NewServiceClient returned error: %v", err)
	}
	if client != nil {
		t.Fatalf("NewServiceClient returned client when disabled: %#v", client)
	}
}

func TestServiceClientPostsAnalyzerContractAndParsesResponse(t *testing.T) {
	fixture, err := os.ReadFile("testdata/synthetic_analysis.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", r.Method)
		}
		if r.URL.Path != "/analyze" {
			t.Fatalf("path = %s, want /analyze", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		var payload serviceRequest
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if payload.TrackID != 77 || payload.StorageKey != "tracks/user/song.wav" || payload.SourceType != "youtube" {
			t.Fatalf("payload = %#v", payload)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(fixture)
	}))
	defer server.Close()

	client, err := NewServiceClient(ServiceConfig{
		Enabled:   true,
		BaseURL:   server.URL,
		AuthToken: "secret-token",
		Timeout:   time.Second,
	})
	if err != nil {
		t.Fatalf("NewServiceClient returned error: %v", err)
	}
	result, err := client.Analyze(context.Background(), Request{
		TrackID:       77,
		StorageKey:    "tracks/user/song.wav",
		SourceURL:     "https://youtu.be/example",
		SourceType:    "youtube",
		DurationMs:    197500,
		Title:         "Fixture Song",
		Artist:        "Fixture Artist",
		SchemaVersion: SchemaVersion,
	})
	if err != nil {
		t.Fatalf("Analyze returned error: %v", err)
	}
	if result.SchemaVersion != SchemaVersion {
		t.Fatalf("schema version = %d, want %d", result.SchemaVersion, SchemaVersion)
	}
	var summary map[string]interface{}
	if err := json.Unmarshal(result.SummaryJSON, &summary); err != nil {
		t.Fatalf("summary json invalid: %v", err)
	}
	if _, ok := summary["bpm"]; !ok {
		t.Fatalf("summary missing bpm: %s", result.SummaryJSON)
	}
	var provenance map[string]interface{}
	if err := json.Unmarshal(result.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance json invalid: %v", err)
	}
	if provenance["analyzer"] != "fixture" {
		t.Fatalf("provenance analyzer = %#v, want fixture", provenance["analyzer"])
	}
}

func TestServiceClientAcceptsPersistenceJSONFieldNames(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("{\"schema_version\":1,\"summary_json\":{\"bpm\":{\"value\":128}},\"artifacts_json\":{},\"provenance_json\":{\"analyzer\":\"fake\"}}"))
	}))
	defer server.Close()

	client, err := NewServiceClient(ServiceConfig{Enabled: true, BaseURL: server.URL})
	if err != nil {
		t.Fatalf("NewServiceClient returned error: %v", err)
	}
	result, err := client.Analyze(context.Background(), Request{TrackID: 1, StorageKey: "tracks/fixture.wav"})
	if err != nil {
		t.Fatalf("Analyze returned error: %v", err)
	}
	if string(result.SummaryJSON) != "{\"bpm\":{\"value\":128}}" {
		t.Fatalf("summary_json = %s", result.SummaryJSON)
	}
}

func TestServiceClientMapsUnsupportedStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "codec unsupported", http.StatusUnsupportedMediaType)
	}))
	defer server.Close()

	client, err := NewServiceClient(ServiceConfig{Enabled: true, BaseURL: server.URL})
	if err != nil {
		t.Fatalf("NewServiceClient returned error: %v", err)
	}
	_, err = client.Analyze(context.Background(), Request{TrackID: 1, StorageKey: "tracks/fixture.wav"})
	if !errors.Is(err, ErrUnsupported) {
		t.Fatalf("Analyze error = %v, want ErrUnsupported", err)
	}
}
