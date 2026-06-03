package discovery

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

type fakeProvider struct {
	name  string
	items []Candidate
	err   error
	delay time.Duration
}

func (p fakeProvider) Name() string { return p.name }
func (p fakeProvider) Search(ctx context.Context, query string, limit int) ([]Candidate, error) {
	if p.delay > 0 {
		select {
		case <-time.After(p.delay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if p.err != nil {
		return nil, p.err
	}
	return p.items, nil
}

func TestServiceSearchProviderFailureIsIsolated(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://example.invalid/1", Title: "one", Downloadable: true}}},
			fakeProvider{name: "soundcloud", err: errors.New("boom")},
		},
		DefaultProviders: []string{"youtube", "soundcloud"},
	})

	resp := svc.Search(context.Background(), "one", nil, 10)
	if len(resp.Results) != 1 {
		t.Fatalf("expected one successful result, got %d", len(resp.Results))
	}
	if len(resp.Providers) != 2 {
		t.Fatalf("expected two provider summaries, got %d", len(resp.Providers))
	}
	var failed bool
	for _, provider := range resp.Providers {
		if provider.Provider == "soundcloud" && provider.Status == ProviderStatusFailed && provider.Error != nil {
			failed = true
		}
	}
	if !failed {
		t.Fatalf("expected soundcloud failure summary")
	}
}

func TestServiceSearchProviderTimeout(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers:          []Provider{fakeProvider{name: "slow", delay: 50 * time.Millisecond}},
		DefaultProviders:   []string{"slow"},
		PerProviderTimeout: 5 * time.Millisecond,
		OverallTimeout:     100 * time.Millisecond,
	})
	resp := svc.Search(context.Background(), "slow", nil, 10)
	if len(resp.Providers) != 1 {
		t.Fatalf("expected one provider summary")
	}
	if resp.Providers[0].Status != ProviderStatusTimeout {
		t.Fatalf("expected timeout, got %s", resp.Providers[0].Status)
	}
}

func TestServiceSearchUnknownProvider(t *testing.T) {
	svc := NewService(ServiceConfig{})
	resp := svc.Search(context.Background(), "x", []string{"bogus"}, 10)
	if len(resp.Providers) != 1 || resp.Providers[0].Status != ProviderStatusUnsupported {
		t.Fatalf("expected unsupported provider summary, got %#v", resp.Providers)
	}
}

type countingProvider struct {
	name  string
	calls atomic.Int32
}

func (p *countingProvider) Name() string { return p.name }
func (p *countingProvider) Search(ctx context.Context, query string, limit int) ([]Candidate, error) {
	p.calls.Add(1)
	return []Candidate{{CandidateID: p.name + ":1", Provider: p.name, SourceURL: "https://example.invalid/1", Title: query, Downloadable: true}}, nil
}

func TestServiceSearchDedupesRepeatedRequestedProviders(t *testing.T) {
	youtube := &countingProvider{name: "youtube"}
	svc := NewService(ServiceConfig{Providers: []Provider{youtube}, DefaultProviders: []string{"youtube"}})

	resp := svc.Search(context.Background(), "same", []string{"youtube", " youtube ", "youtube"}, 10)

	if calls := youtube.calls.Load(); calls != 1 {
		t.Fatalf("youtube Search calls = %d, want 1", calls)
	}
	if len(resp.Providers) != 1 || resp.Providers[0].Provider != "youtube" {
		t.Fatalf("provider summaries = %#v, want exactly one youtube summary", resp.Providers)
	}
}
