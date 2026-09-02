#pragma once
#include "matte_core/pixel.h"

namespace matte {

struct Rect { int x = 0, y = 0, w = 0, h = 0; };

// alpha > threshold 的像素的最小包围盒；全透明返回 {0,0,0,0}。
Rect AlphaBounds(BgraImage img, uint8_t threshold);

// 把 src 的 r 区域紧密打包（stride = r.w*4）拷到 dst。
void CopyRegion(BgraImage src, Rect r, uint8_t* dst);

}  // namespace matte
