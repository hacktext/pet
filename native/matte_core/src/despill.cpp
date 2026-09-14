#include "matte_core/despill.h"

namespace matte {

void ApplyDespill(BgraImage img) {
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      // Max limiter: green above both R and B is spill. Yellow fur (G <= R)
      // and blue eyes (G <= B) keep their green. Not weighted by alpha: the
      // key ramp is steep, so spill-laden fringe often keys fully opaque.
      const uint8_t limit = px[0] > px[2] ? px[0] : px[2];
      if (px[1] > limit) px[1] = limit;
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
