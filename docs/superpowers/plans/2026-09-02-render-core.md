# 渲染内核（Plan A）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把一个绿幕 mp4 抠成带 alpha 的帧缓存，并在一个无边框透明置顶的 Flutter 窗口里循环播放出来。

**Architecture:** 原生层是四个独立的 C++ 静态库（`pcmat` 容器读写、`matte_core` 纯像素运算、`mf_decode` Media Foundation 解码、`pet_matte` 编排），全部用 GoogleTest 覆盖，不依赖 Flutter 即可构建和测试。Flutter 插件 `alpha_video` 链接这些库，把解出的帧通过 External Texture 注册给引擎。示例 app 用 `window_manager` 开一个透明置顶窗验证端到端效果。

**Tech Stack:** Flutter 3.47.2 / Dart 3.13.2、C++17、CMake、GoogleTest、LZ4、Media Foundation、Win32

**Spec:** `docs/superpowers/specs/2026-09-02-desktop-pet-design.md`

## Global Constraints

- 只做 Windows。不写任何 macOS/Linux 代码路径。
- Flutter SDK 位于 `C:\Users\Administrator\code\envs\flutter`，用前需 `$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"`。
- C++ 标准 C++17。编译器为 Visual Studio 生成工具 2026（18.1.1），CMake 走 Flutter 自带流程。
- 容器格式：扩展名 `.aipmat`，magic `AIPMAT1\0`，头部固定 128 字节，索引项固定 48 字节，帧数据 LZ4 压缩。
- 像素格式统一为 **BGRA8 预乘 alpha，sRGB**。
- 缓存分辨率默认 `720×720`（常量 `kDefaultCacheEdge`），不是源片分辨率。
- 第三方依赖只经 CMake `FetchContent` 引入：GoogleTest `v1.15.2`、LZ4 `v1.10.0`。不 vendoring 源码。
- 所有测试用 `ctest` 跑，测试可执行文件不依赖网络、不依赖竞品文件。
- 所有原生目标编译时带 MSVC `/utf-8`。源文件含非 ASCII 字符时，缺这个标志会让 MSVC 按代码页 936 错解并破坏结构体布局（Task 1 实测踩过）。
- **与 spec 的一处有意偏离**：spec 4.2 写的是 D3D11 纹理环 + GpuSurfaceTexture。本计划先用 `flutter::PixelBufferTexture`（CPU 像素缓冲）打通端到端；720×720@24fps 约 50 MB/s 拷贝，实测足够。D3D11 GpuSurface 升级作为 Plan A 之后的独立优化项，不在本计划内。

---

## File Structure

```
native/
  CMakeLists.txt                     顶层：C++17、FetchContent(gtest, lz4)、add_subdirectory
  pcmat/
    include/pcmat/format.h           头部/索引 POD 结构 + 常量
    include/pcmat/writer.h           AipmatWriter
    include/pcmat/reader.h           AipmatReader
    src/writer.cpp
    src/reader.cpp
    tests/test_format.cpp            结构体大小/对齐
    tests/test_roundtrip.cpp         写→读往返
  matte_core/
    include/matte_core/pixel.h       BgraImage 视图类型
    include/matte_core/chroma_key.h  绿幕键控
    include/matte_core/despill.h     去溢色
    include/matte_core/crop.h        alpha 包围盒
    src/chroma_key.cpp
    src/despill.cpp
    src/crop.cpp
    tests/test_chroma_key.cpp
    tests/test_despill.cpp
    tests/test_crop.cpp
  mf_decode/
    include/mf_decode/decoder.h      MfVideoDecoder
    src/decoder.cpp
    tests/test_decoder.cpp           用合成 mp4
  pet_matte/
    include/pet_matte/pet_matte.h    C ABI
    src/pet_matte.cpp                编排 decode→key→despill→crop→write
    tests/test_pipeline.cpp
  testdata/
    make_fixtures.ps1                用 ffmpeg 合成测试 mp4
    .gitignore                       忽略生成的 mp4
packages/
  alpha_video/                       Flutter plugin（windows only）
    lib/alpha_video.dart
    lib/src/alpha_video_controller.dart
    lib/src/alpha_video_view.dart
    windows/CMakeLists.txt
    windows/alpha_video_plugin.cpp
    windows/alpha_video_plugin.h
    windows/frame_source.h           读 .aipmat + 定时推帧
    windows/frame_source.cpp
    example/                         透明置顶窗验证 app
```

---

### Task 1: 原生工程骨架与测试基座

**Files:**
- Create: `native/CMakeLists.txt`
- Create: `native/pcmat/CMakeLists.txt`
- Create: `native/pcmat/include/pcmat/format.h`
- Test: `native/pcmat/tests/test_format.cpp`

**Interfaces:**
- Consumes: 无
- Produces: CMake 目标 `pcmat`（静态库）与 `pcmat_tests`；常量 `pcmat::kMagic`、`pcmat::kHeaderSize`、`pcmat::kIndexEntrySize`；POD 类型 `pcmat::Header`、`pcmat::FrameIndex`

- [ ] **Step 1: 写失败的测试**

`native/pcmat/tests/test_format.cpp`:

```cpp
#include <gtest/gtest.h>
#include "pcmat/format.h"

TEST(Format, HeaderIsExactly128Bytes) {
  EXPECT_EQ(sizeof(pcmat::Header), 128u);
  EXPECT_EQ(pcmat::kHeaderSize, 128u);
}

TEST(Format, IndexEntryIsExactly48Bytes) {
  EXPECT_EQ(sizeof(pcmat::FrameIndex), 48u);
  EXPECT_EQ(pcmat::kIndexEntrySize, 48u);
}

TEST(Format, MagicIsAipmat1) {
  EXPECT_EQ(std::string(pcmat::kMagic, 8), std::string("AIPMAT1\0", 8));
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
```
Expected: 配置或编译失败，因为 `pcmat/format.h` 不存在。

- [ ] **Step 3: 写最小实现**

`native/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.20)
project(aipet_native CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MSVC 无 BOM 时按系统代码页(936)解析源文件，会静默错解中文注释并破坏结构体布局。
add_compile_options($<$<CXX_COMPILER_ID:MSVC>:/utf-8>)

include(FetchContent)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_Declare(googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG v1.15.2)
FetchContent_MakeAvailable(googletest)

FetchContent_Declare(lz4
  GIT_REPOSITORY https://github.com/lz4/lz4.git
  GIT_TAG v1.10.0
  SOURCE_SUBDIR build/cmake)
FetchContent_MakeAvailable(lz4)

enable_testing()
include(GoogleTest)

add_subdirectory(pcmat)
```

`native/pcmat/include/pcmat/format.h`:

```cpp
#pragma once
#include <cstdint>
#include <cstddef>

namespace pcmat {

inline constexpr char kMagic[8] = {'A','I','P','M','A','T','1','\0'};
inline constexpr uint32_t kHeaderSize = 128;
inline constexpr uint32_t kIndexEntrySize = 48;
inline constexpr uint32_t kSchemaVersion = 1;
inline constexpr uint32_t kFlagLz4 = 1u << 0;

#pragma pack(push, 1)
struct Header {
  char     magic[8];
  uint32_t schemaVersion;
  uint32_t headerSize;
  uint32_t flags;
  uint32_t width;
  uint32_t height;
  uint32_t timeBaseDen;
  uint32_t frameCount;
  uint64_t indexOffset;
  uint64_t indexSize;
  uint64_t manifestOffset;
  uint64_t manifestSize;
  uint8_t  reserved[60];
};

struct FrameIndex {
  uint64_t ptsTicks;
  uint64_t durationTicks;
  uint64_t byteOffset;
  uint32_t byteSize;   // 压缩后
  uint32_t rawSize;    // 解压后
  uint16_t cropX, cropY, cropW, cropH;
  uint8_t  reserved[8];
};
#pragma pack(pop)

static_assert(sizeof(Header) == kHeaderSize, "Header must be 128 bytes");
static_assert(sizeof(FrameIndex) == kIndexEntrySize, "FrameIndex must be 48 bytes");

}  // namespace pcmat
```

`native/pcmat/CMakeLists.txt`:

```cmake
add_library(pcmat INTERFACE)
target_include_directories(pcmat INTERFACE include)

add_executable(pcmat_tests tests/test_format.cpp)
target_link_libraries(pcmat_tests PRIVATE pcmat GTest::gtest_main)
gtest_discover_tests(pcmat_tests)
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
ctest --test-dir native/build -C Debug --output-on-failure
```
Expected: 3 个测试全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add native/
git commit -m "feat(native): CMake 骨架与 aipmat 容器格式定义"
```

---

### Task 2: aipmat 写入与读取往返

**Files:**
- Create: `native/pcmat/include/pcmat/writer.h`
- Create: `native/pcmat/include/pcmat/reader.h`
- Create: `native/pcmat/src/writer.cpp`
- Create: `native/pcmat/src/reader.cpp`
- Modify: `native/pcmat/CMakeLists.txt`
- Test: `native/pcmat/tests/test_roundtrip.cpp`

**Interfaces:**
- Consumes: `pcmat::Header`、`pcmat::FrameIndex`（Task 1）
- Produces:
  - `pcmat::Writer(const std::string& path, uint32_t w, uint32_t h, uint32_t timeBaseDen)`
  - `bool Writer::AddFrame(const uint8_t* bgra, size_t size, uint64_t ptsTicks, uint64_t durTicks, uint16_t cx, uint16_t cy, uint16_t cw, uint16_t ch)`
  - `bool Writer::Finish(const std::string& manifestJson)`
  - `pcmat::Reader::Open(const std::string& path) -> std::optional<Reader>`
  - `bool Reader::ReadFrame(uint32_t i, std::vector<uint8_t>& out) const`
  - `const Header& Reader::header() const`、`const FrameIndex& Reader::index(uint32_t i) const`
  - `std::string Reader::manifest() const`

- [ ] **Step 1: 写失败的测试**

`native/pcmat/tests/test_roundtrip.cpp`:

```cpp
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
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cmake --build native/build --config Debug
```
Expected: 编译失败，`writer.h` / `reader.h` 不存在。

- [ ] **Step 3: 写实现**

`native/pcmat/include/pcmat/writer.h`:

```cpp
#pragma once
#include <cstdio>
#include <string>
#include <vector>
#include "pcmat/format.h"

