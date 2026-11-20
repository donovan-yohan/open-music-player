#pragma once
#include "decoder_budget.hpp"
#include "pcm_reader.hpp"
#include "soundq_transport.hpp"
#include "sq_file_decoder.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>

namespace soundq::nativeengine {
// One lazy supplemental reader on the same process-wide decoder budget as
// WorkerDeck. Two callback pages and one filling/submitted spare per Host.
// Only the serialized Host chooses a spare; the worker never owns publication.
class PreparedStemWorker {
public:
    static constexpr uint32_t pageFrames = 8192;
    static constexpr unsigned slots = 3;
    static_assert(pageFrames <= transport::maxPcmPageFrames && pageFrames <= SQ_FILE_MAX_WINDOW_FRAMES);
    struct Job { uint64_t traversal, first; uint32_t count; unsigned slot; };
    struct Reply { Job job; int error; };
    const transport::PreparedStemKey key;

    PreparedStemWorker(const transport::PreparedStemKey& k, std::shared_ptr<const PcmReaderFactory> factory)
        : key(k), factory_(std::move(factory)), thread_([this]{ run(); }) {}
    ~PreparedStemWorker() { stop(); thread_.join(); }
    void request(Job job) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queued_ = job;
        }
        changed_.notify_one();
    }
    std::optional<Reply> take() {
        std::lock_guard<std::mutex> lock(mutex_);
        return std::exchange(reply_, std::nullopt);
    }
    transport::PcmPage page(const Job& job) const noexcept {
        return {pcm_[job.slot].data(),job.first,job.count};
    }
    void stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        changed_.notify_one();
    }
    bool done() {
        std::lock_guard<std::mutex> lock(mutex_);
        return done_;
    }
private:
    void run() noexcept {
        {
            DecoderPermit permit;
            std::unique_ptr<PcmReader> reader;
            for (;;) {
                Job job;
                {
                    std::unique_lock<std::mutex> lock(mutex_);
                    changed_.wait(lock,[this]{ return stopping_ || queued_.has_value(); });
                    if (stopping_) break;
                    job = *queued_;
                    queued_.reset();
                }
                int status = SQ_FILE_OK;
                try {
                    if (!reader) {
                        if (!permit.acquire()) status = SQ_FILE_LIMIT;
                        else if (!(reader = (*factory_)())) status = SQ_FILE_DECODE;
                    }
                    const auto matches = [&]{ return reader->sampleRate() == key.sourceRate && reader->endFrames() == key.sourceFrames; };
                    if (status == SQ_FILE_OK && !matches()) status = SQ_FILE_INVALID_STREAM;
                    if (status == SQ_FILE_OK) {
                        auto& data = pcm_[job.slot]; uint32_t got = 0;
                        status = reader->read(job.first,job.count,data.data(),data.size()*sizeof(float),got);
                        if (status == SQ_FILE_OK && (got != job.count || !matches() ||
                            !std::all_of(data.begin(),data.begin()+size_t{job.count}*2,[](float v){ return std::isfinite(v); })))
                            status = SQ_FILE_INVALID_STREAM;
                    }
                } catch (...) { status = SQ_FILE_DECODE; }
                // A reply is posted only after all writes/geometry checks exit.
                std::lock_guard<std::mutex> lock(mutex_);
                reply_ = Reply{job,status};
            }
        } // reader close and permit release precede the concrete done witness
        std::lock_guard<std::mutex> lock(mutex_);
        done_ = true;
    }
    std::shared_ptr<const PcmReaderFactory> factory_;
    std::array<std::array<float,pageFrames*2>,slots> pcm_{};
    std::mutex mutex_;
    std::condition_variable changed_;
    std::optional<Job> queued_;
    std::optional<Reply> reply_;
    bool stopping_ = false, done_ = false;
    std::thread thread_;
};
}
