#pragma once
#include <atomic>
namespace soundq::nativeengine {
// One process-wide cap includes synchronous extent probes and retained workers.
// A full pool refuses a new probe rather than opening an uncounted fifth decoder.
inline std::atomic<unsigned> decoderPermits{0};
struct DecoderPermit {
    bool held=false;
    bool acquire() noexcept {
        if(held)return true;
        auto count=decoderPermits.load(std::memory_order_relaxed);
        while(count<4){if(decoderPermits.compare_exchange_weak(count,count+1,std::memory_order_acq_rel)){held=true;return true;}}
        return false;
    }
    void release() noexcept {if(held){decoderPermits.fetch_sub(1,std::memory_order_acq_rel);held=false;}}
    ~DecoderPermit(){release();}
};
}
