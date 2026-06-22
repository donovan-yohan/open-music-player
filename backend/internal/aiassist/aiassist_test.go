package aiassist

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testAPIKey = "sk-test-SUPERSECRET-key-do-not-log"

// fakeCompletion writes a minimal OpenAI-compatible chat completion whose message
// content is the given JSON intent string.
func fakeCompletion(t *testing.T, w http.ResponseWriter, intentJSON string) {
	t.Helper()
	resp := map[string]interface{}{
		"choices": []map[string]interface{}{
			{"message": map[string]interface{}{"role": "assistant", "content": intentJSON}},
		},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func newTestClient(t *testing.T, baseURL string) Client {
	t.Helper()
	client := NewClient(Config{Enabled: true, BaseURL: baseURL, APIKey: testAPIKey, Model: "test-model", Timeout: 2 * time.Second})
	if client == nil {
		t.Fatal("NewClient returned nil for a ready config")
	}
	return client
}

func TestExtractIntentParsesStructuredSearch(t *testing.T) {
	var gotAuth, gotPath, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPath = r.URL.Path
		body := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(body)
		gotBody = string(body)
		fakeCompletion(t, w, `{"kind":"search","assistantText":"Searching now","searchQuery":"Porter Robinson Shelter live","providers":["youtube"],"caveats":["may not be the live cut"]}`)
	}))
	defer srv.Close()

	intent, err := newTestClient(t, srv.URL).ExtractIntent(context.Background(), "that live shelter version from youtube")
	if err != nil {
		t.Fatalf("ExtractIntent error: %v", err)
	}
	if intent.Kind != KindSearch {
		t.Fatalf("kind = %q, want search", intent.Kind)
	}
	if intent.SearchQuery != "Porter Robinson Shelter live" {
		t.Fatalf("searchQuery = %q", intent.SearchQuery)
	}
	if len(intent.Providers) != 1 || intent.Providers[0] != "youtube" {
		t.Fatalf("providers = %#v", intent.Providers)
	}
	if gotPath != "/chat/completions" {
		t.Fatalf("request path = %q, want /chat/completions", gotPath)
	}
	if gotAuth != "Bearer "+testAPIKey {
		t.Fatalf("authorization header not set to bearer key")
	}
	// The request must force JSON output so the model returns a parseable intent.
	if !strings.Contains(gotBody, `"response_format"`) || !strings.Contains(gotBody, `"json_object"`) {
		t.Fatalf("request body missing json response_format: %s", gotBody)
	}
}

func TestExtractIntentNormalizesUnknownKind(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fakeCompletion(t, w, `{"kind":"WHATEVER","searchQuery":"  spaced  ","providers":["youtube"," ",""]}`)
	}))
	defer srv.Close()

	intent, err := newTestClient(t, srv.URL).ExtractIntent(context.Background(), "x")
	if err != nil {
		t.Fatalf("ExtractIntent error: %v", err)
	}
	if intent.Kind != KindSearch {
		t.Fatalf("unknown kind = %q, want normalized to search", intent.Kind)
	}
	if intent.SearchQuery != "spaced" {
		t.Fatalf("searchQuery = %q, want trimmed", intent.SearchQuery)
	}
	if len(intent.Providers) != 1 || intent.Providers[0] != "youtube" {
		t.Fatalf("providers = %#v, want only non-empty entries", intent.Providers)
	}
}

func TestExtractIntentParsesClarification(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fakeCompletion(t, w, `{"kind":"clarify","assistantText":"Need detail","clarification":{"question":"Which artist?","options":["Porter Robinson","Madeon"]}}`)
	}))
	defer srv.Close()

	intent, err := newTestClient(t, srv.URL).ExtractIntent(context.Background(), "shelter")
	if err != nil {
		t.Fatalf("ExtractIntent error: %v", err)
	}
	if intent.Kind != KindClarify {
		t.Fatalf("kind = %q, want clarify", intent.Kind)
	}
	if intent.Clarification == nil || intent.Clarification.Question != "Which artist?" || len(intent.Clarification.Options) != 2 {
		t.Fatalf("clarification = %#v", intent.Clarification)
	}
}

func TestExtractIntentMapsUpstreamErrorStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Echo the key in the body to prove the client never surfaces it.
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"boom for key ` + testAPIKey + `"}`))
	}))
	defer srv.Close()

	_, err := newTestClient(t, srv.URL).ExtractIntent(context.Background(), "x")
	assertTypedError(t, err, CodeUpstream)
	assertNoSecret(t, err)
}

func TestExtractIntentMapsMalformedIntentJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fakeCompletion(t, w, `this is not json`)
	}))
	defer srv.Close()

	_, err := newTestClient(t, srv.URL).ExtractIntent(context.Background(), "x")
	assertTypedError(t, err, CodeBadResponse)
}

func TestExtractIntentMapsEmptyChoices(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[]}`))
	}))
	defer srv.Close()

	_, err := newTestClient(t, srv.URL).ExtractIntent(context.Background(), "x")
	assertTypedError(t, err, CodeBadResponse)
}

func TestExtractIntentMapsTimeout(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-release // block until the client's context deadline fires
	}))
	defer srv.Close()
	defer close(release)

	client := NewClient(Config{Enabled: true, BaseURL: srv.URL, APIKey: testAPIKey, Model: "m", Timeout: 30 * time.Millisecond})
	_, err := client.ExtractIntent(context.Background(), "x")
	assertTypedError(t, err, CodeTimeout)
	assertNoSecret(t, err)
}

func TestExtractIntentMapsBodyReadErrors(t *testing.T) {
	client := &openAIClient{
		httpClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       errReadCloser{err: context.DeadlineExceeded},
			}, nil
		})},
		baseURL: "http://assist.invalid",
		apiKey:  testAPIKey,
		model:   "m",
	}

	_, err := client.ExtractIntent(context.Background(), "x")
	assertTypedError(t, err, CodeTimeout)
	assertNoSecret(t, err)
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type errReadCloser struct{ err error }

func (r errReadCloser) Read([]byte) (int, error) { return 0, r.err }
func (r errReadCloser) Close() error             { return nil }

var _ io.ReadCloser = errReadCloser{}

func TestNewClientDisabledWhenNotReady(t *testing.T) {
	cases := []struct {
		name string
		cfg  Config
	}{
		{"disabled flag", Config{Enabled: false, BaseURL: "http://x", APIKey: "k", Model: "m"}},
		{"missing base url", Config{Enabled: true, APIKey: "k", Model: "m"}},
		{"missing key", Config{Enabled: true, BaseURL: "http://x", Model: "m"}},
		{"missing model", Config{Enabled: true, BaseURL: "http://x", APIKey: "k"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if client := NewClient(tc.cfg); client != nil {
				t.Fatalf("NewClient(%s) = non-nil, want nil disabled client", tc.name)
			}
			if tc.cfg.Ready() {
				t.Fatalf("config %s should not be Ready", tc.name)
			}
		})
	}
}

func TestSystemPromptStatesGroundingBoundary(t *testing.T) {
	// Guard the security-critical instruction language so a careless edit can't
	// silently drop the "never invent URLs" boundary from the model contract.
	for _, want := range []string{"NEVER invent", "local-first", "JSON"} {
		if !strings.Contains(SystemPrompt, want) {
			t.Fatalf("SystemPrompt missing boundary phrase %q", want)
		}
	}
}

func assertTypedError(t *testing.T, err error, wantCode string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error with code %q, got nil", wantCode)
	}
	e, ok := err.(*Error)
	if !ok {
		t.Fatalf("error %v is not *aiassist.Error", err)
	}
	if e.Code != wantCode {
		t.Fatalf("error code = %q, want %q", e.Code, wantCode)
	}
}

func assertNoSecret(t *testing.T, err error) {
	t.Helper()
	if err != nil && strings.Contains(err.Error(), testAPIKey) {
		t.Fatalf("error message leaked the API key: %q", err.Error())
	}
}
