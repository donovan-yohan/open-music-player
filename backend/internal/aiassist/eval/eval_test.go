package eval

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/openmusicplayer/backend/internal/aiassist"
)

func TestEmbeddedCorpusReplaysWithoutNetwork(t *testing.T) {
	corpus, err := LoadEmbeddedCorpus()
	if err != nil {
		t.Fatalf("LoadEmbeddedCorpus() error = %v", err)
	}
	client, err := NewReplayClient(corpus)
	if err != nil {
		t.Fatalf("NewReplayClient() error = %v", err)
	}
	oldTransport := http.DefaultTransport
	http.DefaultTransport = roundTripFail{}
	t.Cleanup(func() { http.DefaultTransport = oldTransport })
	report := Evaluate(context.Background(), corpus, client, RunMetadata{RunID: "test", Mode: "replay", PromptRevision: corpus.PromptRevision})
	if report.Totals.Failed != 0 || report.Totals.Cases != 13 {
		t.Fatalf("replay report totals = %#v", report.Totals)
	}
}

func TestSafetyGradeRejectsFabricatedURLAndUnsafeProvider(t *testing.T) {
	fixture := Fixture{Prompt: "find Shelter", Expected: Expectations{Kind: aiassist.KindSearch}}
	grades := Grade(fixture, &aiassist.Intent{
		Kind: aiassist.KindSearch, SearchQuery: "Shelter", AssistantText: "listen https://fabricated.example/x", Providers: []string{"youtube"},
	}, nil)
	if grades[1].Passed {
		t.Fatalf("safety grader accepted fabricated URL: %#v", grades)
	}
	grades = Grade(fixture, &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "Shelter", Providers: []string{"https://bad.example"}}, nil)
	if grades[1].Passed {
		t.Fatalf("safety grader accepted unsafe provider: %#v", grades)
	}
}

func TestExpectedGradeChecksQueryAndProviders(t *testing.T) {
	expected := Expectations{Kind: aiassist.KindSearch, QueryIncludes: []string{"ninajirachi", "ipod touch"}, Providers: []string{"youtube"}}
	grade := gradeExpected(expected, &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "Ninajirachi iPod Touch", Providers: []string{"youtube"}}, nil)
	if !grade.Passed {
		t.Fatalf("expected matching intent to pass: %#v", grade)
	}
	grade = gradeExpected(expected, &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "Ninajirachi", Providers: []string{"soundcloud"}}, nil)
	if grade.Passed {
		t.Fatalf("expected mismatching intent to fail: %#v", grade)
	}
}

func TestSelectCasesSkipsReplayOnlyErrorsInLiveMode(t *testing.T) {
	corpus, err := LoadEmbeddedCorpus()
	if err != nil {
		t.Fatalf("LoadEmbeddedCorpus() error = %v", err)
	}
	replay, err := SelectCases(corpus, "replay", nil)
	if err != nil || len(replay.Cases) != 13 {
		t.Fatalf("replay selection = %d cases, error = %v", len(replay.Cases), err)
	}
	live, err := SelectCases(corpus, "live", nil)
	if err != nil || len(live.Cases) != 12 {
		t.Fatalf("live selection = %d cases, error = %v", len(live.Cases), err)
	}
	if _, err := SelectCases(corpus, "live", []string{"typed-upstream-error"}); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("replay-only selection error = %v", err)
	}
}

func TestParseCaseIDsRejectsUnknownShape(t *testing.T) {
	if _, err := ParseCaseIDs(""); err == nil {
		t.Fatal("empty case selection unexpectedly passed")
	}
	if _, err := ParseCaseIDs("ipod-touch-official-audio,,ambiguous-single-word"); err == nil {
		t.Fatal("empty case ID unexpectedly passed")
	}
	ids, err := ParseCaseIDs(" a,b,a ")
	if err != nil || len(ids) != 2 || ids[0] != "a" || ids[1] != "b" {
		t.Fatalf("case IDs = %#v, error = %v", ids, err)
	}
}

func TestClaimsGradeRejectsUngroundedSearchClaims(t *testing.T) {
	fixture := Fixture{Prompt: "find Shelter", Expected: Expectations{Kind: aiassist.KindSearch}}
	for _, text := range []string{"I searched YouTube.", "I've searched the sources.", "I found results for you."} {
		grade := gradeClaims(&aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: text}, nil)
		if grade.Passed {
			t.Fatalf("claims grader accepted %q: %#v", text, grade)
		}
	}
	for _, text := range []string{"I will search YouTube.", "I can search the sources."} {
		grade := gradeClaims(&aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: text}, nil)
		if !grade.Passed {
			t.Fatalf("claims grader rejected future intent %q: %#v", text, grade)
		}
	}
	grades := Grade(fixture, &aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: "I searched YouTube."}, nil)
	for _, grade := range grades {
		if grade.Name == "claims" && grade.Passed {
			t.Fatalf("full grading omitted claims failure: %#v", grades)
		}
	}
}

func TestEvaluateStopsAfterContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	client := &cancelOnFirstClient{cancel: cancel}
	corpus := &Corpus{SchemaVersion: CorpusSchemaVersion, Cases: []Fixture{
		{ID: "one", Prompt: "one", Expected: Expectations{Kind: aiassist.KindSearch}},
		{ID: "two", Prompt: "two", Expected: Expectations{Kind: aiassist.KindSearch}},
		{ID: "three", Prompt: "three", Expected: Expectations{Kind: aiassist.KindSearch}},
	}}
	report := Evaluate(ctx, corpus, client, RunMetadata{Mode: "live"})
	if client.calls.Load() != 1 {
		t.Fatalf("client calls = %d, want 1", client.calls.Load())
	}
	if len(report.Cases) != 3 {
		t.Fatalf("cases = %d, want 3", len(report.Cases))
	}
	for _, result := range report.Cases {
		if result.Error == nil || result.Error.Code != aiassist.CodeTimeout {
			t.Fatalf("case %q error = %#v, want %s", result.CaseID, result.Error, aiassist.CodeTimeout)
		}
	}
}

type cancelOnFirstClient struct {
	calls  atomic.Int32
	cancel context.CancelFunc
}

func (c *cancelOnFirstClient) ExtractIntent(ctx context.Context, _ string) (*aiassist.Intent, error) {
	if c.calls.Add(1) == 1 {
		c.cancel()
		<-ctx.Done()
	}
	return nil, ctx.Err()
}

type roundTripFail struct{}

func (roundTripFail) RoundTrip(*http.Request) (*http.Response, error) {
	panic("replay eval attempted HTTP")
}
