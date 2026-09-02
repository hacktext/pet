#include <gtest/gtest.h>
#include <vector>
#include "matte_core/despill.h"

TEST(Despill, GreenFringeIsPulledDownToNeighbourAverage) {
  // B=40, G=200, R=60 → G 应被压到 (40+60)/2 = 50
  std::vector<uint8_t> px{40, 200, 60, 255};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 50);
  EXPECT_EQ(px[0], 40);   // B 不动
  EXPECT_EQ(px[2], 60);   // R 不动
  EXPECT_EQ(px[3], 255);  // alpha 不动
}

TEST(Despill, NonGreenDominantPixelIsUnchanged) {
  std::vector<uint8_t> px{200, 100, 220, 255};  // G 不占优
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
