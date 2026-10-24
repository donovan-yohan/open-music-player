#include "device_internal.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <thread>
#include <vector>

static thread_local bool callback_guard = false;
static std::atomic<unsigned> callback_heap_calls{0};
void *operator new(std::size_t n) {
  if (callback_guard) ++callback_heap_calls;
  if (auto *p = std::malloc(n ? n : 1)) return p;
  throw std::bad_alloc();
}
void *operator new[](std::size_t n) { return ::operator new(n); }
void operator delete(void *p) noexcept {
  if (callback_guard) ++callback_heap_calls;
  std::free(p);
}
void operator delete[](void *p) noexcept { ::operator delete(p); }
static bool guarded_output(sq_host::Render& r, float *out, uint32_t frames) {
  callback_guard = true;
  const bool result = r.output(out, frames);
  callback_guard = false;
  return result;
}

#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::abort(); } } while (0)
int main() {
  const sq_config c{SQ_ABI_VERSION, 48000, 8, 2048};
  auto *engine = sq_create(&c);
  CHECK(engine);
  std::vector<float> pcm(2048 * 2);
  for (size_t f = 0; f < 2048; ++f) {
    pcm[f*2] = static_cast<float>(f)/4096;
    pcm[f*2+1] = -pcm[f*2];
  }
  sq_plan p{};
  p.revision = 1; p.master_gain = 1; p.deck_count = 1;
  auto& d = p.decks[0];
  d.instance_id = 1; d.pcm.sample_rate = 48000; d.pcm.bus_count = 1;
  d.pcm.frame_count = 2048; d.pcm.buses[0] = pcm.data();
  d.source_start_frame = 17; d.end_frame = 1024; d.buses[0].gain = 1;
  CHECK(sq_submit(engine, &p) == SQ_OK);
  sq_host::Render render(engine, 48000, 8);
  CHECK(render.ready());
  std::vector<float> out(73*2, 99);
  CHECK(render.output(out.data(), 73));
  CHECK(std::all_of(out.begin(), out.end(), [](float x){return x == 0;}));
  CHECK(sq_rendered_frames(engine) == 0);
  CHECK(sq_applied_revision(engine) == 0);
  CHECK(render.resume() == SQ_DEVICE_OK);
  uint64_t cursor = 0;
  for (uint32_t quantum : {1u, 7u, 8u, 9u, 73u}) {
    out.assign(quantum*2, 99);
    CHECK(guarded_output(render, out.data(), quantum));
    for (uint32_t f = 0; f < quantum; ++f) {
      CHECK(out[f*2] == pcm[(17+cursor+f)*2]);
      CHECK(out[f*2+1] == pcm[(17+cursor+f)*2+1]);
    }
    cursor += quantum;
    CHECK(sq_rendered_frames(engine) == cursor);
    CHECK(sq_applied_revision(engine) == 1);
  }
  render.pause();
  p.revision = 2;
  CHECK(sq_submit(engine, &p) == SQ_OK);
  out.assign(38, 99);
  CHECK(render.output(out.data(), 19));
  CHECK(std::all_of(out.begin(), out.end(), [](float x){return x == 0;}));
  CHECK(sq_rendered_frames(engine) == cursor);
  CHECK(sq_applied_revision(engine) == 1);
  CHECK(render.resume() == SQ_DEVICE_OK);
  CHECK(render.output(out.data(), 19));
  CHECK(out[0] == pcm[(17+cursor)*2]);
  CHECK(sq_rendered_frames(engine) == cursor+19);
  CHECK(sq_applied_revision(engine) == 2);
  render.fail(SQ_DEVICE_DISCONNECTED, -899);
  out.assign(38, 99);
  CHECK(render.output(out.data(), 19));
  CHECK(std::all_of(out.begin(), out.end(), [](float x){return x == 0;}));
  CHECK(sq_rendered_frames(engine) == cursor+19);
  CHECK(render.resume() == SQ_DEVICE_DISCONNECTED);
  CHECK(render.native_error.load() == -899);
  render.pause();
  sq_destroy(engine);
  // A caller-supplied block mismatch is not discoverable through opaque ABI v1;
  // it must fail closed at first callback, without advancing the engine.
  engine = sq_create(&c); CHECK(engine);
  {
    sq_host::Render mismatch(engine, 48000, 9);
    CHECK(mismatch.resume() == SQ_DEVICE_OK);
    float bad_out[18]; std::fill_n(bad_out, 18, 99);
    CHECK(!mismatch.output(bad_out, 9));
    CHECK(std::all_of(bad_out, bad_out+18, [](float x){return x == 0;}));
    CHECK(sq_rendered_frames(engine) == 0);
    CHECK(mismatch.error.load() == SQ_DEVICE_RENDER_FAILED);
    CHECK(mismatch.resume() == SQ_DEVICE_RENDER_FAILED);
    mismatch.pause();
  }
  sq_destroy(engine);
  // Four transport instances and twenty independently controlled aligned buses
  // through the same callback path, with a quantum larger than engine max.
  engine = sq_create(&c); CHECK(engine);
  {
    std::vector<float> assets[4][5];
    sq_plan four{}; four.revision = 1; four.deck_count = 4; four.master_gain = 0.05f;
    for (unsigned deck = 0; deck < 4; ++deck) {
      auto& transport = four.decks[deck];
      transport.slot = deck; transport.instance_id = deck+1;
      transport.start_frame = 3; transport.end_frame = 30;
      transport.source_start_frame = 11;
      transport.pcm.sample_rate = 48000;
      transport.pcm.frame_count = 2048; transport.pcm.bus_count = 5;
      for (unsigned bus = 0; bus < 5; ++bus) {
        auto& samples = assets[deck][bus]; samples.assign(4096, 0);
        samples[34] = static_cast<float>(1+deck+bus)/16;
        samples[35] = -samples[34];
        transport.pcm.buses[bus] = samples.data();
        transport.buses[bus].gain = 1;
      }
    }
    CHECK(sq_submit(engine, &four) == SQ_OK);
    sq_host::Render multi(engine, 48000, 8);
    CHECK(multi.resume() == SQ_DEVICE_OK);
    float samples[146]; CHECK(guarded_output(multi, samples, 73));
    for (unsigned frame = 0; frame < 73; ++frame) {
      double sum = 0;
      if (frame == 9) for (unsigned deck = 0; deck < 4; ++deck)
        for (unsigned bus = 0; bus < 5; ++bus) sum += static_cast<float>(1+deck+bus)/16;
      CHECK(std::abs(samples[frame*2] - static_cast<float>(sum*four.master_gain)) < 1e-7f);
      CHECK(samples[frame*2+1] == -samples[frame*2]);
    }
    CHECK(sq_rendered_frames(engine) == 73);
    multi.pause();
  }
  sq_destroy(engine);
  // A real native callback consumer racing control-thread pause/resume. After
  // pause returns, continuing callbacks must never advance the engine cursor.
  engine = sq_create(&c); CHECK(engine);
  {
    sq_host::Render threaded(engine, 48000, 8);
    std::atomic<bool> done{false};
    std::atomic<unsigned> calls{0};
    std::thread callback([&] {
      float samples[146];
      while (!done.load()) {
        CHECK(guarded_output(threaded, samples, 73));
        calls.fetch_add(1);
      }
    });
    for (unsigned i = 0; i < 100; ++i) {
      CHECK(threaded.resume() == SQ_DEVICE_OK);
      const auto before = calls.load();
      while (calls.load() == before) std::this_thread::yield();
      threaded.pause();
      const auto frozen = sq_rendered_frames(engine);
      const auto paused_calls = calls.load();
      while (calls.load()-paused_calls < 20) std::this_thread::yield();
      CHECK(sq_rendered_frames(engine) == frozen);
    }
    done.store(true);
    callback.join();
    threaded.pause();
  }
  sq_destroy(engine);
  CHECK(callback_heap_calls.load() == 0);
  std::puts("callback quantum/source mapping/pause-drain/resume/errors/no-C++-heap tests passed");
}
