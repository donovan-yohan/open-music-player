package main

import (
	"math"
	"strings"
	"testing"
)

func TestAnalyzeSamplesEstimatesKeyAndCamelot(t *testing.T) {
	const sampleRate = 8000
	samples := sineSamples(sampleRate, 440, 2)

	analysis := analyzeSamples(samples, sampleRate, 2000, 80)

	if !strings.HasPrefix(analysis.keyName, "A ") {
		t.Fatalf("keyName = %q, want A major/minor estimate", analysis.keyName)
	}
	if analysis.camelot == "" {
		t.Fatalf("camelot was empty for estimated key %q", analysis.keyName)
	}
	if analysis.keyConf <= 0 {
		t.Fatalf("keyConf = %v, want positive confidence", analysis.keyConf)
	}
}

func TestBuildResponseIncludesDJContractArtifacts(t *testing.T) {
	const sampleRate = 8000
	samples := sineSamples(sampleRate, 440, 2)
	analysis := analyzeSamples(samples, sampleRate, 2000, 80)

	response := buildResponse(analyzeRequest{
		StorageKey: "tracks/test/a.wav",
		DurationMs: 2000,
	}, analysis)

	summary := response["summary"].(map[string]any)
	for _, key := range []string{
		"bpm",
		"beat_grid",
		"downbeats",
		"key",
		"camelot",
		"loudness",
		"true_peak",
		"waveform",
		"transients",
		"silence",
		"intro",
		"outro",
		"trim",
		"sections",
		"cue_candidates",
		"duration_sanity",
	} {
		if _, ok := summary[key]; !ok {
			t.Fatalf("summary missing %q: %#v", key, summary)
		}
	}

	artifacts := response["artifacts"].(map[string]any)
	for _, key := range []string{
		"source",
		"waveforms",
		"spectral_bands",
		"beat_grid",
		"markers",
	} {
		if _, ok := artifacts[key]; !ok {
			t.Fatalf("artifacts missing %q: %#v", key, artifacts)
		}
	}

	waveform := artifacts["waveforms"].(map[string]any)
	if _, ok := waveform["overview"]; !ok {
		t.Fatalf("waveforms missing overview: %#v", waveform)
	}
	if _, ok := waveform["detail"]; !ok {
		t.Fatalf("waveforms missing detail: %#v", waveform)
	}

	provenance := response["provenance"].(map[string]any)
	models := provenance["model_versions"].(map[string]any)
	if models["key"] != "zero-crossing-chroma-v1" {
		t.Fatalf("key model version = %#v", models["key"])
	}
}

func sineSamples(sampleRate int, frequency float64, seconds int) []float64 {
	total := sampleRate * seconds
	samples := make([]float64, total)
	for i := range samples {
		phase := 2 * math.Pi * frequency * float64(i) / float64(sampleRate)
		samples[i] = math.Sin(phase) * 0.65
	}
	return samples
}