namespace pcmat {

class Writer {
 public:
  Writer(const std::string& path, uint32_t width, uint32_t height, uint32_t timeBaseDen);
  ~Writer();
  Writer(const Writer&) = delete;
  Writer& operator=(const Writer&) = delete;

  bool ok() const { return file_ != nullptr; }
  bool AddFrame(const uint8_t* bgra, size_t size, uint64_t ptsTicks, uint64_t durTicks,
                uint16_t cropX, uint16_t cropY, uint16_t cropW, uint16_t cropH);
  bool Finish(const std::string& manifestJson);

 private:
  FILE* file_ = nullptr;
  Header header_{};
  std::vector<FrameIndex> index_;
  uint64_t cursor_ = 0;
};

}  // namespace pcmat
```

`native/pcmat/src/writer.cpp`:

```cpp
#include "pcmat/writer.h"
#include <cstring>
#include <lz4.h>

namespace pcmat {

Writer::Writer(const std::string& path, uint32_t width, uint32_t height, uint32_t timeBaseDen) {
  file_ = fopen(path.c_str(), "wb");
  if (!file_) return;
  std::memset(&header_, 0, sizeof(header_));
  std::memcpy(header_.magic, kMagic, 8);
  header_.schemaVersion = kSchemaVersion;
  header_.headerSize = kHeaderSize;
  header_.flags = kFlagLz4;
  header_.width = width;
  header_.height = height;
  header_.timeBaseDen = timeBaseDen;
  // 头部占位，Finish 时回填
  std::vector<uint8_t> zero(kHeaderSize, 0);
  fwrite(zero.data(), 1, kHeaderSize, file_);
  cursor_ = kHeaderSize;
}

Writer::~Writer() { if (file_) fclose(file_); }

bool Writer::AddFrame(const uint8_t* bgra, size_t size, uint64_t ptsTicks, uint64_t durTicks,
                      uint16_t cropX, uint16_t cropY, uint16_t cropW, uint16_t cropH) {
  if (!file_ || size == 0) return false;
  const int bound = LZ4_compressBound(static_cast<int>(size));
  std::vector<char> buf(static_cast<size_t>(bound));
  const int n = LZ4_compress_default(reinterpret_cast<const char*>(bgra), buf.data(),
                                     static_cast<int>(size), bound);
  if (n <= 0) return false;
  if (fwrite(buf.data(), 1, static_cast<size_t>(n), file_) != static_cast<size_t>(n)) return false;

  FrameIndex fi{};
  fi.ptsTicks = ptsTicks;
  fi.durationTicks = durTicks;
  fi.byteOffset = cursor_;
  fi.byteSize = static_cast<uint32_t>(n);
  fi.rawSize = static_cast<uint32_t>(size);
  fi.cropX = cropX; fi.cropY = cropY; fi.cropW = cropW; fi.cropH = cropH;
  index_.push_back(fi);
  cursor_ += static_cast<uint64_t>(n);
  return true;
}

bool Writer::Finish(const std::string& manifestJson) {
  if (!file_) return false;
  header_.frameCount = static_cast<uint32_t>(index_.size());
  header_.indexOffset = cursor_;
  header_.indexSize = static_cast<uint64_t>(index_.size()) * kIndexEntrySize;
  if (!index_.empty() &&
      fwrite(index_.data(), kIndexEntrySize, index_.size(), file_) != index_.size()) return false;
  cursor_ += header_.indexSize;

  header_.manifestOffset = cursor_;
  header_.manifestSize = manifestJson.size();
  if (!manifestJson.empty() &&
      fwrite(manifestJson.data(), 1, manifestJson.size(), file_) != manifestJson.size()) return false;

  fseek(file_, 0, SEEK_SET);
  if (fwrite(&header_, 1, kHeaderSize, file_) != kHeaderSize) return false;
  fclose(file_);
  file_ = nullptr;
  return true;
}

}  // namespace pcmat
```

`native/pcmat/include/pcmat/reader.h`:

```cpp
#pragma once
#include <optional>
#include <string>
#include <vector>
#include "pcmat/format.h"

namespace pcmat {

class Reader {
 public:
  static std::optional<Reader> Open(const std::string& path);

  const Header& header() const { return header_; }
  const FrameIndex& index(uint32_t i) const { return index_[i]; }
  std::string manifest() const { return manifest_; }
  bool ReadFrame(uint32_t i, std::vector<uint8_t>& out) const;

 private:
  Header header_{};
  std::vector<FrameIndex> index_;
  std::string manifest_;
  std::vector<uint8_t> blob_;  // 整文件载入
};

}  // namespace pcmat
```

`native/pcmat/src/reader.cpp`:

```cpp
#include "pcmat/reader.h"
#include <cstdio>
#include <cstring>
#include <lz4.h>

namespace pcmat {

std::optional<Reader> Reader::Open(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return std::nullopt;
  fseek(f, 0, SEEK_END);
  const long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (len < static_cast<long>(kHeaderSize)) { fclose(f); return std::nullopt; }

  Reader r;
  r.blob_.resize(static_cast<size_t>(len));
  const size_t got = fread(r.blob_.data(), 1, r.blob_.size(), f);
  fclose(f);
  if (got != r.blob_.size()) return std::nullopt;

  std::memcpy(&r.header_, r.blob_.data(), kHeaderSize);
  if (std::memcmp(r.header_.magic, kMagic, 8) != 0) return std::nullopt;
  if (r.header_.headerSize != kHeaderSize) return std::nullopt;
  if (r.header_.indexOffset + r.header_.indexSize > r.blob_.size()) return std::nullopt;
  if (r.header_.indexSize != static_cast<uint64_t>(r.header_.frameCount) * kIndexEntrySize)
    return std::nullopt;

  r.index_.resize(r.header_.frameCount);
  if (r.header_.frameCount)
    std::memcpy(r.index_.data(), r.blob_.data() + r.header_.indexOffset, r.header_.indexSize);

  if (r.header_.manifestOffset + r.header_.manifestSize > r.blob_.size()) return std::nullopt;
  r.manifest_.assign(reinterpret_cast<const char*>(r.blob_.data() + r.header_.manifestOffset),
                     static_cast<size_t>(r.header_.manifestSize));
  return r;
}

bool Reader::ReadFrame(uint32_t i, std::vector<uint8_t>& out) const {
  if (i >= index_.size()) return false;
  const FrameIndex& fi = index_[i];
  if (fi.byteOffset + fi.byteSize > blob_.size()) return false;
  out.resize(fi.rawSize);
  const int n = LZ4_decompress_safe(
      reinterpret_cast<const char*>(blob_.data() + fi.byteOffset),
      reinterpret_cast<char*>(out.data()),
      static_cast<int>(fi.byteSize), static_cast<int>(fi.rawSize));
  return n == static_cast<int>(fi.rawSize);
}

}  // namespace pcmat
```

`native/pcmat/CMakeLists.txt` 替换为：

```cmake
add_library(pcmat STATIC src/writer.cpp src/reader.cpp)
target_include_directories(pcmat PUBLIC include)
target_link_libraries(pcmat PUBLIC lz4_static)

add_executable(pcmat_tests tests/test_format.cpp tests/test_roundtrip.cpp)
target_link_libraries(pcmat_tests PRIVATE pcmat GTest::gtest_main)
gtest_discover_tests(pcmat_tests)
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
ctest --test-dir native/build -C Debug --output-on-failure
```
Expected: 5 个测试全 PASS。若 `lz4_static` 目标名不对，用 `cmake --build native/build --target help` 查实际名字并改 `target_link_libraries`。

- [ ] **Step 5: 提交**

```bash
git add native/
git commit -m "feat(pcmat): aipmat 容器写入与读取，LZ4 压缩，往返测试覆盖"
```

---

### Task 3: 绿幕键控

**Files:**
- Create: `native/matte_core/include/matte_core/pixel.h`
- Create: `native/matte_core/include/matte_core/chroma_key.h`
- Create: `native/matte_core/src/chroma_key.cpp`
- Create: `native/matte_core/CMakeLists.txt`
- Modify: `native/CMakeLists.txt`（加 `add_subdirectory(matte_core)`）
- Test: `native/matte_core/tests/test_chroma_key.cpp`

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct matte::BgraImage { uint8_t* data; int width; int height; int stride; }`
  - `struct matte::KeyParams { float keyCb=-0.331f; float keyCr=-0.419f; float innerT=0.10f; float outerT=0.25f; }`
  - `void matte::ApplyChromaKey(BgraImage img, const KeyParams& p)` — 就地把 alpha 通道写成键控结果，RGB 不动

- [ ] **Step 1: 写失败的测试**

`native/matte_core/tests/test_chroma_key.cpp`:

