#include "alpha_video_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include "frame_source.h"
#include "pet_matte/pet_matte.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <map>
#include <memory>
#include <string>

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
  std::unique_ptr<FrameSource> source;
  std::unique_ptr<flutter::TextureVariant> texture;
  FlutterDesktopPixelBuffer buffer{};
  uint32_t currentFrame = 0;
  int64_t textureId = -1;
};

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
    clip->source = std::make_unique<FrameSource>();
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

    flutter::EncodableMap out{
        {flutter::EncodableValue("textureId"), flutter::EncodableValue(id)},
        {flutter::EncodableValue("width"), flutter::EncodableValue(
            static_cast<int32_t>(clip->source->width()))},
        {flutter::EncodableValue("height"), flutter::EncodableValue(
            static_cast<int32_t>(clip->source->height()))},
        {flutter::EncodableValue("frameCount"), flutter::EncodableValue(
            static_cast<int32_t>(clip->source->frameCount()))},
    };
    g_clips[id] = std::move(clip);
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (call.method_name() == "dispose") {
    const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
    const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
    auto it = g_clips.find(id);
    if (it != g_clips.end()) {
      // UnregisterTexture(id) alone (no callback) is fire-and-forget: the
      // engine's docs call it "asynchronous", meaning the render thread may
      // still be inside the PixelBufferTexture callback -- which holds a raw
      // Clip* -- when this call returns. Erasing g_clips[id] synchronously
      // right after would risk freeing the Clip out from under that
      // in-flight callback. Instead: take the Clip out of the map now (so a
      // future "open" can't collide with this id while teardown is
      // pending), but keep it alive via shared_ptr until the engine's
      // completion callback confirms it will not call back again.
      std::shared_ptr<Clip> clip = it->second;
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
