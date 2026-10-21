#include <gtest/gtest.h>
#include <cstdint>
#include <vector>
#include "frame_source/hit_mask.h"

namespace {

// A w x h RGBA frame, transparent but for an opaque rectangle [x0, x1) x [y0, y1).
std::vector<uint8_t> FrameWithBox(uint32_t w, uint32_t h, uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1) {
  std::vector<uint8_t> f(static_cast<size_t>(w) * h * 4, 0);
  for (uint32_t y = y0; y < y1; ++y)
    for (uint32_t x = x0; x < x1; ++x) f[(static_cast<size_t>(y) * w + x) * 4 + 3] = 255;
  return f;
}

}  // namespace

TEST(HitMask, EmptyMaskIsNeverOpaque) {
  frame_source::HitMask m;
  EXPECT_TRUE(m.empty());
  EXPECT_FALSE(m.OpaqueAt(0.5, 0.5, 0.1));
}

TEST(HitMask, OpaqueOnThePetTransparentBesideIt) {
  // 100 x 100, the pet a column at x 40..60, y 10..90; sampled every 4th pixel.
  const auto f = FrameWithBox(100, 100, 40, 10, 60, 90);
  frame_source::HitMask m;
  m.Capture(f.data(), 100, 100, 4);
  EXPECT_EQ(m.width(), 25u);
  EXPECT_EQ(m.height(), 25u);
  EXPECT_TRUE(m.OpaqueAt(0.5, 0.5, 0));
  EXPECT_FALSE(m.OpaqueAt(0.1, 0.5, 0));   // left of the column
  EXPECT_FALSE(m.OpaqueAt(0.5, 0.97, 0));  // under its feet
}

TEST(HitMask, RadiusReachesTheEdgeFromJustOutside) {
  const auto f = FrameWithBox(100, 100, 40, 10, 60, 90);
  frame_source::HitMask m;
  m.Capture(f.data(), 100, 100, 4);
  // 0.35 is 5 px left of the column: missed bare, caught with an 8 px radius.
  EXPECT_FALSE(m.OpaqueAt(0.35, 0.5, 0));
  EXPECT_TRUE(m.OpaqueAt(0.35, 0.5, 0.08));
  EXPECT_FALSE(m.OpaqueAt(0.2, 0.5, 0.08));
}

TEST(HitMask, FaintFringeIsNotThePet) {
  std::vector<uint8_t> f(16 * 16 * 4, 0);
  for (size_t i = 3; i < f.size(); i += 4) f[i] = 20;  // a halo under the threshold
  frame_source::HitMask m;
  m.Capture(f.data(), 16, 16, 1);
  EXPECT_FALSE(m.OpaqueAt(0.5, 0.5, 0.5));
  EXPECT_TRUE(m.OpaqueAt(0.5, 0.5, 0, 10));
}

TEST(HitMask, OutsideTheFrameOrBadInputIsNotOpaque) {
  const auto f = FrameWithBox(8, 8, 0, 0, 8, 8);
  frame_source::HitMask m;
  m.Capture(f.data(), 8, 8, 2);
  EXPECT_TRUE(m.OpaqueAt(0, 0, 0));
  EXPECT_TRUE(m.OpaqueAt(1, 1, 0));
  EXPECT_FALSE(m.OpaqueAt(-0.1, 0.5, 0));
  EXPECT_FALSE(m.OpaqueAt(0.5, 1.2, 0));
  m.Capture(nullptr, 8, 8, 2);
  EXPECT_TRUE(m.empty());
}