```cpp
#include <gtest/gtest.h>
#include <vector>
#include "matte_core/chroma_key.h"

namespace {
// BGRA 单像素图，便于逐色验证
std::vector<uint8_t> Px(uint8_t b, uint8_t g, uint8_t r) { return {b, g, r, 255}; }
uint8_t AlphaOf(std::vector<uint8_t> px) {
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyChromaKey(img, matte::KeyParams{});
  return px[3];
}
}  // namespace

TEST(ChromaKey, PureGreenBecomesFullyTransparent) {
  EXPECT_EQ(AlphaOf(Px(0, 255, 0)), 0);
}

TEST(ChromaKey, StudioGreenBecomesFullyTransparent) {
  // 0x00B140，竞品素材实际用的绿
  EXPECT_EQ(AlphaOf(Px(0x40, 0xB1, 0x00)), 0);
}

TEST(ChromaKey, WhiteStaysFullyOpaque) {
  EXPECT_EQ(AlphaOf(Px(255, 255, 255)), 255);
}

TEST(ChromaKey, BlackStaysFullyOpaque) {
  EXPECT_EQ(AlphaOf(Px(0, 0, 0)), 255);
}

TEST(ChromaKey, SkinToneStaysFullyOpaque) {
  EXPECT_EQ(AlphaOf(Px(180, 200, 235)), 255);
}

TEST(ChromaKey, NearGreenEdgeIsPartiallyTransparent) {
  const uint8_t a = AlphaOf(Px(130, 205, 130));
  EXPECT_GT(a, 0);
  EXPECT_LT(a, 255);
}

TEST(ChromaKey, RespectsStrideAndLeavesRgbUntouched) {
  // 2×1 图，stride 12（末尾 4 字节是 padding，不应被写）
  std::vector<uint8_t> buf(12, 0xAB);
  buf[0]=0; buf[1]=255; buf[2]=0; buf[3]=255;        // 绿
  buf[4]=255; buf[5]=255; buf[6]=255; buf[7]=255;    // 白
  matte::BgraImage img{buf.data(), 2, 1, 12};
  matte::ApplyChromaKey(img, matte::KeyParams{});
  EXPECT_EQ(buf[3], 0);      // 绿 → 透明
  EXPECT_EQ(buf[7], 255);    // 白 → 不透明
  EXPECT_EQ(buf[1], 255);    // RGB 未被改动
  EXPECT_EQ(buf[8], 0xAB);   // padding 未被写
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cmake --build native/build --config Debug
```
Expected: 编译失败，`matte_core/chroma_key.h` 不存在。

- [ ] **Step 3: 写实现**

`native/matte_core/include/matte_core/pixel.h`:

```cpp
#pragma once
#include <cstdint>

namespace matte {

struct BgraImage {
  uint8_t* data;
  int width;
  int height;
  int stride;  // 字节/行
  uint8_t* row(int y) const { return data + static_cast<size_t>(y) * stride; }
};

}  // namespace matte
```

`native/matte_core/include/matte_core/chroma_key.h`:

```cpp
#pragma once
#include "matte_core/pixel.h"

namespace matte {

// 键控在归一化 Cb/Cr 平面做：色度距离越接近键色，alpha 越低。
struct KeyParams {
  float keyCb = -0.331f;  // 纯绿 (0,255,0) 的 Cb
  float keyCr = -0.419f;  // 纯绿 (0,255,0) 的 Cr
  float innerT = 0.28f;   // 距离 <= innerT → alpha 0
  float outerT = 0.45f;   // 距离 >= outerT → alpha 255
};

void ApplyChromaKey(BgraImage img, const KeyParams& p);

}  // namespace matte
```

`native/matte_core/src/chroma_key.cpp`:

```cpp
#include "matte_core/chroma_key.h"
#include <algorithm>
#include <cmath>

namespace matte {

void ApplyChromaKey(BgraImage img, const KeyParams& p) {
  const float span = std::max(1e-6f, p.outerT - p.innerT);
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      const float b = px[0] / 255.0f, g = px[1] / 255.0f, r = px[2] / 255.0f;
      // BT.601 色度分量
      const float cb = -0.168736f * r - 0.331264f * g + 0.5f * b;
      const float cr =  0.5f * r - 0.418688f * g - 0.081312f * b;
      const float d = std::sqrt((cb - p.keyCb) * (cb - p.keyCb) +
                                (cr - p.keyCr) * (cr - p.keyCr));
      const float a = std::clamp((d - p.innerT) / span, 0.0f, 1.0f);
      px[3] = static_cast<uint8_t>(std::lround(a * 255.0f));
    }
  }
}

}  // namespace matte
```

`native/matte_core/CMakeLists.txt`:

```cmake
add_library(matte_core STATIC src/chroma_key.cpp)
target_include_directories(matte_core PUBLIC include)

add_executable(matte_core_tests tests/test_chroma_key.cpp)
target_link_libraries(matte_core_tests PRIVATE matte_core GTest::gtest_main)
gtest_discover_tests(matte_core_tests)
```

在 `native/CMakeLists.txt` 末尾追加：

```cmake
add_subdirectory(matte_core)
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
ctest --test-dir native/build -C Debug --output-on-failure -R ChromaKey
```
Expected: 7 个 ChromaKey 测试全 PASS。

阈值已由控制器预先用数值验证过，实测色度距离（到纯绿）：纯绿 0.0000、studio 0x00B140 0.2511、(130,205,130) 0.3769、白/黑 0.5339、肤色 0.5622。配合 `innerT=0.28 / outerT=0.45`，七个断言全部有 ≥0.029 的余量。**如果测试失败，先怀疑实现而不是阈值**——不要动 `KeyParams` 的默认值，改了会破坏其他断言。

- [ ] **Step 5: 提交**

```bash
git add native/
git commit -m "feat(matte): YCbCr 色度距离绿幕键控"
```

---

### Task 4: 去溢色与 alpha 预乘

**Files:**
- Create: `native/matte_core/include/matte_core/despill.h`
- Create: `native/matte_core/src/despill.cpp`
- Modify: `native/matte_core/CMakeLists.txt`
- Test: `native/matte_core/tests/test_despill.cpp`

**Interfaces:**
- Consumes: `matte::BgraImage`（Task 3）
- Produces:
  - `void matte::ApplyDespill(BgraImage img)` — 抑制绿色溢出，RGB 就地改，alpha 不动
  - `void matte::PremultiplyAlpha(BgraImage img)` — 把 RGB 乘上 alpha

- [ ] **Step 1: 写失败的测试**

`native/matte_core/tests/test_despill.cpp`:

```cpp
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
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cmake --build native/build --config Debug
```
Expected: 编译失败，`despill.h` 不存在。

- [ ] **Step 3: 写实现**

`native/matte_core/include/matte_core/despill.h`:

```cpp
#pragma once
#include "matte_core/pixel.h"

namespace matte {

// 绿占优的像素把 G 压到 (R+B)/2，消除毛发边缘的绿边。
void ApplyDespill(BgraImage img);

// BGRA 直通 alpha → 预乘 alpha。
void PremultiplyAlpha(BgraImage img);

}  // namespace matte
```

`native/matte_core/src/despill.cpp`:

```cpp
#include "matte_core/despill.h"

namespace matte {

void ApplyDespill(BgraImage img) {
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      const int limit = (static_cast<int>(px[0]) + static_cast<int>(px[2])) / 2;
      if (px[1] > limit) px[1] = static_cast<uint8_t>(limit);
    }
  }
}

void PremultiplyAlpha(BgraImage img) {
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      const int a = px[3];
      px[0] = static_cast<uint8_t>(px[0] * a / 255);
      px[1] = static_cast<uint8_t>(px[1] * a / 255);
      px[2] = static_cast<uint8_t>(px[2] * a / 255);
    }
  }
}

}  // namespace matte
```

`native/matte_core/CMakeLists.txt` 更新两行：

```cmake
add_library(matte_core STATIC src/chroma_key.cpp src/despill.cpp)
add_executable(matte_core_tests tests/test_chroma_key.cpp tests/test_despill.cpp)
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
ctest --test-dir native/build -C Debug --output-on-failure -R "Despill|Premultiply"
```
Expected: 5 个测试全 PASS。

- [ ] **Step 5: 提交**

```bash
git add native/
git commit -m "feat(matte): 去溢色与 alpha 预乘"
```

---

### Task 5: alpha 包围盒裁剪

**Files:**
- Create: `native/matte_core/include/matte_core/crop.h`
- Create: `native/matte_core/src/crop.cpp`
- Modify: `native/matte_core/CMakeLists.txt`
- Test: `native/matte_core/tests/test_crop.cpp`

**Interfaces:**
- Consumes: `matte::BgraImage`（Task 3）
- Produces:
  - `struct matte::Rect { int x, y, w, h; }`
  - `matte::Rect matte::AlphaBounds(BgraImage img, uint8_t threshold)` — 全透明时返回 `{0,0,0,0}`
  - `void matte::CopyRegion(BgraImage src, Rect r, uint8_t* dst)` — 紧密打包写出 `r.w*r.h*4` 字节

- [ ] **Step 1: 写失败的测试**

`native/matte_core/tests/test_crop.cpp`:

```cpp
#include <gtest/gtest.h>
#include <vector>
#include "matte_core/crop.h"

namespace {
// 4×4 BGRA 全透明，指定像素设为不透明
std::vector<uint8_t> Canvas4x4(std::initializer_list<std::pair<int,int>> opaque) {
  std::vector<uint8_t> v(4 * 4 * 4, 0);
  for (auto [x, y] : opaque) {
    uint8_t* px = v.data() + (static_cast<size_t>(y) * 4 + x) * 4;
    px[0] = 10; px[1] = 20; px[2] = 30; px[3] = 255;
  }
  return v;
}
}  // namespace

TEST(AlphaBounds, SinglePixelGivesUnitRect) {
  auto v = Canvas4x4({{2, 1}});
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.x, 2); EXPECT_EQ(r.y, 1);
  EXPECT_EQ(r.w, 1); EXPECT_EQ(r.h, 1);
}

TEST(AlphaBounds, TwoCornersSpanTheBox) {
  auto v = Canvas4x4({{1, 1}, {3, 2}});
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.x, 1); EXPECT_EQ(r.y, 1);
  EXPECT_EQ(r.w, 3); EXPECT_EQ(r.h, 2);
}

TEST(AlphaBounds, FullyTransparentGivesEmptyRect) {
  auto v = Canvas4x4({});
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.w, 0); EXPECT_EQ(r.h, 0);
}

TEST(AlphaBounds, ThresholdExcludesFaintPixels) {
  auto v = Canvas4x4({{0, 0}});
  v[3] = 5;  // alpha 5，低于阈值 8
  matte::BgraImage img{v.data(), 4, 4, 16};
  auto r = matte::AlphaBounds(img, 8);
  EXPECT_EQ(r.w, 0);
}

TEST(CopyRegion, ExtractsTightlyPackedPixels) {
  auto v = Canvas4x4({{1, 1}, {2, 1}});
  matte::BgraImage img{v.data(), 4, 4, 16};
  matte::Rect r{1, 1, 2, 1};
  std::vector<uint8_t> out(2 * 1 * 4, 0xEE);
  matte::CopyRegion(img, r, out.data());
  EXPECT_EQ(out[0], 10);  EXPECT_EQ(out[3], 255);
  EXPECT_EQ(out[4], 10);  EXPECT_EQ(out[7], 255);
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cmake --build native/build --config Debug
```
Expected: 编译失败，`crop.h` 不存在。

