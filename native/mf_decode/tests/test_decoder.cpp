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
