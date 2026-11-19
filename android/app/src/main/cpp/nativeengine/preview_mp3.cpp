#include "preview_mp3.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <new>

#define DR_MP3_FLOAT_OUTPUT
#define DR_MP3_ONLY_MP3
#define DR_MP3_NO_STDIO
#ifdef SOUNDQ_PREVIEW_LINK_DR_MP3
#define DR_MP3_NO_SIMD // must match sq_file_decoder.cpp
#else
#define DR_MP3_IMPLEMENTATION
#endif
#include "dr_mp3.h"

namespace {
constexpr size_t maxBytes = 2 * 1024 * 1024;
constexpr uint32_t maxSeconds = 30;
constexpr uint32_t packetFrames = 1152; // MPEG-1 Layer III only
constexpr uint32_t synthesisDelay = 529; // dr_mp3's existing Xing/LAME convention
uint32_t be32(const uint8_t* p) {
    return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
struct Frame {
    uint32_t size, rate, channels;
};
Frame parse(const uint8_t* p) {
    // Layer III, MPEG-1, CRC-free, no free-format or reserved fields.
    if (p[0] != 0xff || p[1] != 0xfb || (p[3] & 3) == 2) return {};
    const uint32_t bitrate = p[2] >> 4, index = p[2] >> 2 & 3;
    if (!bitrate || bitrate == 15 || index == 3) return {};
    constexpr uint32_t rates[]{44100,48000,32000};
    constexpr uint32_t kbps[]{0,32,40,48,56,64,80,96,112,128,160,192,224,256,320};
    const auto hz = rates[index];
    return {144000 * kbps[bitrate] / hz + ((p[2] >> 1) & 1), hz,
            (p[3] >> 6) == 3 ? 1u : 2u};
}
}

struct sq_preview_mp3 {
    size_t length, seen = 0, used = 0;
    uint64_t expected, origin = 0;
    sq_preview_pcm sink;
    void* context;
    int terminal = SQ_PREVIEW_OK;
    Frame format{};
    uint32_t packets = 0, decoded = 0, trimStart = 0, trimEnd = 0, pending = 0;
    drmp3dec codec{};
    std::array<uint8_t, 1441> encoded{}; // max frame at 320 kbps/32 kHz incl. padding
    std::array<float, packetFrames * 2> pcm{};

