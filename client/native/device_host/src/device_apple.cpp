#include "device_internal.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <cstring>
#include <new>

namespace {
struct Apple {
  AudioUnit unit = nullptr;
  AudioDeviceID device = kAudioObjectUnknown;
  bool initialized = false, alive_listener = false, default_listener = false;
  dispatch_queue_t route_queue = nullptr;
  AudioObjectPropertyListenerBlock listener = nullptr;
};
const AudioObjectPropertyAddress alive_address{
  kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
const AudioObjectPropertyAddress default_address{
  kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
OSStatus output(void *context, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                UInt32, UInt32 frames, AudioBufferList *buffers) {
  auto *d = static_cast<sq_device *>(context);
  const size_t bytes = static_cast<size_t>(frames)*2*sizeof(float);
  if (!buffers || buffers->mNumberBuffers != 1 ||
      buffers->mBuffers[0].mNumberChannels != 2 ||
      !buffers->mBuffers[0].mData || buffers->mBuffers[0].mDataByteSize < bytes) {
    if (buffers) for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
      if (buffers->mBuffers[i].mData)
        std::memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
    d->render.fail(SQ_DEVICE_CALLBACK_FAILED);
    return kAudio_ParamError;
  }
  d->render.output(static_cast<float *>(buffers->mBuffers[0].mData), frames);
  return noErr; // render failures are sticky and output is silence
}
sq_device_result fail(sq_device *d, sq_device_result result, OSStatus status) {
  d->render.fail(result, status); return result;
}
}
namespace sq_host {
sq_device_result platform_open(sq_device *d) {
  auto *p = new(std::nothrow) Apple;
  if (!p) return SQ_DEVICE_NO_MEMORY;
  d->platform = p;
  UInt32 size = sizeof(p->device);
  OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &default_address,
                                              0, nullptr, &size, &p->device);
  if (status != noErr || p->device == kAudioObjectUnknown)
    return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  AudioComponentDescription description{};
  description.componentType = kAudioUnitType_Output;
  description.componentSubType = kAudioUnitSubType_HALOutput;
  description.componentManufacturer = kAudioUnitManufacturer_Apple;
  auto component = AudioComponentFindNext(nullptr, &description);
  if (!component) return fail(d, SQ_DEVICE_OPEN_FAILED, kAudio_ParamError);
  status = AudioComponentInstanceNew(component, &p->unit);
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  const UInt32 one = 1, zero = 0;
  status = AudioUnitSetProperty(p->unit, kAudioOutputUnitProperty_EnableIO,
                               kAudioUnitScope_Output, 0, &one, sizeof(one));
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  status = AudioUnitSetProperty(p->unit, kAudioOutputUnitProperty_EnableIO,
                               kAudioUnitScope_Input, 1, &zero, sizeof(zero));
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  status = AudioUnitSetProperty(p->unit, kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &p->device, sizeof(p->device));
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  AudioStreamBasicDescription format{};
  format.mSampleRate = d->render.sample_rate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  format.mBytesPerPacket = format.mBytesPerFrame = 2*sizeof(float);
  format.mFramesPerPacket = 1; format.mChannelsPerFrame = 2;
  format.mBitsPerChannel = 8*sizeof(float);
  status = AudioUnitSetProperty(p->unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &format, sizeof(format));
  if (status != noErr) return fail(d, SQ_DEVICE_FORMAT_MISMATCH, status);
  AudioStreamBasicDescription actual{}; size = sizeof(actual);
  status = AudioUnitGetProperty(p->unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &actual, &size);
  if (status != noErr || actual.mSampleRate != format.mSampleRate ||
      actual.mFormatID != format.mFormatID || actual.mFormatFlags != format.mFormatFlags ||
      actual.mChannelsPerFrame != 2 || actual.mBytesPerFrame != 2*sizeof(float))
    return fail(d, SQ_DEVICE_FORMAT_MISMATCH, status);
  const AURenderCallbackStruct callback{output, d};
  status = AudioUnitSetProperty(p->unit, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &callback, sizeof(callback));
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  // The AudioUnit owns output buffers; our scratch is allocated once in Render.
  // HAL quantum can exceed engine max: shared Render splits into bounded blocks.
  status = AudioUnitInitialize(p->unit);
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  p->initialized = true;
  p->route_queue = dispatch_queue_create("soundq.device.route", DISPATCH_QUEUE_SERIAL);
  p->listener = Block_copy(^(UInt32, const AudioObjectPropertyAddress *) {
    d->render.fail(SQ_DEVICE_DISCONNECTED);
  });
  if (!p->route_queue || !p->listener) return fail(d, SQ_DEVICE_NO_MEMORY, 0);
  status = AudioObjectAddPropertyListenerBlock(p->device, &alive_address, p->route_queue, p->listener);
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  p->alive_listener = true;
  status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &default_address, p->route_queue, p->listener);
  if (status != noErr) return fail(d, SQ_DEVICE_OPEN_FAILED, status);
  p->default_listener = true;
  return SQ_DEVICE_OK;
}
sq_device_result platform_start(sq_device *d) {
  const auto status = AudioOutputUnitStart(static_cast<Apple *>(d->platform)->unit);
  return status == noErr ? SQ_DEVICE_OK : fail(d, SQ_DEVICE_START_FAILED, status);
}
sq_device_result platform_pause(sq_device *d) {
  const auto status = AudioOutputUnitStop(static_cast<Apple *>(d->platform)->unit);
  return status == noErr ? SQ_DEVICE_OK : fail(d, SQ_DEVICE_PAUSE_FAILED, status);
}
sq_device_result platform_close(sq_device *d) {
  auto *p = static_cast<Apple *>(d->platform);
  if (!p) return SQ_DEVICE_OK;
  OSStatus status;
  if (p->unit && p->initialized) {
    status = AudioOutputUnitStop(p->unit);
    if (status != noErr) return fail(d, SQ_DEVICE_CLOSE_FAILED, status);
    status = AudioUnitUninitialize(p->unit);
    if (status != noErr) return fail(d, SQ_DEVICE_CLOSE_FAILED, status);
    p->initialized = false;
  }
  if (p->alive_listener) {
    status = AudioObjectRemovePropertyListenerBlock(p->device, &alive_address, p->route_queue, p->listener);
    if (status != noErr) return fail(d, SQ_DEVICE_CLOSE_FAILED, status);
    p->alive_listener = false;
  }
  if (p->default_listener) {
    status = AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &default_address, p->route_queue, p->listener);
    if (status != noErr) return fail(d, SQ_DEVICE_CLOSE_FAILED, status);
    p->default_listener = false;
  }
  if (p->unit) {
    status = AudioComponentInstanceDispose(p->unit);
    if (status != noErr) return fail(d, SQ_DEVICE_CLOSE_FAILED, status);
    p->unit = nullptr;
  }
  // Listener removal prevents new notifications; drain already queued blocks
  // before releasing captured host state. Control calls never run on this queue.
  if (p->route_queue) dispatch_sync(p->route_queue, ^{});
  if (p->listener) Block_release(p->listener);
  if (p->route_queue) dispatch_release(p->route_queue);
  delete p; d->platform = nullptr;
  return SQ_DEVICE_OK;
}
}
