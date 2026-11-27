#include "callback_host.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>

using namespace soundq::nativeengine;
using namespace std::chrono_literals;

namespace {
constexpr unsigned OutputRate = 48000;
constexpr unsigned Block = 256;
constexpr unsigned Tail = 2048;
constexpr int Ordinary = 0;
constexpr int Audition = 2;
constexpr uint64_t OrdinaryGeneration = 11;
constexpr uint64_t AuditionGeneration = 23;

struct CaptureOutput final : Output {
    Callbacks* callback = nullptr;
    bool open(Callbacks& c, uint32_t& rate) override { callback = &c; rate = OutputRate; return true; }
    bool start() override { return true; }
    bool stopClose() override { return true; }
    int32_t xRuns() const noexcept override { return 0; } // Not an OS/device measurement.
    std::array<float, Block * 2> render(unsigned frames) {
        std::array<float, Block * 2> pcm{};
        callback->render(pcm.data(), frames);
        return pcm;
    }
};

std::string deck(const std::string& state, int index) {
    const auto start = state.find("\"decks\":[");
    assert(start != std::string::npos);
    auto first = state.find('{', start);
    for (int i = 0; i < index; ++i) first = state.find('{', state.find('}', first));
    const auto last = state.find('}', first);
    assert(first != std::string::npos && last != std::string::npos);
    return state.substr(first, last - first + 1);
}

uint64_t field(const std::string& state, const std::string& key) {
    const auto marker = "\"" + key + "\":";
    const auto start = state.find(marker);
    assert(start != std::string::npos);
    return std::stoull(state.substr(start + marker.size()));
}

double sourceFrame(const std::string& state) {
    const std::string marker = "\"sourceFrame\":";
    const auto start = state.find(marker);
    assert(start != std::string::npos);
    return std::stod(state.substr(start + marker.size()));
}

bool flag(const std::string& state, const std::string& key) {
    const auto marker = "\"" + key + "\":";
    const auto start = state.find(marker);
    assert(start != std::string::npos);
    return state.compare(start + marker.size(), 4, "true") == 0;
}

template<class Predicate>
std::string waitFor(Registry& registry, uint64_t handle, CaptureOutput& output, int slot, Predicate ready) {
    const auto deadline = std::chrono::steady_clock::now() + 8s;
    for (;;) {
        output.render(1);
        const auto state = deck(registry.state(handle), slot);
        if (ready(state)) return state;
        if (std::chrono::steady_clock::now() >= deadline) {
            std::cerr << "Deck " << slot << " did not settle: " << state << '\n';
            std::abort();
        }
        std::this_thread::sleep_for(1ms);
    }
}
}

int main(int argc, char** argv) {
    assert(argc == 5);
    const uint64_t expectedSourceFrames = std::stoull(argv[3]); // independently decoded by runner
    assert(expectedSourceFrames > 30 * OutputRate);
    Registry registry;
    auto owned = std::make_unique<CaptureOutput>();
    auto* output = owned.get();
    const auto handle = registry.open(std::move(owned));
    assert(handle);
    assert(registry.load(handle, Ordinary, argv[1], OrdinaryGeneration, OrdinaryGeneration, 100));
    waitFor(registry, handle, *output, Ordinary, [](const auto& state) { return flag(state, "ready"); });
    assert(registry.control(handle, 1, Ordinary, 0, 0));
    output->render(Block);
    assert(registry.load(handle, Audition, argv[2], AuditionGeneration, AuditionGeneration, 0));
    const auto prepared = waitFor(registry, handle, *output, Audition, [](const auto& state) { return flag(state, "ready"); });
    assert(field(prepared, "identity") == AuditionGeneration && field(prepared, "generation") == AuditionGeneration);
    assert(field(prepared, "sourceRate") == OutputRate && field(prepared, "sourceFrames") == expectedSourceFrames);
    assert(!flag(prepared, "playing") && field(prepared, "positionMs") == 0);
    assert(flag(deck(registry.state(handle), Ordinary), "playing"));
    assert(registry.control(handle, 11, Ordinary, 0, OrdinaryGeneration));
    const auto parked = waitFor(registry, handle, *output, Ordinary, [](const auto& state) { return flag(state, "handoffPaused"); });
    const auto parkedFrame = sourceFrame(parked);
    assert(parkedFrame >= OutputRate / 10);
    assert(registry.control(handle, 1, Audition, 0, 0));
    std::ofstream capture(argv[4], std::ios::binary);
    for (uint64_t at = 0; at < expectedSourceFrames + Tail;) {
        // Isolate the final audible sample from both the preceding block and quiet tail.
        const auto boundary = at < expectedSourceFrames - 1 ? expectedSourceFrames - 1 :
            at < expectedSourceFrames ? expectedSourceFrames : expectedSourceFrames + Tail;
        const auto count = static_cast<unsigned>(std::min<uint64_t>(Block, boundary - at));
        const auto pcm = output->render(count);
        capture.write(reinterpret_cast<const char*>(pcm.data()), count * 2 * sizeof(float));
        const auto snapshot = registry.state(handle);
        const auto state = deck(snapshot, Audition);
        assert(field(state, "identity") == AuditionGeneration && field(state, "generation") == AuditionGeneration);
        assert(field(state, "missingPcmFrames") == 0);
        at += count;
        const bool ended = at >= expectedSourceFrames;
        assert(field(state, "eofCount") == unsigned(ended) && field(state, "naturalEndCount") == unsigned(ended));
        assert(flag(state, "playing") != ended);
        if (ended) {
            assert(field(state, "naturalEndIdentity") == AuditionGeneration);
            assert(field(state, "naturalEndGeneration") == AuditionGeneration);
        }
        const auto peer = deck(snapshot, Ordinary);
        assert(field(peer, "identity") == OrdinaryGeneration && field(peer, "generation") == OrdinaryGeneration);
        assert(!flag(peer, "playing") && flag(peer, "handoffPaused") && sourceFrame(peer) == parkedFrame);
        assert(field(peer, "eofCount") == 0);
        // Give the real decode worker headroom, but never wait for buffers in the render stream.
        std::this_thread::sleep_for(2ms);
    }
    capture.close();
    assert(capture);
    const auto final = registry.state(handle);
    const auto end = deck(final, Audition);
    assert(!flag(end, "playing") && field(end, "eofCount") == 1 && field(end, "error") == 0);

    assert(registry.control(handle, 8, Audition, 0, 0));
    waitFor(registry, handle, *output, Audition, [](const auto& state) {
        return field(state, "identity") == 0 && field(state, "openDecoders") == 0 && !flag(state, "preparing");
    });
    assert(registry.close(handle));
    std::cout << "PASS full encoded input, spare deck exact EOF, no PCM starvation, parked peer unchanged\n";
}
