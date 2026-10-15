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
native_path::Path TempPath() {
  auto p = std::filesystem::temp_directory_path() / "aipmat_roundtrip.aipmat";
  return p;
}
}  // namespace

TEST(Roundtrip, ThreeFramesSurviveWriteThenRead) {
  const native_path::Path path = TempPath();
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
  auto path = std::filesystem::temp_directory_path() / "bad.aipmat";
  {
    // 必须写满 kHeaderSize 字节：如果文件比 header 还短，Reader::Open 会在
    // 长度检查那一步就提前返回，magic 比较那行根本不会被执行到——即使把
    // magic 比较整个删掉，这个测试之前也照样能通过。
    // 文件名本身是纯 ASCII，narrow fopen 在这里不会有编码损耗，只是为了
    // 直接写入手工构造的损坏字节，不经过 Writer。
    std::vector<uint8_t> buf(pcmat::kHeaderSize, 0);
    std::memcpy(buf.data(), "NOTAMAGIC", 9);
    FILE* f = fopen(path.string().c_str(), "wb");
    fwrite(buf.data(), 1, buf.size(), f);
    fclose(f);
  }
  EXPECT_FALSE(pcmat::Reader::Open(path).has_value());
  std::filesystem::remove(path);
}

TEST(Roundtrip, OpenRejectsCorruptIndexOffsetWithoutCrashing) {
  auto path = std::filesystem::temp_directory_path() / "corrupt_index.aipmat";
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
    FILE* f = fopen(path.string().c_str(), "wb");
    fwrite(buf.data(), 1, buf.size(), f);
    fclose(f);
  }
  EXPECT_FALSE(pcmat::Reader::Open(path).has_value());
  std::filesystem::remove(path);
}

namespace {
// 构造一个 header 字段合法（除了 width/height）的最小文件：magic、
// schemaVersion、headerSize、frameCount=0、index/manifest 都指向空区间，
// 这样如果 width/height 校验被漏掉，唯一会失败的就是我们真正想测的那一项。
void WriteHeaderOnlyFile(const std::filesystem::path& path, uint32_t width, uint32_t height) {
  pcmat::Header h{};
  std::memcpy(h.magic, pcmat::kMagic, 8);
  h.schemaVersion = pcmat::kSchemaVersion;
  h.headerSize = pcmat::kHeaderSize;
  h.flags = pcmat::kFlagLz4;
  h.width = width;
  h.height = height;
  h.timeBaseDen = 10000000;
  h.frameCount = 0;
  h.indexOffset = pcmat::kHeaderSize;
  h.indexSize = 0;
  h.manifestOffset = pcmat::kHeaderSize;
  h.manifestSize = 0;

  std::vector<uint8_t> buf(pcmat::kHeaderSize, 0);
  std::memcpy(buf.data(), &h, sizeof(h));
  FILE* f = fopen(path.string().c_str(), "wb");
  fwrite(buf.data(), 1, buf.size(), f);
  fclose(f);
}
}  // namespace

TEST(Roundtrip, OpenRejectsZeroWidthOrHeight) {
  // Ruling: 一个 width/height 为 0 的画布没有任何意义——没有像素可分配，
  // 却仍然是磁盘上完全合法的一个 uint32_t 字段，不会被 InBounds 之类的
  // 边界检查挡住。
  auto path = std::filesystem::temp_directory_path() / "zero_dim.aipmat";
  WriteHeaderOnlyFile(path, 0, 64);
  EXPECT_FALSE(pcmat::Reader::Open(path).has_value());
  WriteHeaderOnlyFile(path, 64, 0);
  EXPECT_FALSE(pcmat::Reader::Open(path).has_value());
  std::filesystem::remove(path);
}

TEST(Roundtrip, OpenRejectsAbsurdlyLargeDimensionsWithoutCrashing) {
  // I-3 复现链路的落点：targetEdge 校验如果被绕过（或者文件本身就是手工
  // 构造/损坏的），width=height=4294967295 会一路写进 header。frame_source
  // 会据此做 width*height*4 的画布分配，未捕获的 bad_alloc 直接崩溃。
  // Reader::Open 必须在这里就拒绝，画布分配这步永远不会被走到。
  auto path = std::filesystem::temp_directory_path() / "huge_dim.aipmat";
  WriteHeaderOnlyFile(path, UINT32_MAX, UINT32_MAX);
  EXPECT_FALSE(pcmat::Reader::Open(path).has_value());
  std::filesystem::remove(path);
}

TEST(Roundtrip, SurvivesNonAsciiPath) {
  // Task 7 修复的回归测试：Writer 曾经把宽字符路径经 std::string 转换后交给
  // 窄字符 fopen，在 MSVC 下会走进程 ANSI 代码页而不是 UTF-8，路径中代码页
  // 覆盖不到的字符会被静默改写甚至截断。这里刻意混合中文、带附加符号的
  // 拉丁字母、以及一个超出 BMP 需要代理对编码的表情符号，逼近真实场景下
  // %APPDATA% 路径里可能出现的用户名字符集。
  const native_path::Path path =
      std::filesystem::temp_directory_path() / std::filesystem::u8path(u8"测试_ünïcode_🐕.aipmat");
  const uint16_t kW = 4, kH = 4;
  const size_t kBytes = static_cast<size_t>(kW) * kH * 4;
  auto frame = MakeFrame(kBytes, 42);

  {
    pcmat::Writer w(path, 32, 32, 10000000);
    ASSERT_TRUE(w.ok());
    ASSERT_TRUE(w.AddFrame(frame.data(), frame.size(), 0, 416666, 0, 0, kW, kH));
    ASSERT_TRUE(w.Finish(R"({"pipeline":"non_ascii_test"})"));
  }

  auto r = pcmat::Reader::Open(path);
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->header().frameCount, 1u);
  EXPECT_EQ(r->manifest(), R"({"pipeline":"non_ascii_test"})");

  std::vector<uint8_t> out;
  ASSERT_TRUE(r->ReadFrame(0, out));
  EXPECT_EQ(out, frame);

  std::filesystem::remove(path);
}
