// TEST ONLY: actual Engine + production ScheduleWorker, deterministic codec IO.
#include "schedule_worker.hpp"
#include <cassert>
#include <chrono>
#include <iostream>
#include <stdexcept>
using namespace soundq::nativeengine;
namespace transport = soundq::transport;
extern std::atomic<int> testDecoders, testReadError;
extern std::atomic<bool> testHoldRead, testReadEntered;
namespace soundq::transport::test {
extern std::atomic<unsigned> holdStage, reachedStage;
}
namespace {
int failures = 0;
void check(bool value, const char* name) {
    std::cout << (value ? "PASS " : "FAIL ") << name << std::endl;
    if (!value) ++failures;
}
template<class Predicate> void until(Predicate predicate) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!predicate()) {
        if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("worker barrier deadline");
        std::this_thread::yield();
    }
}
transport::ScheduleClip clip(uint64_t id, uint64_t start, uint64_t end) {
    transport::ScheduleClip c;
    c.instance = id; c.slot = 0; c.start = start; c.end = end;
    c.trimIn = 0; c.trimOut = static_cast<double>(end - start);
    c.sourceRate = 32000; c.sourceFrames = 320000;
    return c;
}
struct Fixture {
    std::unique_ptr<transport::Schedule> schedule;
    std::vector<std::string> paths;
    uint64_t sequence = 0;
    transport::Engine engine{32000};
    std::unique_ptr<ScheduleWorker> worker;
    transport::Snapshot snap;
    float output[2]{};
    Fixture(std::vector<transport::ScheduleClip> clips, uint64_t frame,
            std::vector<std::string> files = {})
        : schedule(transport::Schedule::compile(1, 32000, clips)), paths(std::move(files)) {
        assert(schedule);
        if (paths.empty()) paths.assign(clips.size(), "/fake/resident");
        assert(engine.installSchedule(++sequence, schedule.get(), frame));
        render();
        worker = std::make_unique<ScheduleWorker>(0, *schedule, paths, engine, sequence);
    }
    ~Fixture() {
        testHoldRead.store(false);
        assert(engine.installSchedule(++sequence, nullptr, 0));
        render(); // ACK graph retirement before releasing borrowed worker pages.
        worker.reset();
    }
    void render() { engine.render(output, 1); assert(engine.snapshot(snap)); }
    void seek(uint64_t frame) {
        assert(engine.scheduleTransport(++sequence, schedule->revision, 3, frame)); render();
        assert(snap.globalFrame == frame);
    }
    uint64_t publication() {
        const auto before = sequence;
        until([&] { worker->pump(snap); return sequence > before; });
        assert(engine.completedStructuralSequence() < sequence);
        return sequence;
    }
    void holdRefill() {
        testReadEntered.store(false); testHoldRead.store(true);
        until([&] { worker->pump(snap); return testReadEntered.load(); });
    }
    void releaseRead() { testHoldRead.store(false); }
};
void healthyRefill() {
    Fixture f({clip(1, 0, 300000)}, 40000);
    check(!f.worker->ready(f.snap), "initial source is not ready before decoding");
    f.publication();
    check(!f.worker->ready(f.snap), "initial queued window is not acknowledged residency");
    f.render();
    check(f.worker->ready(f.snap), "initial ACK admits actual covered cursor");
    assert(f.snap.decks[0].sourceFrame == 40000);
    // Initial pages [12000,60000), [60000,108000). At 65000 the
    // half-page quantization requests [36000,84000), [84000,132000).
    f.seek(65000); f.holdRefill();
    check(f.worker->ready(f.snap), "held decoder keeps covered acknowledged window ready");
    f.seek(107999);
    check(!f.worker->ready(f.snap), "both interpolation taps must be acknowledged, not just the first");
    f.seek(65000);
    f.releaseRead(); const auto receipt = f.publication();
    check(f.worker->ready(f.snap), "queued healthy refill does not revoke old covered taps before ACK");
    for (int i = 0; i < 32; ++i) f.worker->pump(f.snap);
    check(f.sequence == receipt, "unacknowledged replacement fences further page reuse");
    check(f.worker->ready(f.snap), "repeated maintenance preserves old covered readiness before ACK");
    // Hold the actual callback after FIFO capture, before the queued bind applies.
    transport::test::reachedStage.store(0); transport::test::holdStage.store(1);
    std::thread callback([&] { f.engine.render(f.output, 1); });
    until([] { return transport::test::reachedStage.load() == 1; });
    check(f.engine.completedStructuralSequence() < receipt && f.worker->ready(f.snap),
          "actual held callback retains old readiness before applying replacement");
    transport::test::holdStage.store(0); callback.join();
    assert(f.engine.snapshot(f.snap));
    check(f.worker->ready(f.snap), "replacement ACK admits new covered window without another pump");
    // Reverse refill, then move to a tap covered only by the old window.
    f.seek(40000); f.holdRefill(); f.seek(120000);
    check(f.worker->ready(f.snap), "actual old-only cursor is covered while reverse IO is held");
    f.releaseRead(); f.publication();
    check(f.worker->ready(f.snap), "pending reverse window cannot revoke acknowledged old-only taps");
    f.render();
    check(!f.worker->ready(f.snap), "ACK retires old-only coverage immediately without another pump");
    // At 120000 refill is [108000,156000), [156000,204000), but the
    // currently bound [12000,108000) does not cover this real Engine cursor.
    f.holdRefill();
    check(!f.worker->ready(f.snap), "genuinely uncovered current cursor stays unready during IO");
    f.releaseRead(); f.publication();
    check(!f.worker->ready(f.snap), "pending new coverage alone never grants readiness");
    f.render();
    check(f.worker->ready(f.snap), "new-only cursor becomes ready only after replacement ACK");
    check(testDecoders.load() == 1 && decoderPermits.load() == 1,
          "refills retain exactly one decoder permit for the slot");
}
void replacementIdentity() {
    Fixture f({clip(1, 0, 100000), clip(2, 100000, 200000), clip(3, 200000, 300000)}, 40000);
    assert(f.schedule->banks[0] == f.schedule->banks[2]);
    assert(f.schedule->banks[0] != f.schedule->banks[1]);
    f.publication(); f.render();
    f.publication(); f.render(); // stage nearest future occurrence in other bank
    check(f.worker->ready(f.snap), "current and next banks can both be acknowledged");
    f.seek(240000); f.publication();
    check(!f.worker->ready(f.snap), "different occurrence never inherits old-bank readiness before unbind ACK");
    f.render(); f.holdRefill();
    check(!f.worker->ready(f.snap), "bank reuse waits for fresh different-source IO");
    f.releaseRead(); f.publication();
    check(!f.worker->ready(f.snap), "queued different-source binding cannot use predecessor coverage");
    f.render();
    check(f.worker->ready(f.snap), "different source is admitted after its own binding ACK");
}
void refillFailure() {
    Fixture f({clip(1, 0, 300000)}, 40000);
    f.publication(); f.render();
    f.seek(65000); f.holdRefill();
    testReadError.store(SQ_FILE_DECODE); f.releaseRead(); f.publication();
    check(f.worker->error() == SQ_FILE_DECODE && f.worker->errorInstance() == 1,
          "refill failure preserves original occurrence error attribution");
    check(!f.worker->ready(f.snap), "refill error revokes readiness despite still-covered old taps");
    f.render();
    check(!f.worker->ready(f.snap), "failed empty binding stays unready after ACK");
    testReadError.store(0);
}
void fourDecoderBound() {
    std::vector<transport::ScheduleClip> clips;
    for (uint64_t id = 1; id <= 4; ++id) clips.push_back(clip(id, 0, 300000));
    auto schedule = transport::Schedule::compile(1, 32000, clips); assert(schedule);
    std::vector<std::string> paths(4, "/fake/four");
    transport::Engine engine(32000); uint64_t sequence = 0; float output[2]{};
    assert(engine.installSchedule(++sequence, schedule.get(), 40000)); engine.render(output, 1);
    std::array<std::unique_ptr<ScheduleWorker>, 4> workers;
    for (unsigned slot = 0; slot < 4; ++slot)
        workers[slot] = std::make_unique<ScheduleWorker>(slot, *schedule, paths, engine, sequence);
    transport::Snapshot snap;
    until([&] {
        assert(engine.snapshot(snap));
        for (auto& worker : workers) worker->pump(snap);
        engine.render(output, 1); assert(engine.snapshot(snap));
        return std::all_of(workers.begin(), workers.end(), [&](const auto& w) { return w->ready(snap); });
    });
    DecoderPermit fifth;
    check(testDecoders.load() == 4 && decoderPermits.load() == 4 && !fifth.acquire(),
          "actual four-worker graph retains hard four-decoder cap");
    assert(engine.installSchedule(++sequence, nullptr, 0)); engine.render(output, 1);
    for (auto& worker : workers) worker.reset();
}
void distantSyncDemand() {
    std::vector<float> peerPcm(96000, 0.125f);
    Fixture f({clip(1, 0, 300000), clip(2, 0, 300000)}, 40000);
    assert(f.schedule->clips[1].slot == 1);
    f.publication(); f.render();
    transport::PcmWindow peer;
    peer.pages[0] = {peerPcm.data(), 0, 48000}; peer.count = 1;
    assert(f.engine.bindSchedule(++f.sequence, 1, 2, peer)); f.render();
    assert(f.engine.scheduleTransport(++f.sequence, 1, 1, 0)); f.render();
    // A 32-beat group has one legal incoming origin in this clip; unlike
    // beat-only sync, its phase cannot collapse back near the current cursor.
    transport::LiveSync sync{1, 2, 32, 120, 1406.25, 1406.25, 120, 7812.5, 7812.5};
    assert(f.engine.sync(++f.sequence, 1, sync)); f.render();
    const auto target = f.snap.decks[0].demandSourceFrame;
    assert(target > 200000 && f.snap.decks[0].sourceFrame < 48000);
    f.holdRefill(); f.releaseRead(); f.publication();
    check(f.worker->ready(f.snap), "pending distant sync page keeps actual current taps ready");
    f.render();
    check(f.worker->ready(f.snap), "distant sync refill also retains current coverage after ACK");
    f.seek(static_cast<uint64_t>(target));
    check(f.worker->ready(f.snap), "actual Engine sync demand is resident in second page after ACK");
}
}
int main() {
    healthyRefill();
    replacementIdentity();
    refillFailure();
    distantSyncDemand();
    fourDecoderBound();
    check(testDecoders.load() == 0 && decoderPermits.load() == 0, "retirement drains decoder and permit");
    std::cout << "readiness failures=" << failures << std::endl;
    return failures ? 1 : 0;
}
