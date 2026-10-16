#import "AlphaVideoPlugin.h"

#import <Accelerate/Accelerate.h>
#import <CoreVideo/CoreVideo.h>

#include "frame_source/frame_source.h"
#include "pet_matte/pet_matte.h"
#include "prepare_queue/prepare_queue.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// macOS port of windows/alpha_video_plugin.cpp. The comments there explain the
// threading rules; only what differs on macOS is spelled out here.

namespace {

constexpr int64_t kFallbackFrameMicros = 41666;  // 24fps，仅在 durationTicks 为 0 时使用

prepare_queue::Outcome RunPetMattePrepare(const native_path::Path& src, const native_path::Path& dst,
                                          uint32_t edge) {
  const int32_t code = pet_matte_prepare(src.c_str(), dst.c_str(), edge);
  return prepare_queue::Outcome{code, code != 0 ? pet_matte_last_error() : ""};
}

FlutterError* BadArgs(NSString* message) {
  return [FlutterError errorWithCode:@"bad_args" message:message details:nil];
}

}  // namespace

// One clip: the texture the engine pulls frames from, plus its ticker thread.
// The engine retains the object while the texture is registered and for as
// long as the raster thread may still call copyPixelBuffer after
// unregisterTexture:, which is what the shared_ptr in TeardownClip does on
// Windows.
@interface AlphaVideoClip : NSObject <FlutterTexture>
- (instancetype)initWithSource:(std::unique_ptr<frame_source::FrameSource>)source;
- (frame_source::FrameSource*)source;
- (void)startTickerWithRegistry:(NSObject<FlutterTextureRegistry>*)registry textureId:(int64_t)textureId;
- (void)playLooping:(BOOL)loop;
- (void)pause;
- (uint32_t)currentFrame;
// Stops and joins the ticker; after it returns the ticker never marks the
// texture again, so the id may be unregistered.
- (void)stop;
@end

@implementation AlphaVideoClip {
  std::unique_ptr<frame_source::FrameSource> _source;
  std::atomic<uint32_t> _currentFrame;
  std::thread _ticker;
  std::mutex _mtx;
  std::condition_variable _cv;
  bool _playing;
  bool _loop;
  bool _stopping;
  CVPixelBufferPoolRef _pool;
  std::mutex _poolMtx;  // copyPixelBuffer runs on the raster thread, dealloc anywhere
}

- (instancetype)initWithSource:(std::unique_ptr<frame_source::FrameSource>)source {
  if ((self = [super init])) {
    _source = std::move(source);
    _currentFrame = 0;
    _playing = false;
    _loop = true;
    _stopping = false;
    _pool = nullptr;
  }
  return self;
}

- (void)dealloc {
  [self stop];
  if (_pool) CVPixelBufferPoolRelease(_pool);
}

- (frame_source::FrameSource*)source {
  return _source.get();
}

- (uint32_t)currentFrame {
  return _currentFrame.load();
}

// Same loop as StartTicker on Windows: advance the index, mark the texture,
// wait for the frame's recorded duration (interruptible by stop).
- (void)startTickerWithRegistry:(NSObject<FlutterTextureRegistry>*)registry textureId:(int64_t)textureId {
  frame_source::FrameSource* src = _source.get();
  std::atomic<uint32_t>* current = &_currentFrame;
  std::mutex* mtx = &_mtx;
  std::condition_variable* cv = &_cv;
  bool* playing = &_playing;
  bool* loop = &_loop;
  bool* stopping = &_stopping;
  // Raw pointers into self: the thread is joined in stop, which dealloc also
  // calls, so it never outlives these members.
  _ticker = std::thread([=]() {
    std::unique_lock<std::mutex> lk(*mtx);
    while (true) {
      cv->wait(lk, [=] { return *playing || *stopping; });
      if (*stopping) return;

      const uint32_t next = current->load() + 1;
      const bool atEnd = next >= src->frameCount();
      if (atEnd && !*loop) {
        *playing = false;
        continue;
      }
      current->store(atEnd ? 0 : next);
      const uint64_t ticks = src->frameDurationTicks(current->load());
      const int64_t us = ticks ? static_cast<int64_t>(ticks / 10) : kFallbackFrameMicros;
      lk.unlock();

      // Thread-safe on macOS: the engine forwards it to the raster thread.
      [registry textureFrameAvailable:textureId];

      lk.lock();
      cv->wait_for(lk, std::chrono::microseconds(us), [=] { return *stopping; });
    }
  });
}

