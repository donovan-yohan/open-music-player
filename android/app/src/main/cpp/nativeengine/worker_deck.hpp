#pragma once
#include "soundq_transport.hpp"
#include <cstdint>
#include <memory>
#include <string>

namespace soundq::nativeengine {
struct WorkerStats {
    uint64_t decodedFrames = 0;
    uint64_t decodeCalls = 0;
    uint64_t publishedWindows = 0;
    uint64_t recycledPages = 0;
    uint64_t poolBytes = 0;
    uint32_t openDecoders = 0;
    uint32_t fillsInFlight = 0;
    bool preparing = false;
    bool ready = false;
    int error = 0;
};
// All public methods called by the ONE serialized Engine control producer.
// Decoder/file IO occurs on this deck's worker; callback never touches this class.
// Eight fixed48000frame stereo pages; <=4 current and <=4pending descriptors.
class WorkerDeck {
public:
    WorkerDeck(uint32_t deck, soundq::transport::Engine& engine, uint64_t& sequence);
    ~WorkerDeck(); // only after output quiesced OR retired(); joins before freeing pages.
    WorkerDeck(const WorkerDeck&) = delete;
    WorkerDeck& operator=(const WorkerDeck&) = delete;
    // Nonblocking live control. Reconcile structural receipt, recycle truly
    // retired pages, request/fill cursor neighborhood, publish ready window.
    void pump(const soundq::transport::Snapshot& snapshot);
    // Nonblocking source turnover: unassign old generation, await postblock fence,
    // join/cancel owned fills, reopen on worker, prime and assign new generation.
    // Repeated-source occurrences are distinct assignments. No stream operation.
    // startMs is converted on worker only after exact source rate/extent resolve.
    bool replace(const std::string& path, uint64_t identity, uint64_t generation,
                 uint64_t startMs, double speed = 1);
    // Ordinary listening speed. Pages for speed != 1 are the source pitch-shifted
    // by 1/speed in ORIGINAL source coordinates; the engine consumes them at
    // `speed`, so position/seek/EOF stay source-time and pitch is preserved.
    // Applied atomically with its window; never a traversal discontinuity.
    bool setSpeed(double speed);
    double speed() const noexcept;         // intended
    double appliedSpeed() const noexcept;  // last window/rate submitted to Engine
    bool retire(); // no new decode; caller destroys only after retired()
    bool retired() const noexcept;
    uint32_t sourceRate() const noexcept;
    uint64_t generation() const noexcept;
    uint64_t identity() const noexcept;
    uint64_t sourceFrames() const noexcept;
    WorkerStats stats() const noexcept;
    // Exact same-assignment interpolation taps in callback-acknowledged pages.
    bool ready(const soundq::transport::Snapshot& snapshot) const noexcept;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
