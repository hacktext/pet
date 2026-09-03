#pragma once
#include "matte_core/pixel.h"

namespace matte {

// 键控在归一化 Cb/Cr 平面做：色度距离越接近键色，alpha 越低。
struct KeyParams {
  float keyCb = -0.331f;  // 纯绿 (0,255,0) 的 Cb
  float keyCr = -0.419f;  // 纯绿 (0,255,0) 的 Cr
  float innerT = 0.28f;   // 距离 <= innerT → alpha 0
  float outerT = 0.45f;   // 距离 >= outerT → alpha 255
};

void ApplyChromaKey(BgraImage img, const KeyParams& p);

}  // namespace matte
