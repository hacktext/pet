#pragma once
#include <cstdio>
#include <filesystem>
#include <string>

// 跨平台的文件路径。Windows 上 std::filesystem::path 原生存 UTF-16，c_str()
// 是 wchar_t*，用 _wfopen 打开，非 ASCII 路径（例如用户名含中文的
// %APPDATA%）不经 ANSI 代码页转换；macOS 上原生就是 UTF-8 的 char*，直接
// fopen。调用方一律用 Path，不再自己区分 wstring / string。
namespace native_path {

using Path = std::filesystem::path;

inline FILE* Open(const Path& path, const char* mode) {
#ifdef _WIN32
  const std::wstring wmode(mode, mode + std::char_traits<char>::length(mode));
  // _wfopen_s, not _wfopen: the plugin builds with /WX and _wfopen is C4996.
  FILE* f = nullptr;
  return _wfopen_s(&f, path.c_str(), wmode.c_str()) == 0 ? f : nullptr;
#else
  return std::fopen(path.c_str(), mode);
#endif
}

// 删除文件；失败（包括文件不存在）静默忽略。
inline void Remove(const Path& path) {
  std::error_code ec;
  std::filesystem::remove(path, ec);
}

}  // namespace native_path
