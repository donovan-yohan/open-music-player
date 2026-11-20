#pragma once
#include "pcm_reader.hpp"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#ifdef SOUNDQ_CALLBACK_TEST_SCHEDULE_DRIVER
#include "soundq_transport.hpp"
#endif
namespace soundq::transport { struct PreparedStemKey; struct StemReceipt; }
namespace soundq::nativeengine {
#ifdef SOUNDQ_CALLBACK_TEST_SCHEDULE_DRIVER
struct TestScheduleSnapshot {
    transport::Snapshot value{};
    uint64_t refused=0,history=0,revision=0;
    bool ready=false;
    int error=0;
};
#endif
struct Callbacks {
    virtual ~Callbacks() = default;
    virtual void render(float* stereo, uint32_t frames) noexcept = 0;
    virtual void outputError(int32_t error) noexcept = 0;
};
// stopClose true is a concrete guarantee: no data/error callback can access the
// host again. False retains ALL ownership and can be retried on the control lane.
struct Output {
    virtual ~Output() = default;
    virtual bool open(Callbacks& callbacks, uint32_t& actualRate) = 0;
    virtual bool start() = 0;
    virtual bool stopClose() = 0;
    virtual int32_t xRuns() const noexcept = 0;
};
std::unique_ptr<Output> makeOboeOutput();
// JNI outcome codes, independent of the state JSON producer.
enum class OutputRecovery : int { Unknown = -1, Failed = 0, Healthy = 1, Reset = 2 };
class Registry {
public:
    Registry();
    ~Registry();
    Registry(const Registry&) = delete;
    Registry& operator=(const Registry&) = delete;
    uint64_t open(std::unique_ptr<Output> output);
    bool load(uint64_t handle, int deck, const std::string& path,
              uint64_t identity, uint64_t generation, uint64_t positionMs);
    // Same assignment, prepared and applied at an ordinary listening speed from
    // its first window. Operation 10 changes an assigned ordinary deck's speed.
    bool loadSpeed(uint64_t handle, int deck, const std::string& path,
                   uint64_t identity, uint64_t generation, uint64_t positionMs, double speed);
    bool loadReader(uint64_t handle, int deck, std::shared_ptr<const PcmReaderFactory> factory,
                    uint64_t identity, uint64_t generation, uint64_t positionMs, double speed, bool progressive = false);
    // Explicit intent only: reopen paused, preserving engine/cursor/custody.
    // A changed actual output rate is refused.
    OutputRecovery recoverOutput(uint64_t handle);
    bool control(uint64_t handle, int operation, int deck, double value, uint64_t eventNanos);
    bool crossfade(uint64_t handle, int outgoing, uint64_t outgoingGeneration,
                   int incoming, uint64_t incomingGeneration, uint64_t milliseconds);
    // Six values per clip: startMs, trimInMs, trimOutMs, fadeInMs, fadeOutMs,
    // fullSourceDurationMs (zero for explicit trim). Legacy five-value payloads are strict.
    bool prepareSchedule(uint64_t handle, uint64_t revision, const std::vector<std::string>& paths, const std::vector<int64_t>& values);
    // V2 requires exactly six longs and eight doubles per clip. Plain tempo is
    // all zeros; preserve fields [sourceBpm,startBpm,endBpm,rampStartMs,rampEndMs,
    // sourceAnchorMs,1,curveId], curve 0 linear / 1 smoothstep. Times absolute.
    bool prepareScheduleV2(uint64_t handle, uint64_t revision, const std::vector<std::string>& paths,
                           const std::vector<int64_t>& values,const std::vector<double>& tempo);
    // 1/2 Play/Pause, 3 paused Seek(ms), 4 install candidate, 5 retire, 6 discard candidate.
    bool arrangement(uint64_t handle, int operation, uint64_t value);
    bool scratch(uint64_t handle, int operation, uint64_t instance, uint64_t gesture, uint64_t eventNanos, double rate);
    bool sync(uint64_t handle, uint64_t incoming, uint64_t reference, int beats,
              double referenceBpm, double referenceAnchorMs, double referenceOriginMs,
              double incomingBpm, double incomingAnchorMs, double incomingOriginMs);
    // Latest-only prepared target. Zero glide selects an immediate target at the
    // earliest safely prepared boundary, without pause/seek/reinstall.
    bool liveTempo(uint64_t handle,uint64_t revision,uint64_t instance,uint64_t tag,
                   double sourceBpm,double targetBpm,uint64_t glideFrames,uint64_t reservation=0);
    // One host-owned capability. Claims terminal headroom before exposing a lease.
    uint64_t reserveTempo(uint64_t handle,uint64_t revision,uint64_t instance,double sourceBpm,double originBpm);
    bool restoreTempo(uint64_t handle,uint64_t reservation,uint64_t tag);
    bool releaseTempo(uint64_t handle,uint64_t reservation);
    // Internal one-deck tracer; not a JNI or product API. Caller passes one
    // authorized, aligned prepared stereo window; Host copies it off callback.
    // Nonzero returns are FIFO sequences, not success. Gain 1 ramps to dry;
    // retire after that transition, before supplying another prepared window.
    uint64_t bindPreparedStem(uint64_t handle,const transport::PreparedStemKey& key,
                              uint64_t firstFrame,const std::vector<float>& stereo);
    // Factory captures an authorized immutable member with origin zero and
    // synchronously drained reads/destruction. Invoked only on the worker.
    // Bound is not coverage; window range/ACK and refusal are separate.
    uint64_t bindRollingPreparedStem(uint64_t handle,const transport::PreparedStemKey& key,
                                     std::shared_ptr<const PcmReaderFactory> factory);
    uint64_t setPreparedStemGain(uint64_t handle,uint64_t binding,double gain);
    uint64_t retirePreparedStem(uint64_t handle,uint64_t binding);
    bool readPreparedStem(uint64_t handle,transport::StemReceipt& receipt);
#ifdef SOUNDQ_CALLBACK_TEST_STEM_DRIVER
    uint64_t testStemRefillPending(uint64_t handle);
#endif
    std::string state(uint64_t handle);
#ifdef SOUNDQ_CALLBACK_TEST_SCHEDULE_DRIVER
    // Host-only offline fixture. Pumps real maintenance and observes outstanding
    // worker/command completion; does not render, wait or manufacture readiness.
    bool testScheduleWorkPending(uint64_t handle);
    bool testScheduleSnapshot(uint64_t handle, TestScheduleSnapshot& destination);
#endif
    bool close(uint64_t handle);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