- [ ] **Step 3: 写实现**

`native/matte_core/include/matte_core/crop.h`:

```cpp
#pragma once
#include "matte_core/pixel.h"

namespace matte {

struct Rect { int x = 0, y = 0, w = 0, h = 0; };

// alpha > threshold 的像素的最小包围盒；全透明返回 {0,0,0,0}。
Rect AlphaBounds(BgraImage img, uint8_t threshold);

// 把 src 的 r 区域紧密打包（stride = r.w*4）拷到 dst。
void CopyRegion(BgraImage src, Rect r, uint8_t* dst);

}  // namespace matte
```

`native/matte_core/src/crop.cpp`:

```cpp
#include "matte_core/crop.h"
#include <cstring>

namespace matte {

Rect AlphaBounds(BgraImage img, uint8_t threshold) {
  int minX = img.width, minY = img.height, maxX = -1, maxY = -1;
  for (int y = 0; y < img.height; ++y) {
    const uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      if (row[x * 4 + 3] > threshold) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return Rect{};
  return Rect{minX, minY, maxX - minX + 1, maxY - minY + 1};
}

void CopyRegion(BgraImage src, Rect r, uint8_t* dst) {
  const size_t rowBytes = static_cast<size_t>(r.w) * 4;
  for (int y = 0; y < r.h; ++y) {
    std::memcpy(dst + static_cast<size_t>(y) * rowBytes,
                src.row(r.y + y) + static_cast<size_t>(r.x) * 4, rowBytes);
  }
}

}  // namespace matte
```

`native/matte_core/CMakeLists.txt` 更新两行：

```cmake
add_library(matte_core STATIC src/chroma_key.cpp src/despill.cpp src/crop.cpp)
add_executable(matte_core_tests tests/test_chroma_key.cpp tests/test_despill.cpp tests/test_crop.cpp)
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
ctest --test-dir native/build -C Debug --output-on-failure
```
Expected: 全部测试 PASS。累计 23 个：3 Format + 3 Roundtrip + 7 ChromaKey + 5 Despill/Premultiply + 5 Crop。

- [ ] **Step 5: 提交**

```bash
git add native/
git commit -m "feat(matte): alpha 包围盒计算与区域拷贝"
```

---

### Task 6: Media Foundation 解码

**Files:**
- Create: `native/mf_decode/include/mf_decode/decoder.h`
- Create: `native/mf_decode/src/decoder.cpp`
- Create: `native/mf_decode/CMakeLists.txt`
- Create: `native/testdata/make_fixtures.ps1`
- Create: `native/testdata/.gitignore`
- Modify: `native/CMakeLists.txt`
- Test: `native/mf_decode/tests/test_decoder.cpp`

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct mfd::VideoInfo { uint32_t width, height, frameCount; uint64_t durationTicks; }`
  - `class mfd::Decoder`：`static std::optional<Decoder> Open(const std::wstring& path)`、`const VideoInfo& info() const`、`bool NextFrame(std::vector<uint8_t>& bgra, uint64_t& ptsTicks, uint64_t& durTicks)`（返回 false 表示流结束）

- [ ] **Step 1: 写测试夹具生成脚本和失败的测试**

`native/testdata/make_fixtures.ps1`:

```powershell
# 合成一个确定性的绿幕测试片：320x320，24fps，1 秒 24 帧，
# 纯绿底 + 一个 100x100 白方块每帧右移 6px。
# 方块放在 y=40 而不是垂直居中：居中时上下翻转前后位置几乎不变，
# 任何测试都发现不了解码出来的画面是倒的。实测白块恒定占第 40-139 行，
# 若解码颠倒则会落在 180-279 行，据此可判定正立。
# 背景用纯绿 0x00FF00：实测真实宠物素材背景就是 (8,239,8)/(2,251,3)，基本纯绿。
# 必须用 overlay 而不是 drawbox：ffmpeg 8.1 的 drawbox 坐标表达式不支持逐帧变量
# (n/t)，写了会报 "Undefined constant"，方块根本画不出来。overlay 的 x/y 支持 n。
$ErrorActionPreference = "Stop"
$out = Join-Path $PSScriptRoot "green_box.mp4"
ffmpeg -y -f lavfi -i "color=c=0x00FF00:s=320x320:d=1:r=24" `
  -f lavfi -i "color=c=white:s=100x100:d=1:r=24" `
  -filter_complex "[0:v][1:v]overlay=x='40+n*6':y=40:shortest=1" `
  -c:v libx264 -pix_fmt yuv420p -an $out
Write-Host "wrote $out"
```

`native/testdata/.gitignore`:

```
*.mp4
```

`native/mf_decode/tests/test_decoder.cpp`:

```cpp
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
```

- [ ] **Step 2: 生成夹具并跑测试确认失败**

```powershell
powershell -ExecutionPolicy Bypass -File native/testdata/make_fixtures.ps1
cmake --build native/build --config Debug
```
Expected: 编译失败，`mf_decode/decoder.h` 不存在。

- [ ] **Step 3: 写实现**

`native/mf_decode/include/mf_decode/decoder.h`:

```cpp
#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct IMFSourceReader;

namespace mfd {

struct VideoInfo {
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t frameCount = 0;      // 已知则填，未知为 0
  uint64_t durationTicks = 0;   // 100ns 单位
};

class Decoder {
 public:
  static std::optional<Decoder> Open(const std::wstring& path);
  Decoder(Decoder&&) noexcept;
  Decoder& operator=(Decoder&&) noexcept;
  Decoder(const Decoder&) = delete;
  Decoder& operator=(const Decoder&) = delete;
  ~Decoder();

  const VideoInfo& info() const { return info_; }
  // 输出紧密打包的 BGRA32（stride = width*4）。流结束返回 false。
  bool NextFrame(std::vector<uint8_t>& bgra, uint64_t& ptsTicks, uint64_t& durTicks);

 private:
  Decoder() = default;
  IMFSourceReader* reader_ = nullptr;
  VideoInfo info_{};
  uint64_t lastPts_ = 0;
};

}  // namespace mfd
```

`native/mf_decode/src/decoder.cpp`:

```cpp
#include "mf_decode/decoder.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <cstring>

namespace mfd {
namespace {

struct MfRuntime {
  MfRuntime()  { MFStartup(MF_VERSION); }
  ~MfRuntime() { MFShutdown(); }
};
// 进程内只初始化一次
void EnsureMfStarted() { static MfRuntime rt; }

}  // namespace

std::optional<Decoder> Decoder::Open(const std::wstring& path) {
  EnsureMfStarted();

  IMFAttributes* attrs = nullptr;
  if (FAILED(MFCreateAttributes(&attrs, 1))) return std::nullopt;
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);

  IMFSourceReader* reader = nullptr;
  HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), attrs, &reader);
  attrs->Release();
  if (FAILED(hr) || !reader) return std::nullopt;

  // 输出协商为 BGRA32
  IMFMediaType* outType = nullptr;
  if (FAILED(MFCreateMediaType(&outType))) { reader->Release(); return std::nullopt; }
  outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  outType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  hr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, outType);
  outType->Release();
  if (FAILED(hr)) { reader->Release(); return std::nullopt; }

  IMFMediaType* cur = nullptr;
  if (FAILED(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur))) {
    reader->Release(); return std::nullopt;
  }
  Decoder d;
  d.reader_ = reader;
  UINT32 w = 0, h = 0;
  MFGetAttributeSize(cur, MF_MT_FRAME_SIZE, &w, &h);
  cur->Release();
  d.info_.width = w;
  d.info_.height = h;

  PROPVARIANT var;
  if (SUCCEEDED(reader->GetPresentationAttribute(
          MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &var))) {
    d.info_.durationTicks = var.uhVal.QuadPart;
    PropVariantClear(&var);
  }
  return d;
}

Decoder::Decoder(Decoder&& o) noexcept
    : reader_(o.reader_), info_(o.info_), lastPts_(o.lastPts_) { o.reader_ = nullptr; }

Decoder& Decoder::operator=(Decoder&& o) noexcept {
  if (this != &o) {
    if (reader_) reader_->Release();
    reader_ = o.reader_; info_ = o.info_; lastPts_ = o.lastPts_;
    o.reader_ = nullptr;
  }
  return *this;
}

Decoder::~Decoder() { if (reader_) reader_->Release(); }

bool Decoder::NextFrame(std::vector<uint8_t>& bgra, uint64_t& ptsTicks, uint64_t& durTicks) {
  if (!reader_) return false;
  DWORD flags = 0;
  LONGLONG ts = 0;
  IMFSample* sample = nullptr;
  HRESULT hr = reader_->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                                   nullptr, &flags, &ts, &sample);
  if (FAILED(hr)) return false;
  if (flags & MF_SOURCE_READERF_ENDOFSTREAM) { if (sample) sample->Release(); return false; }
  if (!sample) return false;

  IMFMediaBuffer* buf = nullptr;
  if (FAILED(sample->ConvertToContiguousBuffer(&buf))) { sample->Release(); return false; }

  BYTE* data = nullptr;
  DWORD maxLen = 0, curLen = 0;
  LONG stride = static_cast<LONG>(info_.width) * 4;
  bool locked = false;

  IMF2DBuffer* buf2d = nullptr;
  if (SUCCEEDED(buf->QueryInterface(IID_PPV_ARGS(&buf2d)))) {
    if (SUCCEEDED(buf2d->Lock2D(&data, &stride))) locked = true;
  }
  if (!locked && FAILED(buf->Lock(&data, &maxLen, &curLen))) {
    if (buf2d) buf2d->Release();
    buf->Release(); sample->Release(); return false;
  }

  const size_t rowBytes = static_cast<size_t>(info_.width) * 4;
  bgra.resize(rowBytes * info_.height);
  // MF 的 RGB32 可能是 bottom-up（stride 为负）。Lock2D 返回的是「视觉上的第一行」，
  // stride 为负时后续行在内存里向低地址走，所以有效地址恒为 data + stride*y。
  // 用带符号 stride 直接寻址，两种朝向都正确，不要按符号分支——分支版本会把
  // 负 stride 的情形算到缓冲区之外去。
  for (uint32_t y = 0; y < info_.height; ++y)
    std::memcpy(bgra.data() + y * rowBytes,
                data + static_cast<ptrdiff_t>(stride) * y, rowBytes);
  // RGB32 的第 4 字节未必是 255，统一置为不透明
  for (size_t i = 3; i < bgra.size(); i += 4) bgra[i] = 255;

  // 解锁必须依据「哪个锁真的成功了」，不能依据「是否拿到了 IMF2DBuffer 接口」：
  // QueryInterface 成功但 Lock2D 失败、随后普通 Lock 成功时，后者会解错对象并泄漏锁。
  if (lockedWith2D) buf2d->Unlock2D(); else buf->Unlock();
  if (buf2d) buf2d->Release();
  buf->Release();

  LONGLONG dur = 0;
  if (FAILED(sample->GetSampleDuration(&dur))) dur = 0;
  sample->Release();

  ptsTicks = static_cast<uint64_t>(ts);
  durTicks = static_cast<uint64_t>(dur);
  lastPts_ = ptsTicks;
  return true;
}

}  // namespace mfd
```

