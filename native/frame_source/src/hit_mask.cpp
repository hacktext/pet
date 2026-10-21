#include "frame_source/hit_mask.h"

#include <algorithm>
#include <cmath>

namespace frame_source {

void HitMask::Capture(const uint8_t* rgba, uint32_t w, uint32_t h, uint32_t step) {
  if (!rgba || w == 0 || h == 0 || step == 0) {
    alpha_.clear();
    w_ = h_ = 0;
    return;
  }
  w_ = (w + step - 1) / step;
  h_ = (h + step - 1) / step;
  alpha_.resize(static_cast<size_t>(w_) * h_);
  const size_t stride = static_cast<size_t>(w) * 4;
  for (uint32_t my = 0; my < h_; ++my) {
    const uint8_t* row = rgba + static_cast<size_t>(my) * step * stride;
    uint8_t* out = alpha_.data() + static_cast<size_t>(my) * w_;
    for (uint32_t mx = 0; mx < w_; ++mx) out[mx] = row[static_cast<size_t>(mx) * step * 4 + 3];
  }
}

bool HitMask::OpaqueAt(double u, double v, double radius, uint8_t threshold) const {
  if (alpha_.empty() || !(u >= 0 && u <= 1 && v >= 0 && v <= 1)) return false;
  // u == 1 is the right edge, inside the last cell rather than past it.
  const double cx = std::min(u * w_, w_ - 1e-6);
  const double cy = std::min(v * h_, h_ - 1e-6);
  const double r = std::max(0.0, radius) * w_;
  const int x0 = std::max(0, static_cast<int>(std::floor(cx - r)));
  const int x1 = std::min(static_cast<int>(w_) - 1, static_cast<int>(std::floor(cx + r)));
  const int y0 = std::max(0, static_cast<int>(std::floor(cy - r)));
  const int y1 = std::min(static_cast<int>(h_) - 1, static_cast<int>(std::floor(cy + r)));
  for (int y = y0; y <= y1; ++y) {
    const uint8_t* row = alpha_.data() + static_cast<size_t>(y) * w_;
    for (int x = x0; x <= x1; ++x) {
      if (row[x] < threshold) continue;
      const double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
      // The cell the point is in always counts, however small the radius.
      if (dx * dx + dy * dy <= r * r + 0.5) return true;
    }
  }
  return false;
}

}  // namespace frame_source
