#include "matte_core/despill.h"

namespace matte {

void ApplyDespill(BgraImage img) {
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      const int limit = (static_cast<int>(px[0]) + static_cast<int>(px[2])) / 2;
      const int excess = static_cast<int>(px[1]) - limit;
      if (excess <= 0) continue;
      // Only see-through pixels carry green spill; an opaque yellow coat
      // (G > (R+B)/2 by nature) must keep its green or it turns orange.
      const int seeThrough = 255 - static_cast<int>(px[3]);
      px[1] = static_cast<uint8_t>(px[1] - (excess * seeThrough + 127) / 255);
    }
  }
}

void PremultiplyAlpha(BgraImage img) {
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      const int a = px[3];
      px[0] = static_cast<uint8_t>(px[0] * a / 255);
      px[1] = static_cast<uint8_t>(px[1] * a / 255);
      px[2] = static_cast<uint8_t>(px[2] * a / 255);
    }
  }
}

}  // namespace matte
