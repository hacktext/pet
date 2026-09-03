#include <gtest/gtest.h>
#include <vector>
#include "matte_core/chroma_key.h"

namespace {
// BGRA 单像素图，便于逐色验证
std::vector<uint8_t> Px(uint8_t b, uint8_t g, uint8_t r) { return {b, g, r, 255}; }
uint8_t AlphaOf(std::vector<uint8_t> px) {
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyChromaKey(img, matte::KeyParams{});
  return px[3];
}
}  // namespace

TEST(ChromaKey, PureGreenBecomesFullyTransparent) {
  EXPECT_EQ(AlphaOf(Px(0, 255, 0)), 0);
}

TEST(ChromaKey, StudioGreenBecomesFullyTransparent) {
  // 0x00B140，竞品素材实际用的绿
  EXPECT_EQ(AlphaOf(Px(0x40, 0xB1, 0x00)), 0);
}

TEST(ChromaKey, WhiteStaysFullyOpaque) {
  EXPECT_EQ(AlphaOf(Px(255, 255, 255)), 255);
}

TEST(ChromaKey, BlackStaysFullyOpaque) {
  EXPECT_EQ(AlphaOf(Px(0, 0, 0)), 255);
}

TEST(ChromaKey, SkinToneStaysFullyOpaque) {
  EXPECT_EQ(AlphaOf(Px(180, 200, 235)), 255);
}

TEST(ChromaKey, NearGreenEdgeIsPartiallyTransparent) {
  const uint8_t a = AlphaOf(Px(130, 205, 130));
  EXPECT_GT(a, 0);
  EXPECT_LT(a, 255);
}

TEST(ChromaKey, RespectsStrideAndLeavesRgbUntouched) {
  // 2×1 图，stride 12（末尾 4 字节是 padding，不应被写）
  std::vector<uint8_t> buf(12, 0xAB);
  buf[0]=0; buf[1]=255; buf[2]=0; buf[3]=255;        // 绿
  buf[4]=255; buf[5]=255; buf[6]=255; buf[7]=255;    // 白
  matte::BgraImage img{buf.data(), 2, 1, 12};
  matte::ApplyChromaKey(img, matte::KeyParams{});
  EXPECT_EQ(buf[3], 0);      // 绿 → 透明
  EXPECT_EQ(buf[7], 255);    // 白 → 不透明
  EXPECT_EQ(buf[1], 255);    // RGB 未被改动
  EXPECT_EQ(buf[8], 0xAB);   // padding 未被写
}
