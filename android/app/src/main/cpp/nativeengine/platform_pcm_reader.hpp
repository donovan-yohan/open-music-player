#pragma once
#include "pcm_reader.hpp"
#include "sq_file_decoder.h"
#include "decoder_budget.hpp"
#include <jni.h>
#include <stdexcept>
namespace soundq::nativeengine {
// These objects are never reachable from Engine/render. Worker lifetime owns the
// JVM attachment and peer close. Global ref custody survives uncertain admission.
struct AttachedJvm {
    JavaVM* vm; JNIEnv* env=nullptr;bool attached=false;
    explicit AttachedJvm(JavaVM* value):vm(value) {
        const auto status=vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6);
        if(status==JNI_EDETACHED) {
#if defined(__ANDROID__)
            const auto attachedStatus=vm->AttachCurrentThread(&env,nullptr);
#else
            const auto attachedStatus=vm->AttachCurrentThread(reinterpret_cast<void**>(&env),nullptr);
#endif
            if(attachedStatus!=JNI_OK)throw std::runtime_error("JVM attach refused");
            attached=true;
        } else if(status!=JNI_OK)throw std::runtime_error("JVM unavailable");
    }
    ~AttachedJvm(){if(attached)vm->DetachCurrentThread();}
};
struct PlatformPeer {
    JavaVM* vm=nullptr;jobject object=nullptr;
    jmethodID open=nullptr,read=nullptr,end=nullptr,close=nullptr;
    PlatformPeer(JNIEnv* env,jobject input) {
        if(env->GetJavaVM(&vm)!=JNI_OK)throw std::runtime_error("JVM unavailable");
        const auto cls=env->GetObjectClass(input);
        open=env->GetMethodID(cls,"open","()I");
        read=env->GetMethodID(cls,"read","(JILjava/nio/ByteBuffer;)I");
        end=env->GetMethodID(cls,"endFrames","()J");
        close=env->GetMethodID(cls,"closeReader","()Z");
        env->DeleteLocalRef(cls);
        if(env->ExceptionCheck() || !open || !read || !end || !close)throw std::runtime_error("Platform reader ABI mismatch");
        object=env->NewGlobalRef(input);if(!object)throw std::bad_alloc();
    }
    ~PlatformPeer(){try {AttachedJvm thread(vm);thread.env->DeleteGlobalRef(object);}catch(...) {/* VM shutdown retains reference */}}
};
class PlatformPcmReader final:public PcmReader {
    std::shared_ptr<PlatformPeer> peer;
    AttachedJvm thread;
    uint32_t rate=0;
    mutable uint64_t end=0;
    bool closePeer()noexcept {
        const auto ok=thread.env->CallBooleanMethod(peer->object,peer->close);
        const bool failed=thread.env->ExceptionCheck();
        if(failed)thread.env->ExceptionClear();
        // A failed concrete close keeps a process-wide permit permanently. The
        // Kotlin failed owner retains the actual peer/descriptor; no fifth codec.
        if(failed || !ok) {decoderPermits.fetch_add(1,std::memory_order_acq_rel);retainedPlatformDecoders.fetch_add(1,std::memory_order_acq_rel);}
        return !failed && ok;
    }
    void check()const {if(thread.env->ExceptionCheck()){thread.env->ExceptionClear();throw std::runtime_error("Platform decoder failed or source retired");}}
public:
    explicit PlatformPcmReader(std::shared_ptr<PlatformPeer> p):peer(std::move(p)),thread(peer->vm) {
        try {
        const auto hz=thread.env->CallIntMethod(peer->object,peer->open);check();
        if(hz<8000 || hz>192000)throw std::runtime_error("Unsupported platform sample rate");
        rate=static_cast<uint32_t>(hz);
        const auto known=thread.env->CallLongMethod(peer->object,peer->end);check();
        if(known<0)throw std::runtime_error("Invalid platform endpoint");
        end=static_cast<uint64_t>(known);
        } catch(...) {closePeer();throw;}
    }
    ~PlatformPcmReader()override {
        closePeer(); // Owner separately verifies concrete peer release before its drain ACK.
    }
    uint32_t sampleRate()const override{return rate;}
    uint64_t endFrames()const override{return end;}
    int read(uint64_t first,uint32_t count,float* out,size_t bytes,uint32_t& n)override {
        n=0;
        if(bytes<size_t{count}*8 || first>(uint64_t{1}<<52))return SQ_FILE_INVALID_ARGUMENT;
        auto* env=thread.env;
        const auto buffer=env->NewDirectByteBuffer(out,static_cast<jlong>(size_t{count}*8));
        if(!buffer){check();return SQ_FILE_OUT_OF_MEMORY;}
        const auto result=env->CallIntMethod(peer->object,peer->read,static_cast<jlong>(first),static_cast<jint>(count),buffer);
        env->DeleteLocalRef(buffer);check();
        const auto endpoint=env->CallLongMethod(peer->object,peer->end);check();
        if(endpoint<0 || (end && endpoint!=static_cast<jlong>(end)) || result<0 || static_cast<uint32_t>(result)>count)return SQ_FILE_DECODE;
        end=static_cast<uint64_t>(endpoint);n=static_cast<uint32_t>(result);return 0;
    }
};
}
