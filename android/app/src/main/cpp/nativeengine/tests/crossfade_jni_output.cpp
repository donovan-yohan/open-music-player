// TEST ONLY: replace OS output, not Registry/Host/WorkerDeck/decoder/Engine/JNI.
#include "callback_host.hpp"
#include <jni.h>
#include <array>
#include <memory>
namespace soundq::nativeengine {
namespace { Callbacks* current = nullptr; }
struct ControlledOutput final : Output {
    bool open(Callbacks& cb, uint32_t& rate) override { current=&cb;rate=48000;return true; }
    bool start() override { return true; }
    bool stopClose() override { current=nullptr;return true; }
    int32_t xRuns() const noexcept override { return 0; }
};
std::unique_ptr<Output> makeOboeOutput() { return std::make_unique<ControlledOutput>(); }
}
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_soundq_android_playback_nativeengine_CrossfadeDriver_render(JNIEnv* env,jclass,jint count) {
    if(count<1 || count>256 || !soundq::nativeengine::current)return nullptr;
    std::array<float,512> pcm{};
    soundq::nativeengine::current->render(pcm.data(),static_cast<uint32_t>(count));
    auto result=env->NewFloatArray(count*2);
    if(result)env->SetFloatArrayRegion(result,0,count*2,pcm.data());
    return result;
}
