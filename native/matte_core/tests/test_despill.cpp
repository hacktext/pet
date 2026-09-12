#include <gtest/gtest.h>
#include <vector>
#include "matte_core/despill.h"

TEST(Despill, TransparentGreenFringeIsPulledDownToNeighbourAverage) {
  // a = 0：与旧公式一致。B=40, G=200, R=60 → G 压到 (40+60)/2 = 50
  std::vector<uint8_t> px{40, 200, 60, 0};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 50);
  EXPECT_EQ(px[0], 40);  // B 不动
  EXPECT_EQ(px[2], 60);  // R 不动
  EXPECT_EQ(px[3], 0);   // alpha 不动
}

TEST(Despill, HalfTransparentFringeIsPulledDownByHalf) {
  // a = 128：超出量 150 只压掉 (150*127+127)/255 = 75 → G = 125
  std::vector<uint8_t> px{40, 200, 60, 128};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 125);
}

TEST(Despill, OpaqueYellowFurKeepsItsGreen) {
  // 金毛的黄色高光：G > (R+B)/2，但完全不透明，不能被压成橙色
  std::vector<uint8_t> px{120, 210, 240, 255};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 210);
}

TEST(Despill, NonGreenDominantPixelIsUnchanged) {
  std::vector<uint8_t> px{200, 100, 220, 0};  // G 不占优，即使完全透明
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 100);
}

TEST(Premultiply, HalfAlphaHalvesColour) {
  std::vector<uint8_t> px{200, 100, 50, 128};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::PremultiplyAlpha(img);
  EXPECT_EQ(px[0], 100);
  EXPECT_EQ(px[1], 50);
  EXPECT_EQ(px[2], 25);
  EXPECT_EQ(px[3], 128);
}

TEST(Premultiply, ZeroAlphaZeroesColour) {
  std::vector<uint8_t> px{200, 100, 50, 0};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::PremultiplyAlpha(img);
  EXPECT_EQ(px[0], 0);
  EXPECT_EQ(px[1], 0);
  EXPECT_EQ(px[2], 0);
}

TEST(Premultiply, FullAlphaKeepsColour) {
  std::vector<uint8_t> px{200, 100, 50, 255};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::PremultiplyAlpha(img);
  EXPECT_EQ(px[0], 200);
  EXPECT_EQ(px[1], 100);
  EXPECT_EQ(px[2], 50);
}
