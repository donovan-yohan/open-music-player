#include "device_internal.h"
#include <new>
namespace {
thread_local sq_device_result open_error = SQ_DEVICE_OK;
thread_local int32_t open_native_error = 0;
}
extern "C" {
sq_device *sq_device_open(sq_engine *engine, uint32_t rate, uint32_t block) {
  open_error = SQ_DEVICE_OK; open_native_error = 0;
  if (!engine || rate < 8000 || rate > 192000 || !block || block > 65536) {
    open_error = SQ_DEVICE_INVALID;
    return nullptr;
  }
  auto *device = new(std::nothrow) sq_device(engine, rate, block);
  if (!device || !device->render.ready()) {
    delete device; open_error = SQ_DEVICE_NO_MEMORY; return nullptr;
  }
  auto result = sq_host::platform_open(device);
  if (result != SQ_DEVICE_OK) {
    open_error = result;
    open_native_error = device->render.native_error.load(std::memory_order_acquire);
    // No output has started, so gated callbacks cannot touch the engine. If OS
    // cleanup itself fails, retain the inert context rather than risk a callback
    // use-after-free. This exceptional OS-resource leak is preferable to UAF.
    if (sq_host::platform_close(device) == SQ_DEVICE_OK) {
      device->render.pause();
      delete device;
    }
    return nullptr;
  }
  return device;
}
sq_device_result sq_device_start(sq_device *device) {
  if (!device) return SQ_DEVICE_INVALID;
  auto result = sq_device_error(device);
  if (result != SQ_DEVICE_OK) return result;
  if (device->started) return SQ_DEVICE_OK;
  result = device->render.resume();
  if (result != SQ_DEVICE_OK) return result;
  result = sq_host::platform_start(device);
  if (result != SQ_DEVICE_OK) {
    device->render.fail(result);
    device->render.pause();
    return result;
  }
  device->started = true;
  return sq_device_error(device);
}
sq_device_result sq_device_pause(sq_device *device) {
  if (!device) return SQ_DEVICE_INVALID;
  device->render.pause();
  if (!device->started) return SQ_DEVICE_OK;
  const auto result = sq_host::platform_pause(device);
  if (result != SQ_DEVICE_OK) device->render.fail(result);
  else device->started = false;
  return result;
}
sq_device_result sq_device_close(sq_device *device) {
  if (!device) return SQ_DEVICE_OK;
  device->render.pause();
  const auto result = sq_host::platform_close(device);
  if (result != SQ_DEVICE_OK) {
    device->render.fail(result);
    return result;
  }
  device->render.pause(); // native close has removed callback sources
  delete device;
  return SQ_DEVICE_OK;
}
sq_device_result sq_device_error(const sq_device *device) {
  return device ? static_cast<sq_device_result>(device->render.error.load(std::memory_order_acquire)) : open_error;
}
int32_t sq_device_native_error(const sq_device *device) {
  return device ? device->render.native_error.load(std::memory_order_acquire) : open_native_error;
}
uint32_t sq_device_sample_rate(const sq_device *d) { return d ? d->render.sample_rate : 0; }
uint32_t sq_device_max_block_frames(const sq_device *d) { return d ? d->render.max_block : 0; }
}
