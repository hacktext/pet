#include <gtest/gtest.h>
#include <filesystem>
#include "pet_matte/pet_matte.h"
#include "pcmat/reader.h"

namespace {
std::wstring Fixture() {
  return (std::filesystem::path(AIPET_TESTDATA_DIR) / "green_box.mp4").wstring();
}
std::wstring OutPath() {
  return (std::filesystem::temp_directory_path() / "pipeline_out.aipmat").wstring();
}
}  // namespace

TEST(Pipeline, AbiVersionIsOne) {
  EXPECT_EQ(pet_matte_abi_version(), 1);
}

TEST(Pipeline, ProducesReadableAipmatWithAllFrames) {
  const auto out = OutPath();
  ASSERT_EQ(pet_matte_prepare(Fixture().c_str(), out.c_str(), 320), 0)
      << pet_matte_last_error();

  auto r = pcmat::Reader::Open(out);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->header().frameCount, 24u);
  EXPECT_EQ(r->header().width, 320u);
  EXPECT_FALSE(r->manifest().empty());
  std::filesystem::remove(out);
}

TEST(Pipeline, BackgroundIsKeyedOutAndBoxSurvives) {
  const auto out = OutPath();
  ASSERT_EQ(pet_matte_prepare(Fixture().c_str(), out.c_str(), 320), 0);
  auto r = pcmat::Reader::Open(out);
  ASSERT_TRUE(r.has_value());

  // 白方块 100x100，绿背景应被完全键掉 → 包围盒应接近 100x100
  const auto& fi = r->index(0);
  EXPECT_GT(fi.cropW, 80);
  EXPECT_LT(fi.cropW, 130);
  EXPECT_GT(fi.cropH, 80);
  EXPECT_LT(fi.cropH, 130);

  // 裁剪区中心像素应是不透明的白
  std::vector<uint8_t> frame;
  ASSERT_TRUE(r->ReadFrame(0, frame));
  const size_t cx = fi.cropW / 2, cy = fi.cropH / 2;
  const uint8_t* px = frame.data() + (cy * fi.cropW + cx) * 4;
  EXPECT_EQ(px[3], 255);
  EXPECT_GT(px[0], 200);
  std::filesystem::remove(out);
}

TEST(Pipeline, DownscalesToTargetEdge) {
  const auto out = OutPath();
  ASSERT_EQ(pet_matte_prepare(Fixture().c_str(), out.c_str(), 160), 0);
  auto r = pcmat::Reader::Open(out);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->header().width, 160u);
  EXPECT_EQ(r->header().height, 160u);
  std::filesystem::remove(out);
}

TEST(Pipeline, FailsOnMissingSource) {
  EXPECT_LT(pet_matte_prepare(L"C:\\nope.mp4", OutPath().c_str(), 320), 0);
  EXPECT_STRNE(pet_matte_last_error(), "");
}
