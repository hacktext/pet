#pragma once
#include "matte_core/pixel.h"

namespace matte {

// 去溢色：G 超出 (R+B)/2 的部分按透明度压掉——完全透明的像素压到 (R+B)/2，
// 半透明的按 (1 - a/255) 比例压，完全不透明的不动（保护黄色毛发）。
// 需要 alpha 已由 ApplyChromaKey 写入 px[3]。
void ApplyDespill(BgraImage img);

// BGRA 直通 alpha → 预乘 alpha。
void PremultiplyAlpha(BgraImage img);

}  // namespace matte
