#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
namespace soundq::nativeengine {
// Worker-only source-rate stereo float reader. A zero end is UNKNOWN, never EOF
// or buffered coverage. Positive end is exact and immutable after decoded EOS.
// Short successful reads are legal only when endFrames() seals that exact end.
class PcmReader {
public:
    virtual ~PcmReader() = default;
    virtual uint32_t sampleRate() const = 0;
    virtual uint64_t endFrames() const = 0;
    virtual int read(uint64_t first, uint32_t count, float* stereo, size_t capacity, uint32_t& read) = 0;
};
using PcmReaderFactory = std::function<std::unique_ptr<PcmReader>()>;

}
