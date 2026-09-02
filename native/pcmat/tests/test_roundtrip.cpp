#include <gtest/gtest.h>
#include <filesystem>
#include <numeric>
#include "pcmat/writer.h"
#include "pcmat/reader.h"

namespace {
std::vector<uint8_t> MakeFrame(size_t n, uint8_t seed) {
  std::vector<uint8_t> v(n);
  for (size_t i = 0; i < n; ++i) v[i] = static_cast<uint8_t>((i * 7 + seed) & 0xFF);
  return v;
}
std::string TempPath() {
  auto p = std::filesystem::temp_directory_path() / "aipmat_roundtrip.aipmat";
  return p.string();
}
}  // namespace

TEST(Roundtrip, ThreeFramesSurviveWriteThenRead) {
  const std::string path = TempPath();
  const uint16_t kW = 8, kH = 4;
  const size_t kBytes = static_cast<size_t>(kW) * kH * 4;

  auto f0 = MakeFrame(kBytes, 0), f1 = MakeFrame(kBytes, 33), f2 = MakeFrame(kBytes, 200);
  {
    pcmat::Writer w(path, 64, 64, 10000000);
    ASSERT_TRUE(w.AddFrame(f0.data(), f0.size(), 0,       416666, 0, 0, kW, kH));
    ASSERT_TRUE(w.AddFrame(f1.data(), f1.size(), 416666,  416666, 1, 2, kW, kH));
    ASSERT_TRUE(w.AddFrame(f2.data(), f2.size(), 833332,  416666, 3, 4, kW, kH));
    ASSERT_TRUE(w.Finish(R"({"pipeline":"test"})"));
  }

  auto r = pcmat::Reader::Open(path);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->header().frameCount, 3u);
  EXPECT_EQ(r->header().width, 64u);
  EXPECT_EQ(r->header().height, 64u);
  EXPECT_EQ(r->manifest(), R"({"pipeline":"test"})");

  EXPECT_EQ(r->index(1).ptsTicks, 416666u);
  EXPECT_EQ(r->index(1).cropX, 1u);
  EXPECT_EQ(r->index(1).cropY, 2u);
  EXPECT_EQ(r->index(2).cropX, 3u);

  std::vector<uint8_t> out;
  ASSERT_TRUE(r->ReadFrame(0, out));  EXPECT_EQ(out, f0);
  ASSERT_TRUE(r->ReadFrame(1, out));  EXPECT_EQ(out, f1);
  ASSERT_TRUE(r->ReadFrame(2, out));  EXPECT_EQ(out, f2);

  std::filesystem::remove(path);
}

TEST(Roundtrip, OpenRejectsWrongMagic) {
  auto p = (std::filesystem::temp_directory_path() / "bad.aipmat").string();
  { FILE* f = fopen(p.c_str(), "wb"); fwrite("NOTAMAGIC", 1, 9, f); fclose(f); }
  EXPECT_FALSE(pcmat::Reader::Open(p).has_value());
  std::filesystem::remove(p);
}
