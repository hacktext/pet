#ifndef FLUTTER_PLUGIN_ALPHA_VIDEO_PLUGIN_H_
#define FLUTTER_PLUGIN_ALPHA_VIDEO_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace alpha_video {

class AlphaVideoPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  AlphaVideoPlugin();

  virtual ~AlphaVideoPlugin();

  // Disallow copy and assign.
  AlphaVideoPlugin(const AlphaVideoPlugin&) = delete;
  AlphaVideoPlugin& operator=(const AlphaVideoPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace alpha_video

#endif  // FLUTTER_PLUGIN_ALPHA_VIDEO_PLUGIN_H_
