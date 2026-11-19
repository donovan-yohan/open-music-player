#pragma once
#include "platform_pcm_reader.hpp"
#include "preview_mp3.h"
#include <algorithm>
#include <array>
#include <cstring>

namespace soundq::nativeengine {
// Only the page worker enters Java or the decoder. The control lane owns just
// the global ref and may cancel its OkHttp call without waiting for this worker.
struct PreviewPeer {
    JavaVM* vm = nullptr;
    jobject object = nullptr;
    jmethodID open, read, close;
    PreviewPeer(JNIEnv* env, jobject input) {
        if (env->GetJavaVM(&vm) != JNI_OK) throw std::runtime_error("No JVM");
        const auto cls = env->GetObjectClass(input);
        open = env->GetMethodID(cls, "open", "()[J");
        read = env->GetMethodID(cls, "readEncoded", "([B)I");
        close = env->GetMethodID(cls, "close", "()V");
        env->DeleteLocalRef(cls);
        if (env->ExceptionCheck() || !open || !read || !close) throw std::runtime_error("Preview peer ABI");
        object = env->NewGlobalRef(input);
        if (!object) throw std::bad_alloc();
    }
    ~PreviewPeer() { try { AttachedJvm thread(vm); thread.env->DeleteGlobalRef(object); } catch (...) {} }
};

class PreviewPcmReader final : public PcmReader {
    static constexpr uint32_t chunk = 256;
    std::shared_ptr<PreviewPeer> peer;
    AttachedJvm thread;
    std::unique_ptr<sq_preview_mp3, decltype(&sq_preview_destroy)> codec{nullptr, sq_preview_destroy};
    uint32_t rate = 0, available = 0;
    uint64_t expected = 0, cursor = 0, end = 0;
    jbyteArray bytes = nullptr;
    bool closed = false;
    // A sub-page carry plus at most one chunk's packets, never the entire clip.
    std::array<float, (previewPageFrames + 4 * 1152) * 2> carry{};

    void check() const {
        if (thread.env->ExceptionCheck()) { thread.env->ExceptionClear(); throw std::runtime_error("Preview body failed"); }
    }
    void close() {
        if (closed) return;
        closed = true;
        thread.env->CallVoidMethod(peer->object, peer->close);
        check();
    }
    static int append(void* context, const float* pcm, uint64_t first, uint32_t n, uint32_t hz) {
        auto& r = *static_cast<PreviewPcmReader*>(context);
        if (hz != r.rate || first != r.cursor + r.available || n > r.carry.size()/2 - r.available) return 0;
        std::copy_n(pcm, size_t{n} * 2, r.carry.data() + 2 * r.available);
        r.available += n;
        return 1;
    }
public:
    explicit PreviewPcmReader(std::shared_ptr<PreviewPeer> p): peer(std::move(p)), thread(peer->vm) {
        try {
            auto values = static_cast<jlongArray>(thread.env->CallObjectMethod(peer->object, peer->open));
            check();
            if (!values || thread.env->GetArrayLength(values) != 3) throw std::runtime_error("Preview bounds");
            jlong metadata[3];
            thread.env->GetLongArrayRegion(values, 0, 3, metadata);
            thread.env->DeleteLocalRef(values);
            check();
            if (metadata[0] < 1 || metadata[0] > 2097152 || (metadata[1] != 44100 && metadata[1] != 48000) ||
                metadata[2] < 1 || metadata[2] > 30 * metadata[1]) throw std::runtime_error("Preview bounds");
            rate = static_cast<uint32_t>(metadata[1]);
            expected = static_cast<uint64_t>(metadata[2]);
            codec.reset(sq_preview_create(static_cast<size_t>(metadata[0]), expected, append, this));
            if (!codec) throw std::bad_alloc();
            bytes = thread.env->NewByteArray(chunk);
            check();
            if (!bytes) throw std::bad_alloc();
        } catch (...) { try { close(); } catch (...) {} throw; }
    }
    ~PreviewPcmReader() override {
        try { close(); } catch (...) {}
        if (bytes) thread.env->DeleteLocalRef(bytes);
    }
    uint32_t sampleRate() const override { return rate; }
    uint64_t endFrames() const override { return end; }
    int read(uint64_t first, uint32_t count, float* out, size_t size, uint32_t& n) override {
        n = 0;
        if (first != cursor || count > previewPageFrames || size < size_t{count} * 8) return SQ_FILE_INVALID_ARGUMENT;
        while (available < count && !end) {
            const auto got = thread.env->CallIntMethod(peer->object, peer->read, bytes);
            check();
            if (got == -1) {
                if (sq_preview_finish(codec.get()) != SQ_PREVIEW_OK || cursor + available != expected) return SQ_FILE_DECODE;
                close();
                end = expected;
            } else {
                if (got < 1 || got > static_cast<jint>(chunk)) return SQ_FILE_DECODE;
                std::array<jbyte, chunk> input{};
                thread.env->GetByteArrayRegion(bytes, 0, got, input.data());
                check();
                if (sq_preview_feed(codec.get(), reinterpret_cast<const uint8_t*>(input.data()), got) != SQ_PREVIEW_OK)
                    return SQ_FILE_DECODE;
            }
        }
        n = std::min(count, available);
        std::copy_n(carry.data(), size_t{n} * 2, out);
        available -= n;
        cursor += n;
        std::memmove(carry.data(), carry.data() + size_t{n} * 2, size_t{available} * 8);
        return SQ_FILE_OK;
    }
};
}
