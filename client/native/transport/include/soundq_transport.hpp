#pragma once
#define SOUNDQ_LIVE_TEMPO_API 1
#define SOUNDQ_NATURAL_END_API 1

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace soundq::transport {

// Portable engine, not an OS player. One serialized producer, one render consumer.
// Borrowed PCM is immutable interleaved stereo float32 at sourceRate. Keep it alive
// until output is quiesced and Engine destroyed (prototype lifetime policy).
struct Source {
    const float* samples = nullptr;
    uint64_t frames = 0;
    uint32_t sourceRate = 0;
    uint64_t identity = 0;
};

// Logical extent is independent of resident PCM. Decoder workers fill immutable
// pages, then the serialized control producer publishes descriptors. Missing
// interpolation taps hold/silence only that deck, never create logical EOF.
struct PagedSource {
    // Zero explicitly means unknown/unsealed decoded end, NOT current coverage.
    // Positive frames are exact. Only ordinary paged playback permits unknown.
    uint64_t frames = 0;
    uint32_t sourceRate = 0;
    uint64_t identity = 0;
    // Initial ordinary listening speed, applied with the first window and no
    // ramp. The producer must supply pages already prepared for this speed.
    double speed = 1;
};
// Ordinary listening speed bounds accepted by the engine envelope. Products may
// admit a narrower range; the engine never interprets speed as BPM/tempo law.
constexpr double minListeningSpeed = 0.25, maxListeningSpeed = 4;
constexpr uint32_t maxPcmPageFrames = 48000;
struct PcmPage {
    const float* samples = nullptr;
    uint64_t firstFrame = 0;
    uint32_t frames = 0;
};
struct PcmWindow {
    std::array<PcmPage, 4> pages{};
    uint32_t count = 0;
};

struct DeckSnapshot {
    uint64_t generation = 0;
    uint64_t identity = 0;
    double sourceFrame = 0;
    double rate = 0;
    bool playing = false;
    bool scratching = false;
    uint64_t gesture = 0;
    uint64_t eofCount = 0;
    uint64_t missingPcmFrames = 0;
    uint32_t residentPages = 0;
    double nominalSourceFrame = 0;
    uint64_t lastMoveEventNanos = 0, lastMoveAppliedNanos = 0, lastMoveSequence = 0;
    bool heldZero = false;
    uint64_t syncReference = 0, syncBoundaryFrame = 0;
    uint32_t syncBeats = 0, syncState = 0;
    double syncPhaseErrorFrames = 0, demandSourceFrame = -1;
    uint64_t processingEpoch = 0;
    double effectiveBpm = 0;
    uint64_t tempoGeneration = 0;
    double boundaryGain = 1;
    // Ordinary (not schedule/scratch) decoded-EOF consumption only. The deck
    // index plus generation/identity bind the receipt to the caller's occurrence.
    // Assign/Seek/SetRate/BeginScratch use their structural sequence as revision.
    // Compare captured revision to CURRENT traversal before acting on a receipt;
    // count is cumulative within an assignment, not authority for a later seek.
    uint64_t traversalRevision = 0;
    uint64_t naturalEndCount = 0, naturalEndGeneration = 0, naturalEndIdentity = 0;
    uint64_t naturalEndTraversalRevision = 0;
};
struct LiveSync {
    uint64_t incoming = 0, reference = 0;
    uint32_t beats = 0;
    double referenceBpm = 0, referenceAnchorMs = 0, referenceOriginMs = -1;
    double incomingBpm = 0, incomingAnchorMs = 0, incomingOriginMs = -1;
};
// Immutable metadata, compiled off callback. Frame endpoints use floor(ms*rate/1000).
// Source trims are fractional source frames so millisecond intent is not truncated.
// Absolute output-frame shared law. Original beat anchor stays in source frames.
enum class TempoOverlapPolicy : uint32_t {
    StrictSharedPhase = 1, // legacy: identical absolute law and integer beat phase
    IndependentConstant = 2, // endpoints must agree; no shared pulse or phase claim
    SharedSourceBounds = 3, // identical absolute law; no beat-phase claim
};
struct TempoLaw {
    bool preserve = false;
    uint32_t curve = 0; // 0 linear BPM, 1 smoothstep BPM
    double sourceBpm = 0, startBpm = 0, endBpm = 0;
    double first = 0, end = 0; // exact fractional output-frame boundaries
    double sourceAnchor = 0;
    TempoOverlapPolicy overlapPolicy = TempoOverlapPolicy::StrictSharedPhase;
};
struct TempoSegment {
    TempoLaw tempo{};
    double frame = 0, source = 0;
};
constexpr size_t maxTempoSegments = 64;
struct ScheduleClip {
    uint64_t instance = 0;
    uint32_t slot = 0;
    uint64_t start = 0, end = 0;
    double trimIn = 0, trimOut = 0;
    uint32_t sourceRate = 0;
    uint64_t sourceFrames = 0;
    uint64_t fadeIn = 0, fadeOut = 0;
    double gain = 1;
    TempoLaw tempo{};
    // Runtime continuation anchor. Authored start/trims/fades remain unchanged.
    double mapFrame = -1, mapSource = 0;
    // Immutable bounded prefix for ordinary backward seek. Latest law is above.
    // A new edit after seeking replaces only segments at/after its boundary.
    std::vector<TempoSegment> tempoHistory{};
};
class Schedule {
public:
    struct Span { uint64_t start = 0, end = 0; std::array<int32_t,4> clips{{-1,-1,-1,-1}}; };
    static std::unique_ptr<Schedule> compile(uint64_t revision, uint32_t outputRate,
                                           const std::vector<ScheduleClip>& clips);
    uint64_t revision = 0, duration = 0;
    uint32_t outputRate = 0;
    bool hasPreservedTempo = false;
    std::vector<ScheduleClip> clips;
    std::vector<Span> spans;
    std::vector<uint32_t> banks;
};
struct LatencySample { uint64_t eventNanos = 0, appliedNanos = 0, sequence = 0; };
struct Snapshot {
    uint64_t scheduleRevision = 0, globalFrame = 0, durationFrames = 0;
    bool schedulePlaying = false, scheduleEnded = false, scheduleBuffering = false;
    uint64_t tempoApplied = 0, tempoTerminal = 0;
    uint64_t renderedFrames = 0;
    uint64_t appliedSequence = 0;
    uint64_t lastGestureEventNanos = 0;
    uint64_t lastGestureAppliedFrame = 0;
    uint64_t refusedCommands = 0;
    std::array<DeckSnapshot, 4> decks{};
    std::array<LatencySample, 64> latency{};
    uint64_t latencyCount = 0, movesCoalesced = 0, syncReschedules = 0;
};

enum class Operation : uint32_t {
    Assign, Play, Pause, Seek, SetRate, SetGain,
    BeginScratch, EndScratch, CancelScratch
};
struct Command {
    Operation operation = Operation::Pause;
    uint32_t deck = 0;
    uint64_t sequence = 0;
    uint64_t generation = 0;
    uint64_t gesture = 0;
    Source source{};
    double value = 0;
};
struct ScratchMove {
    uint32_t deck = 0;
    uint64_t generation = 0;
    uint64_t gesture = 0;
    uint64_t sequence = 0;
    uint64_t eventNanos = 0;
    double rate = 0;
};

class Engine {
public:
    explicit Engine(uint32_t outputRate);
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;
    // Schedule and all windows remain borrowed until replacing/retiring post-block receipt.
    bool installSchedule(uint64_t sequence, const Schedule* schedule, uint64_t globalFrame) noexcept;
    bool bindSchedule(uint64_t sequence, uint64_t revision, uint64_t instance, const PcmWindow& window) noexcept;
    // Latest intent invalidates an older pending handoff without changing audio.
    bool tempoIntent(uint64_t revision, uint64_t tag) noexcept;
    // Callback-consumed receipt for a mathematically unchanged constant law.
    bool acknowledgeTempo(uint64_t sequence, uint64_t revision, uint64_t instance,
                          uint64_t tag, double sourceBpm, double targetBpm) noexcept;
    // Refresh producer metadata from the post-block receipt after a handoff.
    bool settleTempo(uint64_t tag) noexcept;
    // Rejected/stale descriptor: reclaim only after tempoTerminal >= tag AND
    // structural completion. Applied graph stays borrowed until a later applied
    // handoff or install/retire post-block receipt; pages until binding replacement.
    // changedMask addresses stable slots; unchanged bindings/decks are retained.
    bool handoffTempo(uint64_t sequence, const Schedule* graph, uint64_t tag,
                      uint64_t boundary, uint32_t changedMask,
                      const std::array<PcmWindow,4>& windows) noexcept;
    // 1 Play, 2 Pause, 3 atomic paused Seek; 7 master gain in millionths.
    bool scheduleTransport(uint64_t sequence, uint64_t revision, uint32_t operation, uint64_t globalFrame) noexcept;
    bool scratch(uint64_t sequence, uint64_t revision, uint32_t operation, uint64_t instance,
                 uint64_t gesture, uint64_t eventNanos, double rate) noexcept;
    bool sync(uint64_t sequence, uint64_t revision, const LiveSync& request) noexcept;
    // Zero frames cancels the ordinary pair, keeping outgoing at its current cursor.
    bool crossfade(uint64_t sequence, uint32_t outgoing, uint64_t outgoingGeneration,
                   uint32_t incoming, uint64_t incomingGeneration, uint64_t frames) noexcept;
    // Callback timestamp is CLOCK_MONOTONIC / Android uptime. Zero uses steady_clock.
    void renderAt(float* stereoOutput, uint32_t frames, uint64_t callbackNanos) noexcept;
    // Return false on malformed command or full fixed-capacity structural queue.
    // Sequence and assignment generations are caller-provided nonzero values.
    bool submit(const Command& command) noexcept;
    // Same producer/FIFO/sequence namespace as submit. Failure borrows nothing.
    // Pages are sorted, nonoverlapping and inside the exact logical source.
    bool assignPaged(uint32_t deck, uint64_t sequence, uint64_t generation,
                     const PagedSource& source, const PcmWindow& window) noexcept;
    // Replace residency only, preserving cursor/rate/gain/gesture and logical EOF.
    bool publishWindow(uint32_t deck, uint64_t sequence, uint64_t generation,
                       const PcmWindow& window) noexcept;
    // Ordinary listening speed handoff: replace residency AND set the deck rate
    // in the same consumed block, without a smoothing ramp. Source cursor,
    // traversal revision, logical extent and EOF/natural-end evidence are
    // unchanged; only consumption pace changes. Refused while scratching.
    bool publishWindowRate(uint32_t deck, uint64_t sequence, uint64_t generation,
                           const PcmWindow& window, double rate) noexcept;
    // Same-generation decoded-EOS seal plus final window/rate. Positive exact end
    // is immutable once sealed. Does not move cursor or mint a traversal/receipt.
    bool publishWindowEnd(uint32_t deck, uint64_t sequence, uint64_t generation,
                          const PcmWindow& window, uint64_t exactEnd, double speed) noexcept;
    // Keeps generation tombstone, clears source/play/gesture. A newer assignment
    // must use a larger generation. Pending old decoder replies stay inadmissible.
    bool unassign(uint32_t deck, uint64_t sequence, uint64_t generation) noexcept;
    // Release/acquire post-block FIFO receipt, independent of coalesced moves.
    // A replaced window may be reclaimed after its replacing structural receipt
    // ONLY if no later queued/current publication references those same bytes.
    // Once callbacks stop, quiesce output before releasing any remaining pages.
    uint64_t completedStructuralSequence() const noexcept;
    // Bounded coalescing lane, never stores structural events. Move can arrive
    // before Begin is rendered; do not consume it until its matching lease applies.
    bool move(const ScratchMove& movement) noexcept;
    // No heap operations, mutex, IO, decoder, JNI or caller callbacks here.
    void render(float* stereoOutput, uint32_t frames) noexcept;
    // Coherent published snapshot. Nonblocking: false if reader falls behind.
    bool snapshot(Snapshot& destination) const noexcept;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace soundq::transport
