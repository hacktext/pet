#include "include/alpha_video/alpha_video_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "alpha_video_plugin.h"

void AlphaVideoPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  alpha_video::AlphaVideoPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
