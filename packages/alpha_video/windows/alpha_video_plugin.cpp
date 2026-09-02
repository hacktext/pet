#include "alpha_video_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include "frame_source/frame_source.h"
#include "pet_matte/pet_matte.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace alpha_video {

namespace {

// Dart 的字符串到达时是 UTF-8；Windows 路径原生是 UTF-16。
// 失败或输入非法时返回空串（调用方需区分「输入本来就是空」的情况）。
std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                    s.data(), static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L' ');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                          s.data(), static_cast<int>(s.size()), w.data(), n) != n) {
    return std::wstring();
  }
  return w;
}

struct Clip {
  std::unique_ptr<frame_source::FrameSource> source;
  std::unique_ptr<flutter::TextureVariant> texture;
  FlutterDesktopPixelBuffer buffer{};

  // currentFrame is written by the ticker thread and read by the
  // PixelBufferTexture callback on Flutter's render thread with no other
  // synchronization between the two, so it must be atomic (a plain
  // uint32_t here would be a data race / undefined behaviour the moment
  // the ticker thread exists). A relaxed load/store would be sufficient
  // since there is no other memory this variable needs to be ordered
  // against, but we use the atomic default (sequentially consistent) for
  // simplicity -- it is still just one atomic op per frame in each
  // direction, so the stricter ordering costs nothing observable here.
  std::atomic<uint32_t> currentFrame{0};
  int64_t textureId = -1;

  // Ticker thread + playback state. playing/loop/stopping are guarded by
  // mtx and observed by the ticker's condition_variable wait; currentFrame
  // itself does not need mtx (see above).
  std::thread ticker;
  std::mutex mtx;
  std::condition_variable cv;
  bool playing = false;
  bool loop = true;
  bool stopping = false;
  flutter::TextureRegistrar* registrar = nullptr;

  // Safety net for process/plugin teardown while a clip is still open: if
  // "dispose" was never called (app killed, engine torn down without the
  // Dart side cleaning up), g_clips's own static destruction would destroy
  // this Clip -- and with it a still-joinable std::thread, which makes
  // std::thread's destructor call std::terminate(). "dispose" already
  // does the correct stop-then-join-then-unregister sequence itself (see
  // below), so in that path this destructor finds the thread already
  // joined and does nothing; it only does real work on the teardown path
  // dispose() does not cover.
  ~Clip() {
    if (ticker.joinable()) {
      {
        std::lock_guard<std::mutex> lk(mtx);
        stopping = true;
        playing = false;
      }
      cv.notify_all();
      ticker.join();
    }
  }
};

constexpr int64_t kFallbackFrameMicros = 41666;  // 24fps，仅在 durationTicks 为 0 时使用

// 独立于 Flutter 引擎线程的推帧线程：按 FrameSource 索引里记录的每帧时长
// (durationTicks，100ns 单位) 睡眠，然后调用 MarkTextureFrameAvailable，
// 让引擎在下次合成时回调 PixelBufferTexture 去取新帧。这个线程只推进
// currentFrame 索引，绝不调用 FrameRgba —— FrameRgba 会改写 FrameSource
// 内部的 packed_/canvas_ 缓冲区，必须只在渲染线程的 PixelBufferTexture
// 回调里调用。
//
// 这里捕获裸指针 c 而不是 shared_ptr：这个线程完全由 Clip 自己拥有和
// join（dispose 里先 stop+join 再解注册纹理，~Clip 兜底），一旦 join()
// 返回，这个线程就已经退出、再也不会碰 Clip，所以捕获裸指针是安全的。
// 这和 PixelBufferTexture 回调捕获裸指针的情况不同：那是因为
// UnregisterTexture 是异步的，dispose 返回后引擎仍可能在调用那个回调，
// 所以那边要用 shared_ptr 续命；这里没有这个问题，因为线程的生命周期
// 完全由我们自己的 join() 调用同步控制，不依赖引擎的任何异步回调。
void StartTicker(Clip* c) {
  c->ticker = std::thread([c]() {
    while (true) {
      std::unique_lock<std::mutex> lk(c->mtx);
      c->cv.wait(lk, [c] { return c->playing || c->stopping; });
      if (c->stopping) return;

      const uint32_t next = c->currentFrame + 1;
      const bool atEnd = next >= c->source->frameCount();
      if (atEnd && !c->loop) {
        c->playing = false;
        continue;
      }
      c->currentFrame = atEnd ? 0 : next;
      const int64_t id = c->textureId;
      auto* reg = c->registrar;
      // 按刚推进到的这一帧索引项记录的时长睡眠；为 0（无记录/越界）时
      // 回退到 24fps。源素材标记为可变帧率，固定常量会相对记录的时间
      // 轴漂移。
      const uint64_t ticks = c->source->frameDurationTicks(c->currentFrame);
      const int64_t us = ticks ? static_cast<int64_t>(ticks / 10) : kFallbackFrameMicros;
      lk.unlock();

      reg->MarkTextureFrameAvailable(id);
      std::this_thread::sleep_for(std::chrono::microseconds(us));
    }
  });
}

