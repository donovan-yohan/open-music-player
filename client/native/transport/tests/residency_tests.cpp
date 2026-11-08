#include "soundq_transport.hpp"

#include <array>
#include <atomic>
#include <cstdint>
#include <limits>
#include <thread>
#include <new>
#include <cstdlib>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>

namespace heap_probe {
thread_local bool callback = false;
std::atomic<unsigned> operations{0};
void hit() noexcept { if (callback) operations.fetch_add(1, std::memory_order_relaxed); }
}
void* operator new(std::size_t bytes) {
    heap_probe::hit();
    if (void* memory = std::malloc(bytes == 0 ? 1 : bytes)) return memory;
    throw std::bad_alloc();
}
void* operator new[](std::size_t bytes) { return ::operator new(bytes); }
void operator delete(void* memory) noexcept { heap_probe::hit(); std::free(memory); }
void operator delete[](void* memory) noexcept { ::operator delete(memory); }
void* operator new(std::size_t bytes, std::align_val_t alignment) {
    heap_probe::hit();
    void* memory = nullptr;
    if (posix_memalign(&memory, static_cast<std::size_t>(alignment), bytes == 0 ? 1 : bytes) != 0)
        throw std::bad_alloc();
    return memory;
}
void* operator new[](std::size_t bytes, std::align_val_t alignment) { return ::operator new(bytes, alignment); }
void operator delete(void* memory, std::align_val_t) noexcept { ::operator delete(memory); }
void operator delete[](void* memory, std::align_val_t) noexcept { ::operator delete(memory); }


