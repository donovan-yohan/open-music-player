#include "worker_deck.hpp"
#include "sq_file_decoder.h"
#include "decoder_budget.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>

namespace soundq::nativeengine {
#ifdef SOUNDQ_CALLBACK_TEST_BARRIERS
namespace test { void workerJoin() noexcept; }
#endif
namespace {
constexpr uint32_t pageFrames = 48000;
constexpr uint32_t pageSamples = pageFrames * 2;
constexpr uint32_t poolPages = 8;
constexpr uint64_t poolBytes = uint64_t{poolPages} * pageSamples * sizeof(float);
static_assert(pageFrames == transport::maxPcmPageFrames);
static_assert(pageFrames == SQ_FILE_MAX_WINDOW_FRAMES);

// Slot metadata belongs only to the serialized control producer. A submitted
// worker task exclusively owns its reserved PCM bytes until its concrete reply.
struct Batch {
    std::array<uint32_t, 4> slots{};
    std::array<uint64_t, 4> first{};
    std::array<uint32_t, 4> frames{};
    uint32_t count = 0;
};
Batch neighborhood(Batch batch, uint64_t extent, uint64_t cursor) {
    const uint64_t last = (extent - 1) / pageFrames;
    const uint64_t center = std::min(cursor, extent - 1) / pageFrames;
    const uint64_t first = center == 0 ? 0 : center - 1;
    const uint64_t end = std::min(last, center + 2);
    batch.count = static_cast<uint32_t>(end - first + 1);
    for (uint32_t i = 0; i < batch.count; ++i) {
        batch.first[i] = (first + i) * pageFrames;
        batch.frames[i] = static_cast<uint32_t>(std::min<uint64_t>(pageFrames, extent - batch.first[i]));
    }
    return batch;
}
bool sameRange(const Batch& a, const Batch& b) {
    if (a.count != b.count) return false;
    for (uint32_t i = 0; i < a.count; ++i)
        if (a.first[i] != b.first[i] || a.frames[i] != b.frames[i]) return false;
    return true;
}
}

struct WorkerDeck::Impl {
    enum class Phase { Empty, Priming, Assigning, Live, Retiring, Failed };
    enum class Pending { None, Filling, Ready, Submitted };
    struct Intent {
        std::string path;
        uint64_t identity = 0, generation = 0, start = 0;
    };
    struct Job {
        bool open = false;
        uint64_t token = 0, extent = 0, cursor = 0;
        std::string path;
        Batch batch{};
    };
    struct Reply {
        uint64_t token = 0, extent = 0;
        uint32_t rate = 0;
        int error = 0;
        Batch batch{};
    };

    uint32_t deck;
    transport::Engine& engine;
    uint64_t& sequence;
    std::array<std::unique_ptr<float[]>, poolPages> pages;
    std::array<bool, poolPages> occupied{};
    Intent intended{};
    Phase phase = Phase::Empty;
    Pending pendingState = Pending::None;
    Batch current{}, pending{};
    uint32_t rate = 0;
    bool unloading = false;
    uint64_t extent = 0, pendingReceipt = 0, retirementReceipt = 0, seekReceipt = 0;
    WorkerStats controlStats{};

    // Single-task/single-reply mailbox. No mutex is held during open/read/close.
    // pump only tries this mutex; the callback has no reference to this class.
    std::mutex mutex;
    std::condition_variable changed;
    std::optional<Job> queued;
    std::optional<Reply> reply;
    bool outstanding = false; // producer-only, includes an unconsumed reply
    std::atomic<bool> stopping{false};
    std::atomic<uint64_t> token{1}, decodedFrames{0}, decodeCalls{0};
    std::atomic<uint32_t> openDecoders{0}, fillsInFlight{0};
    std::thread worker;

