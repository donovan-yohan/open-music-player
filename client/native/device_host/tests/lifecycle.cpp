#include "device_internal.h"
#include <cstdio>
#include <cstdlib>
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::abort(); } } while (0)
namespace {
sq_device_result open_result = SQ_DEVICE_OK, start_result = SQ_DEVICE_OK;
sq_device_result stop_result = SQ_DEVICE_OK, close_result = SQ_DEVICE_OK;
unsigned starts = 0, stops = 0, closes = 0;
}
namespace sq_host {
sq_device_result platform_open(sq_device *) { return open_result; }
sq_device_result platform_start(sq_device *) { ++starts; return start_result; }
sq_device_result platform_pause(sq_device *) { ++stops; return stop_result; }
sq_device_result platform_close(sq_device *) { ++closes; return close_result; }
}
int main() {
  const sq_config c{SQ_ABI_VERSION, 48000, 8, 2048};
  auto *e = sq_create(&c); CHECK(e);
  open_result = SQ_DEVICE_OPEN_FAILED;
  CHECK(!sq_device_open(e, 48000, 8));
  CHECK(sq_device_error(nullptr) == SQ_DEVICE_OPEN_FAILED);
  CHECK(closes == 1); // partially opened OS resources are reclaimed
  closes = 0;
  open_result = SQ_DEVICE_OK;
  auto *d = sq_device_open(e, 48000, 8); CHECK(d);
  CHECK(sq_device_sample_rate(d) == 48000);
  CHECK(sq_device_max_block_frames(d) == 8);
  float output[2]{99,99};
  CHECK(d->render.output(output, 1));
  CHECK(output[0] == 0 && sq_rendered_frames(e) == 0);
  CHECK(sq_device_start(d) == SQ_DEVICE_OK);
  CHECK(sq_device_start(d) == SQ_DEVICE_OK && starts == 1);
  CHECK(d->render.output(output, 1)); CHECK(sq_rendered_frames(e) == 1);
  CHECK(sq_device_pause(d) == SQ_DEVICE_OK);
  CHECK(sq_device_pause(d) == SQ_DEVICE_OK && stops == 1);
  CHECK(d->render.output(output, 1)); CHECK(sq_rendered_frames(e) == 1);
  CHECK(sq_device_start(d) == SQ_DEVICE_OK);
  stop_result = SQ_DEVICE_PAUSE_FAILED;
  CHECK(sq_device_pause(d) == SQ_DEVICE_PAUSE_FAILED);
  CHECK(d->render.output(output, 1)); CHECK(sq_rendered_frames(e) == 1);
  CHECK(sq_device_error(d) == SQ_DEVICE_PAUSE_FAILED);
  CHECK(sq_device_start(d) == SQ_DEVICE_PAUSE_FAILED);
  close_result = SQ_DEVICE_CLOSE_FAILED;
  CHECK(sq_device_close(d) == SQ_DEVICE_CLOSE_FAILED);
  CHECK(d->render.output(output, 1)); CHECK(sq_rendered_frames(e) == 1);
  close_result = SQ_DEVICE_OK;
  CHECK(sq_device_close(d) == SQ_DEVICE_OK && closes == 2);
  stop_result = SQ_DEVICE_OK;
  d = sq_device_open(e, 48000, 8); CHECK(d);
  start_result = SQ_DEVICE_START_FAILED;
  CHECK(sq_device_start(d) == SQ_DEVICE_START_FAILED);
  CHECK(d->render.output(output, 1)); CHECK(sq_rendered_frames(e) == 1);
  CHECK(sq_device_close(d) == SQ_DEVICE_OK);
  sq_destroy(e);
  std::puts("host lifecycle/error/close-retry tests passed (fake platform only)");
}
