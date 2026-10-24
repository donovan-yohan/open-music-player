// Test-only platform: actual host/render/core, no OS audio APIs or Dart callback.
#include "device_internal.h"
#include <array>
#include <chrono>
#include <thread>

namespace {
constexpr uint32_t max_frames = 256;
sq_device *device = nullptr; // control-thread only; never exported
std::array<sq_device_result, 4> results{}; // open/start/pause/close
std::array<int32_t, 4> native_codes{};
std::array<uint32_t, 4> calls{};
std::array<float, max_frames * 2> output{};
uint32_t output_frames = 0;
std::thread worker;
std::atomic<bool> hold{false}, waiting{false};

sq_device_result control(unsigned op, sq_device *d) {
  ++calls[op];
  if (results[op] != SQ_DEVICE_OK) d->render.fail(results[op], native_codes[op]);
  return results[op];
}
}
namespace sq_host {
sq_device_result platform_open(sq_device *d) {
  const auto result = control(0, d);
  if (result == SQ_DEVICE_OK) device = d;
  return result;
}
sq_device_result platform_start(sq_device *d) { return control(1, d); }
sq_device_result platform_pause(sq_device *d) { return control(2, d); }
sq_device_result platform_close(sq_device *d) {
  const auto result = control(3, d);
  if (result == SQ_DEVICE_OK && device == d) device = nullptr;
  return result;
}
}

extern "C" {
// Core is built with only its sq_render symbol renamed. This forwarding seam
// parks an active real host callback before entering the UNMODIFIED real core.
// It neither replaces output nor fabricates cursor/revision acknowledgements.
sq_result sq_ffi_actual_render(sq_engine *, float *, uint32_t);
SQ_API sq_result sq_render(sq_engine *e, float *out, uint32_t frames) {
  if (hold.load()) {
    waiting.store(true);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (hold.load() && std::chrono::steady_clock::now() < deadline)
      std::this_thread::yield();
    hold.store(false); // bounded even if a failing Dart test never releases us
    waiting.store(false);
  }
  return sq_ffi_actual_render(e, out, frames);
}
SQ_API int32_t sq_ffi_test_reset() {
  if (device || worker.joinable()) return 1;
  results.fill(SQ_DEVICE_OK); native_codes.fill(0); calls.fill(0);
  output.fill(0); output_frames = 0;
  return 0;
}
SQ_API int32_t sq_ffi_test_set_result(uint32_t op, int32_t result, int32_t code) {
  if (op >= results.size() || result < SQ_DEVICE_OK || result > SQ_DEVICE_CALLBACK_FAILED)
    return 1;
  results[op] = static_cast<sq_device_result>(result); native_codes[op] = code;
  return 0;
}
SQ_API uint32_t sq_ffi_test_calls(uint32_t op) {
  return op < calls.size() ? calls[op] : 0;
}
SQ_API uint32_t sq_ffi_test_rate() { return sq_device_sample_rate(device); }
SQ_API uint32_t sq_ffi_test_block() { return sq_device_max_block_frames(device); }
SQ_API int32_t sq_ffi_test_callback(uint32_t frames) {
  if (!device || !frames || frames > max_frames || worker.joinable()) return 1;
  output_frames = frames;
  return device->render.output(output.data(), frames) ? 0 : 2;
}
SQ_API float sq_ffi_test_sample(uint32_t sample) {
  if (worker.joinable() || sample >= output_frames * 2) return 0;
  return output[sample];
}
SQ_API int32_t sq_ffi_test_begin_block(uint32_t frames) {
  if (!device || !frames || frames > max_frames || worker.joinable()) return 1;
  output_frames = frames; waiting.store(false); hold.store(true);
  worker = std::thread([frames] { device->render.output(output.data(), frames); });
  return 0;
}
SQ_API int32_t sq_ffi_test_waiting() { return waiting.load() ? 1 : 0; }
SQ_API void sq_ffi_test_finish_block() {
  hold.store(false);
  if (worker.joinable()) worker.join();
}
SQ_API int32_t sq_ffi_test_fail(int32_t result, int32_t code) {
  if (!device || result <= SQ_DEVICE_OK || result > SQ_DEVICE_CALLBACK_FAILED) return 1;
  device->render.fail(static_cast<sq_device_result>(result), code);
  return 0;
}
}
