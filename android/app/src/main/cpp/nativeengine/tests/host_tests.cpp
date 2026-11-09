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
    float lastSample = 0;
    bool open(Callbacks& cb, uint32_t& rate) override { ++opens; callback = &cb; rate = actualRate; return !failOpen; }
    bool start() override { ++starts; return !failStart; }
    bool stopClose() override { ++closes; return !failClose; }
    int32_t xRuns() const noexcept override { return 0; }
    void block() { std::array<float, 512> pcm{}; callback->render(pcm.data(), 256); lastSample = pcm.back(); }
};
std::string deck(const std::string& json) {
    const auto start = json.find("\"decks\":[") + 9;
    return json.substr(start, json.find('}', start) - start + 1);
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
    out->callback->outputError(-899);
    assert(!registry.control(handle, 1, 0, 0, 0));
    assert(registry.state(handle).find("\"error\":-899") != std::string::npos);
    const auto beforeRecovery = deck(registry.state(handle));
    const auto opensBefore = out->opens;
    // Explicit recovery must recreate output, not merely clear its error latch.
    // Existing output/engine/decoder custody and source cursor survive.
    assert(registry.control(handle, 9, 0, 0, 0));
    assert(registry.state(handle).find("\"error\":0") != std::string::npos);
    assert(testDecoders == 1);
    assert(out->opens == opensBefore + 1);
    const auto afterRecovery = deck(registry.state(handle));
    const auto cursor = [](const std::string& d) { const auto at=d.find("\"sourceFrame\":"); return d.substr(at,d.find(',',at)-at); };
    assert(cursor(afterRecovery) == cursor(beforeRecovery));
    assert(registry.control(handle, 9, 0, 0, 0));
    assert(out->opens == opensBefore + 1); // healthy retry never doubles output
    out->block();
    assert(deck(registry.state(handle)).find("\"playing\":false") != std::string::npos);
    assert(registry.control(handle, 1, 0, 0, 0)); out->block();
    assert(deck(registry.state(handle)).find("\"playing\":true") != std::string::npos);
    assert(registry.control(handle,4,0,0,0));
    assert(registry.control(handle,5,0,-1,10)); out->block();
    // Failed open/start and rate mismatch remain gated with decoder custody.
    out->callback->outputError(-899); out->failOpen = true;
    assert(!registry.control(handle, 9, 0, 0, 0)); assert(testDecoders == 1);
    assert(registry.state(handle).find("\"error\":-899") != std::string::npos);
    out->failOpen = false; out->failStart = true;
    assert(!registry.control(handle, 9, 0, 0, 0)); assert(testDecoders == 1);
    out->failStart = false; out->actualRate = 48000;
    const auto startsBefore = out->starts;
    assert(!registry.control(handle, 9, 0, 0, 0)); assert(out->starts == startsBefore);
    assert(registry.state(handle).find("\"error\":-10003") != std::string::npos);
    out->actualRate = 44100; assert(registry.control(handle, 9, 0, 0, 0));
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
    assert(registry.control(handle, 9, 0, 0, 0));
    assert(registry.load(handle, 0, "/fake/final", 88, 8, 0));
    until(registry, handle, *out, "\"ready\":true");
    out->callback->outputError(-899);
    out->failClose = true;
    const auto refusedOpen = out->opens;
    assert(!registry.control(handle,9,0,0,0));
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
    assert(registry.control(handle,9,0,0,0));
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
    assert(registry.control(handle,9,0,0,0));
    assert(registry.prepareSchedule(handle,2,{"/fake/a"},{0,0,5000,0,0,0}));
    assert(registry.close(handle)); assert(testDecoders==0);
    std::cout << "PASS: lifetime, 4 empty decks, exact source rate/frames, deferred intents, pause gesture, turnover, unload ACK+join, sticky route error, failed-close custody, stale handles\n";
}
