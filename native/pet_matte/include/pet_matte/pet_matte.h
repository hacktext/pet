#pragma once
#include <cstdint>

inline constexpr uint32_t kDefaultCacheEdge = 720;

extern "C" {

int32_t pet_matte_abi_version(void);

// 把绿幕 mp4 抠像并写成 .aipmat。targetEdge 为输出方形边长（0 表示保持源尺寸）。
// 返回 0 成功；-1 打不开源；-2 解码失败；-3 写入失败。
int32_t pet_matte_prepare(const wchar_t* srcMp4, const wchar_t* dstAipmat, uint32_t targetEdge);

const char* pet_matte_last_error(void);

}  // extern "C"
