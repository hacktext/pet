#include "matte_core/chroma_key.h"
#include <algorithm>
#include <cmath>

namespace matte {

void ApplyChromaKey(BgraImage img, const KeyParams& p) {
  const float span = std::max(1e-6f, p.outerT - p.innerT);
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      const float b = px[0] / 255.0f, g = px[1] / 255.0f, r = px[2] / 255.0f;
      // BT.601 色度分量
      const float cb = -0.168736f * r - 0.331264f * g + 0.5f * b;
      const float cr =  0.5f * r - 0.418688f * g - 0.081312f * b;
      const float d = std::sqrt((cb - p.keyCb) * (cb - p.keyCb) +
                                (cr - p.keyCr) * (cr - p.keyCr));
      const float a = std::clamp((d - p.innerT) / span, 0.0f, 1.0f);
      px[3] = static_cast<uint8_t>(std::lround(a * 255.0f));
    }
  }
}

}  // namespace matte
