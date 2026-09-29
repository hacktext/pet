#include <gtest/gtest.h>
#include <vector>
#include "matte_core/despill.h"

TEST(Despill, GreenSpillIsRemovedWhateverTheAlpha) {
  // B=40, G=200, R=60 → G 压到 max(R,B) = 60。键控的过渡带很陡，含绿幕的毛边常拿到
  // 很高甚至 255 的 alpha，所以去溢色不能按 alpha 打折（2026-09-13 真机 A6 的绿边）。
  for (uint8_t a : {uint8_t{0}, uint8_t{128}, uint8_t{255}}) {
    std::vector<uint8_t> px{40, 200, 60, a};
    matte::BgraImage img{px.data(), 1, 1, 4};
    matte::ApplyDespill(img);
    EXPECT_EQ(px[1], 60) << "alpha " << int(a);
    EXPECT_EQ(px[0], 40) << "alpha " << int(a);  // B 不动
    EXPECT_EQ(px[2], 60) << "alpha " << int(a);  // R 不动
    EXPECT_EQ(px[3], a) << "alpha " << int(a);   // alpha 不动
  }
}

TEST(Despill, GoldenFurEdgeKeepsItsColour) {
  // 金毛半透明的毛边：G > (R+B)/2 = 180，但 G < R，不是绿溢色，不能被压成橙色
  std::vector<uint8_t> px{120, 210, 240, 128};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 210);
}

TEST(Despill, OpaqueGoldenFurKeepsItsColour) {
  std::vector<uint8_t> px{120, 210, 240, 255};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 210);
}

TEST(Despill, BlueEyeKeepsItsGreen) {
  // 布偶猫偏青的蓝眼睛：G 高于 (R+B)/2 = 140，但低于 B，不是绿溢色
  std::vector<uint8_t> px{200, 150, 80, 255};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 150);
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
