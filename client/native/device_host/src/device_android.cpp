#include "device_internal.h"
#include <aaudio/AAudio.h>
#include <chrono>
#include <new>

namespace {
struct Android { AAudioStream *stream = nullptr; };
aaudio_data_callback_result_t output(AAudioStream *, void *context, void *audio, int32_t frames) {
  auto *d = static_cast<sq_device *>(context);
  if (frames < 0 || !audio) {
    d->render.fail(SQ_DEVICE_CALLBACK_FAILED);
    return AAUDIO_CALLBACK_RESULT_STOP;
  }
  if (!d->render.output(static_cast<float *>(audio), static_cast<uint32_t>(frames)))
    return AAUDIO_CALLBACK_RESULT_STOP;
  return AAUDIO_CALLBACK_RESULT_CONTINUE;
}
void error(AAudioStream *, void *context, aaudio_result_t code) {
  // Do NOT stop/close here (AAudio forbids it). Control thread sees sticky error
  // and explicitly closes/reopens. No Dart or UI callback is invoked.
  static_cast<sq_device *>(context)->render.fail(SQ_DEVICE_DISCONNECTED, code);
}
sq_device_result fail(sq_device *d, sq_device_result result, aaudio_result_t code) {
  d->render.fail(result, code); return result;
}
sq_device_result await(sq_device *d, aaudio_stream_state_t wanted, sq_device_result result) {
  auto *stream = static_cast<Android *>(d->platform)->stream;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  auto state = AAudioStream_getState(stream);
  while (state != wanted) {
    if (state == AAUDIO_STREAM_STATE_DISCONNECTED)
      return fail(d, SQ_DEVICE_DISCONNECTED, AAUDIO_ERROR_DISCONNECTED);
    if (state == AAUDIO_STREAM_STATE_CLOSED || state == AAUDIO_STREAM_STATE_CLOSING)
      return fail(d, result, AAUDIO_ERROR_INVALID_STATE);
    const auto left = std::chrono::duration_cast<std::chrono::nanoseconds>(
        deadline - std::chrono::steady_clock::now()).count();
    if (left <= 0) return fail(d, result, AAUDIO_ERROR_TIMEOUT);
    const auto code = AAudioStream_waitForStateChange(stream, state, &state, left);
    if (code != AAUDIO_OK) return fail(d, result, code);
  }
  return SQ_DEVICE_OK;
}
}
namespace sq_host {
sq_device_result platform_open(sq_device *d) {
  auto *p = new(std::nothrow) Android;
  if (!p) return SQ_DEVICE_NO_MEMORY;
  d->platform = p;
  AAudioStreamBuilder *builder = nullptr;
  auto code = AAudio_createStreamBuilder(&builder);
  if (code != AAUDIO_OK) return fail(d, SQ_DEVICE_OPEN_FAILED, code);
  AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
  AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
  AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
  AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
  AAudioStreamBuilder_setChannelCount(builder, 2);
  AAudioStreamBuilder_setSampleRate(builder, static_cast<int32_t>(d->render.sample_rate));
  AAudioStreamBuilder_setDataCallback(builder, output, d);
  AAudioStreamBuilder_setErrorCallback(builder, error, d);
  // Do not fix frames-per-callback: hardware can choose variable quantum.
  code = AAudioStreamBuilder_openStream(builder, &p->stream);
  const auto delete_code = AAudioStreamBuilder_delete(builder);
  if (code != AAUDIO_OK) return fail(d, SQ_DEVICE_OPEN_FAILED, code);
  if (delete_code != AAUDIO_OK) return fail(d, SQ_DEVICE_OPEN_FAILED, delete_code);
  if (AAudioStream_getSampleRate(p->stream) != static_cast<int32_t>(d->render.sample_rate) ||
      AAudioStream_getChannelCount(p->stream) != 2 ||
      AAudioStream_getFormat(p->stream) != AAUDIO_FORMAT_PCM_FLOAT)
    return fail(d, SQ_DEVICE_FORMAT_MISMATCH, 0);
  return SQ_DEVICE_OK;
}
sq_device_result platform_start(sq_device *d) {
  const auto code = AAudioStream_requestStart(static_cast<Android *>(d->platform)->stream);
  if (code != AAUDIO_OK) return fail(d, SQ_DEVICE_START_FAILED, code);
  return await(d, AAUDIO_STREAM_STATE_STARTED, SQ_DEVICE_START_FAILED);
}
sq_device_result platform_pause(sq_device *d) {
  const auto code = AAudioStream_requestPause(static_cast<Android *>(d->platform)->stream);
  if (code != AAUDIO_OK) return fail(d, SQ_DEVICE_PAUSE_FAILED, code);
  return await(d, AAUDIO_STREAM_STATE_PAUSED, SQ_DEVICE_PAUSE_FAILED);
}
sq_device_result platform_close(sq_device *d) {
  auto *p = static_cast<Android *>(d->platform);
  if (!p) return SQ_DEVICE_OK;
  if (p->stream) {
    // AAudio close synchronously releases callbacks. Gate and drain engine first
    // in common host; never call this from AAudio data/error callback.
    const auto code = AAudioStream_close(p->stream);
    if (code != AAUDIO_OK) return fail(d, SQ_DEVICE_CLOSE_FAILED, code);
    p->stream = nullptr;
  }
  delete p; d->platform = nullptr;
  return SQ_DEVICE_OK;
}
}