- (void)playLooping:(BOOL)loop {
  {
    std::lock_guard<std::mutex> lk(_mtx);
    _loop = loop;
    _playing = true;
  }
  _cv.notify_all();
}

- (void)pause {
  std::lock_guard<std::mutex> lk(_mtx);
  _playing = false;
}

- (void)stop {
  {
    std::lock_guard<std::mutex> lk(_mtx);
    _stopping = true;
    _playing = false;
  }
  _cv.notify_all();
  if (_ticker.joinable() && _ticker.get_id() != std::this_thread::get_id()) _ticker.join();
}

// Raster thread. FrameRgba rewrites the source's internal buffers, so it is
// only ever called here (never from the ticker), exactly as on Windows.
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  std::lock_guard<std::mutex> lk(_poolMtx);
  const uint8_t* rgba = _source->FrameRgba(_currentFrame.load());
  if (!rgba) return nullptr;
  const size_t w = _source->width();
  const size_t h = _source->height();

  if (!_pool) {
    NSDictionary* attrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferWidthKey : @(w),
      (id)kCVPixelBufferHeightKey : @(h),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)attrs, &_pool) !=
        kCVReturnSuccess) {
      _pool = nullptr;
      return nullptr;
    }
  }
  CVPixelBufferRef buffer = nullptr;
  if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &buffer) != kCVReturnSuccess) return nullptr;
  if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
    CVPixelBufferRelease(buffer);
    return nullptr;
  }
  // The .aipmat pixels are premultiplied RGBA (pet_matte premultiplies);
  // the texture wants BGRA, so swap R and B and keep the premultiplication.
  vImage_Buffer from = {const_cast<uint8_t*>(rgba), h, w, w * 4};
  vImage_Buffer to = {CVPixelBufferGetBaseAddress(buffer), h, w, CVPixelBufferGetBytesPerRow(buffer)};
  const uint8_t map[4] = {2, 1, 0, 3};
  const vImage_Error err = vImagePermuteChannels_ARGB8888(&from, &to, map, kvImageNoFlags);
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  if (err != kvImageNoError) {
    CVPixelBufferRelease(buffer);
    return nullptr;
  }
  return buffer;  // +1; the engine releases it
}

@end

@implementation AlphaVideoPlugin {
  NSObject<FlutterTextureRegistry>* _textures;
  NSMutableDictionary<NSNumber*, AlphaVideoClip*>* _clips;
  std::unique_ptr<prepare_queue::PrepareQueue> _queue;
  // Cleared when the engine goes away: replies already posted to the main
  // queue are then dropped instead of run, like the PeekMessage loop that
  // deletes them on Windows.
  std::shared_ptr<std::atomic<bool>> _alive;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"aipet.alpha_video/methods"
                                                              binaryMessenger:[registrar messenger]];
  AlphaVideoPlugin* instance = [[AlphaVideoPlugin alloc] initWithTextures:[registrar textures]];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithTextures:(NSObject<FlutterTextureRegistry>*)textures {
  if ((self = [super init])) {
    _textures = textures;
    _clips = [NSMutableDictionary dictionary];
    _alive = std::make_shared<std::atomic<bool>>(true);
    std::shared_ptr<std::atomic<bool>> alive = _alive;
    _queue = std::make_unique<prepare_queue::PrepareQueue>(
        RunPetMattePrepare, [alive](prepare_queue::PrepareQueue::Task task) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (alive->load()) task();
          });
        });
  }
  return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [self teardown];
}

- (void)dealloc {
  [self teardown];
}

// Same order as ~AlphaVideoPlugin on Windows: the queue first (a running
// prepare finishes; nobody awaits the replies), then every clip, ticker
// before texture.
- (void)teardown {
  if (_alive) _alive->store(false);
  _queue.reset();
  for (NSNumber* key in _clips.allKeys) [self disposeClip:key.longLongValue];
}

- (void)disposeClip:(int64_t)textureId {
  AlphaVideoClip* clip = _clips[@(textureId)];
  if (!clip) return;
  [_clips removeObjectForKey:@(textureId)];
  [clip stop];
  [_textures unregisterTexture:textureId];
}

