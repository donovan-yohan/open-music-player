// Package stems owns the wire contract, queue class, and worker client for
// on-demand stem separation. It is deliberately independent of the analyzer:
// separation runs on its own Redis list with its own worker pool so a
// minutes-long separation can never starve Beat This analysis or downloads.
package stems

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"strings"
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
	Generation       int64     `json:"generation"`
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

// GenerationJobID isolates deliveries from previous requests/recovery. Zero is
// retained only for old callers; SQL never admits an unfenced zero generation.
func GenerationJobID(trackID int64, channelSet, model string, generation int64) string {
	id := JobID(trackID, channelSet, model)
	if generation > 0 {
		return fmt.Sprintf("%s:g%d", id, generation)
	}
	return id
}

// Member describes encoded bytes and their decoded, trimmed PCM timeline.
// Energy.FrameCount is intentionally a separate, low-rate visual grid.
type Member struct {
	Channel            string `json:"channel"`
	Key                string `json:"key"`
	Path               string `json:"path,omitempty"`
	SHA256             string `json:"sha256"`
	Bytes              int64  `json:"bytes"`
	DurationMs         int64  `json:"duration_ms"`
	Derivation         string `json:"derivation"`
	SampleFrames       int64  `json:"sample_frames"`
	SampleRateHz       int    `json:"sample_rate_hz"`
	Channels           int    `json:"channels"`
	OriginFrame        *int64 `json:"origin_frame"`
	DelayFrames        *int64 `json:"delay_frames"`
	EncoderDelayFrames *int64 `json:"encoder_delay_frames"`
	DelayProvenance    string `json:"delay_provenance"`
}
type Artifacts struct {
	Objects []Member        `json:"objects"`
	Codec   json.RawMessage `json:"codec"`
	NullSum json.RawMessage `json:"null_sum,omitempty"`
	Energy  json.RawMessage `json:"energy"`
}

const DelayProvenance = "ffmpeg-ogg-opus-preskip-end-trim-v1"

func ValidSHA256(hash string) bool {
	if len(hash) != 64 || hash != strings.ToLower(hash) {
		return false
	}
	_, err := hex.DecodeString(hash)
	return err == nil
}
func ValidSourceHash(hash string) bool {
	return strings.HasPrefix(hash, "sha256:") && ValidSHA256(strings.TrimPrefix(hash, "sha256:"))
}
func MemberKey(trackID int64, model, source string, generation int64, channel, digest string) string {
	return fmt.Sprintf("stems/%d/%s/%s/g%d/%s/%s.opus", trackID, model, strings.TrimPrefix(source, "sha256:"), generation, BaseObjectChannel(channel), digest)
}

