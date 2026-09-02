#include "alpha_video_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include "pet_matte/pet_matte.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace alpha_video {

// static
void AlphaVideoPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "aipet.alpha_video/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<AlphaVideoPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

AlphaVideoPlugin::AlphaVideoPlugin() {}

AlphaVideoPlugin::~AlphaVideoPlugin() {}

void AlphaVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "abiVersion") {
    result->Success(flutter::EncodableValue(pet_matte_abi_version()));
    return;
  }
  result->NotImplemented();
}

}  // namespace alpha_video
