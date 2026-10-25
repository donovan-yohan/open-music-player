#include "soundq_device.h"
#include <cstdio>
#include <cstdlib>

#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::abort(); } } while (0)
int main() {
  CHECK(sq_device_open(nullptr, 48000, 128) == nullptr);
  CHECK(sq_device_error(nullptr) == SQ_DEVICE_INVALID);
  CHECK(sq_device_native_error(nullptr) == 0);
  const sq_config config{SQ_ABI_VERSION, 48000, 128, 2048};
  auto *engine = sq_create(&config);
  CHECK(engine);
  CHECK(sq_device_open(engine, 0, 128) == nullptr);
  CHECK(sq_device_error(nullptr) == SQ_DEVICE_INVALID);
  CHECK(sq_device_open(engine, 48000, 0) == nullptr);
  CHECK(sq_device_open(engine, 48000, 65537) == nullptr);
  CHECK(sq_device_open(engine, 192001, 128) == nullptr);
  CHECK(sq_rendered_frames(engine) == 0);
  CHECK(sq_device_start(nullptr) == SQ_DEVICE_INVALID);
  CHECK(sq_device_pause(nullptr) == SQ_DEVICE_INVALID);
  CHECK(sq_device_close(nullptr) == SQ_DEVICE_OK);
  sq_destroy(engine);
  std::puts("device invalid-config tests passed (no OS open/start)");
}
