// TEST ONLY: deterministic codec boundary; never included by Android target.
#include "sq_file_decoder.h"
#include <atomic>
#include <cstring>
#include <cmath>
#include <thread>
struct sq_file_decoder { uint32_t rate; int64_t frames; bool tone; };
std::atomic<int> testDecoders{0};
std::atomic<bool> testHoldOpen{false}, testOpenEntered{false};
std::atomic<bool> testHoldRead{false}, testReadEntered{false};
std::atomic<int> testReadError{0};
extern "C" int sq_file_decoder_open(const char* path, uint64_t, sq_file_decoder** out) {
    *out = nullptr;
    if (testHoldOpen.load()) {
        testOpenEntered.store(true);
        while (testHoldOpen.load()) std::this_thread::yield();
    }
    if (std::strstr(path, "invalid")) return SQ_FILE_INVALID_STREAM;
    *out = new sq_file_decoder{32000, 320000, std::strstr(path, "tone") != nullptr};
    ++testDecoders;
    return SQ_FILE_OK;
}
extern "C" uint32_t sq_file_decoder_sample_rate(const sq_file_decoder* d) { return d ? d->rate : 0; }
extern "C" uint32_t sq_file_decoder_channels(const sq_file_decoder* d) { return d ? 2 : 0; }
extern "C" int64_t sq_file_decoder_frame_count(const sq_file_decoder* d) { return d ? d->frames : -1; }
extern "C" int sq_file_decoder_read_window(sq_file_decoder* d, int64_t start, uint32_t count,
                                          float* out, size_t capacity, uint32_t* read) {
    *read = 0;
    if(testHoldRead.load()){testReadEntered.store(true);while(testHoldRead.load())std::this_thread::yield();}
    if(const auto error=testReadError.load())return error;
    if (!d || start < 0 || start > d->frames || capacity < size_t{count} * 2 * sizeof(float)) return SQ_FILE_INVALID_ARGUMENT;
    *read = static_cast<uint32_t>(d->frames - start < count ? d->frames - start : count);
    for (uint64_t i = 0; i < uint64_t{*read} * 2; ++i) out[i] = d->tone ? static_cast<float>(.125*std::sin(2*3.14159265358979323846*440*(start+static_cast<int64_t>(i/2))/d->rate)) : 0.125f;
    return SQ_FILE_OK;
}
extern "C" void sq_file_decoder_destroy(sq_file_decoder* d) { if (d) { --testDecoders; delete d; } }
