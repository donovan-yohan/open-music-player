#include "callback_host.hpp"
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <iostream>
#include <string>
#include <thread>
using namespace soundq::nativeengine;
extern std::atomic<int> testDecoders;
extern std::atomic<bool> testHoldOpen, testOpenEntered;
extern std::atomic<bool> testHoldRead, testReadEntered;
std::atomic<bool> joining{false};
namespace soundq::nativeengine::test {
void workerJoin() noexcept { if (testHoldOpen.load() || testHoldRead.load()) joining.store(true); }
}
struct FakeOutput final : Output {
    Callbacks* callback = nullptr;
    bool failClose = false, failStart = false, failOpen = false;
    uint32_t actualRate = 44100;
    int closes = 0, opens = 0, starts = 0;
    int32_t streamXRuns = 0;
    float lastSample = 0;
    bool open(Callbacks& cb, uint32_t& rate) override { ++opens; streamXRuns = 0; callback = &cb; rate = actualRate; return !failOpen; }
    bool start() override { ++starts; return !failStart; }
    bool stopClose() override { ++closes; if (!failClose) streamXRuns = -1; return !failClose; }
    int32_t xRuns() const noexcept override { return streamXRuns; }
    void block() { std::array<float, 512> pcm{}; callback->render(pcm.data(), 256); lastSample = pcm.back(); }
};
std::string deck(const std::string& json, unsigned slot = 0) {
    auto start = json.find("\"decks\":[") + 9;
    while (slot--) start = json.find('{', json.find('}', start));
    return json.substr(start, json.find('}', start) - start + 1);
}
uint64_t firstOutput(const std::string& json, unsigned slot = 0) {
    const auto detail = deck(json, slot);
    const std::string key = "\"firstNonSilentRenderNanos\":";
    const auto at = detail.find(key);
    assert(at != std::string::npos && "native diagnostics must expose the deck-owned first output receipt");
    return std::stoull(detail.substr(at + key.size()));
}
std::string until(Registry& r, uint64_t h, FakeOutput& out, const std::string& needle) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    do {
        out.block();
        auto json = r.state(h);
        if (deck(json).find(needle) != std::string::npos) return json;
        std::this_thread::yield();
    } while (std::chrono::steady_clock::now() < deadline);
    assert(!"native host condition deadline"); return {};
}
std::string terminal(const std::string& state) {
    const std::string key = "\"terminalDecks\":[";
    const auto at = state.find(key);
    assert(at != std::string::npos);
    const auto start = at + key.size();
    if (state.compare(start, 4, "null") == 0) return "null";
    assert(state[start] == '{');
    return state.substr(start, state.find('}', start) - start + 1);
}
uint64_t field(const std::string& json, const std::string& name) {
    const auto key = "\"" + name + "\":";
    const auto at = json.find(key);
    assert(at != std::string::npos);
    return std::stoull(json.substr(at + key.size()));
}
void terminalRecovery(Registry& registry, uint64_t handle, FakeOutput& output, bool readBeforeRecovery) {
    output.streamXRuns = 7;
    assert(registry.load(handle, 0, "/fake/end-on-first-stream", 91, 3, 9980));
    assert(registry.control(handle, 1, 0, 0, 0));
    const auto playing = until(registry, handle, output, "\"playing\":true");
    const auto traversal = field(deck(playing), "traversalRevision");
    assert(traversal > 0 && field(deck(playing), "naturalEndCount") == 0);
    assert(terminal(playing) == "null" && output.lastSample == .125f);
    assert(field(playing, "outputStreamEpoch") == 1 && field(playing, "xRuns") == 7);
    // PCM crosses the sealed endpoint with no state sampling. A decoded last
    // tap followed by silence is then confirmed by the actual natural-end receipt.
    for (int i = 0; i < 4 && output.lastSample != 0; ++i) output.block();
    assert(output.lastSample == 0);
    const auto early = readBeforeRecovery ? terminal(registry.state(handle)) : "null";
    if (readBeforeRecovery) {
        assert(field(early, "outputStreamEpoch") == 1 && field(early, "xRuns") == 7);
    }

    output.streamXRuns = -1; // the disconnected stream can no longer be sampled
    output.callback->outputError(-899);
    output.failStart = true;
    assert(registry.recoverOutput(handle) == OutputRecovery::Failed);
    output.failStart = false;
    assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
    assert(output.opens == 3 && output.closes == 2 && output.xRuns() == 0);
    output.block(); // successor can already publish snapshots before the reader returns
    assert(output.lastSample == 0);
    const auto recovered = registry.state(handle);
    assert(field(recovered, "error") == 0 && field(recovered, "outputStreamEpoch") == 2 && field(recovered, "xRuns") == 0);
    const auto ended = terminal(recovered);
    std::cout << "after recovery: " << ended << std::endl;
    assert(field(ended, "generation") == 3 && field(ended, "identity") == 91);
    assert(field(ended, "traversalRevision") == traversal && field(ended, "naturalEndCount") == 1);
    assert(field(ended, "sourceFrame") == 320000 && field(ended, "sourceFrames") == 320000);
    assert(field(ended, "outputStreamEpoch") == 1 && "terminal epoch must name the stream that rendered EOF");
    if (readBeforeRecovery) assert(ended == early);
    else assert(ended.find("\"xRuns\":-1,") != std::string::npos);

    assert(registry.control(handle, 3, 0, 10000, 0));
    output.block();
    const auto sought = registry.state(handle);
    assert(field(deck(sought), "traversalRevision") != traversal);
    assert(terminal(sought) == ended); // a seek to EOF does not replace natural evidence
    assert(registry.control(handle, 3, 0, 9980, 0));
    output.block();
    assert(registry.control(handle, 1, 0, 0, 0));
    const auto replay = until(registry, handle, output, "\"naturalEndCount\":2");
    const auto fresh = terminal(replay);
    assert(field(fresh, "generation") == 3 && field(fresh, "identity") == 91);
    assert(field(fresh, "traversalRevision") == field(deck(replay), "traversalRevision"));
    assert(field(fresh, "traversalRevision") != traversal && field(fresh, "naturalEndCount") == 2);
    assert(field(fresh, "firstNonSilentRenderNanos") == field(ended, "firstNonSilentRenderNanos"));
    assert(field(fresh, "outputStreamEpoch") == 2 && field(fresh, "xRuns") == 0);
    std::cout << "after new traversal: " << fresh << '\n';
}
int main(int argc, char** argv) {
    Registry registry;
    auto output = std::make_unique<FakeOutput>(); auto* out = output.get();
    auto handle = registry.open(std::move(output));
    assert(handle != 0);
    assert(registry.open(std::make_unique<FakeOutput>()) == 0);
    auto json = registry.state(handle);
    assert(json.find("\"sampleRate\":44100") != std::string::npos);
    assert(json.find("\"openDecoders\":0") != std::string::npos);
    assert(json.find("\"pcmPoolBytes\":12288000") != std::string::npos);
    assert(testDecoders == 0);
    if (argc == 2 && std::string(argv[1]) == "--json") {
        std::cout << json << '\n'; assert(registry.close(handle)); return 0;
    }
    if (argc == 2 && (std::string(argv[1]) == "--terminal-recovery" || std::string(argv[1]) == "--terminal-recovery-retained")) {
        terminalRecovery(registry, handle, *out, std::string(argv[1]) == "--terminal-recovery-retained");
        assert(registry.close(handle)); return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--output-epoch") {
        const auto read = [&](const std::string& key) {
            const auto state = registry.state(handle);
            const auto field = "\"" + key + "\":";
            const auto at = state.find(field);
            assert(at != std::string::npos && "diagnostic field missing");
            return std::stoull(state.substr(at + field.size()));
        };
        const auto initial = read("outputStreamEpoch");
        assert(initial > 0 && read("renderedFrames") == 0 && read("xRuns") == 0);
        out->block();
        assert(read("renderedFrames") == 256 && read("outputStreamEpoch") == initial);
        assert(registry.recoverOutput(handle) == OutputRecovery::Healthy);
        assert(read("outputStreamEpoch") == initial);
        out->callback->outputError(-899);
        out->failStart = true;
        assert(registry.recoverOutput(handle) == OutputRecovery::Failed);
        assert(read("outputStreamEpoch") == initial);
        out->failStart = false;
        assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
        const auto recovered = read("outputStreamEpoch");
        assert(recovered == initial + 1 && read("xRuns") == 0);
        const auto before = read("renderedFrames");
        out->block();
        assert(read("renderedFrames") == before + 256 && read("outputStreamEpoch") == recovered);
        assert(registry.close(handle));
        handle = registry.open(std::make_unique<FakeOutput>());
        assert(handle != 0 && read("outputStreamEpoch") == recovered + 1);
        assert(registry.close(handle)); return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--first-output") {
        assert(firstOutput(json) == 0);
        assert(registry.load(handle, 0, "/fake/first", 17, 17, 0));
        assert(registry.load(handle, 2, "/fake/preview", 18, 18, 0));
        assert(registry.control(handle, 1, 0, 0, 0));
        until(registry, handle, *out, "\"playing\":true");
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        do {
            out->block(); json=registry.state(handle);
            assert(std::chrono::steady_clock::now()<deadline);
        } while (deck(json,2).find("\"ready\":true")==std::string::npos);
        const auto ordinary=firstOutput(json);
        assert(ordinary>0 && firstOutput(json,2)==0);

        assert(registry.control(handle, 7, 2, 0, 0)); // muted while PCM advances
        for (unsigned i=0; i<3; ++i) out->block();
        assert(registry.control(handle, 1, 2, 0, 0));
        for (unsigned i=0; i<3; ++i) out->block();
        json=registry.state(handle);
        assert(deck(json,2).find("\"playing\":true")!=std::string::npos && firstOutput(json,2)==0);
        assert(registry.control(handle, 7, 2, 1, 0));
        assert(firstOutput(registry.state(handle),2)==0);
        out->block();
        json=registry.state(handle);
        const auto preview=firstOutput(json,2);
        assert(preview>ordinary);
        out->block();
        json=registry.state(handle);
        assert(firstOutput(json,2)==preview && firstOutput(json)==ordinary);

        assert(registry.control(handle, 8, 2, 0, 0));
        assert(firstOutput(registry.state(handle),2)==0);
        do {
            out->block(); json=registry.state(handle);
            assert(std::chrono::steady_clock::now()<deadline);
        } while (deck(json,2).find("\"identity\":0")==std::string::npos);
        assert(registry.load(handle, 2, "/fake/preview", 18, 19, 0));
        assert(firstOutput(registry.state(handle),2)==0);
        assert(registry.control(handle, 1, 2, 0, 0));
        do {
            out->block(); json=registry.state(handle);
            assert(std::chrono::steady_clock::now()<deadline);
        } while (firstOutput(json,2)==0);
        assert(firstOutput(json,2)>preview && firstOutput(json)==ordinary);
        assert(registry.close(handle));
        std::cout << "PASS first non-silent render belongs to the current audible deck generation\n";
        return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--handoff-pause") {
        assert(registry.load(handle, 0, "/fake/first", 17, 17, 321));
        assert(registry.control(handle, 1, 0, 0, 0));
        until(registry, handle, *out, "\"playing\":true");
        // Different from the last consumer poll: actually render another block.
        out->block();
        const auto before = deck(registry.state(handle));
        assert(!registry.control(handle, 11, 0, 0, 16));
        assert(registry.control(handle, 11, 0, 0, 17));
        const auto held = deck(registry.state(handle));
        assert(held.find("\"playing\":true") != std::string::npos);
        assert(held.find("\"handoffPaused\":false") != std::string::npos);
        out->block();
        const auto paused = deck(registry.state(handle));
        assert(paused.find("\"handoffPaused\":true") != std::string::npos);
        assert(paused.find("\"playing\":false") != std::string::npos);
        const auto frame = [](const std::string& value) {
            return std::stod(value.substr(value.find("\"sourceFrame\":") + 14));
        };
        assert(frame(paused) == frame(before) && frame(paused) > 321 * 32);
        assert(registry.control(handle, 8, 0, 0, 0));
        assert(deck(registry.state(handle)).find("\"handoffPaused\":false") != std::string::npos);
        until(registry, handle, *out, "\"identity\":0");
        assert(registry.load(handle, 0, "/fake/zero", 18, 18, 0));
        until(registry, handle, *out, "\"ready\":true");
        assert(deck(registry.state(handle)).find("\"handoffPaused\":false") != std::string::npos);
        assert(registry.control(handle, 11, 0, 0, 18));
        assert(deck(registry.state(handle)).find("\"handoffPaused\":false") != std::string::npos);
        out->block();
        const auto zero = deck(registry.state(handle));
        assert(zero.find("\"handoffPaused\":true") != std::string::npos && frame(zero) == 0);
        out->callback->outputError(-899);
        assert(deck(registry.state(handle)).find("\"handoffPaused\":false") != std::string::npos);
        std::cout << "PASS exact moving and zero Pause, held callback, slot reuse, outage: " << frame(paused) << " -> " << frame(zero) << '\n';
        assert(registry.close(handle));
        return 0;
    }
    // Held decoder reads are drained before schedule retirement releases bytes.
    assert(registry.prepareSchedule(handle,99,{"/fake/a","/fake/b"},{0,0,1000,0,0,0,0,1000,0,0}));
    assert(registry.arrangement(handle,4,0));out->block();
    testHoldRead.store(true);registry.state(handle);
    const auto readDeadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    while(!testReadEntered.load() && std::chrono::steady_clock::now()<readDeadline){registry.state(handle);out->block();std::this_thread::yield();}
    assert(testReadEntered.load());assert(registry.arrangement(handle,5,0));out->block();
    std::atomic<bool> retiredGraph{false};
    std::thread retirement([&]{registry.state(handle);retiredGraph.store(true);});
    const auto retirementDeadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    while(!joining.load() && std::chrono::steady_clock::now()<retirementDeadline)std::this_thread::yield();
    assert(joining.load());assert(testHoldRead.load());assert(!retiredGraph.load());joining.store(false);
    testHoldRead.store(false);retirement.join();assert(retiredGraph.load());assert(testDecoders==0);
    assert(registry.state(handle).find("\"scheduleRevision\":0")!=std::string::npos);
    assert(registry.load(handle, 0, "/fake/first", 11, 1, 1500));
    assert(registry.load(handle, 0, "/fake/first", 11, 1, 1500));
    assert(!registry.load(handle, 0, "/fake/other", 12, 1, 0));
    assert(!registry.control(handle, 3, 0, 2000, 0));
    assert(registry.control(handle, 1, 0, 0, 0));
    assert(registry.control(handle, 7, 0, 0.25, 0));
    until(registry, handle, *out, "\"ready\":true"); out->block();
    json = registry.state(handle);
    assert(deck(json).find("\"sourceRate\":32000") != std::string::npos);
    assert(deck(json).find("\"sourceFrames\":320000") != std::string::npos);
    assert(deck(json).find("\"durationMs\":10000") != std::string::npos);
    assert(deck(json).find("\"playing\":true") != std::string::npos);
    // The actual ordinary-deck producer must supply journal qualification evidence.
    assert(deck(json).find("\"rate\":1") != std::string::npos);
    assert(deck(json).find("\"scratching\":false") != std::string::npos);
    assert(out->lastSample == 0.03125f); // real Engine PCM reflects deferred 0.25 gain
    assert(json.find("\"nonSilentCallbacks\":0") == std::string::npos);
    assert(json.find("\"nonSilentCallbacks\":") != std::string::npos);
    assert(registry.control(handle, 3, 0, 2000, 0)); out->block();
    json = registry.state(handle);
    assert(deck(json).find("\"positionMs\":2005") != std::string::npos);
    assert(registry.control(handle, 4, 0, 0, 0));
    assert(registry.control(handle, 5, 0, -1, 10));
    assert(registry.control(handle, 2, 0, 0, 0));
    assert(!registry.control(handle, 6, 0, 0, 0)); out->block();
    assert(deck(registry.state(handle)).find("\"playing\":false") != std::string::npos);
    assert(registry.control(handle, 3, 0, 9000, 0)); out->block();
    assert(registry.control(handle, 1, 0, 0, 0));
    until(registry, handle, *out, "\"eofCount\":1");
    json = registry.state(handle);
    assert(deck(json).find("\"positionMs\":10000") != std::string::npos);
    assert(deck(json).find("\"playing\":false") != std::string::npos);
    // Exact-endpoint seeks also complete through the real Engine/host seam.
    assert(json.find("\"naturalEndVersion\":1") != std::string::npos);
    assert(deck(json).find("\"naturalEndCount\":1") != std::string::npos);
    assert(deck(json).find("\"naturalEndGeneration\":1") != std::string::npos);
    assert(deck(json).find("\"naturalEndIdentity\":11") != std::string::npos);
    if (argc == 2 && std::string(argv[1]) == "--terminal-receipt") {
        const auto ended = terminal(json);
        for (const char* exact : {"\"generation\":1,", "\"identity\":11,", "\"naturalEndCount\":1,",
                 "\"sourceFrame\":320000,", "\"sourceFrames\":320000,", "\"sourceRate\":32000,", "\"xRuns\":0,",
                 "\"outputStreamEpoch\":1,"}) {
            if (ended.find(exact) == std::string::npos) std::cerr << "Missing " << exact << " in " << ended << '\n';
            assert(ended.find(exact) != std::string::npos);
        }
        const auto liveEnd = deck(json);
        const auto missing = liveEnd.find("\"missingPcmFrames\":");
        assert(missing != std::string::npos);
        assert(ended.find(liveEnd.substr(missing, liveEnd.find(',', missing) - missing + 1)) != std::string::npos);
        assert(registry.control(handle, 8, 0, 0, 0));
        json = until(registry, handle, *out, "\"identity\":0");
        assert(terminal(json) == ended); // delayed reader missed the live end and the unload ACK
        assert(registry.load(handle, 0, "/fake/replacement", 22, 2, 10000));
        assert(registry.control(handle, 1, 0, 0, 0));
        json = until(registry, handle, *out, "\"eofCount\":1"); // endpoint admission, not a natural end
        assert(deck(json).find("\"naturalEndCount\":0") != std::string::npos);
        assert(terminal(json) == ended);
        assert(registry.control(handle, 3, 0, 9000, 0)); out->block();
        assert(registry.control(handle, 1, 0, 0, 0));
        json = until(registry, handle, *out, "\"naturalEndCount\":1");
        assert(terminal(json).find("\"generation\":2,\"identity\":22,") != std::string::npos);
        assert(registry.close(handle)); return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--natural-json") {
        std::cout << json << '\n'; assert(registry.close(handle)); return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--error-json") {
        out->callback->outputError(-899);
        json = registry.state(handle);
        assert(deck(json).find("\"naturalEndCount\":0") != std::string::npos);
        std::cout << json << '\n'; assert(registry.close(handle)); return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--retiring-json") {
        assert(registry.control(handle, 8, 0, 0, 0));
        json = registry.state(handle); // intentionally before callback unassign ACK
        assert(deck(json).find("\"naturalEndCount\":0") != std::string::npos);
        std::cout << json << '\n'; assert(registry.close(handle)); return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--replacement-json") {
        assert(registry.load(handle, 0, "/fake/replacement", 22, 2, 0));
        json = registry.state(handle); // old callback deck, new control identity
        assert(deck(json).find("\"identity\":22") != std::string::npos);
        assert(deck(json).find("\"naturalEndCount\":0") != std::string::npos);
        std::cout << json << '\n'; assert(registry.close(handle)); return 0;
    }
    assert(registry.control(handle, 3, 0, 0, 0)); out->block();
    assert(registry.control(handle, 1, 0, 0, 0)); out->block();
    assert(registry.control(handle, 3, 0, 10000, 0)); out->block();
    json = registry.state(handle);
    assert(deck(json).find("\"eofCount\":2") != std::string::npos);
    assert(deck(json).find("\"naturalEndCount\":1") != std::string::npos);
    if (argc == 2 && std::string(argv[1]) == "--sought-json") {
        std::cout << json << '\n'; assert(registry.close(handle)); return 0;
    }
    assert(deck(json).find("\"playing\":false") != std::string::npos);
    assert(registry.load(handle, 0, "/fake/second", 22, 2, 0));
    // Play issued during turnover must target the intended, not retired gen.
    assert(registry.control(handle, 1, 0, 0, 0));
    until(registry, handle, *out, "\"ready\":true"); out->block();
    assert(deck(registry.state(handle)).find("\"playing\":true") != std::string::npos);
    assert(!registry.load(handle, 0, "/fake/first", 11, 1, 0));
    assert(deck(registry.state(handle)).find("\"naturalEndCount\":0") != std::string::npos);
    assert(registry.control(handle, 8, 0, 0, 0));
    json = registry.state(handle);
    assert(deck(json).find("\"identity\":22") != std::string::npos); // no render ACK, still owned
    until(registry, handle, *out, "\"generation\":2,\"identity\":0");
    assert(testDecoders == 0);
    assert(registry.load(handle, 0, "/fake/third", 33, 3, 0));
    until(registry, handle, *out, "\"ready\":true");
    // A load is never an implicit Play, even after prior occurrence was playing.
    assert(deck(registry.state(handle)).find("\"playing\":false") != std::string::npos);
    // Deferred pause beats an earlier Play while the worker is still preparing.
    assert(registry.load(handle, 0, "/fake/fourth", 44, 4, 999999999));
    assert(registry.control(handle, 1, 0, 0, 0));
    assert(registry.control(handle, 2, 0, 0, 0));
    until(registry, handle, *out, "\"ready\":true"); out->block();
    json = registry.state(handle);
    assert(deck(json).find("\"positionMs\":10000") != std::string::npos);
    assert(deck(json).find("\"playing\":false") != std::string::npos);
    assert(registry.control(handle, 8, 0, 0, 0));
    until(registry, handle, *out, "\"generation\":4,\"identity\":0");
    // Destruction must join an in-flight worker, not just forget metadata.
    testHoldOpen.store(true);
    assert(registry.load(handle, 0, "/fake/held", 55, 5, 0));
    registry.state(handle);
    const auto openDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!testOpenEntered.load() && std::chrono::steady_clock::now() < openDeadline) std::this_thread::yield();
    assert(testOpenEntered.load());
    assert(registry.control(handle, 8, 0, 0, 0));
    std::atomic<bool> stopped{false};
    std::thread retire([&] { registry.state(handle); stopped.store(true); });
    // Positively reach the actual worker destructor's join boundary.
    const auto joinDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!joining.load() && std::chrono::steady_clock::now() < joinDeadline) std::this_thread::yield();
    assert(joining.load());
    assert(!stopped.load());
    testHoldOpen.store(false);
    retire.join(); assert(stopped.load()); assert(testDecoders == 0);
    // After Unload ACK, free file authority is visible only after worker join.
    json = registry.state(handle);
    assert(deck(json).find("\"generation\":5,\"identity\":0") != std::string::npos);
    assert(json.find("\"openDecoders\":0") != std::string::npos);
    assert(registry.load(handle, 0, "/fake/invalid", 77, 6, 0));
    until(registry, handle, *out, "\"error\":-3");
    assert(deck(registry.state(handle)).find("\"naturalEndCount\":0") != std::string::npos);
    assert(testDecoders == 0);
    // Decoder-local failure never invalidates root or a fresh intended generation.
    assert(registry.load(handle, 0, "/fake/route", 66, 7, 1500));
    until(registry, handle, *out, "\"ready\":true");
    const auto traversal = [](const std::string& d) { const auto at=d.find("\"traversalRevision\":"); assert(at!=std::string::npos); return d.substr(at,d.find(',',at)-at); };
    const auto admittedTraversal=traversal(deck(registry.state(handle)));
    assert(registry.control(handle, 1, 0, 0, 0));
    until(registry, handle, *out, "\"playing\":true");
    const auto routeOpens = out->opens;
    assert(registry.recoverOutput(0) == OutputRecovery::Failed);
    assert(registry.recoverOutput(handle) == OutputRecovery::Healthy);
    const auto healthyRoute = registry.state(handle);
    assert(deck(healthyRoute).find("\"playing\":true") != std::string::npos && out->opens == routeOpens);
    out->callback->outputError(-899);
    // First consumer of the sticky error; no state read is needed for this result.
    out->failOpen = true;
    assert(registry.recoverOutput(handle) == OutputRecovery::Failed);
    out->failOpen = false;
    assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
    const auto recoveredRoute = registry.state(handle);
    assert(deck(recoveredRoute).find("\"playing\":false") != std::string::npos && out->opens == routeOpens + 2);
    assert(traversal(deck(recoveredRoute)) == admittedTraversal);
    assert(registry.recoverOutput(handle) == OutputRecovery::Healthy);
    out->callback->outputError(-899);
    assert(!registry.control(handle, 1, 0, 0, 0));
    assert(registry.state(handle).find("\"error\":-899") != std::string::npos);
    const auto beforeRecovery = deck(registry.state(handle));
    const auto opensBefore = out->opens;
    // Explicit recovery must recreate output, not merely clear its error latch.
    // Existing output/engine/decoder custody and source cursor survive.
    assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
    assert(registry.state(handle).find("\"error\":0") != std::string::npos);
    assert(testDecoders == 1);
    assert(out->opens == opensBefore + 1);
    const auto afterRecovery = deck(registry.state(handle));
    // Ordinary output recovery is not a source seek or a new journal traversal.
    assert(traversal(afterRecovery) == admittedTraversal);
    const auto cursor = [](const std::string& d) { const auto at=d.find("\"sourceFrame\":"); return d.substr(at,d.find(',',at)-at); };
    assert(cursor(afterRecovery) == cursor(beforeRecovery));
    assert(registry.recoverOutput(handle) == OutputRecovery::Healthy);
    assert(out->opens == opensBefore + 1); // healthy retry never doubles output
    out->block();
    assert(deck(registry.state(handle)).find("\"playing\":false") != std::string::npos);
    assert(registry.control(handle, 1, 0, 0, 0)); out->block();
    assert(deck(registry.state(handle)).find("\"playing\":true") != std::string::npos);
    assert(registry.control(handle,4,0,0,0));
    assert(registry.control(handle,5,0,-1,10)); out->block();
    // Failed open/start and rate mismatch remain gated with decoder custody.
    out->callback->outputError(-899); out->failOpen = true;
    assert(registry.recoverOutput(handle) == OutputRecovery::Failed); assert(testDecoders == 1);
    assert(registry.state(handle).find("\"error\":-899") != std::string::npos);
    out->failOpen = false; out->failStart = true;
    assert(registry.recoverOutput(handle) == OutputRecovery::Failed); assert(testDecoders == 1);
    out->failStart = false; out->actualRate = 48000;
    const auto startsBefore = out->starts;
    assert(registry.recoverOutput(handle) == OutputRecovery::Failed); assert(out->starts == startsBefore);
    assert(registry.state(handle).find("\"error\":-10003") != std::string::npos);
    out->actualRate = 44100; assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
    out->block(); assert(deck(registry.state(handle)).find("\"playing\":false") != std::string::npos);
    const auto sourceCursor = [&](const std::string& state) { const auto d=deck(state);const std::string key="\"sourceFrame\":";const auto at=d.find(key)+key.size();return std::stod(d.substr(at)); };
    const auto recoveredPosition=sourceCursor(registry.state(handle));
    assert(registry.control(handle,1,0,0,0));out->block();
    assert(sourceCursor(registry.state(handle)) > recoveredPosition);
    assert(deck(registry.state(handle)).find("\"playing\":true")!=std::string::npos);
    // Source retirement remains reachable on a disconnected output without recovery.
    out->callback->outputError(-899);
    assert(registry.control(handle, 8, 0, 0, 0));
    until(registry, handle, *out, "\"identity\":0"); assert(testDecoders == 0);
    assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
    assert(registry.load(handle, 0, "/fake/final", 88, 8, 0));
    until(registry, handle, *out, "\"ready\":true");
    out->callback->outputError(-899);
    out->failClose = true;
    const auto refusedOpen = out->opens;
    assert(registry.recoverOutput(handle) == OutputRecovery::Failed);
    assert(out->opens == refusedOpen && testDecoders == 1);
    assert(!registry.close(handle)); assert(testDecoders == 1);
    assert(registry.open(std::make_unique<FakeOutput>()) == 0);
    out->failClose = false;
    assert(registry.close(handle)); assert(testDecoders == 0);
    assert(!registry.close(handle));
    assert(!registry.control(handle, 1, 0, 0, 0));
    auto neverStarted = std::make_unique<FakeOutput>();
    neverStarted->failStart = true;
    assert(registry.open(std::move(neverStarted)) == 0);
    auto next = registry.open(std::make_unique<FakeOutput>());
    assert(next != 0 && next != handle);
    assert(registry.close(next));
    // Installed schedule keeps its revision/global cursor and sources across a
    // disconnect; recovery alone is paused and explicit Play reuses the graph.
    auto scheduled = std::make_unique<FakeOutput>(); out = scheduled.get();
    handle = registry.open(std::move(scheduled));
    assert(registry.prepareSchedule(handle, 1, {"/fake/a"}, {0,0,5000,0,0,0}));
    assert(registry.arrangement(handle,4,0));
    auto readySchedule = [&] {
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(registry.state(handle).find("\"scheduleReady\":true")==std::string::npos) {
            assert(std::chrono::steady_clock::now()<deadline); out->block(); std::this_thread::yield();
        }
    };
    readySchedule(); assert(registry.arrangement(handle,1,0)); out->block();
    assert(registry.arrangement(handle,3,1200)); out->block(); readySchedule();
    out->callback->outputError(-899);
    assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
    json=registry.state(handle);
    assert(json.find("\"globalFrame\":52920")!=std::string::npos);
    assert(json.find("\"schedulePlaying\":false")!=std::string::npos);
    assert(json.find("\"scheduleRevision\":1")!=std::string::npos);
    assert(testDecoders==1); readySchedule();
    assert(registry.arrangement(handle,1,0)); out->block();
    assert(registry.state(handle).find("\"schedulePlaying\":true")!=std::string::npos);
    out->callback->outputError(-899);
    assert(registry.arrangement(handle,5,0));
    const auto retireDeadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    while(registry.state(handle).find("\"scheduleRevision\":0")==std::string::npos) assert(std::chrono::steady_clock::now()<retireDeadline);
    assert(testDecoders==0);
    assert(!registry.prepareSchedule(handle,2,{"/fake/a"},{0,0,5000,0,0,0}));
    assert(registry.recoverOutput(handle) == OutputRecovery::Reset);
    assert(registry.prepareSchedule(handle,2,{"/fake/a"},{0,0,5000,0,0,0}));
    assert(registry.close(handle)); assert(testDecoders==0);
    std::cout << "PASS: lifetime, 4 empty decks, exact source rate/frames, deferred intents, pause gesture, turnover, unload ACK+join, sticky route error, failed-close custody, stale handles\n";
}
