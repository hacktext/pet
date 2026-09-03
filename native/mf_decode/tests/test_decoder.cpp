#include <gtest/gtest.h>
#include <filesystem>
#include "mf_decode/decoder.h"

namespace {
std::wstring FixturePath() {
  return (std::filesystem::path(AIPET_TESTDATA_DIR) / "green_box.mp4").wstring();
}
}  // namespace

TEST(Decoder, ReportsDimensionsOfFixture) {
  auto d = mfd::Decoder::Open(FixturePath());
  ASSERT_TRUE(d.has_value()) << "先跑 native/testdata/make_fixtures.ps1 生成夹具";
  EXPECT_EQ(d->info().width, 320u);
  EXPECT_EQ(d->info().height, 320u);
}

TEST(Decoder, DecodesTwentyFourFrames) {
  auto d = mfd::Decoder::Open(FixturePath());
  ASSERT_TRUE(d.has_value());
  std::vector<uint8_t> bgra;
  uint64_t pts = 0, dur = 0;
  int n = 0;
  while (d->NextFrame(bgra, pts, dur)) {
    EXPECT_EQ(bgra.size(), 320u * 320u * 4u);
    ++n;
  }
  EXPECT_EQ(n, 24);
}

TEST(Decoder, FirstFrameCornerIsPureGreen) {
  auto d = mfd::Decoder::Open(FixturePath());
  ASSERT_TRUE(d.has_value());
  std::vector<uint8_t> bgra;
  uint64_t pts = 0, dur = 0;
  ASSERT_TRUE(d->NextFrame(bgra, pts, dur));
  // 左上角是背景纯绿。yuv420p 往返后实测为 (B,G,R) = (0,254,0)，给 10 的容差。
  EXPECT_NEAR(bgra[0], 0, 10);
  EXPECT_NEAR(bgra[1], 255, 10);
  EXPECT_NEAR(bgra[2], 0, 10);
  EXPECT_EQ(bgra[3], 255);
}

TEST(Decoder, DecodesFrameRightSideUp) {
  auto d = mfd::Decoder::Open(FixturePath());
  ASSERT_TRUE(d.has_value());
  std::vector<uint8_t> bgra;
  uint64_t pts = 0, dur = 0;
  ASSERT_TRUE(d->NextFrame(bgra, pts, dur));

  const uint32_t width = d->info().width;
  const uint32_t height = d->info().height;
  int minRow = -1, maxRow = -1;
  for (uint32_t y = 0; y < height; ++y) {
    for (uint32_t x = 0; x < width; ++x) {
      const size_t i = (static_cast<size_t>(y) * width + x) * 4;
      // 近白：B/G/R 都足够高
      if (bgra[i] > 200 && bgra[i + 1] > 200 && bgra[i + 2] > 200) {
        if (minRow < 0) minRow = static_cast<int>(y);
        maxRow = static_cast<int>(y);
      }
    }
  }
  ASSERT_GE(minRow, 0) << "第 0 帧里没找到白色方块";
  // 夹具里白块固定在第 40~139 行（第 0 帧只有 x 会变化），给 6 的容差
  // 兼顾 yuv420p 往返造成的边缘混色。
  EXPECT_NEAR(minRow, 40, 6);
  EXPECT_NEAR(maxRow, 139, 6);
  // 若解码结果上下颠倒，方块会落在第 180~279 行；显式断言排除这个区间，
  // 这样颠倒时测试会明确失败，而不是恰好碰运气通过。
  EXPECT_LT(maxRow, 180);
}

TEST(Decoder, PtsIncreasesMonotonically) {
  auto d = mfd::Decoder::Open(FixturePath());
  ASSERT_TRUE(d.has_value());
  std::vector<uint8_t> bgra;
  uint64_t pts = 0, dur = 0, prev = 0;
  ASSERT_TRUE(d->NextFrame(bgra, prev, dur));
  while (d->NextFrame(bgra, pts, dur)) {
    EXPECT_GT(pts, prev);
    prev = pts;
  }
}

TEST(Decoder, OpenFailsOnMissingFile) {
  EXPECT_FALSE(mfd::Decoder::Open(L"C:\\definitely\\not\\here.mp4").has_value());
}

TEST(Decoder, HadErrorStaysFalseAfterCleanFullDecode) {
  // 钉住干净路径的契约：NextFrame 对干净的流结束和中途解码失败都返回
  // false，hadError() 是调用方区分二者的唯一手段。一次完整、无故障的
  // 解码结束后 hadError() 必须仍是 false——否则调用方会把每一次正常
  // 结束都误判成失败。在这套夹具上真实模拟一次中途解码失败不现实，
  // 所以这里只钉住反面：干净路径不应该误置位。
  auto d = mfd::Decoder::Open(FixturePath());
  ASSERT_TRUE(d.has_value());
  EXPECT_FALSE(d->hadError());

  std::vector<uint8_t> bgra;
  uint64_t pts = 0, dur = 0;
  int n = 0;
  while (d->NextFrame(bgra, pts, dur)) ++n;

  EXPECT_EQ(n, 24);
  EXPECT_FALSE(d->hadError());
}
