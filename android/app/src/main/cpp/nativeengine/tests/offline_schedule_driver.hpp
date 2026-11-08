#pragma once
#include "callback_host.hpp"
#include <cassert>
#include <chrono>
#include <thread>

// TEST ONLY. A manually driven Output has no real-time preparation contract.
// Wait for real decoder/DSP replies and callback ACKs before spending samples.
// Neither the producer nor this helper renders nonzero blocks or changes policy.
class OfflineScheduleDriver {
    soundq::nativeengine::Registry* owner = nullptr;
    uint64_t handle = 0;
    uint32_t remaining = 0;
public:
    void attach(soundq::nativeengine::Registry& registry, uint64_t h) {
        owner = &registry; handle = h;
    }
    template<class Drain> void settle(Drain drain) {
        if (!owner) return;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (owner->testScheduleWorkPending(handle)) {
            drain(); // The fixture's sole Output callback, zero frames only.
            assert(std::chrono::steady_clock::now() < deadline);
            // Poll cadence is not readiness. Only real completion admits samples.
            std::this_thread::sleep_for(std::chrono::microseconds(50));
        }
    }
    template<class Drain> void beforeBlock(uint32_t frames, Drain drain) {
        // Single-sample oracles use the same <=256-frame maintenance quantum as
        // Host blocks. Do not double their real JSON/control work every sample.
        if (!remaining || frames >= 256) { settle(drain); remaining = 256; }
        remaining = frames >= remaining ? 0 : remaining - frames;
    }
};
