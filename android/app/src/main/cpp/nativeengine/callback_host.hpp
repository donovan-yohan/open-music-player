#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#ifdef SOUNDQ_CALLBACK_TEST_SCHEDULE_DRIVER
#include "soundq_transport.hpp"
#endif
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
class Registry {
public:
    Registry();
    ~Registry();
    Registry(const Registry&) = delete;
    Registry& operator=(const Registry&) = delete;
    uint64_t open(std::unique_ptr<Output> output);
    bool load(uint64_t handle, int deck, const std::string& path,
              uint64_t identity, uint64_t generation, uint64_t positionMs);
    // Operation 9 reopens failed output paused, preserving engine/cursor/custody.
    // Explicit user intent only. A changed actual output rate is refused.
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