    int stop(int code) { return terminal = code; }
    int status() const { return terminal; }
    int tag(const Frame& f) {
        const size_t marker = f.channels == 1 ? 21 : 36;
        if (f.size < marker + 8) return stop(SQ_PREVIEW_FORMAT);
        const auto* p = encoded.data() + marker;
        if (std::memcmp(p,"Xing",4) && std::memcmp(p,"Info",4)) return stop(SQ_PREVIEW_FORMAT);
        const auto flags = be32(p + 4);
        if ((flags & 3) != 3 || flags > 15) return stop(SQ_PREVIEW_FORMAT);
        const size_t encoder = marker + 16 + ((flags & 4) ? 100 : 0) + ((flags & 8) ? 4 : 0);
        if (f.size < encoder + 36) return stop(SQ_PREVIEW_FORMAT);
        p = encoded.data() + encoder;
        if (std::memcmp(p,"LAME",4) && std::memcmp(p,"Lavc",4)) return stop(SQ_PREVIEW_FORMAT);
        const auto count = be32(encoded.data() + marker + 8);
        const auto byteCount = be32(encoded.data() + marker + 12);
        const uint64_t rawFrames = uint64_t{count} * packetFrames;
        const uint32_t delay = uint32_t(p[21]) << 4 | p[22] >> 4;
        const uint32_t padding = uint32_t(p[22] & 15) << 8 | p[23];
        if (!count || byteCount != length || padding < synthesisDelay ||
            rawFrames <= delay + padding || rawFrames - delay - padding != expected ||
            expected > uint64_t{f.rate} * maxSeconds) return stop(SQ_PREVIEW_FORMAT);
        format = f;
        packets = count;
        trimStart = delay + synthesisDelay;
        trimEnd = padding - synthesisDelay;
        return SQ_PREVIEW_OK;
    }
    int publish(uint32_t first, uint32_t n) {
        const auto at = origin;
        if (n && !sink(context, pcm.data() + first * 2, at, n, format.rate))
            return stop(SQ_PREVIEW_RETIRED);
        origin += n;
        return SQ_PREVIEW_OK;
    }
    int packet(const Frame& f) {
        if (!packets) return tag(f);
        if (decoded == packets || f.rate != format.rate || f.channels != format.channels)
            return stop(SQ_PREVIEW_FORMAT);
        drmp3dec_frame_info info{};
        const auto n = drmp3dec_decode_frame(&codec, encoded.data(), int(f.size), pcm.data(), &info);
        if (n != packetFrames || info.frame_bytes != int(f.size) || info.layer != 3 ||
            info.channels != int(f.channels) || info.sample_rate != int(f.rate)) return stop(SQ_PREVIEW_FORMAT);
        const auto rawStart = uint64_t{decoded++} * packetFrames;
        const auto first = std::max<uint64_t>(rawStart,trimStart);
        const auto end = std::min(rawStart + packetFrames,uint64_t{packets} * packetFrames - trimEnd);
        if (first >= end) return SQ_PREVIEW_OK;
        const auto local = uint32_t(first - rawStart), count = uint32_t(end - first);
        if (f.channels == 1) {
            for (uint32_t i = packetFrames; i-- != 0;) pcm[2*i + 1] = pcm[2*i] = pcm[i];
        }
        for (uint32_t i = local * 2; i < (local + count) * 2; ++i)
            if (!std::isfinite(pcm[i])) return stop(SQ_PREVIEW_FORMAT);
        // Withhold the last usable PCM even if a later packet is entirely padding.
        // Never overwrite held PCM: the next decode may still need to validate padding.
        if (first - trimStart != origin) return stop(SQ_PREVIEW_FORMAT);
        if (origin + count == expected) {
            pending = count;
            std::copy_n(pcm.data() + 2*local, 2*count, tail.data());
            return SQ_PREVIEW_OK;
        }
        return publish(local, count);
    }
    std::array<float, packetFrames * 2> tail{};
    sq_preview_mp3(size_t l, uint64_t f, sq_preview_pcm s, void* c)
        : length(l), expected(f), sink(s), context(c) { drmp3dec_init(&codec); }
};

extern "C" sq_preview_mp3* sq_preview_create(size_t length, uint64_t frames, sq_preview_pcm sink, void* ctx) {
    if (!sink || !length || length > maxBytes || !frames || frames > 48000u * maxSeconds) return nullptr;
    return new (std::nothrow) sq_preview_mp3(length, frames, sink, ctx);
}
extern "C" int sq_preview_feed(sq_preview_mp3* s, const uint8_t* p, size_t n) {
    if (!s) return SQ_PREVIEW_FORMAT;
    if (s->status()) return s->status();
    if (n > s->length - s->seen) return s->stop(SQ_PREVIEW_LIMIT);
    if (!p && n) return s->stop(SQ_PREVIEW_FORMAT);
    s->seen += n;
    while (n) {
        size_t target = 4;
        Frame f{};
        if (s->used >= 4) {
            f = parse(s->encoded.data());
            if (!f.size || f.size > s->encoded.size()) return s->stop(SQ_PREVIEW_FORMAT);
            target = f.size;
        }
        const auto copy = std::min(n,target - s->used);
        std::memcpy(s->encoded.data() + s->used,p,copy);
        s->used += copy;
        n -= copy;
        p += copy;
        if (f.size && s->used == target) {
            if (const auto error = s->packet(f)) return error;
            s->used = 0;
        }
    }
    return SQ_PREVIEW_OK;
}
extern "C" int sq_preview_finish(sq_preview_mp3* s) {
    if (!s) return SQ_PREVIEW_FORMAT;
    if (s->status()) return s->status();
    if (s->seen != s->length || s->used || !s->packets || s->decoded != s->packets ||
        !s->pending || s->origin + s->pending != s->expected) return s->stop(SQ_PREVIEW_TRUNCATED);
    if (!s->sink(s->context, s->tail.data(), s->origin, s->pending, s->format.rate))
        return s->stop(SQ_PREVIEW_RETIRED);
    s->origin += s->pending;
    s->stop(SQ_PREVIEW_CLOSED);
    return SQ_PREVIEW_OK;
}
extern "C" void sq_preview_destroy(sq_preview_mp3* s) { delete s; }
extern "C" size_t sq_preview_state_bytes() { return sizeof(sq_preview_mp3); }
