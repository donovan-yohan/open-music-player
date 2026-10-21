#ifndef SQ_DEVICE_INTERNAL_H
#define SQ_DEVICE_INTERNAL_H
#include "soundq_device.h"
#include <atomic>
#include <memory>

namespace sq_host {
static_assert(std::atomic<uint32_t>::is_always_lock_free, "callback atomics must be lock-free");
static_assert(std::atomic<bool>::is_always_lock_free, "callback gate must be lock-free");
static_assert(std::atomic<int32_t>::is_always_lock_free, "callback atomics must be lock-free");
struct Render {
  sq_engine *engine;
  const uint32_t sample_rate, max_block;
  std::unique_ptr<float[]> scratch;
  std::atomic<bool> enabled{false};
  std::atomic<uint32_t> active{0};
  std::atomic<int32_t> error{SQ_DEVICE_OK}, native_error{0};
  Render(sq_engine *e, uint32_t rate, uint32_t block);
  bool ready() const;
  void fail(sq_device_result result, int32_t native = 0);
  void pause(); // non-real-time; waits for engine reads to finish
  sq_device_result resume();
  // Sole callback consumer; zeroes paused/failed output; splits large quantum.
  bool output(float *out, uint32_t frames);
};
}
struct sq_device {
  sq_host::Render render;
  void *platform = nullptr;
  bool started = false; // control-thread only; OS may still run after stop error
  sq_device(sq_engine *e, uint32_t rate, uint32_t block) : render(e, rate, block) {}
};
namespace sq_host {
sq_device_result platform_open(sq_device *device);
sq_device_result platform_start(sq_device *device);
sq_device_result platform_pause(sq_device *device);
sq_device_result platform_close(sq_device *device);
}
#endif
