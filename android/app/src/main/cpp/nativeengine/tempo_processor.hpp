#pragma once
#include "soundq_transport.hpp"
#include "pcm_reader.hpp"
#include "sq_file_decoder.h"
#include <memory>
struct sq_file_decoder;
namespace soundq::nativeengine {
constexpr uint32_t tempoPageFrames=8192;
// Worker-only. Owns bounded analysis history, IO staging and two cached output
// pages. PCM rate is the original decoder rate, not the device output rate.
class TempoProcessor {
public:
    // transpose != 1 only for ordinary listening speed (identity time map).
    TempoProcessor(const transport::ScheduleClip& clip,uint32_t outputRate,double transpose=1);
    ~TempoProcessor();
    int window(PcmReader& decoder,uint64_t first,float* firstPage,uint32_t& firstCount,
               float* secondPage,uint32_t& secondCount);
    int window(sq_file_decoder* decoder,uint64_t first,float* firstPage,uint32_t& firstCount,
               float* secondPage,uint32_t& secondCount);
private:
    struct Impl;std::unique_ptr<Impl> impl;
};
}
