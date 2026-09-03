#pragma once
#include "matte_core/pixel.h"

namespace matte {

// 绿占优的像素把 G 压到 (R+B)/2，消除毛发边缘的绿边。
void ApplyDespill(BgraImage img);

// BGRA 直通 alpha → 预乘 alpha。
void PremultiplyAlpha(BgraImage img);

}  // namespace matte