`native/mf_decode/CMakeLists.txt`:

```cmake
add_library(mf_decode STATIC src/decoder.cpp)
target_include_directories(mf_decode PUBLIC include)
target_link_libraries(mf_decode PUBLIC mfplat mfreadwrite mfuuid ole32 propsys)

add_executable(mf_decode_tests tests/test_decoder.cpp)
target_compile_definitions(mf_decode_tests PRIVATE
  AIPET_TESTDATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../testdata")
target_link_libraries(mf_decode_tests PRIVATE mf_decode GTest::gtest_main)
gtest_discover_tests(mf_decode_tests)
```

在 `native/CMakeLists.txt` 末尾追加：

```cmake
add_subdirectory(mf_decode)
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
ctest --test-dir native/build -C Debug --output-on-failure -R Decoder
```
Expected: 5 个 Decoder 测试全 PASS。

夹具已由控制器实测：`ffprobe` 报 `nb_frames=24`、320×320，第 0/12/23 帧的白块均为 100×100 且每帧右移 6px。若 `DecodesTwentyFourFrames` 得到别的数字，先确认 `make_fixtures.ps1` 跑的是本计划里这一版（overlay 版，不是 drawbox 版）。

- [ ] **Step 5: 提交**

```bash
git add native/
git commit -m "feat(mf): Media Foundation BGRA32 逐帧解码"
```

---

### Task 7: 抠像管线编排与 C ABI

**Files:**
- Create: `native/pet_matte/include/pet_matte/pet_matte.h`
- Create: `native/pet_matte/src/pet_matte.cpp`
- Create: `native/pet_matte/CMakeLists.txt`
- Modify: `native/CMakeLists.txt`
- Test: `native/pet_matte/tests/test_pipeline.cpp`

**Interfaces:**
- Consumes: `pcmat::Writer`（Task 2）、`matte::ApplyChromaKey`/`ApplyDespill`/`PremultiplyAlpha`（Task 3-4）、`matte::AlphaBounds`/`CopyRegion`（Task 5）、`mfd::Decoder`（Task 6）
- Produces: C ABI
  - `int32_t pet_matte_abi_version(void)` → `1`
  - `int32_t pet_matte_prepare(const wchar_t* srcMp4, const wchar_t* dstAipmat, uint32_t targetEdge)` → `0` 成功，负值为错误码
  - `const char* pet_matte_last_error(void)`
  - 常量 `kDefaultCacheEdge = 720`

- [ ] **Step 1: 写失败的测试**

`native/pet_matte/tests/test_pipeline.cpp`:

```cpp
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

  auto r = pcmat::Reader::Open(std::filesystem::path(out).string());
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->header().frameCount, 24u);
  EXPECT_EQ(r->header().width, 320u);
  EXPECT_FALSE(r->manifest().empty());
  std::filesystem::remove(out);
}

TEST(Pipeline, BackgroundIsKeyedOutAndBoxSurvives) {
  const auto out = OutPath();
  ASSERT_EQ(pet_matte_prepare(Fixture().c_str(), out.c_str(), 320), 0);
  auto r = pcmat::Reader::Open(std::filesystem::path(out).string());
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
  auto r = pcmat::Reader::Open(std::filesystem::path(out).string());
  ASSERT_TRUE(r.has_value());
  EXPECT_EQ(r->header().width, 160u);
  EXPECT_EQ(r->header().height, 160u);
  std::filesystem::remove(out);
}

TEST(Pipeline, FailsOnMissingSource) {
  EXPECT_LT(pet_matte_prepare(L"C:\\nope.mp4", OutPath().c_str(), 320), 0);
  EXPECT_STRNE(pet_matte_last_error(), "");
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cmake --build native/build --config Debug
```
Expected: 编译失败，`pet_matte/pet_matte.h` 不存在。

- [ ] **Step 3: 写实现**

`native/pet_matte/include/pet_matte/pet_matte.h`:

```cpp
#pragma once
#include <cstdint>

inline constexpr uint32_t kDefaultCacheEdge = 720;

extern "C" {

int32_t pet_matte_abi_version(void);

// 把绿幕 mp4 抠像并写成 .aipmat。targetEdge 为输出方形边长（0 表示保持源尺寸）。
// 返回 0 成功；-1 打不开源；-2 解码失败；-3 写入失败。
int32_t pet_matte_prepare(const wchar_t* srcMp4, const wchar_t* dstAipmat, uint32_t targetEdge);

const char* pet_matte_last_error(void);

}  // extern "C"
```

`native/pet_matte/src/pet_matte.cpp`:

```cpp
#include "pet_matte/pet_matte.h"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "matte_core/chroma_key.h"
#include "matte_core/crop.h"
#include "matte_core/despill.h"
#include "mf_decode/decoder.h"
#include "pcmat/writer.h"

namespace {

std::string g_lastError;

// 最近邻缩放，BGRA 紧密打包。抠像前做，降低后续所有逐像素运算的成本。
void ResizeNearest(const std::vector<uint8_t>& src, int sw, int sh,
                   std::vector<uint8_t>& dst, int dw, int dh) {
  dst.resize(static_cast<size_t>(dw) * dh * 4);
  for (int y = 0; y < dh; ++y) {
    const int sy = y * sh / dh;
    const uint8_t* srow = src.data() + static_cast<size_t>(sy) * sw * 4;
    uint8_t* drow = dst.data() + static_cast<size_t>(y) * dw * 4;
    for (int x = 0; x < dw; ++x) {
      const int sx = x * sw / dw;
      std::memcpy(drow + static_cast<size_t>(x) * 4,
                  srow + static_cast<size_t>(sx) * 4, 4);
    }
  }
}

}  // namespace

extern "C" {

int32_t pet_matte_abi_version(void) { return 1; }

const char* pet_matte_last_error(void) { return g_lastError.c_str(); }

int32_t pet_matte_prepare(const wchar_t* srcMp4, const wchar_t* dstAipmat, uint32_t targetEdge) {
  g_lastError.clear();

  auto dec = mfd::Decoder::Open(srcMp4);
  if (!dec.has_value()) { g_lastError = "cannot open source video"; return -1; }

  const int sw = static_cast<int>(dec->info().width);
  const int sh = static_cast<int>(dec->info().height);
  if (sw <= 0 || sh <= 0) { g_lastError = "invalid source dimensions"; return -2; }

  const int dw = targetEdge ? static_cast<int>(targetEdge) : sw;
  const int dh = targetEdge ? static_cast<int>(targetEdge) : sh;

  pcmat::Writer writer(std::filesystem::path(dstAipmat).string(),
                       static_cast<uint32_t>(dw), static_cast<uint32_t>(dh), 10000000);
  if (!writer.ok()) { g_lastError = "cannot open destination"; return -3; }

  std::vector<uint8_t> src, work, packed;
  uint64_t pts = 0, dur = 0;
  uint32_t frames = 0;

  while (dec->NextFrame(src, pts, dur)) {
    if (dw != sw || dh != sh) ResizeNearest(src, sw, sh, work, dw, dh);
    else work = src;

    matte::BgraImage img{work.data(), dw, dh, dw * 4};
    matte::ApplyChromaKey(img, matte::KeyParams{});
    matte::ApplyDespill(img);
    matte::PremultiplyAlpha(img);

    matte::Rect r = matte::AlphaBounds(img, 8);
    if (r.w == 0 || r.h == 0) { r = matte::Rect{0, 0, 1, 1}; }  // 全透明帧存 1 像素占位

    packed.resize(static_cast<size_t>(r.w) * r.h * 4);
    matte::CopyRegion(img, r, packed.data());

    if (!writer.AddFrame(packed.data(), packed.size(), pts, dur,
                         static_cast<uint16_t>(r.x), static_cast<uint16_t>(r.y),
                         static_cast<uint16_t>(r.w), static_cast<uint16_t>(r.h))) {
      g_lastError = "frame write failed";
      return -3;
    }
    ++frames;
  }

  if (frames == 0) { g_lastError = "no frames decoded"; return -2; }

  const std::string manifest =
      std::string("{\"pipeline\":\"aipet-green-matte-1\",\"frames\":") +
      std::to_string(frames) + "}";
  if (!writer.Finish(manifest)) { g_lastError = "finalize failed"; return -3; }
  return 0;
}

}  // extern "C"
```

`native/pet_matte/CMakeLists.txt`:

```cmake
add_library(pet_matte STATIC src/pet_matte.cpp)
target_include_directories(pet_matte PUBLIC include)
target_link_libraries(pet_matte PUBLIC pcmat matte_core mf_decode)

add_executable(pet_matte_tests tests/test_pipeline.cpp)
target_compile_definitions(pet_matte_tests PRIVATE
  AIPET_TESTDATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../testdata")
target_link_libraries(pet_matte_tests PRIVATE pet_matte GTest::gtest_main)
gtest_discover_tests(pet_matte_tests)
```

