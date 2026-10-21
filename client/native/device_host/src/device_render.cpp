#include "device_internal.h"
#include <algorithm>
#include <new>
#include <thread>

namespace sq_host {
Render::Render(sq_engine *e, uint32_t rate, uint32_t block)
    : engine(e), sample_rate(rate), max_block(block),
      scratch(new(std::nothrow) float[static_cast<size_t>(block)*2]{}) {}
bool Render::ready() const { return scratch != nullptr; }
void Render::fail(sq_device_result result, int32_t native) {
  int32_t expected = SQ_DEVICE_OK;
  if (error.compare_exchange_strong(expected, result, std::memory_order_acq_rel))
    native_error.store(native, std::memory_order_release);
  enabled.store(false); // seq_cst pairs with callback entry/pause drain
}
void Render::pause() {
  enabled.store(false);
  while (active.load() != 0) std::this_thread::yield();
}
sq_device_result Render::resume() {
  const auto result = static_cast<sq_device_result>(error.load(std::memory_order_acquire));
  if (result != SQ_DEVICE_OK) return result;
  enabled.store(true);
  return SQ_DEVICE_OK;
}
bool Render::output(float *out, uint32_t frames) {
  if (!out) { fail(SQ_DEVICE_CALLBACK_FAILED); return false; }
  std::fill_n(out, static_cast<size_t>(frames)*2, 0.0f);
  if (active.fetch_add(1) != 0) {
    // OS promises serialized data callbacks. Fail closed instead of allowing two
    // consumers to touch the SPSC core or the preallocated scratch buffer.
    fail(SQ_DEVICE_CALLBACK_FAILED);
    active.fetch_sub(1);
    return false;
  }
  bool ok = true;
  for (uint32_t offset = 0; offset < frames && enabled.load() &&
       error.load(std::memory_order_acquire) == SQ_DEVICE_OK;) {
    const uint32_t count = std::min(max_block, frames-offset);
    if (sq_render(engine, scratch.get(), count) != SQ_OK) {
      fail(SQ_DEVICE_RENDER_FAILED);
      std::fill_n(out, static_cast<size_t>(frames)*2, 0.0f);
      ok = false;
      break;
    }
    std::copy_n(scratch.get(), static_cast<size_t>(count)*2,
                out + static_cast<size_t>(offset)*2);
    offset += count;
  }
  active.fetch_sub(1);
  return ok;
}
}
