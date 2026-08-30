// Package stems owns the wire contract, queue class, and worker client for
// on-demand stem separation. It is deliberately independent of the analyzer:
// separation runs on its own Redis list with its own worker pool so a
// minutes-long separation can never starve Beat This analysis or downloads.
package stems

import (
	"fmt"
	"time"
)

// SchemaVersion is the version of the /separate request and manifest contract.
const SchemaVersion = 1

// Canonical channel-set names. These are the only audio-addressable sets; the
// client color registry, edit events, and energy channels all key off them.
const (
	// ChannelSetStems4Demucs is the base coherent four-stem output. The legacy
	// identifier remains wire-compatible with saved UI payloads.
	ChannelSetStems4Demucs = "stems4-demucs-v1"
	// ChannelSetStems5Hybrid adds the deterministic LR4-180Hz kick/perc split of
	// the drums stem. vocals/bass/melody reference the base objects.
	ChannelSetStems5Hybrid = "stems5-hybrid-v1"

	// DefaultChannelSet is what a trigger without an explicit channel set gets.
	DefaultChannelSet = ChannelSetStems5Hybrid
)

// Stem model versions. The stems5 suffix records the crossover so a change to
// either the inference provider/model or the DSP split invalidates artifacts via
// MarkStaleByStemModelVersion.
const (
	StemModelVersionStems4 = "audio-separator-htdemucs-ft-4s-v1"
	StemModelVersionStems5 = "audio-separator-htdemucs-ft-4s-v1+lr4-180"
)

// Worker identity advertised by the stems worker's GET /health and echoed in
// every /separate request as expected_worker/expected_worker_version.
const (
	WorkerName    = "stemsep-worker"
	WorkerVersion = "2026-08-30-1"

	// InferenceProvider and the model artifact constants are the exact health
	// contract that the API admits at startup. The Go worker independently
	// verifies the Python helper against these same immutable values.
	InferenceProvider        = "audio-separator"
	InferenceProviderVersion = "0.47.0"
	ModelFamily              = "demucs"
	ModelName                = "htdemucs_ft"
	ModelConfigSHA256        = "69470b8c1bbd674437b51bc9fb491327a10ab0396b702c93389b9cf750016346"
	ModelDevice              = "cpu"
)

var expectedModelWeightSHA256 = map[string]string{
	"f7e0c4bc-ba3fe64a.th": "ba3fe64ae8ef66ac9a4857222ce48efbdc5eb3ad375cb79dd13debee5aaa4066",
	"d12395a8-e57c48e6.th": "e57c48e6b0e38af4f7118d7bd08c49f0a0c0edf7d09143bdd902ea0d237303e6",
	"92cfc3b6-ef3bcb9c.th": "ef3bcb9c8b40d14ae5d51b6db2587339cc12c6b77c0be151ce6d69002e087bf2",
	"04573f0d-f3cf25b2.th": "f3cf25b222c4eed7cd49dd8b2c9597d50c18bd154090f7b919cfa5f93cf22c49",
}

var expectedOutputMapping = map[string]string{
	"vocals": "omp-vocals.wav",
	"drums":  "omp-drums.wav",
	"bass":   "omp-bass.wav",
	"other":  "omp-other.wav",
}

// Derivation tags recorded per artifact object in the manifest.
const (
	// DerivationSeparator marks a channel emitted directly by the provider.
	DerivationSeparator = "separator"
	// DerivationCrossover marks the deterministic DSP-derived kick/perc pair.
	// These are real audio artifacts that null-sum to drums, which is what makes
	// stems5-hybrid-v1 audio-addressable rather than a visual overlay.
	DerivationCrossover = "dsp-crossover-lr4-180"
)

// channelSets is the single source of truth for wire channel names per set.
// The name "hihat" is RETIRED; "perc" is canonical for the non-kick percussion
// channel, matching the honest UX copy ("Hats & Percussion", "mostly removed").
var channelSets = map[string][]string{
	ChannelSetStems4Demucs: {"vocals", "drums", "bass", "other"},
	ChannelSetStems5Hybrid: {"vocals", "melody", "bass", "kick", "perc"},
}

// channelAliases maps a channel-set channel name onto the base object it
// references. stems5 does not duplicate vocals/bass; "melody" is the DJ-facing
// alias of the model's "other" object under its immutable model prefix.
var channelAliases = map[string]string{
	"melody": "other",
}

var stemModelVersions = map[string]string{
	ChannelSetStems4Demucs: StemModelVersionStems4,
	ChannelSetStems5Hybrid: StemModelVersionStems5,
}

// Channels returns the canonical wire channel names for a channel set.
func Channels(channelSet string) ([]string, bool) {
	channels, ok := channelSets[channelSet]
	if !ok {
		return nil, false
	}
	return append([]string(nil), channels...), true
}

// IsKnownChannelSet reports whether the channel set is one this build can
// separate. Unknown sets must be rejected rather than defaulted, so a client
// typo never silently produces the wrong artifact class.
func IsKnownChannelSet(channelSet string) bool {
	_, ok := channelSets[channelSet]
	return ok
}

// StemModelVersionFor returns the model identity this build produces for a
// channel set.
func StemModelVersionFor(channelSet string) (string, bool) {
	version, ok := stemModelVersions[channelSet]
	return version, ok
}

// BaseObjectChannel resolves a channel name to the object name it is stored
// under. Aliased channels resolve to their base object; everything else is
// stored under its own name.
func BaseObjectChannel(channel string) string {
	if base, ok := channelAliases[channel]; ok {
		return base
	}
	return channel
}

// Job status values for the Redis queue class. They are separate from the
// track_stems row status: Redis carries delivery state, Postgres carries the
// durable authority.
const (
	JobStatusQueued     = "queued"
	JobStatusSeparating = "separating"
	JobStatusComplete   = "complete"
	JobStatusFailed     = "failed"
)

// Job is one unit of separation work.
type Job struct {
	ID               string    `json:"id"`
	TrackID          int64     `json:"trackId"`
	ChannelSet       string    `json:"channelSet"`
	StemModelVersion string    `json:"stemModelVersion"`
	StorageKey       string    `json:"storageKey"`
	SourceFileHash   string    `json:"sourceFileHash,omitempty"`
	Status           string    `json:"status"`
	Error            string    `json:"error,omitempty"`
	RetryCount       int       `json:"retryCount"`
	CreatedAt        time.Time `json:"createdAt"`
	UpdatedAt        time.Time `json:"updatedAt"`
}

// IsTerminal reports whether the job will not be picked up again.
func (j *Job) IsTerminal() bool {
	if j == nil {
		return true
	}
	return j.Status == JobStatusComplete || j.Status == JobStatusFailed
}

// JobID is the deterministic dedupe key for a separation request. It matches the
// track_stems unique identity so a repeated trigger cannot create a second job.
func JobID(trackID int64, channelSet, stemModelVersion string) string {
	return fmt.Sprintf("%d:%s:%s", trackID, channelSet, stemModelVersion)
}
