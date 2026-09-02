#include <gtest/gtest.h>
#include <cstdint>
#include <cstring>
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

  // Controller decision 2: Header::reserved 写入时始终清零，读回后必须仍是全零。
  for (uint8_t b : r->header().reserved) EXPECT_EQ(b, 0);

  EXPECT_EQ(r->index(1).ptsTicks, 416666u);
  EXPECT_EQ(r->index(1).cropX, 1u);
  EXPECT_EQ(r->index(1).cropY, 2u);
  EXPECT_EQ(r->index(2).cropX, 3u);

  // 同上，FrameIndex::reserved 也必须全零。
  for (uint32_t i = 0; i < r->header().frameCount; ++i) {
    for (uint8_t b : r->index(i).reserved) EXPECT_EQ(b, 0);
  }

  std::vector<uint8_t> out;
  ASSERT_TRUE(r->ReadFrame(0, out));  EXPECT_EQ(out, f0);
  ASSERT_TRUE(r->ReadFrame(1, out));  EXPECT_EQ(out, f1);
  ASSERT_TRUE(r->ReadFrame(2, out));  EXPECT_EQ(out, f2);

  std::filesystem::remove(path);
}

TEST(Roundtrip, OpenRejectsWrongMagic) {
  auto p = (std::filesystem::temp_directory_path() / "bad.aipmat").string();
  {
    // 必须写满 kHeaderSize 字节：如果文件比 header 还短，Reader::Open 会在
    // 长度检查那一步就提前返回，magic 比较那行根本不会被执行到——即使把
    // magic 比较整个删掉，这个测试之前也照样能通过。
    std::vector<uint8_t> buf(pcmat::kHeaderSize, 0);
    std::memcpy(buf.data(), "NOTAMAGIC", 9);
    FILE* f = fopen(p.c_str(), "wb");
    fwrite(buf.data(), 1, buf.size(), f);
    fclose(f);
  }
  EXPECT_FALSE(pcmat::Reader::Open(p).has_value());
  std::filesystem::remove(p);
}

TEST(Roundtrip, OpenRejectsCorruptIndexOffsetWithoutCrashing) {
  auto p = (std::filesystem::temp_directory_path() / "corrupt_index.aipmat").string();
  {
    pcmat::Header h{};
    std::memcpy(h.magic, pcmat::kMagic, 8);
    h.schemaVersion = pcmat::kSchemaVersion;
    h.headerSize = pcmat::kHeaderSize;
    h.flags = pcmat::kFlagLz4;
    h.width = 64;
    h.height = 64;
    h.timeBaseDen = 10000000;
    h.frameCount = 1;
    // indexOffset 逼近 UINT64_MAX：indexOffset + indexSize 在 64 位无符号加法下
    // 会回绕成一个很小的数。如果边界检查写成 "offset + size > total" 就会被
    // 这个回绕骗过，进而对 blob_.data() + indexOffset 做越界指针运算并崩溃。
    h.indexOffset = UINT64_MAX - 10;
    h.indexSize = pcmat::kIndexEntrySize;
    h.manifestOffset = 0;
    h.manifestSize = 0;

    std::vector<uint8_t> buf(pcmat::kHeaderSize, 0);
    std::memcpy(buf.data(), &h, sizeof(h));
    FILE* f = fopen(p.c_str(), "wb");
    fwrite(buf.data(), 1, buf.size(), f);
    fclose(f);
  }
  EXPECT_FALSE(pcmat::Reader::Open(p).has_value());
  std::filesystem::remove(p);
}