    Impl(uint32_t d, transport::Engine& e, uint64_t& s) : deck(d), engine(e), sequence(s) {
        for (auto& page : pages) page.reset(new float[pageSamples]);
        controlStats.poolBytes = poolBytes;
        worker = std::thread([this] { run(); });
    }
    ~Impl() {
        // Caller MUST have quiesced output or acquired retired() postblock ACK.
        // Worker destroys decoder before join returns and pages can be freed.
        {
            // Pair the wait predicate with its mutex so shutdown cannot lose a
            // notification between the worker's predicate check and CV wait.
            std::lock_guard<std::mutex> lock(mutex);
            stopping.store(true, std::memory_order_release);
            token.fetch_add(1, std::memory_order_acq_rel);
        }
        changed.notify_one();
#ifdef SOUNDQ_CALLBACK_TEST_BARRIERS
        test::workerJoin();
#endif
        if (worker.joinable()) worker.join();
    }
    bool valid(const std::string& path, uint64_t id, uint64_t generation) const {
        return deck < 4 && !path.empty() && path[0] == '/' &&
               path.find('\0') == std::string::npos && id != 0 && generation != 0 &&
               generation > intended.generation;
    }
    uint64_t nextSequence() {
        if (sequence == std::numeric_limits<uint64_t>::max()) return 0;
        return ++sequence;
    }
    bool obsolete(uint64_t jobToken) const {
        return stopping.load(std::memory_order_acquire) ||
               token.load(std::memory_order_acquire) != jobToken;
    }
    void release(Batch& batch) {
        for (uint32_t i = 0; i < batch.count; ++i) {
            occupied[batch.slots[i]] = false;
            ++controlStats.recycledPages;
        }
        batch = {};
    }
    void discardUnborrowed(Batch& batch) {
        // Cancellation/rejection has no Engine release authority to account for.
        for (uint32_t i = 0; i < batch.count; ++i) occupied[batch.slots[i]] = false;
        batch = {};
    }
    bool dispatch(Job job, bool blocking) {
        std::unique_lock<std::mutex> lock(mutex, std::defer_lock);
        if (blocking) lock.lock(); else if (!lock.try_lock()) return false;
        if (outstanding || queued || reply || stopping.load(std::memory_order_acquire)) return false;
        queued.emplace(std::move(job));
        outstanding = true;
        lock.unlock();
        changed.notify_one();
        return true;
    }
    bool startFill(bool open, uint64_t cursor, bool blocking = false) {
        if (outstanding || pendingState != Pending::None) return false;
        Job job{};
        job.open = open;
        job.path = open ? intended.path : std::string{};
        job.token = token.load(std::memory_order_acquire);
        job.extent = extent;
        job.cursor = cursor; // milliseconds for open, source frames for subsequent fills
        if (open) job.batch.count = 4;
        else job.batch = neighborhood({}, extent, cursor);
        uint32_t found = 0;
        for (uint32_t i = 0; i < poolPages && found < job.batch.count; ++i)
            if (!occupied[i]) job.batch.slots[found++] = i;
        if (found != job.batch.count) return false;
        const auto reserved = job.batch;
        if (!dispatch(std::move(job), blocking)) return false;
        for (uint32_t i = 0; i < reserved.count; ++i) occupied[reserved.slots[i]] = true;
        pending = reserved;
        pendingState = Pending::Filling;
        return true;
    }
    void acceptReply(Reply result) {
        outstanding = false;
        if (pendingState != Pending::Filling) return;
        if (result.token != token.load(std::memory_order_acquire) || phase == Phase::Retiring) {
            discardUnborrowed(pending);
            pendingState = Pending::None;
            return;
        }
        if (result.error != 0) {
            discardUnborrowed(pending);
            pendingState = Pending::None;
            controlStats.error = result.error;
            controlStats.ready = controlStats.preparing = false;
            phase = Phase::Failed;
            return;
        }
        for (uint32_t i = result.batch.count; i < pending.count; ++i)
            occupied[pending.slots[i]] = false;
        pending = result.batch;
        extent = result.extent;
        if (result.rate != 0) rate = result.rate;
        pendingState = Pending::Ready;
    }
    bool harvest(bool wait = false) {
        std::unique_lock<std::mutex> lock(mutex, std::defer_lock);
        if (wait) {
            lock.lock();
            changed.wait(lock, [this] { return reply.has_value() || stopping.load(std::memory_order_acquire); });
        } else if (!lock.try_lock()) return false;
        if (!reply) return false;
        Reply result = *reply;
        reply.reset();
        lock.unlock();
        acceptReply(result);
        return true;
    }
    transport::PcmWindow window(const Batch& batch) const {
        transport::PcmWindow w{};
        w.count = batch.count;
        for (uint32_t i = 0; i < batch.count; ++i)
            w.pages[i] = {pages[batch.slots[i]].get(), batch.first[i], batch.frames[i]};
        return w;
    }
    bool assign() {
        if (pendingState != Pending::Ready) return false;
        const auto seq = nextSequence();
        if (seq == 0 || !engine.assignPaged(deck, seq, intended.generation,
                {extent, rate, intended.identity}, window(pending))) return false;
        pendingReceipt = seq;
        pendingState = Pending::Submitted;
        phase = Phase::Assigning;
        ++controlStats.publishedWindows;
        return true;
    }
    static uint64_t millisecondsToFrame(uint64_t ms, uint32_t hz, uint64_t frames) {
        const long double target = static_cast<long double>(ms) * hz / 1000.0L;
        return target >= frames ? frames : static_cast<uint64_t>(target);
    }
    uint64_t startFrame() const { return millisecondsToFrame(intended.start, rate, extent); }
    void seek() {
        if (seekReceipt != 0) return;
        transport::Command command{};
        command.operation = transport::Operation::Seek;
        command.deck = deck;
        command.generation = intended.generation;
        command.sequence = nextSequence();
        command.value = static_cast<double>(startFrame());
        if (command.sequence != 0 && engine.submit(command)) seekReceipt = command.sequence;
    }
    void reconcile(uint64_t completed) {
        if (phase == Phase::Retiring) {
            if (completed < retirementReceipt) return;
            // A later unassign retires both borrowed descriptor sets. A filling
            // task is different custody and cannot be recycled until its reply.
            release(current);
            if (pendingState == Pending::Submitted) {
                release(pending);
                pendingState = Pending::None;
            } else if (pendingState == Pending::Ready) {
                discardUnborrowed(pending);
                pendingState = Pending::None;
            }
            if (!unloading && !outstanding && startFill(true, intended.start)) phase = Phase::Priming;
            return;
        }
        if (pendingState == Pending::Submitted && completed >= pendingReceipt) {
            release(current);
            current = pending;
            pending = {};
            pendingState = Pending::None;
        }
    }
    void pump(const transport::Snapshot& snapshot) {
        harvest();
        // Never use Snapshot::appliedSequence. A coalesced movement can advance
        // it before the block has finished reading an old structural window.
        const auto completed = engine.completedStructuralSequence();
        reconcile(completed);
        if (phase == Phase::Retiring || phase == Phase::Failed || phase == Phase::Empty) return;
        if (phase == Phase::Priming && pendingState == Pending::Ready) assign();
        if (phase == Phase::Assigning) {
            seek();
            if (pendingState == Pending::None && current.count != 0 &&
                seekReceipt != 0 && completed >= seekReceipt) {
                controlStats.ready = true;
                controlStats.preparing = false;
                phase = Phase::Live;
            }
            return;
        }
        if (phase != Phase::Live) return;
        if (pendingState == Pending::Ready) {
            const auto seq = nextSequence();
            if (seq != 0 && engine.publishWindow(deck, seq, intended.generation, window(pending))) {
                pendingReceipt = seq;
                pendingState = Pending::Submitted;
                ++controlStats.publishedWindows;
            }
            // False borrows nothing; retain the ready slots and retry unchanged.
            return;
        }
        if (pendingState != Pending::None) return;
        const auto& observed = snapshot.decks[deck];
        if (observed.generation != intended.generation || observed.identity != intended.identity ||
            !std::isfinite(observed.sourceFrame) || observed.sourceFrame < 0) return;
        const auto cursor = observed.sourceFrame >= static_cast<double>(extent)
            ? extent - 1 : static_cast<uint64_t>(observed.sourceFrame);
        const auto target = neighborhood({}, extent, cursor);
        if (!sameRange(current, target)) startFill(false, cursor);
    }
    void run() {
        sq_file_decoder* decoder = nullptr; // worker-only lifetime, including close
        DecoderPermit permit;
        for (;;) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(mutex);
                changed.wait(lock, [this] { return stopping.load(std::memory_order_acquire) || queued.has_value(); });
                if (stopping.load(std::memory_order_acquire)) break;
                job = std::move(*queued);
                queued.reset();
            }
            Reply result{};
            result.token = job.token;
            result.extent = job.extent;
            fillsInFlight.store(1, std::memory_order_release);
            try {
            if (job.open && !obsolete(job.token)) {
                sq_file_decoder_destroy(decoder);
                decoder = nullptr;
                openDecoders.store(0, std::memory_order_release);
                permit.release();
                if(!permit.acquire())result.error=SQ_FILE_LIMIT;
                else result.error = sq_file_decoder_open(job.path.c_str(), SQ_FILE_MAX_FILE_BYTES, &decoder);
                if (decoder) openDecoders.store(1, std::memory_order_release);
                if (result.error == 0 && !decoder) result.error = SQ_FILE_DECODE;
                if (result.error == 0) {
                    const auto frames = sq_file_decoder_frame_count(decoder);
                    result.rate = sq_file_decoder_sample_rate(decoder);
                    if (result.rate == 0 || sq_file_decoder_channels(decoder) != 2)
                        result.error = SQ_FILE_UNSUPPORTED;
                    else if (frames <= 0) result.error = SQ_FILE_INVALID_STREAM;
                    else if (static_cast<uint64_t>(frames) > (uint64_t{1} << 52)) result.error = SQ_FILE_LIMIT;
                    else {
                        result.extent = static_cast<uint64_t>(frames);
                        job.cursor = millisecondsToFrame(job.cursor, result.rate, result.extent);
                    }
                }
            }
            if (result.error == 0 && !obsolete(job.token)) {
                if (!decoder || result.extent == 0) result.error = SQ_FILE_DECODE;
                else {
                    result.batch = neighborhood(job.batch, result.extent, job.cursor);
                    const auto center = std::min(job.cursor, result.extent - 1) / pageFrames;
                    // Decode the cursor/interpolation-neighbor pair first, then
                    // backward safety, then forward safety. Publish sorted only
                    // after the complete immutable window has been filled.
                    const std::array<uint64_t, 4> priority{{center, center + 1,
                        center == 0 ? std::numeric_limits<uint64_t>::max() : center - 1, center + 2}};
                    for (const auto page : priority) {
                        for (uint32_t i = 0; i < result.batch.count; ++i) {
                            if (result.batch.first[i] / pageFrames != page) continue;
                            if (obsolete(job.token)) break;
                            uint32_t read = 0;
                            decodeCalls.fetch_add(1, std::memory_order_relaxed);
                            const int error = sq_file_decoder_read_window(decoder,
                                static_cast<int64_t>(result.batch.first[i]), result.batch.frames[i],
                                pages[result.batch.slots[i]].get(), size_t{pageSamples} * sizeof(float), &read);
                            if (error != SQ_FILE_OK || read != result.batch.frames[i]) {
                                result.error = error == SQ_FILE_OK ? SQ_FILE_DECODE : error;
                                break;
                            }
                            decodedFrames.fetch_add(read, std::memory_order_relaxed);
                        }
                        if (result.error != 0 || obsolete(job.token)) break;
                    }
                }
            }
            } catch (...) { result.error = SQ_FILE_OUT_OF_MEMORY; }
            if (result.error != 0 && decoder) {
                sq_file_decoder_destroy(decoder);
                decoder = nullptr;
                openDecoders.store(0, std::memory_order_release);
                permit.release();
            }
            fillsInFlight.store(0, std::memory_order_release);
            {
                std::lock_guard<std::mutex> lock(mutex);
                reply = result; // reply also proves an obsolete write has exited
            }
            changed.notify_one();
        }
        sq_file_decoder_destroy(decoder);
        openDecoders.store(0, std::memory_order_release);
        fillsInFlight.store(0, std::memory_order_release);
    }
};

