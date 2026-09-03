#include <gtest/gtest.h>
#include <cstdint>
#include <filesystem>
#include <vector>
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

TEST(Pipeline, RejectsTargetEdgeAboveCeiling) {
  // 平常的越界值：比 kMaxCacheEdge 大但仍是一个合理的 uint32_t。
  EXPECT_EQ(pet_matte_prepare(Fixture().c_str(), OutPath().c_str(), kMaxCacheEdge + 1), -2);
  EXPECT_STRNE(pet_matte_last_error(), "");
}

TEST(Pipeline, RejectsTargetEdgeWrappedFromNegativeInt) {
  // I-3 复现链路里的具体触发值：Dart 侧传 targetEdge: -1，插件把它
  // static_cast<uint32_t> 后就是 UINT32_MAX，绝不能被当成一个"很大但合法"
  // 的边长悄悄接受。
  EXPECT_EQ(pet_matte_prepare(Fixture().c_str(), OutPath().c_str(), UINT32_MAX), -2);
  EXPECT_STRNE(pet_matte_last_error(), "");
}

TEST(Pipeline, ZeroTargetEdgeUsesDefaultCacheEdge) {
  const auto out = OutPath();
  ASSERT_EQ(pet_matte_prepare(Fixture().c_str(), out.c_str(), 0), 0)
      << pet_matte_last_error();
  auto r = pcmat::Reader::Open(out);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->header().width, kDefaultCacheEdge);
  EXPECT_EQ(r->header().height, kDefaultCacheEdge);
  std::filesystem::remove(out);
}

TEST(Pipeline, FringePixelsArePremultiplied) {
  // BackgroundIsKeyedOutAndBoxSurvives only samples the crop *centre*, where
  // alpha is 255 and premultiplication is the identity (a == 255 means
  // colour * alpha/255 == colour) -- it would pass identically whether or
  // not PremultiplyAlpha ever ran. Premultiplied BGRA8 is the actual
  // contract that decides whether the pet composites with a dark halo, and
  // that contract only shows up where 0 < alpha < 255: the box's edge
  // pixels, softened into a green/white gradient by the fixture's gblur
  // (see native/testdata/make_fixtures.ps1 -- plain overlay compositing
  // between two already-yuv420p sources turned out to produce a perfectly
  // binary 0/255 alpha canvas with no edge blending at all, so the blur was
  // added there specifically so this contract has something to test against).
  const auto out = OutPath();
  ASSERT_EQ(pet_matte_prepare(Fixture().c_str(), out.c_str(), 320), 0)
      << pet_matte_last_error();
  auto r = pcmat::Reader::Open(out);
  ASSERT_TRUE(r.has_value());

  std::vector<uint8_t> frame;
  ASSERT_TRUE(r->ReadFrame(0, frame));

  bool foundFringe = false;
  for (size_t i = 0; i + 3 < frame.size(); i += 4) {
    const uint8_t b = frame[i + 0], g = frame[i + 1], red = frame[i + 2], a = frame[i + 3];
    if (a == 0 || a == 255) continue;  // 只关心部分透明的过渡像素
    foundFringe = true;
    // 预乘 alpha 的定义性质：任何颜色分量都不能超过 alpha（颜色已经按
    // alpha/255 缩放过）。这也顺带能抓到"重复预乘"这种事故——重复预乘后
    // 分量会比这更小，但如果管线里漏掉了预乘这一步，分量会保持接近未预乘
    // 的原色（这里是白 (255,255,255) 与绿 (0,255,0) 的混合），大概率超过
    // 一个远小于 255 的 alpha，从而让下面的断言失败。
    EXPECT_LE(red, a) << "at byte offset " << i;
    EXPECT_LE(g, a) << "at byte offset " << i;
    EXPECT_LE(b, a) << "at byte offset " << i;
  }
  ASSERT_TRUE(foundFringe)
      << "expected at least one partially-transparent fringe pixel in frame 0's "
         "crop (the fixture's gblur should soften the box's hard edge against "
         "the green background)";
  std::filesystem::remove(out);
}