namespace soundq::transport::test {
extern std::atomic<unsigned> holdStage;
extern std::atomic<unsigned> reachedStage;
}
using namespace soundq::transport;
namespace {
void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
void near(double actual, double expected, const char* message) {
    if (!std::isfinite(actual) || std::abs(actual - expected) > 1e-6) {
        std::fprintf(stderr, "%s: actual=%.17g expected=%.17g\n", message, actual, expected);
        throw std::runtime_error(message);
    }
}
Command command(Operation operation, uint64_t sequence, double value = 0, uint32_t deck = 0,
                uint64_t generation = 1) {
    Command result;
    result.operation = operation; result.sequence = sequence; result.value = value;
    result.deck = deck; result.generation = generation;
    return result;
}
Snapshot snapshot(Engine& engine) {
    Snapshot result;
    check(engine.snapshot(result), "coherent snapshot");
    return result;
}
PcmWindow window(const float* samples, uint64_t first, uint32_t frames) {
    PcmWindow result;
    result.count = 1; result.pages[0] = {samples, first, frames};
    return result;
}
void paged_seam_fractional_reverse() {
    const std::array<float, 16> continuous{1, -1, 3, -3, 7, -7, 13, -13,
                                          21, -21, 31, -31, 43, -43, 57, -57};
    const std::vector<float> firstPage(continuous.begin(), continuous.begin() + 8);
    const std::vector<float> secondPage(continuous.begin() + 8, continuous.end());
    PcmWindow pages = window(firstPage.data(), 0, 4);
    pages.count = 2; pages.pages[1] = {secondPage.data(), 4, 4};
    Engine paged(48000), full(48000);
    check(paged.assignPaged(0, 1, 1, {8, 24000, 77}, pages), "paged assignment admitted");
    auto assign = command(Operation::Assign, 1);
    assign.source = {continuous.data(), 8, 24000, 77};
    check(full.submit(assign), "continuous reference admitted");
    for (double rate : {1.0, -1.0}) {
        for (Engine* engine : {&paged, &full}) {
            check(engine->submit(command(Operation::SetRate, rate > 0 ? 2 : 6, rate)), "rate admitted");
            engine->render(nullptr, 128);
            check(engine->submit(command(Operation::Seek, rate > 0 ? 3 : 7, rate > 0 ? 2.25 : 6.75)), "seam seek");
            check(engine->submit(command(Operation::Play, rate > 0 ? 4 : 8)), "seam play");
        }
        std::array<float, 24> actual{}, expected{};
        paged.render(actual.data(), 12); full.render(expected.data(), 12);
        check(actual == expected, "seam/final-clamp fractional PCM bit identical");
        const auto state = snapshot(paged).decks[0];
        check(state.generation == 1 && state.identity == 77 && state.residentPages == 2,
              "logical assignment and coherent resident descriptors");
        check(state.missingPcmFrames == 0, "adjacent pages have both interpolation taps");
        near(state.sourceFrame, snapshot(full).decks[0].sourceFrame, "fractional seam cursor");
        if (rate > 0) {
            check(state.eofCount == 1 && !state.playing, "logical EOF only at source extent");
            check(paged.submit(command(Operation::Pause, 5)), "pause paged for reverse settle");
            check(full.submit(command(Operation::Pause, 5)), "pause reference for reverse settle");
        }
    }
    Engine rolling(48000), reference(48000);
    check(rolling.assignPaged(0, 1, 1, {8, 24000, 77}, pages), "ramped paged reference");
    assign.sequence = 1;
    check(reference.submit(assign), "ramped continuous reference");
    for (Engine* engine : {&rolling, &reference}) {
        check(engine->submit(command(Operation::Seek, 2, 3.25)), "ramped seam seek");
        check(engine->submit(command(Operation::SetGain, 3, 0.2)), "window gain ramp");
        auto begin = command(Operation::BeginScratch, 4); begin.gesture = 1;
        check(engine->submit(begin), "window reference gesture");
        check(engine->move({0, 1, 1, 5, 7, -0.75}), "window reference rate ramp");
    }
    std::array<float, 38> actual{}, expected{};
    rolling.render(actual.data(), 19); reference.render(expected.data(), 19);
    check(actual == expected, "pre-window live ramps match");
    check(rolling.publishWindow(0, 6, 1, pages), "replace descriptors without resetting live ramps");
    for (unsigned block = 0; block < 8; ++block) {
        rolling.render(actual.data(), 19); reference.render(expected.data(), 19);
        check(actual == expected, "window preserves every gain/rate ramp output sample");
        const auto a = snapshot(rolling).decks[0];
        const auto b = snapshot(reference).decks[0];
        check(a.sourceFrame == b.sourceFrame && a.rate == b.rate && a.eofCount == b.eofCount &&
              a.playing == b.playing && a.scratching == b.scratching && a.gesture == b.gesture,
              "live window replacement preserves exact policy and EOF transitions");
    }
}
void starvation_holds_only_missing_deck() {
    const std::array<float, 16> pcm{1, -1, 2, -2, 4, -4, 8, -8, 16, -16, 32, -32, 64, -64, 128, -128};
    Engine engine(48000), peer(48000);
    check(engine.assignPaged(0, 1, 1, {8, 24000, 42}, window(pcm.data(), 0, 2)), "partial source");
    check(engine.submit(command(Operation::Seek, 2, 1.5)), "missing second tap seek");
    auto begin = command(Operation::BeginScratch, 3); begin.gesture = 9;
    check(engine.submit(begin), "starved gesture");
    check(engine.move({0, 1, 9, 4, 888, -1}), "starved reverse ramp");
    check(engine.submit(command(Operation::SetGain, 5, 0)), "starved gain ramp");
    for (Engine* target : {&engine, &peer}) {
        auto c = command(Operation::Assign, 6, 0, 1);
        c.source = {pcm.data(), 8, 24000, 42};
        check(target->submit(c), "independent peer assignment");
        check(target->submit(command(Operation::Play, 7, 0, 1)), "independent peer play");
    }
    std::array<float, 256> actual{}, expected{};
    engine.render(actual.data(), 128); peer.render(expected.data(), 128);
    check(actual == expected, "missing deck silenced, peer PCM bit identical");
    const auto state = snapshot(engine).decks[0];
    near(state.sourceFrame, 1.5, "missing tap holds only missing deck cursor");
    near(state.rate, -1, "rate ramp advances under starvation");
    check(state.eofCount == 0 && state.playing && state.scratching && state.gesture == 9 &&
          state.identity == 42 && state.missingPcmFrames == 127 && state.residentPages == 1,
          "starvation is not EOF and counts active nonzero-rate missed frames");
    // Reverse from logical EOF must not move the sentinel until PCM is available.
    Engine end(48000);
    check(end.assignPaged(0, 1, 1, {8, 48000, 42}, {}), "empty initial window allowed");
    check(end.submit(command(Operation::SetRate, 2, -1)), "EOF reverse target");
    end.render(nullptr, 128);
    check(end.submit(command(Operation::Seek, 3, 8)), "EOF sentinel seek");
    check(end.submit(command(Operation::Play, 4)), "reverse from EOF");
    end.render(nullptr, 3);
    const auto endState = snapshot(end).decks[0];
    near(endState.sourceFrame, 8, "starved reverse preserves logical EOF cursor");
    check(endState.missingPcmFrames == 3 && endState.eofCount == 0, "missing sentinel taps do not synthesize EOF");
}
void residency_updates_and_tombstones() {
    const std::array<float, 16> pcm{1, -1, 2, -2, 4, -4, 8, -8, 16, -16, 32, -32, 64, -64, 128, -128};
    Engine engine(48000);
    check(engine.assignPaged(0, 1, 1, {8, 24000, 42}, window(pcm.data(), 0, 2)), "initial partial window");
    check(engine.submit(command(Operation::Seek, 2, 1.5)), "gap seek");
    check(engine.submit(command(Operation::Play, 3)), "gap play");
    engine.render(nullptr, 3);
    auto before = snapshot(engine).decks[0];
    check(before.missingPcmFrames == 3 && before.eofCount == 0, "missing frames before recovery");
    check(engine.publishWindow(0, 4, 1, window(pcm.data(), 0, 8)), "complete second tap");
    engine.render(nullptr, 0);
    auto after = snapshot(engine).decks[0];
    near(after.sourceFrame, before.sourceFrame, "window preserves fractional cursor");
    check(after.generation == before.generation && after.identity == before.identity &&
          after.rate == before.rate && after.playing == before.playing &&
          after.missingPcmFrames == before.missingPcmFrames && after.eofCount == 0,
          "window changes residency only");
    std::array<float, 2> output{};
    engine.render(output.data(), 1);
    near(output[0], 3, "replenishment resumes held sample"); near(output[1], -3, "resumed right channel");
    check(engine.publishWindow(0, 5, 1, {}), "empty replacement admitted");
    auto begin = command(Operation::BeginScratch, 6); begin.gesture = 19;
    check(engine.submit(begin), "gesture before missing PCM");
    check(engine.move({0, 1, 19, 7, 55, -1}), "ramp before missing PCM");
    engine.render(nullptr, 40);
    before = snapshot(engine).decks[0];
    check(before.residentPages == 0 && before.scratching && before.gesture == 19, "empty residency keeps gesture");
    check(engine.publishWindow(0, 8, 1, window(pcm.data(), 0, 8)), "window during live ramp");
    engine.render(nullptr, 0);
    after = snapshot(engine).decks[0];
    check(after.sourceFrame == before.sourceFrame && after.rate == before.rate &&
          after.scratching && after.gesture == 19 && after.eofCount == before.eofCount,
          "update preserves cursor ramp and lease");
    engine.render(nullptr, 88);
    near(snapshot(engine).decks[0].rate, -1, "window did not reset ramp progress");
    check(engine.unassign(0, 9, 1), "exact generation unassign admitted");
    // Delayed worker storage can disappear after a refused call, even before render.
    auto late = std::make_unique<std::array<float, 2>>(); late->fill(0.5F);
    check(!engine.publishWindow(0, 10, 1, window(late->data(), 0, 1)), "stale completion refused after admitted retirement");
    late.reset();
    check(!engine.move({0, 1, 19, 10, 56, 1}), "unassign revokes producer gesture immediately");
    check(!engine.submit(command(Operation::Play, 10)), "unassigned generation has no source");
    check(!engine.assignPaged(0, 10, 1, {8, 24000, 42}, {}), "tombstone refuses same generation");
    check(!engine.unassign(0, 10, 2), "wrong generation unassign refused");
    check(!engine.unassign(0, 10, 1), "already retired source refused");
    engine.render(nullptr, 0);
    after = snapshot(engine).decks[0];
    check(after.generation == 1 && after.identity == 0 && after.sourceFrame == 0 &&
          !after.playing && !after.scratching && after.gesture == 0 && after.eofCount == 0 &&
          after.missingPcmFrames == 0 && after.residentPages == 0, "render state cleared with generation tombstone");
    check(engine.completedStructuralSequence() == 9, "retirement receipt");
    check(engine.assignPaged(0, 10, 2, {8, 24000, 42}, window(pcm.data(), 0, 8)), "new occurrence larger generation");
    check(!engine.publishWindow(0, 11, 1, window(pcm.data(), 0, 8)), "old completion cannot change replacement");
    check(engine.submit(command(Operation::Play, 11, 0, 0, 2)), "new occurrence plays");
    engine.render(nullptr, 16);
    after = snapshot(engine).decks[0];
    check(after.generation == 2 && after.eofCount == 1 && !after.playing && after.sourceFrame == 8,
          "ordinary successor reaches actual EOF");
    check(engine.publishWindow(0, 12, 2, {}), "replace residency at logical EOF");
    engine.render(nullptr, 1);
    after = snapshot(engine).decks[0];
    check(after.eofCount == 1 && !after.playing && after.sourceFrame == 8 && after.missingPcmFrames == 0,
          "window at EOF does not restart or count starvation");
}
void paged_validation_and_capacity() {
    std::vector<float> pcm(static_cast<std::size_t>(maxPcmPageFrames + 1) * 2, 0.25F);
    Engine engine(48000);
    const PagedSource source{1000000, 48000, 19};
    check(!engine.assignPaged(4, 1, 1, source, {}), "invalid paged deck");
    check(!engine.assignPaged(0, 0, 1, source, {}), "zero sequence");
    check(!engine.assignPaged(0, 1, 0, source, {}), "zero generation");
    for (const PagedSource invalid : {PagedSource{0, 48000, 19}, PagedSource{1, 0, 19},
                                      PagedSource{1, 48000, 0}, PagedSource{UINT64_MAX, 48000, 19}})
        check(!engine.assignPaged(0, 1, 1, invalid, {}), "invalid logical extent metadata");
    PcmWindow invalid;
    invalid.count = 5;
    check(!engine.assignPaged(0, 1, 1, source, invalid), "more than four pages");
    for (const PcmPage bad : {PcmPage{nullptr, 0, 1}, PcmPage{pcm.data(), 0, 0},
                             PcmPage{pcm.data(), 0, maxPcmPageFrames + 1},
                             PcmPage{pcm.data(), 1000000, 1}, PcmPage{pcm.data(), UINT64_MAX, 4},
                             PcmPage{reinterpret_cast<const float*>(UINTPTR_MAX - 3), 0, 1},
                             PcmPage{reinterpret_cast<const float*>(1), 0, 1}}) {
        invalid = {}; invalid.count = 1; invalid.pages[0] = bad;
        check(!engine.assignPaged(0, 1, 1, source, invalid), "invalid descriptor arithmetic");
    }
    invalid = window(pcm.data(), 10, 10); invalid.count = 2;
    invalid.pages[1] = {pcm.data(), 19, 2};
    check(!engine.assignPaged(0, 1, 1, source, invalid), "overlapping pages");
    invalid.pages[1] = {pcm.data(), 0, 2};
    check(!engine.assignPaged(0, 1, 1, source, invalid), "unsorted pages");
    pcm[1] = std::numeric_limits<float>::infinity();
    check(!engine.assignPaged(0, 1, 1, source, window(pcm.data(), 0, 1)), "infinite PCM");
    pcm[1] = std::nanf("");
    check(!engine.assignPaged(0, 1, 1, source, window(pcm.data(), 0, 1)), "NaN PCM");
    pcm[1] = 0.25F;
    PcmWindow four;
    four.count = 4;
    for (unsigned i = 0; i < 4; ++i) four.pages[i] = {pcm.data(), i * maxPcmPageFrames, maxPcmPageFrames};
    check(engine.assignPaged(0, 1, 1, source, four), "four maximum pages within large logical source");
    engine.render(nullptr, 0);
    check(snapshot(engine).decks[0].residentPages == 4, "all four resident descriptors coherent");
    check(!engine.publishWindow(0, 2, 1, invalid), "invalid publication refuses without new references");
    for (uint64_t seq = 2; seq <= 65; ++seq)
        check(engine.submit(command(Operation::Pause, seq)), "fill existing 64-slot queue");
    check(!engine.publishWindow(0, 66, 1, {}), "full queue rejects page replacement");
    check(!engine.unassign(0, 66, 1), "full queue rejects unassign");
    check(!engine.assignPaged(0, 66, 2, source, {}), "full queue rejects assignment");
    auto begin = command(Operation::BeginScratch, 66); begin.gesture = 1;
    check(!engine.submit(begin), "all structural kinds share FIFO capacity");
    engine.render(nullptr, 0);
    check(snapshot(engine).decks[0].residentPages == 4, "refused publications do not change current window");
    check(engine.publishWindow(0, 66, 1, {}), "failed assign and unassign left producer ownership unchanged");
    check(engine.submit(command(Operation::Seek, 67, 900000)), "seek uses logical extent, not resident pages");
    check(engine.submit(command(Operation::Play, 68)), "play empty residency");
    engine.render(nullptr, 2);
    check(snapshot(engine).decks[0].missingPcmFrames == 2, "logical seek starves instead of EOF");
    auto assign = command(Operation::Assign, 69, 0, 0, 2);
    assign.source = {pcm.data(), 8, 48000, 19};
    check(engine.submit(assign), "fullPCM can replace paged mode");
    check(!engine.publishWindow(0, 70, 2, {}), "window cannot mutate fullPCM source");
    check(engine.unassign(0, 70, 2), "fullPCM unassign supported");
    engine.render(nullptr, 0);
    check(engine.assignPaged(0, 71, 3, source, {}), "paged mode can follow retired fullPCM");
    Engine leased(48000);
    check(leased.assignPaged(0, 1, 1, source, {}), "lease pressure source");
    auto lease = command(Operation::BeginScratch, 2); lease.gesture = 88;
    check(leased.submit(lease), "lease before full FIFO");
    for (uint64_t seq = 3; seq <= 64; ++seq)
        check(leased.submit(command(Operation::Pause, seq)), "lease full FIFO");
    check(!leased.unassign(0, 65, 1), "failed unassign with active gesture");
    check(!leased.assignPaged(0, 65, 2, source, {}), "failed reassignment with active gesture");
    check(leased.move({0, 1, 88, 65, 1, -1}), "failed unassign/reassign do not revoke gesture");
    leased.render(nullptr, 0);
    check(!leased.unassign(0, 65, 1), "accepted move advanced shared admission sequence");
    check(leased.unassign(0, 66, 1), "retirement can retry with fresh sequence");

}
void structural_receipt_cannot_be_overtaken() {
    auto oldPage = std::make_unique<std::array<float, 16>>(); oldPage->fill(0.25F);
    const std::array<float, 16> nextPage{1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7, 8, -8};
    Engine engine(48000);
    check(engine.assignPaged(0, 1, 1, {8, 48000, 42}, window(oldPage->data(), 0, 8)), "receipt initial page");
    auto begin = command(Operation::BeginScratch, 2); begin.gesture = 1;
    check(engine.submit(begin), "receipt gesture");
    engine.render(nullptr, 0);
    check(engine.completedStructuralSequence() == 2, "initial postblock receipt");
    test::reachedStage.store(0); test::holdStage.store(1);
    std::array<float, 2> output{};
    std::thread callback([&] { engine.render(output.data(), 1); });
    while (test::reachedStage.load(std::memory_order_acquire) != 1) std::this_thread::yield();
    const bool accepted = engine.publishWindow(0, 3, 1, window(nextPage.data(), 0, 8));
    const bool moved = engine.move({0, 1, 1, 4, 99, 1});
    test::holdStage.store(0, std::memory_order_release); callback.join();
    check(accepted && moved, "window and newer move admitted after block capture");
    check(snapshot(engine).appliedSequence == 4, "move overtook uncaptured structural publication");
    near(output[0], 0.25, "captured block still read old PCM");
    check(engine.completedStructuralSequence() == 2, "mixed applied sequence cannot release uncaptured page update");
    test::reachedStage.store(0); test::holdStage.store(2);
    std::thread replacement([&] { engine.render(output.data(), 1); });
    while (test::reachedStage.load(std::memory_order_acquire) != 2) std::this_thread::yield();
    const bool premature = engine.completedStructuralSequence() >= 3;
    test::holdStage.store(0, std::memory_order_release); replacement.join();
    check(!premature, "structural receipt withheld until postblock completion");
    check(engine.completedStructuralSequence() == 3, "receipt advances by structural sequence, never move maximum");
    oldPage.reset(); // safe after acquire, no current or pending reference to old bytes
    near(output[0], 2, "replacement actually sampled after acknowledged turnover");
    engine.render(output.data(), 1);
    near(output[0], 3, "continued output after old PCM reclaimed");
    check(engine.completedStructuralSequence() == 3, "move-only blocks never inflate receipt");
}
void rolling_publication_reclaim_and_heap() {
    Engine engine(48000);
    const std::vector<float> peer(400000, 0.5F);
    auto peerAssign = command(Operation::Assign, 1, 0, 1);
    peerAssign.source = {peer.data(), peer.size() / 2, 1, 42};
    check(engine.submit(peerAssign), "rolling independent peer");
    check(engine.submit(command(Operation::Play, 2, 0, 1)), "rolling peer play");
    using Page = std::array<float, 130>;
    std::array<std::unique_ptr<Page>, 2> pool;
    pool[0] = std::make_unique<Page>(); pool[0]->fill(0.25F);
    constexpr uint64_t iterations = 500;
    check(engine.assignPaged(0, 3, 1, {iterations * 64 + 1000, 48000, 42}, window(pool[0]->data(), 0, 65)), "rolling initial page");
    check(engine.submit(command(Operation::Play, 4)), "rolling play");
    engine.render(nullptr, 66); // Establish positive starvation before concurrent replenishment.
    const auto before = heap_probe::operations.load();
    std::atomic<bool> done{false};
    std::atomic<unsigned> errors{0}, snapshots{0};
    std::thread observer([&] {
        while (!done.load(std::memory_order_acquire)) {
            Snapshot state;
            if (!engine.snapshot(state)) continue;
            snapshots.fetch_add(1, std::memory_order_relaxed);
            const auto& d = state.decks[0];
            if (d.generation != 1 || d.identity != 42 || d.residentPages > 1 ||
                d.eofCount != 0 || !std::isfinite(d.sourceFrame)) errors.fetch_add(1);
        }
    });
    std::thread callback([&] {
        std::array<float, 16> output{};
        while (!done.load(std::memory_order_acquire)) {
            heap_probe::callback = true;
            engine.render(output.data(), 8);
            heap_probe::callback = false;
            for (float sample : output)
                if (sample != 0.5F && sample != 0.75F) errors.fetch_add(1);
        }
    });
    uint64_t sequence = 4;
    for (uint64_t i = 1; i <= iterations; ++i) {
        const auto slot = static_cast<std::size_t>(i % 2);
        pool[slot] = std::make_unique<Page>(); pool[slot]->fill(0.25F);
        const auto replacing = ++sequence;
        while (!engine.publishWindow(0, replacing, 1, window(pool[slot]->data(), i * 64, 65)))
            std::this_thread::yield();
        while (engine.completedStructuralSequence() < replacing) std::this_thread::yield();
        // No pending/current descriptors refer to the omitted slot. Free and
        // reuse off callback only after the actual acquire release receipt.
        pool[1 - slot].reset();
        const auto seek = ++sequence;
        while (!engine.submit(command(Operation::Seek, seek, static_cast<double>(i * 64))))
            std::this_thread::yield();
        while (engine.completedStructuralSequence() < seek) std::this_thread::yield();
    }
    done.store(true, std::memory_order_release); callback.join(); observer.join();
    check(errors.load() == 0 && snapshots.load() > 0, "rolling snapshots and independent peer PCM coherent during reclamation");
    check(heap_probe::operations.load() == before, "rolling callback makes no C++ heap operations");
    const auto state = snapshot(engine).decks[0];
    check(state.missingPcmFrames > 0 && state.eofCount == 0 && state.playing && state.residentPages == 1,
          "repeated replacements remain logical source, not occurrence turnover");
}
}
int main() {
    try {
        paged_seam_fractional_reverse();
        std::puts("PASS paged_seam_fractional_reverse");
        starvation_holds_only_missing_deck();
        std::puts("PASS starvation_holds_only_missing_deck");
        residency_updates_and_tombstones();
        std::puts("PASS residency_updates_and_tombstones");
        paged_validation_and_capacity();
        std::puts("PASS paged_validation_and_capacity");
        structural_receipt_cannot_be_overtaken();
        std::puts("PASS structural_receipt_cannot_be_overtaken");
        rolling_publication_reclaim_and_heap();
        std::puts("PASS rolling_publication_reclaim_and_heap");
        std::puts("6/6 residency families passed");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
