#ifndef FLUTTER_PLUGIN_ALPHA_VIDEO_PLUGIN_H_
#define FLUTTER_PLUGIN_ALPHA_VIDEO_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <cstdint>
#include <map>
#include <memory>

namespace alpha_video {

// Defined in alpha_video_plugin.cpp. Opaque here: the header only needs to
// name the type to declare clips_ below (std::shared_ptr<Clip> is a
// complete type regardless of Clip's own completeness, so this compiles
// without pulling frame_source/pet_matte or <thread>/<mutex> into every
// translation unit that includes this header).
struct Clip;

class AlphaVideoPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  // |registrar| is owned by the Flutter engine and outlives this plugin
  // (the plugin is itself owned by the registrar via AddPlugin). Kept so
  // HandleMethodCall can reach registrar_->texture_registrar() for "open"
  // and "dispose".
  explicit AlphaVideoPlugin(flutter::PluginRegistrarWindows *registrar);

  // Tears down every clip this plugin (== this engine) still owns: stops
  // and joins its ticker thread, then asks the engine to unregister its
  // texture -- the same sequence "dispose" runs, for anything the Dart side
  // never disposed itself (process killed, engine torn down, hot restart).
  // This runs on the platform thread while the engine, its
  // TextureRegistrar and every other thread are still alive, which is
  // exactly the property a namespace-scope static holding the clips could
  // never have (see C-2 in the final review).
  virtual ~AlphaVideoPlugin();

  // Disallow copy and assign.
  AlphaVideoPlugin(const AlphaVideoPlugin&) = delete;
  AlphaVideoPlugin& operator=(const AlphaVideoPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  // Stops and joins clip's ticker thread, then hands its texture id to the
  // engine's UnregisterTexture, keeping the Clip alive (via the shared_ptr
  // captured in the completion callback) until the engine confirms it will
  // not invoke the pixel-buffer callback again. Caller must already have
  // removed clip's entry from clips_ (see the "dispose" handler and
  // ~AlphaVideoPlugin for the two call sites).
  void TeardownClip(int64_t id, std::shared_ptr<Clip> clip);

  flutter::PluginRegistrarWindows *registrar_;

  // Owns every open Clip for this plugin instance, i.e. this engine. Scoped
  // to the plugin rather than a DLL-lifetime namespace static so that (a)
  // two engines (two AlphaVideoPlugin instances -- multi-window HUD/bubble
  // is spec'd to need this) each get their own texture-id space instead of
  // colliding in one shared map, and (b) ~AlphaVideoPlugin can tear every
  // clip down while this engine's threads, registrar and channel are all
  // still alive, instead of relying on DLL_PROCESS_DETACH ordering that a
  // static's destructor cannot control. See C-2 in the final review.
  std::map<int64_t, std::shared_ptr<Clip>> clips_;
};

}  // namespace alpha_video

#endif  // FLUTTER_PLUGIN_ALPHA_VIDEO_PLUGIN_H_