在 `native/CMakeLists.txt` 末尾追加：

```cmake
add_subdirectory(pet_matte)
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
cmake -S native -B native/build
cmake --build native/build --config Debug
ctest --test-dir native/build -C Debug --output-on-failure
```
Expected: 全部测试 PASS。累计 33 个：23（Task 1-5）+ 5 Decoder + 5 Pipeline。

- [ ] **Step 5: 用真实素材做一次人工验证**

写一个临时小程序或用 ctest 之外的方式，对本机真实绿幕素材跑一遍，把第 0 帧导成 PNG 肉眼检查毛发边缘：

```powershell
# 源素材（本机开发用，不进仓库）
$src = "$env:APPDATA\com.petcompanion\宠伴赛博陪伴\pets\generated\0af4f2d6-ca2b-4028-80e1-e41944b8edd6\82cd8b28-f904-469e-abac-3ea9433b009f\walk-walk.mp4"
```

检查点：狗毛边缘无绿边、无锯齿、背景全透明。若有绿边，回 Task 3 调 `outerT`，回 Task 4 确认 despill 生效。

- [ ] **Step 6: 提交**

```bash
git add native/
git commit -m "feat(pet_matte): 抠像管线编排与 C ABI"
```

---

### Task 8: alpha_video 插件骨架

**Files:**
- Create: `packages/alpha_video/`（用 `flutter create --template=plugin` 生成后裁剪）
- Modify: `packages/alpha_video/lib/alpha_video.dart`
- Modify: `packages/alpha_video/windows/CMakeLists.txt`
- Modify: `packages/alpha_video/windows/alpha_video_plugin.cpp`
- Test: `packages/alpha_video/example/integration_test/plugin_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - Dart：`AlphaVideo.abiVersion() -> Future<int>`
  - 方法通道名 `aipet.alpha_video/methods`，方法 `abiVersion`

- [ ] **Step 1: 生成插件骨架**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
flutter create --template=plugin --platforms=windows --org com.aipet `
  --project-name alpha_video packages/alpha_video
```

删除生成的 `lib/alpha_video_platform_interface.dart` 和 `lib/alpha_video_method_channel.dart`（我们只有一个平台，联邦式接口是多余的）。

- [ ] **Step 2: 写失败的测试**

`packages/alpha_video/example/integration_test/plugin_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:alpha_video/alpha_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('abiVersion returns 1 from native', (tester) async {
    expect(await AlphaVideo.abiVersion(), 1);
  });
}
```

在 `packages/alpha_video/example/pubspec.yaml` 的 `dev_dependencies` 加：

```yaml
  integration_test:
    sdk: flutter
```

- [ ] **Step 3: 跑测试确认失败**

```powershell
cd packages/alpha_video/example
flutter test integration_test/plugin_test.dart -d windows
```
Expected: FAIL —— `AlphaVideo.abiVersion` 未定义。

- [ ] **Step 4: 写实现**

`packages/alpha_video/lib/alpha_video.dart`:

```dart
import 'package:flutter/services.dart';

class AlphaVideo {
  static const MethodChannel _channel = MethodChannel('aipet.alpha_video/methods');

  static Future<int> abiVersion() async {
    final v = await _channel.invokeMethod<int>('abiVersion');
    return v ?? 0;
  }
}
```

`packages/alpha_video/windows/alpha_video_plugin.cpp` 的 `HandleMethodCall` 改为：

```cpp
void AlphaVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "abiVersion") {
    result->Success(flutter::EncodableValue(pet_matte_abi_version()));
    return;
  }
  result->NotImplemented();
}
```

在同文件顶部加 `#include "pet_matte/pet_matte.h"`。

`packages/alpha_video/windows/CMakeLists.txt` 中，在 `apply_standard_settings(${PLUGIN_NAME})` 之后加：

```cmake
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../../native" native_build)
target_link_libraries(${PLUGIN_NAME} PRIVATE pet_matte)
```

同时把通道名从模板生成的改成 `aipet.alpha_video/methods`。

- [ ] **Step 5: 跑测试确认通过**

```powershell
cd packages/alpha_video/example
flutter test integration_test/plugin_test.dart -d windows
```
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add packages/alpha_video/
git commit -m "feat(alpha_video): Flutter Windows 插件骨架，打通到 pet_matte 的 ABI"
```

---

### Task 9: 帧源与外部纹理注册（静态首帧）

**Files:**
- Create: `packages/alpha_video/windows/frame_source.h`
- Create: `packages/alpha_video/windows/frame_source.cpp`
- Modify: `packages/alpha_video/windows/alpha_video_plugin.cpp`
- Modify: `packages/alpha_video/windows/CMakeLists.txt`
- Modify: `packages/alpha_video/lib/alpha_video.dart`
- Create: `packages/alpha_video/lib/src/alpha_video_controller.dart`
- Test: `packages/alpha_video/example/integration_test/texture_test.dart`

**Interfaces:**
- Consumes: `pcmat::Reader`（Task 2）、`pet_matte_prepare`（Task 7）、`AlphaVideo`（Task 8）
- Produces:
  - C++：`class FrameSource`，`bool Load(const std::wstring& aipmatPath)`、`const uint8_t* FrameRgba(uint32_t i)`、`uint32_t width()/height()/frameCount()`、`uint64_t frameDurationTicks(uint32_t i) const`
  - Dart：`AlphaVideoController.open(String aipmatPath) -> Future<AlphaVideoController>`，字段 `textureId`、`width`、`height`、`frameCount`；`Future<void> dispose()`
  - 方法通道新增 `open`（参数 `path`，返回 `{textureId,width,height,frameCount}`）、`dispose`（参数 `textureId`）

**说明：** 帧在容器里是裁剪过的，`FrameSource` 负责把它按 `crop` 贴回整幅画布并转成 Flutter 需要的 **RGBA**（`FlutterDesktopPixelBuffer` 要求 RGBA 序，而容器里存的是 BGRA，需逐像素交换 R/B）。

- [ ] **Step 1: 写失败的测试**

`packages/alpha_video/example/integration_test/texture_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:alpha_video/alpha_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String aipmat;

  setUpAll(() async {
    aipmat = '${Directory.systemTemp.path}\\itest_clip.aipmat';
    final src = '${Directory.current.path}\\..\\..\\..\\native\\testdata\\green_box.mp4';
    expect(File(src).existsSync(), isTrue,
        reason: '先跑 native/testdata/make_fixtures.ps1');
    final code = await AlphaVideo.prepare(source: src, destination: aipmat, targetEdge: 320);
    expect(code, 0);
  });

  testWidgets('open registers a texture and reports media info', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    expect(c.textureId, greaterThanOrEqualTo(0));
    expect(c.width, 320);
    expect(c.height, 320);
    expect(c.frameCount, 24);
    await c.dispose();
  });

  testWidgets('opening a missing file throws', (tester) async {
    expect(() => AlphaVideoController.open('C:\\nope.aipmat'), throwsA(isA<PlatformException>()));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cd packages/alpha_video/example
flutter test integration_test/texture_test.dart -d windows
```
Expected: FAIL —— `AlphaVideo.prepare` / `AlphaVideoController` 未定义。

- [ ] **Step 3: 写 C++ 帧源**

`packages/alpha_video/windows/frame_source.h`:

```cpp
#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
#include "pcmat/reader.h"

class FrameSource {
 public:
  // 宽字符路径：pcmat::Reader 在 Task 7 已改为 UTF-16 + _wfopen。
  bool Load(const std::wstring& path);
  uint32_t width() const { return reader_ ? reader_->header().width : 0; }
  uint32_t height() const { return reader_ ? reader_->header().height : 0; }
  uint32_t frameCount() const { return reader_ ? reader_->header().frameCount : 0; }

  // 把第 i 帧展开成整幅 RGBA 画布；返回内部缓冲，下次调用即失效。
  const uint8_t* FrameRgba(uint32_t i);

  // 第 i 帧索引项记录的时长（100ns 单位）；越界或无记录返回 0。
  uint64_t frameDurationTicks(uint32_t i) const {
    return (reader_ && i < frameCount()) ? reader_->index(i).durationTicks : 0;
  }

 private:
  std::optional<pcmat::Reader> reader_;
  std::vector<uint8_t> packed_;
  std::vector<uint8_t> canvas_;
};
```

`packages/alpha_video/windows/frame_source.cpp`:

```cpp
#include "frame_source.h"
#include <algorithm>
#include <cstring>

bool FrameSource::Load(const std::wstring& path) {
  reader_ = pcmat::Reader::Open(path);
  if (!reader_) return false;
  canvas_.assign(static_cast<size_t>(width()) * height() * 4, 0);
  return true;
}

const uint8_t* FrameSource::FrameRgba(uint32_t i) {
  if (!reader_ || i >= frameCount()) return nullptr;
  if (!reader_->ReadFrame(i, packed_)) return nullptr;

  std::fill(canvas_.begin(), canvas_.end(), 0);
  const auto& fi = reader_->index(i);
  const uint32_t W = width();
  for (uint16_t y = 0; y < fi.cropH; ++y) {
    const uint8_t* src = packed_.data() + static_cast<size_t>(y) * fi.cropW * 4;
    uint8_t* dst = canvas_.data() + (static_cast<size_t>(fi.cropY + y) * W + fi.cropX) * 4;
    for (uint16_t x = 0; x < fi.cropW; ++x) {
      // 容器是 BGRA，Flutter PixelBuffer 要 RGBA
      dst[x * 4 + 0] = src[x * 4 + 2];
      dst[x * 4 + 1] = src[x * 4 + 1];
      dst[x * 4 + 2] = src[x * 4 + 0];
      dst[x * 4 + 3] = src[x * 4 + 3];
    }
  }
  return canvas_.data();
}
```

- [ ] **Step 4: 在插件里注册外部纹理**

`packages/alpha_video/windows/alpha_video_plugin.cpp` 关键片段：

```cpp
#include <windows.h>
#include <flutter/texture_registrar.h>
#include <map>
#include <memory>
#include <string>
#include "frame_source.h"
#include "pet_matte/pet_matte.h"

namespace {

// Dart 的字符串到达时是 UTF-8；Windows 路径原生是 UTF-16。
// 失败或输入非法时返回空串（调用方需区分「输入本来就是空」的情况）。
std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                    s.data(), static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring w(static_cast<size_t>(n), L' ');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                          s.data(), static_cast<int>(s.size()), w.data(), n) != n) {
    return std::wstring();
  }
  return w;
}