// Keyed by texture id. Each Clip's PixelBufferTexture callback captures a
// raw `Clip*` (see "open" below); that pointer is only safe to dereference
// while the Clip is still alive. shared_ptr (not unique_ptr) so "dispose"
// can hand a copy to the engine's unregister-completion callback below and
// keep the Clip alive until the engine confirms it will not invoke the
// pixel-buffer callback again.
std::map<int64_t, std::shared_ptr<Clip>> g_clips;

}  // namespace

// static
void AlphaVideoPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "aipet.alpha_video/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<AlphaVideoPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

AlphaVideoPlugin::AlphaVideoPlugin(flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {}

AlphaVideoPlugin::~AlphaVideoPlugin() {}

void AlphaVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "abiVersion") {
    result->Success(flutter::EncodableValue(pet_matte_abi_version()));
    return;
  }

  if (call.method_name() == "open") {
    const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
    const auto path = std::get<std::string>(args.at(flutter::EncodableValue("path")));
    const std::wstring wpath = Utf8ToWide(path);
    if (wpath.empty() && !path.empty()) {
      result->Error("bad_path", "path is not valid UTF-8");
      return;
    }

    auto clip = std::make_unique<Clip>();
    clip->source = std::make_unique<frame_source::FrameSource>();
    if (!clip->source->Load(wpath)) {
      result->Error("open_failed", "cannot read aipmat: " + path);
      return;
    }

    Clip* raw = clip.get();
    clip->texture = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture(
            [raw](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
              const uint8_t* px = raw->source->FrameRgba(raw->currentFrame);
              if (!px) return nullptr;
              raw->buffer.buffer = px;
              raw->buffer.width = raw->source->width();
              raw->buffer.height = raw->source->height();
              return &raw->buffer;
            }));

    const int64_t id = registrar_->texture_registrar()->RegisterTexture(clip->texture.get());
    clip->textureId = id;
    clip->registrar = registrar_->texture_registrar();

    flutter::EncodableMap out{
        {flutter::EncodableValue("textureId"), flutter::EncodableValue(id)},
        {flutter::EncodableValue("width"), flutter::EncodableValue(
            static_cast<int32_t>(clip->source->width()))},
        {flutter::EncodableValue("height"), flutter::EncodableValue(
            static_cast<int32_t>(clip->source->height()))},
        {flutter::EncodableValue("frameCount"), flutter::EncodableValue(
            static_cast<int32_t>(clip->source->frameCount()))},
    };
    StartTicker(raw);
    g_clips[id] = std::move(clip);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (call.method_name() == "play") {
    const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
    const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
    const bool loop = std::get<bool>(args.at(flutter::EncodableValue("loop")));
    auto it = g_clips.find(id);
    if (it == g_clips.end()) {
      result->Error("no_clip", "unknown textureId");
      return;
    }
    {
      std::lock_guard<std::mutex> lk(it->second->mtx);
      it->second->loop = loop;
      it->second->playing = true;
    }
    it->second->cv.notify_all();
    result->Success();
    return;
  }

  if (call.method_name() == "pause") {
    const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
    const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
    auto it = g_clips.find(id);
    if (it == g_clips.end()) {
      result->Error("no_clip", "unknown textureId");
      return;
    }
    {
      std::lock_guard<std::mutex> lk(it->second->mtx);
      it->second->playing = false;
    }
    result->Success();
    return;
  }

  if (call.method_name() == "currentFrame") {
    const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
    const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
    auto it = g_clips.find(id);
    if (it == g_clips.end()) {
      result->Error("no_clip", "unknown textureId");
      return;
    }
    // Atomic load; no mtx needed (see the comment on Clip::currentFrame).
    result->Success(flutter::EncodableValue(
        static_cast<int32_t>(it->second->currentFrame.load())));
    return;
  }

  if (call.method_name() == "dispose") {
    const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
    const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
    auto it = g_clips.find(id);
    if (it != g_clips.end()) {
      std::shared_ptr<Clip> clip = it->second;

      // Stop and join the ticker thread FIRST, before anything else below.
      // Once join() returns, the ticker will never call
      // MarkTextureFrameAvailable(id) again, so it's now safe to unregister
      // that texture id. Doing this in the other order would let the
      // ticker race UnregisterTexture: it could mark a texture id "available"
      // that the engine is mid-unregistration for, or that has already been
      // handed to a brand-new Clip from a subsequent "open" reusing the id.
      {
        std::lock_guard<std::mutex> lk(clip->mtx);
        clip->stopping = true;
        clip->playing = false;
      }
      clip->cv.notify_all();
      if (clip->ticker.joinable()) clip->ticker.join();

      // UnregisterTexture(id) alone (no callback) is fire-and-forget: the
      // engine's docs call it "asynchronous", meaning the render thread may
      // still be inside the PixelBufferTexture callback -- which holds a raw
      // Clip* -- when this call returns. Erasing g_clips[id] synchronously
      // right after would risk freeing the Clip out from under that
      // in-flight callback. Instead: take the Clip out of the map now (so a
      // future "open" can't collide with this id while teardown is
      // pending), but keep it alive via shared_ptr until the engine's
      // completion callback confirms it will not call back again.
      g_clips.erase(it);
      registrar_->texture_registrar()->UnregisterTexture(
          id, [clip]() {
            // Intentionally empty: destroying the last reference to `clip`
            // here (as this lambda itself is destroyed) is the whole point.
          });
    }
    result->Success();
    return;
  }

  if (call.method_name() == "prepare") {
    const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
    const auto src = std::get<std::string>(args.at(flutter::EncodableValue("source")));
    const auto dst = std::get<std::string>(args.at(flutter::EncodableValue("destination")));
    const auto edge = std::get<int32_t>(args.at(flutter::EncodableValue("targetEdge")));
    // Dart 通过 MethodChannel 送来的是 UTF-8。绝不能用 wstring(s.begin(), s.end())
    // 逐字节拓宽——那会把每个 UTF-8 字节当成一个 wchar_t，非 ASCII 路径直接损坏。
    // 这正是 Task 7 修掉的那类缺陷，必须走真正的编码转换。
    const std::wstring wsrc = Utf8ToWide(src);
    const std::wstring wdst = Utf8ToWide(dst);
    if (wsrc.empty() != src.empty() || wdst.empty() != dst.empty()) {
      result->Error("bad_path", "path is not valid UTF-8");
      return;
    }
    result->Success(flutter::EncodableValue(
        pet_matte_prepare(wsrc.c_str(), wdst.c_str(), static_cast<uint32_t>(edge))));
    return;
  }

  result->NotImplemented();
}

}  // namespace alpha_video