WorkerDeck::WorkerDeck(uint32_t deck, transport::Engine& engine, uint64_t& sequence)
    : impl_(std::make_unique<Impl>(deck, engine, sequence)) {}
WorkerDeck::~WorkerDeck() = default;

void WorkerDeck::pump(const transport::Snapshot& snapshot) { impl_->pump(snapshot); }

bool WorkerDeck::replace(const std::string& path, uint64_t identity, uint64_t generation, uint64_t startMs) {
    auto& p = *impl_;
    if (!p.valid(path, identity, generation)) return false;
    // Copy before committing any side effect. Refusal leaves the old request,
    // decoder and ready/current slot custody unchanged.
    Impl::Intent next{path, identity, generation, startMs};
    uint64_t retirement = p.phase == Impl::Phase::Retiring ? p.retirementReceipt : 0;
    if (p.phase != Impl::Phase::Retiring && (p.current.count != 0 || p.pendingState == Impl::Pending::Submitted)) {
        retirement = p.nextSequence();
        if (retirement == 0 || !p.engine.unassign(p.deck, retirement, p.intended.generation)) return false;
    }
    p.token.fetch_add(1, std::memory_order_acq_rel); // revoke before accepting late completion
    p.intended = std::move(next);
    p.unloading = false;
    p.extent = 0;
    p.rate = 0;
    p.seekReceipt = 0;
    p.retirementReceipt = retirement;
    p.controlStats.error = 0;
    p.controlStats.ready = false;
    p.controlStats.preparing = true;
    p.phase = Impl::Phase::Retiring;
    // No wait, join, decoder close/open or file access. pump consumes the old
    // structural receipt AND concrete worker reply before scheduling reopen.
    return true;
}
bool WorkerDeck::retire() {
    auto& p = *impl_;
    uint64_t receipt = p.phase == Impl::Phase::Retiring ? p.retirementReceipt : 0;
    if (p.phase != Impl::Phase::Retiring &&
        (p.current.count != 0 || p.pendingState == Impl::Pending::Submitted)) {
        receipt = p.nextSequence();
        if (receipt == 0 || !p.engine.unassign(p.deck, receipt, p.intended.generation)) return false;
    }
    p.token.fetch_add(1, std::memory_order_acq_rel);
    p.retirementReceipt = receipt;
    p.unloading = true;
    p.controlStats.ready = false;
    p.controlStats.preparing = true;
    p.phase = Impl::Phase::Retiring;
    return true;
}
bool WorkerDeck::retired() const noexcept {
    return impl_->unloading && impl_->engine.completedStructuralSequence() >= impl_->retirementReceipt;
}
uint32_t WorkerDeck::sourceRate() const noexcept { return impl_->rate; }
uint64_t WorkerDeck::generation() const noexcept { return impl_->intended.generation; }
uint64_t WorkerDeck::identity() const noexcept { return impl_->intended.identity; }
uint64_t WorkerDeck::sourceFrames() const noexcept { return impl_->extent; }
WorkerStats WorkerDeck::stats() const noexcept {
    auto result = impl_->controlStats;
    result.decodedFrames = impl_->decodedFrames.load(std::memory_order_acquire);
    result.decodeCalls = impl_->decodeCalls.load(std::memory_order_acquire);
    result.openDecoders = impl_->openDecoders.load(std::memory_order_acquire);
    result.fillsInFlight = impl_->fillsInFlight.load(std::memory_order_acquire);
    return result;
}
} // namespace soundq::nativeengine