struct Clip {
  std::unique_ptr<FrameSource> source;
  std::unique_ptr<flutter::TextureVariant> texture;
  FlutterDesktopPixelBuffer buffer{};
  uint32_t currentFrame = 0;
  int64_t textureId = -1;
};

std::map<int64_t, std::unique_ptr<Clip>> g_clips;

}  // namespace

// registrar_ 是插件持有的 flutter::PluginRegistrarWindows*
void AlphaVideoPlugin::HandleOpen(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto path = std::get<std::string>(args.at(flutter::EncodableValue("path")));
  const std::wstring wpath = Utf8ToWide(path);
  if (wpath.empty() && !path.empty()) {
    result->Error("bad_path", "path is not valid UTF-8");
    return;
  }

  auto clip = std::make_unique<Clip>();
  clip->source = std::make_unique<FrameSource>();
  if (!clip->source->Load(wpath)) {
    result->Error("open_failed", "cannot read aipmat: " + path);
    return;
  }

  Clip* raw = clip.get();
  clip->texture = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture(
          [raw](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
            const uint8_t* px = raw->source->FrameRgba(raw->currentFrame);
            if (!px) return nullptr;
            raw->buffer.buffer = px;
            raw->buffer.width = raw->source->width();
            raw->buffer.height = raw->source->height();
            return &raw->buffer;
          }));

  const int64_t id = registrar_->texture_registrar()->RegisterTexture(clip->texture.get());
  clip->textureId = id;

  flutter::EncodableMap out{
      {flutter::EncodableValue("textureId"), flutter::EncodableValue(id)},
      {flutter::EncodableValue("width"), flutter::EncodableValue(
          static_cast<int32_t>(clip->source->width()))},
      {flutter::EncodableValue("height"), flutter::EncodableValue(
          static_cast<int32_t>(clip->source->height()))},
      {flutter::EncodableValue("frameCount"), flutter::EncodableValue(
          static_cast<int32_t>(clip->source->frameCount()))},
  };
  g_clips[id] = std::move(clip);
  result->Success(flutter::EncodableValue(out));
}
```

`dispose` 分支：

```cpp
if (call.method_name() == "dispose") {
  const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
  const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
  auto it = g_clips.find(id);
  if (it != g_clips.end()) {
    registrar_->texture_registrar()->UnregisterTexture(id);
    g_clips.erase(it);
  }
  result->Success();
  return;
}
```

`prepare` 分支（同步调用 Task 7 的 ABI）：

```cpp
if (call.method_name() == "prepare") {
  const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
  const auto src = std::get<std::string>(args.at(flutter::EncodableValue("source")));
  const auto dst = std::get<std::string>(args.at(flutter::EncodableValue("destination")));
  const auto edge = std::get<int32_t>(args.at(flutter::EncodableValue("targetEdge")));
  // Dart 通过 MethodChannel 送来的是 UTF-8。绝不能用 wstring(s.begin(), s.end())
  // 逐字节拓宽——那会把每个 UTF-8 字节当成一个 wchar_t，非 ASCII 路径直接损坏。
  // 这正是 Task 7 修掉的那类缺陷，必须走真正的编码转换。
  const std::wstring wsrc = Utf8ToWide(src);
  const std::wstring wdst = Utf8ToWide(dst);
  if (wsrc.empty() != src.empty() || wdst.empty() != dst.empty()) {
    result->Error("bad_path", "path is not valid UTF-8");
    return;
  }
  result->Success(flutter::EncodableValue(
      pet_matte_prepare(wsrc.c_str(), wdst.c_str(), static_cast<uint32_t>(edge))));
  return;
}
```

`CMakeLists.txt` 的 `PLUGIN_SOURCES` 加上 `frame_source.cpp`。

- [ ] **Step 5: 写 Dart 侧**

`packages/alpha_video/lib/src/alpha_video_controller.dart`:

```dart
import 'package:flutter/services.dart';

const MethodChannel channel = MethodChannel('aipet.alpha_video/methods');

class AlphaVideoController {
  AlphaVideoController._(this.textureId, this.width, this.height, this.frameCount);

  final int textureId;
  final int width;
  final int height;
  final int frameCount;

  static Future<AlphaVideoController> open(String aipmatPath) async {
    final m = await channel.invokeMapMethod<String, dynamic>('open', {'path': aipmatPath});
    if (m == null) throw PlatformException(code: 'open_failed', message: aipmatPath);
    return AlphaVideoController._(
        m['textureId'] as int, m['width'] as int, m['height'] as int, m['frameCount'] as int);
  }

  Future<void> dispose() => channel.invokeMethod('dispose', {'textureId': textureId});
}
```

`packages/alpha_video/lib/alpha_video.dart` —— **整体替换**（不是追加：下面这段包含完整的 `class AlphaVideo`，追加会与 Task 8 的声明重复）：

```dart
export 'src/alpha_video_controller.dart';

class AlphaVideo {
  static const MethodChannel _channel = MethodChannel('aipet.alpha_video/methods');

  static Future<int> abiVersion() async =>
      await _channel.invokeMethod<int>('abiVersion') ?? 0;

