#include "soundq_transport.hpp"

#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <thread>
#include <new>
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
Command command(Operation op, uint64_t sequence, uint32_t deck = 0,
                uint64_t generation = 1, double value = 0) {
    Command c;
    c.operation = op; c.sequence = sequence; c.deck = deck;
    c.generation = generation; c.value = value;
    return c;
}
void assign(Engine& engine, const std::vector<float>& pcm, uint64_t sequence = 1,
            uint32_t deck = 0, uint64_t generation = 1, uint32_t rate = 48000,
            uint64_t identity = 1) {
    auto c = command(Operation::Assign, sequence, deck, generation);
    c.source = {pcm.data(), pcm.size() / 2, rate, identity};
    check(engine.submit(c), "assign admitted");
}
Snapshot snapshot(Engine& engine) {
    Snapshot result;
    check(engine.snapshot(result), "snapshot readable without concurrent writer");
    return result;
}
void ordinary_playback() {
    const std::vector<float> pcm{1, -1, 2, -2, 3, -3, 4, -4};
    Engine engine(48000);
    assign(engine, pcm);
    check(engine.submit(command(Operation::Play, 2)), "play admitted");
    float output[12]{};
    engine.render(output, 6);
    for (unsigned i = 0; i < 12; ++i)
        near(output[i], i < pcm.size() ? pcm[i] : 0, "one-deck sample/EOF");
    const auto state = snapshot(engine);
    near(state.decks[0].sourceFrame, 4, "EOF cursor clamped");
    check(state.decks[0].eofCount == 1, "one EOF transition");
    check(!state.decks[0].playing, "EOF is not rendering");
    check(state.renderedFrames == 6 && state.appliedSequence == 2, "publication counters");
}
void endpoint_seek_completion() {
    const std::vector<float> pcm(960, 0.25F);
    for (bool paused : {false, true}) {
        Engine engine(48000);
        assign(engine, pcm);
        uint64_t sequence = 1;
        if (!paused) check(engine.submit(command(Operation::Play, ++sequence)), "endpoint initial play");
        check(engine.submit(command(Operation::Seek, ++sequence, 0, 1, 480)), "exact endpoint seek");
        engine.render(nullptr, 1);
        if (paused) {
            check(snapshot(engine).decks[0].eofCount == 0, "paused endpoint is not completion");
            check(engine.submit(command(Operation::Play, ++sequence)), "play from paused endpoint");
            engine.render(nullptr, 1);
        }
        auto state = snapshot(engine);
        check(state.decks[0].eofCount == 1, "endpoint produces one completion");
        check(!state.decks[0].playing, "endpoint stops ordinary motion");
        engine.render(nullptr, 10);
        check(snapshot(engine).decks[0].eofCount == 1, "endpoint never repeats completion");
        check(engine.submit(command(Operation::Seek, ++sequence, 0, 1, 0)), "replay seek");
        check(engine.submit(command(Operation::Play, ++sequence)), "replay play");
        engine.render(nullptr, 480);
        check(snapshot(engine).decks[0].eofCount == 2, "replay produces fresh completion");
    }
}
void fractional_pause_seek() {
    std::vector<float> pcm(64);
    for (unsigned i = 0; i < 32; ++i) { pcm[2 * i] = static_cast<float>(i); pcm[2 * i + 1] = -static_cast<float>(i); }
    Engine engine(48000);
    assign(engine, pcm, 1, 0, 1, 24000);
    check(engine.submit(command(Operation::Play, 2)), "fractional play");
    float output[16]{};
    engine.render(output, 8);
    for (unsigned i = 0; i < 8; ++i) {
        near(output[2 * i], i * 0.5, "fractional forward left");
        near(output[2 * i + 1], -static_cast<double>(i) * 0.5, "fractional forward right");
    }
    check(engine.submit(command(Operation::Pause, 3)), "pause");
    engine.render(output, 8);
    for (float sample : output) near(sample, 0, "paused silence");
    near(snapshot(engine).decks[0].sourceFrame, 4, "pause freezes cursor");
    check(engine.submit(command(Operation::Play, 4)), "resume from pause");
    engine.render(output, 8);
    for (unsigned i = 0; i < 8; ++i) {
        near(output[2 * i], 4 + i * 0.5, "pause/play resumes left");
        near(output[2 * i + 1], -4 - i * 0.5, "pause/play resumes right");
    }
    check(engine.submit(command(Operation::Pause, 5)), "pause again");
    check(engine.submit(command(Operation::Seek, 6, 0, 1, 12.25)), "seek");
    engine.render(nullptr, 0);
    near(snapshot(engine).decks[0].sourceFrame, 12.25, "seek while paused");
    check(engine.submit(command(Operation::SetRate, 7, 0, 1, -1)), "reverse rate");
    engine.render(nullptr, 128); // Control rate ramps settle even while paused.
    check(engine.submit(command(Operation::Play, 8)), "reverse play");
    engine.render(output, 8);
    for (unsigned i = 0; i < 8; ++i) {
        near(output[2 * i], 12.25 - i * 0.5, "fractional reverse left");
        near(output[2 * i + 1], -12.25 + i * 0.5, "fractional reverse right");
    }
    std::vector<float> nonlinear(8192);
    for (unsigned i = 0; i < nonlinear.size(); ++i)
        nonlinear[i] = static_cast<float>((i * 31) % 83) / 128;
    for (uint32_t sourceRate : {32000U, 44100U, 96000U}) {
        for (double rate : {-1.25, 0.75}) {
            Engine probe(48000);
            assign(probe, nonlinear, 1, 0, 1, sourceRate);
            check(probe.submit(command(Operation::SetRate, 2, 0, 1, rate)), "numerical rate");
            probe.render(nullptr, 128);
            check(probe.submit(command(Operation::Seek, 3, 0, 1, 2000.25)), "numerical fractional seek");
            check(probe.submit(command(Operation::Play, 4)), "numerical play");
            std::array<float, 514> samples{};
            probe.render(samples.data(), 257);
            double position = 2000.25;
            for (unsigned i = 0; i < 257; ++i) {
                const auto index = static_cast<std::size_t>(position);
                const double fraction = position - static_cast<double>(index);
                for (unsigned channel = 0; channel < 2; ++channel) {
                    const double expected = (nonlinear[2 * index + channel] * (1 - fraction) +
                                             nonlinear[2 * (index + 1) + channel] * fraction) * std::min(1.0, std::abs(rate));
                    near(samples[2 * i + channel], expected, "nonlinear source every fractional sample");
                }
                position += rate * sourceRate / 48000;
            }
            near(snapshot(probe).decks[0].sourceFrame, position, "source/output ratio exact cursor");
        }
    }
}
void scratch_lease_and_ramps() {
    const std::vector<float> pcm(8192, 1.0F);
    Engine engine(48000);
    assign(engine, pcm);
    check(engine.submit(command(Operation::Seek, 2, 0, 1, 1024)), "scratch initial position");
    auto begin = command(Operation::BeginScratch, 3); begin.gesture = 41;
    check(engine.submit(begin), "begin admitted");
    check(engine.move({0, 1, 41, 4, 1234, -1}), "move before render retained");
    float output[256]{};
    engine.render(output, 128);
    double cursor = 1024;
    for (unsigned i = 0; i < 128; ++i) {
        const double rate = 1 - (i + 1) / 64.0;
        cursor += rate;
        near(output[2 * i], std::abs(rate), "signed rate ramp/zero attenuation left");
        near(output[2 * i + 1], std::abs(rate), "signed rate ramp/zero attenuation right");
    }
    auto state = snapshot(engine);
    near(state.decks[0].sourceFrame, cursor, "scratch integrated rate");
    near(state.decks[0].rate, -1, "scratch target settled");
    check(state.decks[0].scratching && state.decks[0].gesture == 41, "active lease");
    check(state.lastGestureEventNanos == 1234 && state.lastGestureAppliedFrame == 0,
          "pre-render move applied at block entry");
    check(engine.move({0, 1, 41, 5, 1235, 0}), "zero move");
    engine.render(output, 128);
    for (unsigned i = 0; i < 128; ++i) near(output[2 * i], 1 - (i + 1) / 128.0, "zero-rate fade");
    const auto frozen = snapshot(engine).decks[0].sourceFrame;
    engine.render(output, 128);
    for (float sample : output) near(sample, 0, "zero rate is silence, not DC");
    near(snapshot(engine).decks[0].sourceFrame, frozen, "zero freezes cursor");
    auto end = command(Operation::EndScratch, 6); end.gesture = 41;
    check(engine.submit(end), "end admitted");
    check(!engine.move({0, 1, 41, 7, 1236, 1}), "late move refused before end render");
    engine.render(output, 128);
    state = snapshot(engine);
    check(!state.decks[0].scratching && !state.decks[0].playing && state.decks[0].gesture == 0,
          "end restores paused policy");
    near(state.decks[0].sourceFrame, frozen, "end restores from scratched position");
    near(state.decks[0].rate, 1, "end restores rate");
    begin.sequence = 7; begin.gesture = 42;
    check(engine.submit(begin), "second begin before block");
    check(engine.move({0, 1, 42, 8, 1237, -8}), "second pre-block move");
    end.sequence = 9; end.gesture = 42;
    check(engine.submit(end), "terminal before next block");
    engine.render(output, 128);
    for (float sample : output) near(sample, 0, "retired pre-block move cannot render");
    near(snapshot(engine).decks[0].sourceFrame, frozen, "begin/move/end batch remains paused");
}
void admission_and_capacity() {
    const std::vector<float> pcm(64, 0.25F);
    Engine engine(48000);
    assign(engine, pcm);
    engine.render(nullptr, 0);
    auto invalid = command(Operation::SetRate, 2, 0, 1, std::nan(""));
    check(!engine.submit(invalid), "NaN rate refused");
    invalid.value = std::numeric_limits<double>::infinity();
    check(!engine.submit(invalid), "infinite rate refused");
    invalid.value = 8.01;
    check(!engine.submit(invalid), "rate envelope enforced");
    invalid = command(Operation::SetGain, 2, 0, 1, -1);
    check(!engine.submit(invalid), "negative gain refused");
    invalid = command(Operation::Seek, 2, 0, 1, 33);
    check(!engine.submit(invalid), "seek beyond finite source refused");
    invalid.value = -0.1;
    check(!engine.submit(invalid), "negative seek refused");
    invalid.value = std::nan("");
    check(!engine.submit(invalid), "NaN seek refused");
    invalid = command(static_cast<Operation>(99), 2);
    check(!engine.submit(invalid), "unknown operation refused");
    invalid = command(Operation::Play, 2, 4);
    check(!engine.submit(invalid), "invalid deck refused");
    invalid = command(Operation::Play, 2, 0, 0);
    check(!engine.submit(invalid), "zero generation refused");
    check(!engine.submit(command(Operation::Play, 0)), "zero sequence refused");
    check(!engine.submit(command(Operation::Play, 1)), "stale sequence refused");
    invalid = command(Operation::Assign, 2);
    invalid.source = {pcm.data(), 32, 48000, 1};
    check(!engine.submit(invalid), "same generation replacement refused");
    invalid.generation = 2; invalid.source.sourceRate = 0;
    check(!engine.submit(invalid), "zero source rate refused");
    invalid.source.sourceRate = 48000; invalid.source.frames = 0;
    check(!engine.submit(invalid), "empty source refused");
    invalid.source.frames = UINT64_MAX;
    check(!engine.submit(invalid), "unrepresentable extent refused");
    invalid.source.frames = 32; invalid.source.identity = 0;
    check(!engine.submit(invalid), "zero source identity refused");
    invalid.source.identity = 1; invalid.source.samples = nullptr;
    check(!engine.submit(invalid), "null source refused");
    const std::vector<float> nonfinite{0, std::numeric_limits<float>::infinity()};
    invalid.source = {nonfinite.data(), 1, 48000, 1};
    check(!engine.submit(invalid), "nonfinite PCM refused off callback");
    for (uint64_t seq = 2; seq <= 65; ++seq)
        check(engine.submit(command(Operation::Pause, seq)), "all 64 structural slots admitted");
    check(!engine.submit(command(Operation::Play, 66)), "65th command refused");
    engine.render(nullptr, 0);
    check(snapshot(engine).appliedSequence == 65, "full queue drains in FIFO order");
    check(engine.submit(command(Operation::Play, 66)), "rejected command sequence can retry after drain");
    engine.render(nullptr, 0);
    check(snapshot(engine).decks[0].playing, "queue reusable");
    check(snapshot(engine).refusedCommands == 20, "exact refusal accounting");
    bool threw = false;
    try { Engine bad(0); } catch (const std::invalid_argument&) { threw = true; }
    check(threw, "zero output rate rejected");
    Engine leased(48000);
    assign(leased, pcm);
    leased.render(nullptr, 0);
    for (uint64_t seq = 2; seq <= 65; ++seq)
        check(leased.submit(command(Operation::Pause, seq)), "lease pressure fill");
    auto begin = command(Operation::BeginScratch, 66); begin.gesture = 1;
    check(!leased.submit(begin), "full queue refuses Begin");
    check(!leased.move({0, 1, 1, 67, 0, -1}), "failed Begin grants no lease");
    leased.render(nullptr, 0);
    check(leased.submit(begin), "Begin retry grants lease");
    check(leased.move({0, 1, 1, 67, 0, -1}), "move under retried Begin");
    for (uint64_t seq = 68; seq <= 130; ++seq)
        check(leased.submit(command(Operation::Pause, seq)), "terminal pressure fill");
    auto end = command(Operation::EndScratch, 131); end.gesture = 1;
    check(!leased.submit(end), "full queue refuses terminal");
    check(leased.move({0, 1, 1, 132, 0, 1}), "failed terminal does not revoke live lease");
    leased.render(nullptr, 0);
    end.sequence = 133;
    check(leased.submit(end), "fresh sequence retries terminal after intervening move");
    leased.render(nullptr, 0);
    check(!snapshot(leased).decks[0].scratching, "terminal retry retires lease");
}
void bounds_retirement_and_restore() {
    const std::vector<float> pcm{2, -2, 4, -4, 6, -6, 8, -8};
    Engine engine(48000);
    assign(engine, pcm);
    check(engine.submit(command(Operation::SetRate, 2, 0, 1, -1)), "negative rate");
    engine.render(nullptr, 128);
    check(engine.submit(command(Operation::Seek, 3, 0, 1, 1.5)), "reverse fractional bounds seek");
    check(engine.submit(command(Operation::Play, 4)), "reverse at beginning play");
    float output[16]{};
    engine.render(output, 8);
    const double expected[]{5, -5, 3, -3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    for (unsigned i = 0; i < 16; ++i) near(output[i], expected[i], "reverse bound samples");
    near(snapshot(engine).decks[0].sourceFrame, 0, "reverse clamps at beginning");
    check(engine.submit(command(Operation::SetRate, 5, 0, 1, 1)), "resume forward rate");
    engine.render(output, 8);
    for (float sample : output) near(sample, 0, "reverse ramp waits at boundary");
    engine.render(nullptr, 200);
    check(snapshot(engine).decks[0].eofCount == 1, "forward resume reaches EOF once");
    engine.render(output, 8);
    for (float sample : output) near(sample, 0, "EOF never repeats");
    check(snapshot(engine).decks[0].eofCount == 1, "EOF count stable on silence");

    const std::vector<float> longPcm(16384, 0.5F);
    Engine restoring(48000);
    assign(restoring, longPcm);
    check(restoring.submit(command(Operation::SetRate, 2, 0, 1, 0.5)), "pre-scratch rate");
    restoring.render(nullptr, 128);
    check(restoring.submit(command(Operation::Seek, 3, 0, 1, 2000)), "restore start");
    check(restoring.submit(command(Operation::Play, 4)), "pre-scratch playing");
    auto begin = command(Operation::BeginScratch, 5); begin.gesture = 7;
    check(restoring.submit(begin), "restore begin");
    check(restoring.move({0, 1, 7, 6, 1, -1}), "restore reverse move");
    restoring.render(nullptr, 128);
    const auto scratched = snapshot(restoring).decks[0].sourceFrame;
    auto cancel = command(Operation::CancelScratch, 7); cancel.gesture = 7;
    check(restoring.submit(cancel), "terminal cancellation");
    check(!restoring.move({0, 1, 7, 8, 2, 1}), "cancel retires move admission");
    restoring.render(nullptr, 0);
    near(snapshot(restoring).decks[0].sourceFrame, scratched, "cancel does not reset position");
    check(snapshot(restoring).decks[0].playing && !snapshot(restoring).decks[0].scratching,
          "cancel restores playing policy");
    restoring.render(nullptr, 128);
    near(snapshot(restoring).decks[0].rate, 0.5, "cancel restores saved rate target");
    begin.sequence = 8;
    check(!restoring.submit(begin), "ended gesture ID cannot be reused in assignment");
    begin.gesture = 8;
    check(restoring.submit(begin), "new gesture");
    assign(restoring, longPcm, 9, 0, 2, 48000, 1); // Repeated source, new occurrence generation.
    check(!restoring.move({0, 1, 8, 10, 3, -1}), "reassignment retires old gesture immediately");
    cancel.sequence = 10; cancel.gesture = 8;
    check(!restoring.submit(cancel), "stale terminal refused after reassign");
    check(!restoring.submit(command(Operation::Seek, 10, 0, 1, 0)), "stale generation refused");
    restoring.render(nullptr, 8);
    const auto reassigned = snapshot(restoring).decks[0];
    check(reassigned.generation == 2 && reassigned.identity == 1 && !reassigned.scratching && !reassigned.playing,
          "replacement explicitly retires prior rendering and lease");
    near(reassigned.sourceFrame, 0, "replacement starts new occurrence");

    const std::vector<float> one{0.75F, -0.25F};
    Engine single(48000);
    assign(single, one, 1, 0, 1, 24000);
    check(single.submit(command(Operation::Play, 2)), "single-frame play");
    single.render(output, 8);
    for (unsigned i = 0; i < 8; ++i) {
        near(output[2 * i], i < 2 ? 0.75 : 0, "single-frame interpolation bounded left");
        near(output[2 * i + 1], i < 2 ? -0.25 : 0, "single-frame interpolation bounded right");
    }
}

void gain_and_partition_invariance() {
    const std::vector<float> pcm(32768, 1.0F);
    Engine whole(48000), split(48000);
    for (Engine* engine : {&whole, &split}) {
        assign(*engine, pcm, 1, 0, 1, 44100);
        check(engine->submit(command(Operation::Seek, 2, 0, 1, 1000.25)), "partition seek");
        check(engine->submit(command(Operation::SetGain, 3, 0, 1, 0)), "gain fade");
        auto begin = command(Operation::BeginScratch, 4); begin.gesture = 1;
        check(engine->submit(begin), "partition begin");
        check(engine->move({0, 1, 1, 5, 88, -0.75}), "partition move");
    }
    std::array<float, 512> a{}, b{};
    whole.render(a.data(), 256);
    const std::array<uint32_t, 6> blocks{1, 17, 63, 47, 3, 125};
    unsigned offset = 0;
    for (auto count : blocks) { split.render(b.data() + 2 * offset, count); offset += count; }
    check(offset == 256, "partition fixture extent");
    for (unsigned i = 0; i < 256; ++i) {
        check(a[2 * i] == b[2 * i] && a[2 * i + 1] == b[2 * i + 1], "partition sample-identical");
        const double gain = i < 128 ? 1 - (i + 1) / 128.0 : 0;
        const double rate = i < 128 ? 1 - 1.75 * (i + 1) / 128.0 : -0.75;
        near(a[2 * i], gain * std::abs(rate), "every gain/rate ramp sample");
    }
    near(snapshot(whole).decks[0].sourceFrame, snapshot(split).decks[0].sourceFrame, "partition cursor");
    check(whole.submit(command(Operation::SetGain, 6, 0, 1, 1)), "gain fade in");
    whole.render(a.data(), 128);
    for (unsigned i = 0; i < 128; ++i) near(a[2 * i], 0.75 * (i + 1) / 128.0, "every gain fade-in sample");
    check(whole.move({0, 1, 1, 7, 89, -2}), "older coalesced move");
    check(whole.submit(command(Operation::SetRate, 8, 0, 1, 0.5)), "later structural rate");
    whole.render(a.data(), 128);
    near(snapshot(whole).decks[0].rate, 0.5, "older mailbox cannot override later structural rate");
}

void four_deck_independence() {
    std::vector<float> pcm(32768);
    for (unsigned i = 0; i < 16384; ++i) {
        pcm[2 * i] = static_cast<float>((i * 13) % 97) / 128;
        pcm[2 * i + 1] = -static_cast<float>((i * 7) % 89) / 128;
    }
    Engine mixed(48000), peers(48000), scratched(48000);
    uint64_t sequence = 0;
    for (uint32_t deck = 0; deck < 4; ++deck) {
        const auto assignSeq = ++sequence;
        const auto seekSeq = ++sequence;
        const auto playSeq = ++sequence;
        for (Engine* engine : {&mixed, deck == 0 ? &scratched : &peers}) {
            assign(*engine, pcm, assignSeq, deck, 1, 44100, 42);
            check(engine->submit(command(Operation::Seek, seekSeq, deck, 1, 2000 + deck * 17.25)), "independent occurrence seek");
            check(engine->submit(command(Operation::Play, playSeq, deck)), "peer play");
        }
    }
    auto begin = command(Operation::BeginScratch, ++sequence); begin.gesture = 1;
    for (Engine* engine : {&mixed, &scratched}) {
        check(engine->submit(begin), "four-deck scratch begin");
        check(engine->move({0, 1, 1, sequence + 1, 7, -1.5}), "four-deck scratch move");
    }
    ++sequence;
    std::array<float, 514> actual{}, peerOutput{}, scratchOutput{};
    for (unsigned block = 0; block < 6; ++block) {
        mixed.render(actual.data(), 257); peers.render(peerOutput.data(), 257); scratched.render(scratchOutput.data(), 257);
        const auto m = snapshot(mixed); const auto p = snapshot(peers);
        for (unsigned deck = 1; deck < 4; ++deck) {
            check(m.decks[deck].sourceFrame == p.decks[deck].sourceFrame, "live peer cursor sample-identical");
            check(m.decks[deck].rate == p.decks[deck].rate && m.decks[deck].playing == p.decks[deck].playing,
                  "live peer policy unchanged");
        }
        for (unsigned i = 0; i < actual.size(); ++i)
            near(actual[i], static_cast<double>(peerOutput[i]) + scratchOutput[i], "four-deck mix every sample");
    }
    // Exact reference samples with scratched deck muted, while its reverse cursor remains live.
    check(mixed.submit(command(Operation::SetGain, ++sequence, 0, 1, 0)), "mute scratched contribution");
    mixed.render(nullptr, 128); peers.render(nullptr, 128);
    mixed.render(actual.data(), 257); peers.render(peerOutput.data(), 257);
    for (unsigned i = 0; i < actual.size(); ++i) check(actual[i] == peerOutput[i], "three live peers bit-identical reference");
    const auto state = snapshot(mixed);
    check(state.decks[1].identity == state.decks[2].identity &&
          state.decks[1].sourceFrame != state.decks[2].sourceFrame, "same source has independent occurrences");
}
void coherent_concurrent_publication() {
    const std::vector<float> pcm(4096, 0.25F);
    Engine engine(48000);
    std::atomic<bool> stop{false};
    std::atomic<unsigned> failures{0}, successes{0};
    std::array<std::thread, 3> readers;
    for (auto& reader : readers) reader = std::thread([&] {
        uint64_t previousFrame = 0;
        do {
            Snapshot state;
            if (!engine.snapshot(state)) continue;
            successes.fetch_add(1, std::memory_order_relaxed);
            if (state.renderedFrames < previousFrame) failures.fetch_add(1);
            previousFrame = state.renderedFrames;
            for (unsigned deck = 0; deck < 4; ++deck) {
                const auto expectedGeneration = (state.appliedSequence + 3 - deck) / 4;
                const auto& d = state.decks[deck];
                if (d.generation != expectedGeneration ||
                    d.identity != (expectedGeneration == 0 ? 0 : expectedGeneration * 17 + deck) ||
                    d.sourceFrame != 0 || d.playing || d.scratching || d.gesture != 0)
                    failures.fetch_add(1, std::memory_order_relaxed);
            }
        } while (!stop.load(std::memory_order_acquire));
    });
    std::thread renderer([&] {
        float output[14]{};
        while (!stop.load(std::memory_order_acquire)) engine.render(output, 7);
        engine.render(output, 7);
    });
    for (uint64_t seq = 1; seq <= 8000; ++seq) {
        const auto deck = static_cast<uint32_t>((seq - 1) % 4);
        const auto generation = (seq - 1) / 4 + 1;
        auto c = command(Operation::Assign, seq, deck, generation);
        c.source = {pcm.data(), pcm.size() / 2, 48000, generation * 17 + deck};
        while (!engine.submit(c)) std::this_thread::yield();
    }
    for (;;) {
        Snapshot state;
        if (engine.snapshot(state) && state.appliedSequence == 8000) break;
        std::this_thread::yield();
    }
    stop.store(true, std::memory_order_release);
    renderer.join();
    for (auto& reader : readers) reader.join();
    check(failures.load() == 0 && successes.load() > 0, "all readers observe coherent complete snapshots");
}

void coalescing_and_callback_heap() {
    const std::vector<float> pcm(65536, 0.25F);
    Engine engine(48000);
    assign(engine, pcm);
    check(engine.submit(command(Operation::Seek, 2, 0, 1, 16000)), "coalescing initial seek");
    auto begin = command(Operation::BeginScratch, 3); begin.gesture = 1;
    check(engine.submit(begin), "coalescing begin");
    for (uint64_t seq = 4; seq <= 1003; ++seq)
        check(engine.move({0, 1, 1, seq, seq * 7, seq == 1003 ? -2.0 : 2.0}), "bounded mailbox coalesces burst");
    check(!engine.move({0, 1, 1, 1002, 0, 1}), "stale move sequence refused");
    check(!engine.move({0, 1, 2, 1004, 0, 1}), "wrong gesture move refused");
    check(!engine.move({0, 1, 1, 1004, 0, std::nan("")}), "nonfinite move refused");
    check(!engine.move({0, 1, 1, 1004, 0, 8.1}), "move envelope refused");
    std::array<float, 256> output{};
    const auto before = heap_probe::operations.load();
    heap_probe::callback = true;
    engine.render(output.data(), 128);
    heap_probe::callback = false;
    check(heap_probe::operations.load() == before, "callback has no C++ heap allocation or destruction");
    const auto state = snapshot(engine);
    near(state.decks[0].rate, -2, "last coalesced move applied");
    check(state.appliedSequence == 1003 && state.lastGestureEventNanos == 7021,
          "mailbox payload fields coherent");
    // A concurrent producer repeatedly replaces every payload word while callback reads.
    std::atomic<bool> done{false};
    std::atomic<unsigned> incoherent{0}, observed{0};
    std::thread consumer([&] {
        while (!done.load(std::memory_order_acquire)) {
            heap_probe::callback = true;
            engine.render(output.data(), 1);
            heap_probe::callback = false;
            Snapshot s;
            if (engine.snapshot(s) && s.appliedSequence >= 1004) {
                observed.fetch_add(1);
                if (s.lastGestureEventNanos != s.appliedSequence * 7 ||
                    s.lastGestureAppliedFrame > s.renderedFrames || !std::isfinite(s.decks[0].rate))
                    incoherent.fetch_add(1);
            }
        }
    });
    for (uint64_t seq = 1004; seq <= 11003; ++seq)
        check(engine.move({0, 1, 1, seq, seq * 7, (seq & 1U) != 0 ? -1.0 : 1.0}), "concurrent mailbox write");
    for (;;) {
        Snapshot s;
        if (engine.snapshot(s) && s.appliedSequence == 11003) break;
        std::this_thread::yield();
    }
    done.store(true, std::memory_order_release); consumer.join();
    check(incoherent.load() == 0 && observed.load() > 0, "atomic mailbox cannot tear payload");
    check(heap_probe::operations.load() == before, "concurrent callbacks remain heap-free");
    auto end = command(Operation::EndScratch, 11004); end.gesture = 1;
    check(engine.submit(end), "heap probe end");
    assign(engine, pcm, 11005, 0, 2, 48000, 2);
    heap_probe::callback = true;
    engine.render(output.data(), 128);
    engine.render(nullptr, 0);
    heap_probe::callback = false;
    check(heap_probe::operations.load() == before, "terminal/replacement callbacks remain heap-free");
}
} // namespace

int main() {
    try {
        const std::array<std::pair<const char*, void(*)()>, 10> families{{
            {"ordinary_playback", ordinary_playback},
            {"endpoint_seek_completion", endpoint_seek_completion},
            {"fractional_pause_seek", fractional_pause_seek},
            {"scratch_lease_and_ramps", scratch_lease_and_ramps},
            {"admission_and_capacity", admission_and_capacity},
            {"bounds_retirement_and_restore", bounds_retirement_and_restore},
            {"gain_and_partition_invariance", gain_and_partition_invariance},
            {"four_deck_independence", four_deck_independence},
            {"coherent_concurrent_publication", coherent_concurrent_publication},
            {"coalescing_and_callback_heap", coalescing_and_callback_heap}
        }};
        for (const auto& family : families) { family.second(); std::printf("PASS %s\n", family.first); }
        std::printf("%zu/%zu test families passed\n", families.size(), families.size());
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
