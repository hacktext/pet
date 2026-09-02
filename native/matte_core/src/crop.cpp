#include "matte_core/crop.h"
#include <cstring>

namespace matte {

Rect AlphaBounds(BgraImage img, uint8_t threshold) {
  int minX = img.width, minY = img.height, maxX = -1, maxY = -1;
  for (int y = 0; y < img.height; ++y) {
    const uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      if (row[x * 4 + 3] > threshold) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return Rect{};
  return Rect{minX, minY, maxX - minX + 1, maxY - minY + 1};
}

void CopyRegion(BgraImage src, Rect r, uint8_t* dst) {
  const size_t rowBytes = static_cast<size_t>(r.w) * 4;
  for (int y = 0; y < r.h; ++y) {
    std::memcpy(dst + static_cast<size_t>(y) * rowBytes,
                src.row(r.y + y) + static_cast<size_t>(r.x) * 4, rowBytes);
  }
}

}  // namespace matte
