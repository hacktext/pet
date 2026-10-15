#include "alpha_video_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include "frame_source/frame_source.h"
#include "pet_matte/pet_matte.h"
#include "prepare_queue/prepare_queue.h"

#include <objbase.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <exception>
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

}  // namespace

// Defined here (not in the anonymous namespace above) because
// alpha_video_plugin.h forward-declares it as a member type of
// AlphaVideoPlugin::clips_.
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

  // Belt-and-braces guard, NOT the teardown path. Every Clip is now owned
  // by AlphaVideoPlugin::clips_, and both the "dispose" handler and
  // ~AlphaVideoPlugin() (see alpha_video_plugin.cpp's TeardownClip) already
  // stop and join the ticker before the last shared_ptr<Clip> is dropped --
  // on the platform thread, with the registrar still valid. So in the
  // normal path this destructor finds the thread already joined and does
  // nothing. It exists only so that no future code path that drops a
  // Clip without going through TeardownClip can leave a still-joinable
  // std::thread here, which would make std::thread's own destructor call
  // std::terminate(). It is deliberately not relied on for real teardown:
  // a namespace/DLL-scope static's destructor runs during
  // DLL_PROCESS_DETACH, after ExitProcess has already torn down every
  // other thread, so a join() there can deadlock on a mutex the ticker
  // died holding -- which is precisely why clips_ was moved onto the
  // plugin instead (C-2 in the final review).
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

namespace {

constexpr int64_t kFallbackFrameMicros = 41666;  // 24fps，仅在 durationTicks 为 0 时使用

// 独立于 Flutter 引擎线程的推帧线程：按 FrameSource 索引里记录的每帧时长
// (durationTicks，100ns 单位) 等待，然后调用 MarkTextureFrameAvailable，
// 让引擎在下次合成时回调 PixelBufferTexture 去取新帧。这个线程只推进
// currentFrame 索引，绝不调用 FrameRgba —— FrameRgba 会改写 FrameSource
// 内部的 packed_/canvas_ 缓冲区，必须只在渲染线程的 PixelBufferTexture
// 回调里调用。
//
// 帧间等待用的是带谓词的 cv.wait_for，而不是 sleep_for：sleep_for 不可
// 被 notify_all() 打断，如果这里用它，dispose()/~Clip() 设置 stopping 后
// 仍要睡完当前这一帧剩下的全部时长，ticker.join() 才会返回——而源素材是
// 可变帧率，一帧的记录时长可以远大于 24fps 的约 42ms，届时会在 dispose
// 期间冻结分发方法调用的 Flutter 平台线程整段时间。wait_for 一收到
// notify 就会重新检查谓词并立刻醒来，把这段阻塞收窄到接近于零。
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
    std::unique_lock<std::mutex> lk(c->mtx);
    while (true) {
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
      // 按刚推进到的这一帧索引项记录的时长等待；为 0（无记录/越界）时
      // 回退到 24fps。源素材标记为可变帧率，固定常量会相对记录的时间
      // 轴漂移。
      const uint64_t ticks = c->source->frameDurationTicks(c->currentFrame);
      const int64_t us = ticks ? static_cast<int64_t>(ticks / 10) : kFallbackFrameMicros;
      lk.unlock();

      reg->MarkTextureFrameAvailable(id);

      // 重新加锁后再等待：MarkTextureFrameAvailable 必须在锁外调用（保持
      // 不变量不变），但 wait_for 需要持锁进入。stopping 变 true 后
      // notify_all() 会让这里立刻醒来重新检查谓词并返回，而不必等满
      // us 微秒。
      lk.lock();
      c->cv.wait_for(lk, std::chrono::microseconds(us), [c] { return c->stopping; });
    }
  });
}

constexpr UINT kRunOnPlatformThread = WM_APP + 0x51;
constexpr wchar_t kMessageWindowClass[] = L"AipetAlphaVideoPlatformThread";

// Runs on the platform thread: the window is created there.
LRESULT CALLBACK PlatformThreadProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kRunOnPlatformThread) {
    std::unique_ptr<prepare_queue::PrepareQueue::Task> task(
        reinterpret_cast<prepare_queue::PrepareQueue::Task*>(lp));
    (*task)();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

HWND CreatePlatformThreadWindow() {
  static const bool registered = [] {
    WNDCLASSW wc{};
    wc.lpfnWndProc = PlatformThreadProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kMessageWindowClass;
    return RegisterClassW(&wc) != 0;
  }();
  (void)registered;  // a second engine reuses the class; CreateWindowExW reports real failures
  return CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                         GetModuleHandleW(nullptr), nullptr);
}

// Worker thread. Media Foundation gets a COM apartment of its own here; on
// the platform thread (blocking fallback) CoInitializeEx fails with
// RPC_E_CHANGED_MODE and nothing is uninitialized.
prepare_queue::Outcome RunPetMattePrepare(const native_path::Path& src, const native_path::Path& dst,
                                          uint32_t edge) {
  const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const int32_t code = pet_matte_prepare(src.c_str(), dst.c_str(), edge);
  prepare_queue::Outcome out{code, code != 0 ? pet_matte_last_error() : ""};
  if (SUCCEEDED(hr)) CoUninitialize();
  return out;
}

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
    : registrar_(registrar), message_window_(CreatePlatformThreadWindow()) {
  if (!message_window_) return;
  HWND hwnd = message_window_;
  prepare_queue_ = std::make_unique<prepare_queue::PrepareQueue>(
      RunPetMattePrepare, [hwnd](prepare_queue::PrepareQueue::Task task) {
        auto* boxed = new prepare_queue::PrepareQueue::Task(std::move(task));
        if (!PostMessageW(hwnd, kRunOnPlatformThread, 0, reinterpret_cast<LPARAM>(boxed))) delete boxed;
      });
}

