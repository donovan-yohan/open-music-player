#include "callback_host.hpp"
#include "platform_pcm_reader.hpp"
#include <jni.h>
#include <cstdint>
#include <string>
namespace {
soundq::nativeengine::Registry& registry() {
    // Process lifetime; a failed close must retain the last audible owner, not
    // run an unsafe static destructor as the VM unloads unrelated Java state.
    static auto* value = new soundq::nativeengine::Registry();
    return *value;
}
bool path(JNIEnv* env, jstring input, std::string& result) {
    if (!input) return false;
    const jsize length = env->GetStringLength(input);
    if (length <= 0 || length > 32768) return false;
    const jchar* chars = env->GetStringChars(input, nullptr);
    if (!chars) return false;
    bool valid = true;
    try {
        result.reserve(static_cast<size_t>(length) * 3);
        for (jsize i = 0; i < length; ++i) {
            uint32_t cp = chars[i];
            if (cp == 0) { valid = false; break; }
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                if (i + 1 == length || chars[i + 1] < 0xDC00 || chars[i + 1] > 0xDFFF) { valid = false; break; }
                cp = 0x10000 + ((cp - 0xD800) << 10) + (chars[++i] - 0xDC00);
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) { valid = false; break; }
            if (cp < 0x80) result.push_back(static_cast<char>(cp));
            else if (cp < 0x800) {
                result.push_back(static_cast<char>(0xC0 | (cp >> 6)));
                result.push_back(static_cast<char>(0x80 | (cp & 63)));
            } else if (cp < 0x10000) {
                result.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 6) & 63)));
                result.push_back(static_cast<char>(0x80 | (cp & 63)));
            } else {
                result.push_back(static_cast<char>(0xF0 | (cp >> 18)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 12) & 63)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 6) & 63)));
                result.push_back(static_cast<char>(0x80 | (cp & 63)));
            }
        }
    } catch (...) { env->ReleaseStringChars(input, chars); throw; }
    env->ReleaseStringChars(input, chars);
    return valid;
}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_prepareSchedule(
    JNIEnv* env,jclass,jlong handle,jlong revision,jobjectArray input,jlongArray values) {
    try {
        if(handle<=0 || revision<=0 || !input || !values)return JNI_FALSE;
        const auto count=env->GetArrayLength(input);
        if(count<1 || count>500)return JNI_FALSE;
        const auto length=env->GetArrayLength(values);
        if(length!=count*5 && length!=count*6)return JNI_FALSE;
        std::vector<std::string> paths;std::vector<jlong> raw(static_cast<size_t>(length));
        env->GetLongArrayRegion(values,0,length,raw.data());if(env->ExceptionCheck())return JNI_FALSE;
        for(jsize i=0;i<count;++i) {
            auto s=static_cast<jstring>(env->GetObjectArrayElement(input,i));std::string value;
            const bool valid=path(env,s,value);env->DeleteLocalRef(s);if(!valid)return JNI_FALSE;paths.push_back(std::move(value));
        }
        const std::vector<int64_t> numbers(raw.begin(),raw.end());
        return registry().prepareSchedule(static_cast<uint64_t>(handle),static_cast<uint64_t>(revision),paths,numbers)?JNI_TRUE:JNI_FALSE;
    }catch(...){return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_prepareScheduleV2(
    JNIEnv* env,jclass,jlong handle,jlong revision,jobjectArray input,jlongArray values,jdoubleArray tempo) {
    try {
        if(handle<=0 || revision<=0 || !input || !values || !tempo)return JNI_FALSE;
        const auto count=env->GetArrayLength(input);
        if(count<1 || count>500 || env->GetArrayLength(values)!=count*6 || env->GetArrayLength(tempo)!=count*8)return JNI_FALSE;
        std::vector<jlong> raw(static_cast<size_t>(count)*6);std::vector<double> law(static_cast<size_t>(count)*8);
        env->GetLongArrayRegion(values,0,count*6,raw.data());env->GetDoubleArrayRegion(tempo,0,count*8,law.data());
        if(env->ExceptionCheck())return JNI_FALSE;
        std::vector<std::string> paths;
        for(jsize i=0;i<count;++i) {
            auto s=static_cast<jstring>(env->GetObjectArrayElement(input,i));std::string value;
            if(env->ExceptionCheck())return JNI_FALSE;
            const bool valid=path(env,s,value);env->DeleteLocalRef(s);if(!valid)return JNI_FALSE;paths.push_back(std::move(value));
        }
        return registry().prepareScheduleV2(static_cast<uint64_t>(handle),static_cast<uint64_t>(revision),paths,
            std::vector<int64_t>(raw.begin(),raw.end()),law)?JNI_TRUE:JNI_FALSE;
    }catch(...){return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_crossfade(
    JNIEnv*,jclass,jlong handle,jint out,jlong og,jint in,jlong ig,jlong ms) {
    try {return handle>0 && og>0 && ig>0 && ms>=0 && registry().crossfade(handle,out,og,in,ig,ms)?JNI_TRUE:JNI_FALSE;}
    catch(...){return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_arrangement(
    JNIEnv*,jclass,jlong handle,jint operation,jlong value) {
    try{return handle>0 && value>=0 && registry().arrangement(static_cast<uint64_t>(handle),operation,static_cast<uint64_t>(value))?JNI_TRUE:JNI_FALSE;}
    catch(...){return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_liveTempo(
    JNIEnv*,jclass,jlong handle,jlong revision,jlong instance,jlong tag,jdouble sourceBpm,jdouble targetBpm,jlong glideFrames,jlong reservation) {
    try { return handle>0 && revision>0 && instance>0 && tag>0 && glideFrames>=0 && reservation>=0 &&
        registry().liveTempo(static_cast<uint64_t>(handle),static_cast<uint64_t>(revision),static_cast<uint64_t>(instance),
            static_cast<uint64_t>(tag),sourceBpm,targetBpm,static_cast<uint64_t>(glideFrames),static_cast<uint64_t>(reservation)) ? JNI_TRUE : JNI_FALSE; }
    catch(...) { return JNI_FALSE; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_reserveTempo(
    JNIEnv*,jclass,jlong handle,jlong revision,jlong instance,jdouble source,jdouble origin) {
    try {return handle>0 && revision>0 && instance>0?static_cast<jlong>(registry().reserveTempo(handle,revision,instance,source,origin)):0;}
    catch(...) {return 0;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_restoreTempo(
    JNIEnv*,jclass,jlong handle,jlong reservation,jlong tag) {
    try {return handle>0 && reservation>0 && tag>0 && registry().restoreTempo(handle,reservation,tag)?JNI_TRUE:JNI_FALSE;}
    catch(...) {return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_releaseTempo(
    JNIEnv*,jclass,jlong handle,jlong reservation) {
    try {return handle>0 && reservation>0 && registry().releaseTempo(handle,reservation)?JNI_TRUE:JNI_FALSE;}
    catch(...) {return JNI_FALSE;}
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_open(JNIEnv*, jclass) {
    try { return static_cast<jlong>(registry().open(soundq::nativeengine::makeOboeOutput())); }
    catch (...) { return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_scratch(
    JNIEnv*,jclass,jlong handle,jint operation,jlong instance,jlong gesture,jlong eventNanos,jdouble rate) {
    try{return handle>0 && instance>0 && gesture>0 && eventNanos>0 && registry().scratch(static_cast<uint64_t>(handle),operation,
        static_cast<uint64_t>(instance),static_cast<uint64_t>(gesture),static_cast<uint64_t>(eventNanos),rate)?JNI_TRUE:JNI_FALSE;}
    catch(...){return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_sync(
    JNIEnv*,jclass,jlong handle,jlong incoming,jlong reference,jint beats,jdouble rb,jdouble ra,jdouble ro,jdouble ib,jdouble ia,jdouble io) {
    try{return handle>0 && incoming>0 && (beats==0 || reference>0) && registry().sync(static_cast<uint64_t>(handle),static_cast<uint64_t>(incoming),
        reference>0?static_cast<uint64_t>(reference):0,beats,rb,ra,ro,ib,ia,io)?JNI_TRUE:JNI_FALSE;}
    catch(...){return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_load(
    JNIEnv* env, jclass, jlong handle, jint deck, jstring input, jlong identity, jlong generation, jlong positionMs) {
    try {
        if (handle <= 0 || identity <= 0 || generation <= 0 || positionMs < 0) return JNI_FALSE;
        std::string source;
        return path(env, input, source) && registry().load(static_cast<uint64_t>(handle), deck, source,
            static_cast<uint64_t>(identity), static_cast<uint64_t>(generation), static_cast<uint64_t>(positionMs)) ? JNI_TRUE : JNI_FALSE;
    } catch (...) { return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_loadReader(
    JNIEnv* env,jclass,jlong handle,jint deck,jobject reader,jlong identity,jlong generation,jlong position,jdouble speed) {
    try {
        if(handle<=0 || identity<=0 || generation<=0 || position<0 || !reader)return JNI_FALSE;
        auto peer=std::make_shared<soundq::nativeengine::PlatformPeer>(env,reader);
        auto factory=std::make_shared<const soundq::nativeengine::PcmReaderFactory>([peer]{return std::make_unique<soundq::nativeengine::PlatformPcmReader>(peer);});
        return registry().loadReader(handle,deck,std::move(factory),identity,generation,position,speed)?JNI_TRUE:JNI_FALSE;
    } catch(...) {if(env->ExceptionCheck())env->ExceptionClear();return JNI_FALSE;}
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_loadSpeed(
    JNIEnv* env, jclass, jlong handle, jint deck, jstring input, jlong identity, jlong generation, jlong positionMs, jdouble speed) {
    try {
        if (handle <= 0 || identity <= 0 || generation <= 0 || positionMs < 0) return JNI_FALSE;
        std::string source;
        return path(env, input, source) && registry().loadSpeed(static_cast<uint64_t>(handle), deck, source,
            static_cast<uint64_t>(identity), static_cast<uint64_t>(generation), static_cast<uint64_t>(positionMs), speed) ? JNI_TRUE : JNI_FALSE;
    } catch (...) { return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_control(
    JNIEnv*, jclass, jlong handle, jint operation, jint deck, jdouble value, jlong eventNanos) {
    try {
        return handle > 0 && eventNanos >= 0 && registry().control(static_cast<uint64_t>(handle), operation, deck,
            value, static_cast<uint64_t>(eventNanos)) ? JNI_TRUE : JNI_FALSE;
    } catch (...) { return JNI_FALSE; }
}
extern "C" JNIEXPORT jstring JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_state(JNIEnv* env, jclass, jlong handle) {
    try {
        const auto json = registry().state(handle > 0 ? static_cast<uint64_t>(handle) : 0);
        return env->NewStringUTF(json.c_str());
    } catch (...) { return env->NewStringUTF("{\"error\":-10001,\"decks\":[]}"); }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_soundq_android_playback_nativeengine_NativeCallbackBridge_close(JNIEnv*, jclass, jlong handle) {
    try { return handle > 0 && registry().close(static_cast<uint64_t>(handle)) ? JNI_TRUE : JNI_FALSE; }
    catch (...) { return JNI_FALSE; }
}
