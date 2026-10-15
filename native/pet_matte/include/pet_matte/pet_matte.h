#pragma once
#include <cstdint>

inline constexpr uint32_t kDefaultCacheEdge = 720;

// targetEdge 的合法上限：kMaxCacheEdge 必须大于 kDefaultCacheEdge（这条关系
// 由 pet_matte.cpp 里的 static_assert 强制），使上限始终以默认值的量级为
// 基准，而不是一个孤立的魔法数字。4096 同时也落在主流 GPU 纹理边长上限的
// 量级上，宽裕覆盖任何真实使用场景，又足够小，挡得住 targetEdge 转型失控
// 的极端值（例如 Dart 侧传入负数，被 static_cast<uint32_t> 之后回绕出的
// 42 亿）。
inline constexpr uint32_t kMaxCacheEdge = 4096;

// 路径的字符类型：Windows 是 UTF-16 的 wchar_t，macOS 是 UTF-8 的 char，
// 和 std::filesystem::path::value_type 一致。
#ifdef _WIN32
typedef wchar_t pet_matte_char;
#else
typedef char pet_matte_char;
#endif

extern "C" {

int32_t pet_matte_abi_version(void);

// 把绿幕 mp4 抠像并写成 .aipmat。targetEdge 为输出方形边长；0 表示使用
// kDefaultCacheEdge。合法范围是 [0, kMaxCacheEdge]，越界会被拒绝而不是
// 静默截断——越界值一路传到写盘的 crop 矩形字段会导致记录的裁剪框和实际
// 载荷对不上。
// 返回 0 成功；-1 打不开源；-2 targetEdge 越界或解码失败；-3 写入失败。
int32_t pet_matte_prepare(const pet_matte_char* srcMp4, const pet_matte_char* dstAipmat, uint32_t targetEdge);

const char* pet_matte_last_error(void);

}  // extern "C"