// ValidateManifest is shared by the service client, queue worker and publisher.
// No untyped artifact key is eligible for publication or subsequent signing.
func ValidateManifest(m *Manifest, req Request) error {
	if m == nil {
		return fmt.Errorf("nil stems manifest")
	}
	model, ok := StemModelVersionFor(req.ChannelSet)
	if !ok || m.SchemaVersion != SchemaVersion || m.TrackID != req.TrackID || m.ChannelSet != req.ChannelSet || m.StemModelVersion != model || m.Generation != req.Generation {
		return fmt.Errorf("stems manifest identity mismatch")
	}
	if m.SourceStorageKey != req.StorageKey || !ValidSourceHash(m.SourceFileHash) || (req.ExpectedSourceFileHash != "" && m.SourceFileHash != req.ExpectedSourceFileHash) {
		return fmt.Errorf("stems manifest source mismatch")
	}
	worker, version, err := m.ProvenanceIdentity()
	if err != nil {
		return err
	}
	if worker != WorkerName || version != WorkerVersion {
		return fmt.Errorf("%w: manifest worker", ErrWorkerIdentityMismatch)
	}
	var a Artifacts
	if err := json.Unmarshal(m.Artifacts, &a); err != nil {
		return err
	}
	var codec struct {
		Name     string `json:"name"`
		Rate     int    `json:"sample_rate_hz"`
		Channels int    `json:"channels"`
	}
	if err := json.Unmarshal(a.Codec, &codec); err != nil {
		return fmt.Errorf("missing codec: %w", err)
	}
	if codec.Name != "libopus" || codec.Rate != 48000 || codec.Channels != 2 {
		return fmt.Errorf("unsupported member codec")
	}
	if req.ChannelSet == ChannelSetStems5Hybrid {
		var null struct {
			Passed    bool     `json:"passed"`
			Residual  *float64 `json:"residual_db"`
			Threshold float64  `json:"threshold_db"`
			Pair      []string `json:"pair"`
			Against   string   `json:"against"`
		}
		if err := json.Unmarshal(a.NullSum, &null); err != nil {
			return fmt.Errorf("missing crossover null sum: %w", err)
		}
		if !null.Passed || null.Residual == nil || *null.Residual > -80 || null.Threshold != -80 || len(null.Pair) != 2 || null.Pair[0] != "kick" || null.Pair[1] != "perc" || null.Against != "drums" {
			return fmt.Errorf("invalid crossover null sum")
		}
	}
	roles, _ := Channels(req.ChannelSet)
	if req.ChannelSet == ChannelSetStems5Hybrid {
		roles = append(roles, "drums")
	}
	if len(a.Objects) != len(roles) {
		return fmt.Errorf("incomplete stem member set")
	}
	expected := map[string]bool{}
	for _, r := range roles {
		expected[r] = true
	}
	var frames int64
	var encoderDelay *int64
	for _, o := range a.Objects {
		if !expected[o.Channel] {
			return fmt.Errorf("unknown or duplicate stem member %q", o.Channel)
		}
		delete(expected, o.Channel)
		derivation := DerivationSeparator
		if o.Channel == "kick" || o.Channel == "perc" {
			derivation = DerivationCrossover
		}
		if !ValidSHA256(o.SHA256) || o.Bytes <= 0 || o.Key != MemberKey(m.TrackID, model, m.SourceFileHash, m.Generation, o.Channel, o.SHA256) || o.Derivation != derivation || o.Path != "" {
			return fmt.Errorf("invalid stem member identity %q", o.Channel)
		}
		if o.SampleFrames <= 0 || o.SampleRateHz != 48000 || o.Channels != 2 || o.OriginFrame == nil || *o.OriginFrame != 0 || o.DelayFrames == nil || *o.DelayFrames != 0 || o.EncoderDelayFrames == nil || *o.EncoderDelayFrames < 0 || o.DelayProvenance != DelayProvenance {
			return fmt.Errorf("invalid PCM timeline %q", o.Channel)
		}
		if encoderDelay == nil {
			encoderDelay = o.EncoderDelayFrames
		} else if *encoderDelay != *o.EncoderDelayFrames {
			return fmt.Errorf("mixed member encoder delays")
		}
		if frames == 0 {
			frames = o.SampleFrames
		}
		if frames != o.SampleFrames || math.Abs(float64(o.DurationMs)-float64(o.SampleFrames)*1000/float64(o.SampleRateHz)) > 1 {
			return fmt.Errorf("unaligned PCM member %q", o.Channel)
		}
	}
	if math.Abs(float64(m.DurationMs)-float64(frames)*1000/48000) > 1 {
		return fmt.Errorf("manifest duration mismatch")
	}
	var energy struct {
		FrameHz    int               `json:"frame_hz"`
		FrameCount int               `json:"frame_count"`
		Encoding   string            `json:"encoding"`
		Channels   map[string]string `json:"channels"`
	}
	if err := json.Unmarshal(a.Energy, &energy); err != nil {
		return err
	}
	if energy.FrameHz != 80 || energy.Encoding != "uint8-linear" || energy.FrameCount != int(math.Round(float64(frames)*80/48000)) || len(energy.Channels) != len(roles) {
		return fmt.Errorf("invalid energy grid")
	}
	for _, r := range roles {
		data, err := base64.StdEncoding.DecodeString(energy.Channels[r])
		if err != nil || len(data) != energy.FrameCount {
			return fmt.Errorf("invalid energy member %q", r)
		}
	}
	return nil
}

// JobID is the deterministic dedupe key for a separation request. It matches the
// track_stems unique identity so a repeated trigger cannot create a second job.
func JobID(trackID int64, channelSet, stemModelVersion string) string {
	return fmt.Sprintf("%d:%s:%s", trackID, channelSet, stemModelVersion)
}