AlphaVideoPlugin::~AlphaVideoPlugin() {
  // Stop the queue first: it joins the worker (a running prepare finishes)
  // and posts cancellations for jobs that never started. This engine is going
  // away and nobody awaits those replies, so drop every posted task without
  // running it, then destroy the window.
  prepare_queue_.reset();
  if (message_window_) {
    MSG msg;
    while (PeekMessageW(&msg, message_window_, kRunOnPlatformThread, kRunOnPlatformThread, PM_REMOVE)) {
      delete reinterpret_cast<prepare_queue::PrepareQueue::Task*>(msg.lParam);
    }
    DestroyWindow(message_window_);
    message_window_ = nullptr;
  }
  // Tear down anything the Dart side never disposed. Safe to do here and
  // nowhere else: this runs on the platform thread (engine destruction is
  // synchronous from the caller that drops the FlutterViewController), with
  // registrar_ and every clip's ticker thread still alive -- unlike a
  // namespace-scope static's destructor, which would run during
  // DLL_PROCESS_DETACH after ExitProcess has already killed those threads.
  while (!clips_.empty()) {
    auto it = clips_.begin();
    const int64_t id = it->first;
    std::shared_ptr<Clip> clip = std::move(it->second);
    clips_.erase(it);
    TeardownClip(id, std::move(clip));
  }
}

void AlphaVideoPlugin::TeardownClip(int64_t id, std::shared_ptr<Clip> clip) {
  // Stop and join the ticker thread FIRST, before anything else below. Once
  // join() returns, the ticker will never call MarkTextureFrameAvailable(id)
  // again, so it's now safe to unregister that texture id. Doing this in
  // the other order would let the ticker race UnregisterTexture: it could
  // mark a texture id "available" that the engine is mid-unregistration
  // for, or that has already been handed to a brand-new Clip from a
  // subsequent "open" reusing the id.
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
  // Clip* -- when this call returns. The caller already removed clip from
  // clips_ before calling here (so a future "open" can't collide with this
  // id while teardown is pending); keep it alive via shared_ptr until the
  // engine's completion callback confirms it will not call back again.
  registrar_->texture_registrar()->UnregisterTexture(
      id, [clip]() {
        // Intentionally empty: destroying the last reference to `clip`
        // here (as this lambda itself is destroyed) is the whole point.
      });
}

void AlphaVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "abiVersion") {
    result->Success(flutter::EncodableValue(pet_matte_abi_version()));
    return;
  }

  // Every other method takes an EncodableMap of arguments. call.arguments()
  // is a raw pointer that is null when Dart invokes the method with no
  // argument at all (e.g. channel.invokeMethod('play')) -- std::get on
  // *call.arguments() in that case is a null dereference, not a throw.
  if (!call.arguments()) {
    result->Error("bad_args", "missing arguments");
    return;
  }

  // std::get throws bad_variant_access on a type mismatch, args.at() throws
  // out_of_range on a missing key, and Load()/Reader::Open() can throw
  // bad_alloc. Any of those unwinding out of HandleMethodCall would cross
  // the engine's C callback boundary and terminate the process silently, so
  // every branch below runs under one catch-all guard.
  try {
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
      clips_[id] = std::move(clip);
      result->Success(flutter::EncodableValue(out));
      return;
    }

    if (call.method_name() == "play") {
      const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
      const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
      const bool loop = std::get<bool>(args.at(flutter::EncodableValue("loop")));
      auto it = clips_.find(id);
      if (it == clips_.end()) {
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
      auto it = clips_.find(id);
      if (it == clips_.end()) {
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
      auto it = clips_.find(id);
      if (it == clips_.end()) {
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
      auto it = clips_.find(id);
      if (it != clips_.end()) {
        std::shared_ptr<Clip> clip = std::move(it->second);
        // Take the Clip out of the map now (so a future "open" can't
        // collide with this id while teardown is pending); TeardownClip
        // keeps it alive via shared_ptr for as long as the engine needs.
        clips_.erase(it);
        TeardownClip(id, std::move(clip));
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
      if (!prepare_queue_) {  // no message window: keep the old blocking path
        const prepare_queue::Outcome o = RunPetMattePrepare(wsrc, wdst, static_cast<uint32_t>(edge));
        if (o.code != 0) {
          result->Error("prepare_failed", o.error, flutter::EncodableValue(o.code));
        } else {
          result->Success(flutter::EncodableValue(o.code));
        }
        return;
      }
      // Answered later on the platform thread (PlatformThreadProc runs the
      // posted Done). Failures still arrive as Error("prepare_failed", ...)
      // carrying pet_matte_last_error(), as before.
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> pending(std::move(result));
      prepare_queue_->Submit(wsrc, wdst, static_cast<uint32_t>(edge),
                             [pending](const prepare_queue::Outcome& o) {
                               if (o.code != 0) {
                                 pending->Error("prepare_failed", o.error, flutter::EncodableValue(o.code));
                               } else {
                                 pending->Success(flutter::EncodableValue(o.code));
                               }
                             });
      return;
    }

    result->NotImplemented();
  } catch (const std::exception& e) {
    if (result) result->Error("bad_args", e.what());
  }
}

}  // namespace alpha_video