- (AlphaVideoClip*)clipFor:(NSDictionary*)args result:(FlutterResult)result {
  id raw = args[@"textureId"];
  if (![raw isKindOfClass:[NSNumber class]]) {
    result(BadArgs(@"textureId must be an int"));
    return nil;
  }
  AlphaVideoClip* clip = _clips[raw];
  if (!clip) result([FlutterError errorWithCode:@"no_clip" message:@"unknown textureId" details:nil]);
  return clip;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"abiVersion"]) {
    result(@(pet_matte_abi_version()));
    return;
  }
  if (![call.arguments isKindOfClass:[NSDictionary class]]) {
    result(BadArgs(@"missing arguments"));
    return;
  }
  NSDictionary* args = call.arguments;

  try {
    if ([call.method isEqualToString:@"open"]) {
      NSString* path = args[@"path"];
      if (![path isKindOfClass:[NSString class]]) {
        result(BadArgs(@"path must be a string"));
        return;
      }
      auto source = std::make_unique<frame_source::FrameSource>();
      if (!source->Load(native_path::Path(path.UTF8String))) {
        result([FlutterError errorWithCode:@"open_failed"
                                   message:[@"cannot read aipmat: " stringByAppendingString:path]
                                   details:nil]);
        return;
      }
      AlphaVideoClip* clip = [[AlphaVideoClip alloc] initWithSource:std::move(source)];
      const int64_t textureId = [_textures registerTexture:clip];
      [clip startTickerWithRegistry:_textures textureId:textureId];
      _clips[@(textureId)] = clip;
      result(@{
        @"textureId" : @(textureId),
        @"width" : @(static_cast<int32_t>(clip.source->width())),
        @"height" : @(static_cast<int32_t>(clip.source->height())),
        @"frameCount" : @(static_cast<int32_t>(clip.source->frameCount())),
      });
      return;
    }

    if ([call.method isEqualToString:@"play"]) {
      id loop = args[@"loop"];
      if (![loop isKindOfClass:[NSNumber class]]) {
        result(BadArgs(@"loop must be a bool"));
        return;
      }
      AlphaVideoClip* clip = [self clipFor:args result:result];
      if (!clip) return;
      [clip playLooping:[loop boolValue]];
      result(nil);
      return;
    }

    if ([call.method isEqualToString:@"pause"]) {
      AlphaVideoClip* clip = [self clipFor:args result:result];
      if (!clip) return;
      [clip pause];
      result(nil);
      return;
    }

    if ([call.method isEqualToString:@"currentFrame"]) {
      AlphaVideoClip* clip = [self clipFor:args result:result];
      if (!clip) return;
      result(@(static_cast<int32_t>(clip.currentFrame)));
      return;
    }

    if ([call.method isEqualToString:@"dispose"]) {
      id raw = args[@"textureId"];
      if (![raw isKindOfClass:[NSNumber class]]) {
        result(BadArgs(@"textureId must be an int"));
        return;
      }
      [self disposeClip:[raw longLongValue]];
      result(nil);
      return;
    }

    if ([call.method isEqualToString:@"prepare"]) {
      NSString* src = args[@"source"];
      NSString* dst = args[@"destination"];
      id edge = args[@"targetEdge"];
      if (![src isKindOfClass:[NSString class]] || ![dst isKindOfClass:[NSString class]] ||
          ![edge isKindOfClass:[NSNumber class]]) {
        result(BadArgs(@"source, destination and targetEdge are required"));
        return;
      }
      FlutterResult reply = [result copy];
      // Answered later on the main thread; failures arrive as
      // Error("prepare_failed", ...) carrying pet_matte_last_error().
      _queue->Submit(native_path::Path(src.UTF8String), native_path::Path(dst.UTF8String),
                     static_cast<uint32_t>([edge intValue]), [reply](const prepare_queue::Outcome& o) {
                       if (o.code != 0) {
                         reply([FlutterError errorWithCode:@"prepare_failed"
                                                   message:[NSString stringWithUTF8String:o.error.c_str()]
                                                   details:@(o.code)]);
                       } else {
                         reply(@(o.code));
                       }
                     });
      return;
    }

    result(FlutterMethodNotImplemented);
  } catch (const std::exception& e) {
    result(BadArgs([NSString stringWithUTF8String:e.what()]));
  }
}

@end
