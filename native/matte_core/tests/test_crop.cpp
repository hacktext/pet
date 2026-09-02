#include <gtest/gtest.h>
#include <vector>
#include "matte_core/crop.h"

namespace {
// 4×4 BGRA 全透明，指定像素设为不透明
std::vector<uint8_t> Canvas4x4(std::initializer_list<std::pair<int,int>> opaque) {
  std::vector<uint8_t> v(4 * 4 * 4, 0);
  for (auto [x, y] : opaque) {
    uint8_t* px = v.data() + (static_cast<size_t>(y) * 4 + x) * 4;
    px[0] = 10; px[1] = 20; px[2] = 30; px[3] = 255;
  }
  return v;
}
}  // namespace

TEST(AlphaBounds, SinglePixelGivesUnitRect) {
  auto v = Canvas4x4({{2, 1}});
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.x, 2); EXPECT_EQ(r.y, 1);
  EXPECT_EQ(r.w, 1); EXPECT_EQ(r.h, 1);
}

TEST(AlphaBounds, TwoCornersSpanTheBox) {
  auto v = Canvas4x4({{1, 1}, {3, 2}});
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.x, 1); EXPECT_EQ(r.y, 1);
  EXPECT_EQ(r.w, 3); EXPECT_EQ(r.h, 2);
}

TEST(AlphaBounds, FullyTransparentGivesEmptyRect) {
  auto v = Canvas4x4({});
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.w, 0); EXPECT_EQ(r.h, 0);
}

TEST(AlphaBounds, ThresholdExcludesFaintPixels) {
  auto v = Canvas4x4({{0, 0}});
  v[3] = 5;  // alpha 5，低于阈值 8
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.w, 0);
}

TEST(CopyRegion, ExtractsTightlyPackedPixels) {
  auto v = Canvas4x4({{1, 1}, {2, 1}});
  matte::BgraImage img{v.data(), 4, 4, 16};
  matte::Rect r{1, 1, 2, 1};
  std::vector<uint8_t> out(2 * 1 * 4, 0xEE);
  matte::CopyRegion(img, r, out.data());
  EXPECT_EQ(out[0], 10);  EXPECT_EQ(out[3], 255);
  EXPECT_EQ(out[4], 10);  EXPECT_EQ(out[7], 255);
}
