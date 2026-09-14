#pragma once
#include "matte_core/pixel.h"

namespace matte {

// 去溢色（最大值限制）：G = min(G, max(R, B))。绿色同时高于 R 和 B 才算溢色；
// 黄色毛发（G <= R）和偏青的蓝眼睛（G <= B）不受影响。不按 alpha 打折——键控过渡带很陡，
// 含绿幕的毛边常被判成完全不透明。alpha 不读也不改。
void ApplyDespill(BgraImage img);

// BGRA 直通 alpha → 预乘 alpha。
void PremultiplyAlpha(BgraImage img);

}  // namespace matte