  static Future<int> prepare({
    required String source,
    required String destination,
    int targetEdge = 720,
  }) async =>
      await _channel.invokeMethod<int>('prepare', {
        'source': source,
        'destination': destination,
        'targetEdge': targetEdge,
      }) ??
      -99;
}
```

- [ ] **Step 6: 跑测试确认通过**

```powershell
cd packages/alpha_video/example
flutter test integration_test/texture_test.dart -d windows
```
Expected: 2 个测试 PASS。

- [ ] **Step 7: 提交**

```bash
git add packages/alpha_video/
git commit -m "feat(alpha_video): 帧源与 PixelBufferTexture 外部纹理注册"
```

---

### Task 10: 按时间轴推帧与循环播放

**Files:**
- Modify: `packages/alpha_video/windows/alpha_video_plugin.cpp`
- Modify: `packages/alpha_video/lib/src/alpha_video_controller.dart`
- Create: `packages/alpha_video/lib/src/alpha_video_view.dart`
- Test: `packages/alpha_video/example/integration_test/playback_test.dart`

**Interfaces:**
- Consumes: `AlphaVideoController`（Task 9）、`FrameSource::frameDurationTicks`（Task 9，用于帧定时）
- Produces:
  - 方法通道新增 `play`（参数 `textureId`、`loop`）、`pause`（参数 `textureId`）、`currentFrame`（参数 `textureId`，返回 int）
  - Dart：`controller.play({bool loop = true})`、`controller.pause()`、`controller.currentFrame()`
  - Widget：`AlphaVideoView(controller: c)` — 内部就是 `Texture(textureId: c.textureId)`

**说明：** 推帧用 Win32 多媒体定时器不可靠，改用一个独立 `std::thread` + `condition_variable`，按索引里的 `durationTicks` 睡到下一帧，然后 `MarkTextureFrameAvailable`。停止时通过 flag + notify 唤醒退出。

**定时口径**：睡眠时长取**下一帧索引项的 `durationTicks`**（100ns 单位，除以 10 得微秒）；该值为 0 时回退到 41666µs（24fps）。源素材被标记为可变帧率，固定常量会相对记录的时间轴漂移。

- [ ] **Step 1: 写失败的测试**

`packages/alpha_video/example/integration_test/playback_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:alpha_video/alpha_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String aipmat;

  setUpAll(() async {
    aipmat = '${Directory.systemTemp.path}\\playback_clip.aipmat';
    final src = '${Directory.current.path}\\..\\..\\..\\native\\testdata\\green_box.mp4';
    await AlphaVideo.prepare(source: src, destination: aipmat, targetEdge: 320);
  });

  testWidgets('frame advances while playing', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    expect(await c.currentFrame(), 0);
    await c.play(loop: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final mid = await c.currentFrame();
    expect(mid, greaterThan(0));
    await c.dispose();
  });

  testWidgets('pause freezes the frame', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    await c.play(loop: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await c.pause();
    final a = await c.currentFrame();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await c.currentFrame(), a);
    await c.dispose();
  });

  testWidgets('loop wraps around instead of stopping at the end', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    await c.play(loop: true);
    // 夹具是 1 秒 24 帧，等 1.4 秒必然已经绕回
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    final f = await c.currentFrame();
    expect(f, lessThan(c.frameCount));
    await c.dispose();
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
cd packages/alpha_video/example
flutter test integration_test/playback_test.dart -d windows
```
Expected: FAIL —— `play` / `pause` / `currentFrame` 未实现。

- [ ] **Step 3: 写实现**

在 `Clip` 结构里加：

```cpp
  std::thread ticker;
  std::mutex mtx;
  std::condition_variable cv;
  bool playing = false;
  bool loop = true;
  bool stopping = false;
  flutter::TextureRegistrar* registrar = nullptr;
```

推帧线程：

```cpp
void StartTicker(Clip* c) {
  c->ticker = std::thread([c]() {
    while (true) {
      std::unique_lock<std::mutex> lk(c->mtx);
      c->cv.wait(lk, [c] { return c->playing || c->stopping; });
      if (c->stopping) return;

      const uint32_t next = c->currentFrame + 1;
      const bool atEnd = next >= c->source->frameCount();
      if (atEnd && !c->loop) { c->playing = false; continue; }
      c->currentFrame = atEnd ? 0 : next;
      const int64_t id = c->textureId;
      auto* reg = c->registrar;
      // 按该帧索引项记录的时长推进；为 0 时回退到 24fps
      const uint64_t ticks = c->source->frameDurationTicks(c->currentFrame);
      const int64_t us = ticks ? static_cast<int64_t>(ticks / 10) : 41666;
      lk.unlock();

      reg->MarkTextureFrameAvailable(id);
      std::this_thread::sleep_for(std::chrono::microseconds(us));
    }
  });
}
```

`play` / `pause` / `currentFrame` 分支：

```cpp
if (call.method_name() == "play") {
  const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
  const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
  const bool loop = std::get<bool>(args.at(flutter::EncodableValue("loop")));
  auto it = g_clips.find(id);
  if (it == g_clips.end()) { result->Error("no_clip", "unknown textureId"); return; }
  { std::lock_guard<std::mutex> lk(it->second->mtx);
    it->second->loop = loop; it->second->playing = true; }
  it->second->cv.notify_all();
  result->Success();
  return;
}

if (call.method_name() == "pause") {
  const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
  const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
  auto it = g_clips.find(id);
  if (it == g_clips.end()) { result->Error("no_clip", "unknown textureId"); return; }
  { std::lock_guard<std::mutex> lk(it->second->mtx); it->second->playing = false; }
  result->Success();
  return;
}

if (call.method_name() == "currentFrame") {
  const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
  const int64_t id = std::get<int64_t>(args.at(flutter::EncodableValue("textureId")));
  auto it = g_clips.find(id);
  if (it == g_clips.end()) { result->Error("no_clip", "unknown textureId"); return; }
  std::lock_guard<std::mutex> lk(it->second->mtx);
  result->Success(flutter::EncodableValue(static_cast<int32_t>(it->second->currentFrame)));
  return;
}
```

`dispose` 里在 `UnregisterTexture` 之前先停线程：

```cpp
  { std::lock_guard<std::mutex> lk(it->second->mtx);
    it->second->stopping = true; it->second->playing = false; }
  it->second->cv.notify_all();
  if (it->second->ticker.joinable()) it->second->ticker.join();
```

`open` 里在返回前 `clip->registrar = registrar_->texture_registrar(); StartTicker(raw);`。

Dart 侧 `AlphaVideoController` 追加：

```dart
  Future<void> play({bool loop = true}) =>
      channel.invokeMethod('play', {'textureId': textureId, 'loop': loop});

  Future<void> pause() => channel.invokeMethod('pause', {'textureId': textureId});

  Future<int> currentFrame() async =>
      await channel.invokeMethod<int>('currentFrame', {'textureId': textureId}) ?? 0;
```

`packages/alpha_video/lib/src/alpha_video_view.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'alpha_video_controller.dart';

class AlphaVideoView extends StatelessWidget {
  const AlphaVideoView({super.key, required this.controller});

  final AlphaVideoController controller;

  @override
  Widget build(BuildContext context) => Texture(textureId: controller.textureId);
}
```

在 `lib/alpha_video.dart` 加 `export 'src/alpha_video_view.dart';`。

- [ ] **Step 4: 跑测试确认通过**

```powershell
cd packages/alpha_video/example
flutter test integration_test/playback_test.dart -d windows
```
Expected: 3 个测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add packages/alpha_video/
git commit -m "feat(alpha_video): 推帧线程、播放/暂停/循环与 AlphaVideoView"
```

---

### Task 11: 透明置顶窗端到端验证

**Files:**
- Create: `apps/pet_shell/`（`flutter create`）
- Modify: `apps/pet_shell/lib/main.dart`
- Modify: `apps/pet_shell/pubspec.yaml`
- Modify: `apps/pet_shell/windows/runner/main.cpp`
- Create: `apps/pet_shell/windows/runner/win32_window.cpp` 的透明改动

**Interfaces:**
- Consumes: `AlphaVideoController`、`AlphaVideoView`（Task 9-10）
- Produces: 一个可运行的 `pet_shell` app —— 无边框透明置顶窗，循环播放抠像后的宠物

- [ ] **Step 1: 建 app 并接入依赖**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
flutter create --platforms=windows --org com.aipet --project-name pet_shell apps/pet_shell
```

`apps/pet_shell/pubspec.yaml` 的 `dependencies` 加：

```yaml
  alpha_video:
    path: ../../packages/alpha_video
  window_manager: ^0.4.3
```

- [ ] **Step 2: 让原生窗口支持透明**

`apps/pet_shell/windows/runner/main.cpp`，在 `window.Create(...)` 之前把窗口类背景改成不绘制。在 `win32_window.cpp` 的 `WindowClassRegistrar::GetWindowClass()` 里：

```cpp
  window_class.hbrBackground = nullptr;  // 原本是 (HBRUSH)(COLOR_WINDOW + 1)
```

**不要用 `SetLayeredWindowAttributes(..., LWA_COLORKEY)`。** 色键只让某一个确切 RGB 全透明：宠物身上凡是命中该色的像素会被打成洞，而且边缘是硬二值的，正好毁掉逐像素抠像。竞品用的就是 window_manager 那条路，已知在本平台可用。

先只靠 `hbrBackground = nullptr` 加 Dart 侧 `window_manager` 的透明背景（见 Step 3 的 `WindowOptions.backgroundColor: Colors.transparent`），不加任何分层窗口属性。

> 若窗口仍然画出不透明底色，升级方案是 `WS_EX_NOREDIRECTIONBITMAP` + DirectComposition，**不是**色键。这一步的成败判据是 Step 4 的肉眼验证。

- [ ] **Step 3: 写 main.dart**

`apps/pet_shell/lib/main.dart`:

```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:alpha_video/alpha_video.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(360, 360),
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(false);
      await windowManager.show();
    },
  );

  runApp(const PetShellApp());
}

class PetShellApp extends StatefulWidget {
  const PetShellApp({super.key});
  @override
  State<PetShellApp> createState() => _PetShellAppState();
}

class _PetShellAppState extends State<PetShellApp> {
  AlphaVideoController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // 开发期素材：环境变量 AIPET_DEV_CLIP 指向一个绿幕 mp4
    final src = Platform.environment['AIPET_DEV_CLIP'];
    if (src == null || !File(src).existsSync()) {
      setState(() => _error = '设置 AIPET_DEV_CLIP 指向一个绿幕 mp4');
      return;
    }
    final dst = '${Directory.systemTemp.path}\\pet_shell_dev.aipmat';
    final code = await AlphaVideo.prepare(source: src, destination: dst, targetEdge: 720);
    if (code != 0) {
      setState(() => _error = '抠像失败，错误码 $code');
      return;
    }
    final c = await AlphaVideoController.open(dst);
    await c.play(loop: true);
    setState(() => _controller = c);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: GestureDetector(
          onPanStart: (_) => windowManager.startDragging(),
          child: Center(
            child: _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12))
                : _controller == null
                    ? const SizedBox.shrink()
                    : AlphaVideoView(controller: _controller!),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 跑起来肉眼验证**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
$env:AIPET_DEV_CLIP = "$env:APPDATA\com.petcompanion\宠伴赛博陪伴\pets\generated\0af4f2d6-ca2b-4028-80e1-e41944b8edd6\82cd8b28-f904-469e-abac-3ea9433b009f\walk-walk.mp4"
cd apps/pet_shell
flutter run -d windows --release
```

**验收判据**（全部满足才算这个任务完成）：

1. 窗口无边框、无标题栏、无阴影，背景完全透明，能看见桌面
2. 狗在窗口里循环走动，动作连贯不卡顿
3. 狗的边缘没有绿边、没有黑框
4. 窗口始终置顶，拖动窗口内任意位置可移动
5. 任务管理器里进程 CPU 占用稳定在个位数百分比

任何一条不满足，记录现象后回对应任务修复：绿边→Task 3/4；卡顿→Task 10；黑框/不透明→Step 2 的窗口方案。

- [ ] **Step 5: 记录实测数据**

把 CPU%、内存、磁盘占用（`.aipmat` 文件大小）记到 `docs/superpowers/plans/2026-09-02-render-core-results.md`，Plan B 的窗口和缓存决策要用这组数。

- [ ] **Step 6: 提交**

```bash
git add apps/ docs/
git commit -m "feat(pet_shell): 透明置顶窗端到端跑通抠像视频播放"
```

---

## Self-Review

**Spec 覆盖检查：**

| Spec 章节 | 覆盖任务 |
|---|---|
| 4.2 pet_matte 解码/键控/despill/预乘/裁剪/写缓存 | Task 3-7 |
| 4.2 alpha_video 读缓存/纹理/通道 | Task 8-10 |
| 4.3 `.aipmat` 容器格式 | Task 1-2 |
| 4.4 缓存目录布局、cacheKey、原子写、LRU | **未覆盖 —— 属于 Plan B**，本计划只做单文件读写 |
| 4.1 多窗、逐像素命中测试 | **未覆盖 —— Plan B** |
| 4.6 领域模型、养成数值 | **未覆盖 —— Plan B** |
| 4.7 错误处理（并发锁、隔离区、磁盘不足） | **未覆盖 —— Plan B** |
| 4.8 测试策略（原生黄金测试、往返测试） | Task 1-7 |

Plan A 的边界是「一个绿幕 mp4 变成透明窗里的动画」，上表中标注 Plan B 的项均在其范围内，不是遗漏。

**类型一致性检查：** `pcmat::Writer::AddFrame` 的参数顺序（Task 2 定义）与 Task 7 的调用一致；`matte::BgraImage` 字段（Task 3）在 Task 4/5/7 中用法一致；`FrameSource` 接口（Task 9）与 Task 10 的 `Clip` 用法一致；`AlphaVideoController` 的字段与方法在 Task 9/10/11 中一致。

**已知待验证项：**

- Task 2 Step 4 的 `lz4_static` 目标名依赖 LZ4 上游 CMake 的命名，已在步骤里给出排查方法。
- Task 11 Step 2 的透明窗方案（色键 vs DWM blur-behind）需实测选定，判据写在 Step 4。
- Task 6 的夹具帧数可能是 24 或 25，已在步骤里说明如何处理。

---

## 后续（不在本计划内）

1. **D3D11 GpuSurfaceTexture 升级** —— 用 `FlutterDesktopGpuSurfaceTypeD3d11Texture2D` 替换 `PixelBufferTexture`，去掉每帧 CPU 拷贝。等 Task 11 的实测数据出来再决定要不要做。
2. **Plan B：桌宠应用层** —— 多窗 HUD/气泡/托盘、动作状态机、养成数值、逐像素命中测试、缓存目录与 LRU。
