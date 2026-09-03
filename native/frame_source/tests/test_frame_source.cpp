#include <gtest/gtest.h>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <vector>
#include "pcmat/writer.h"
#include "frame_source/frame_source.h"

namespace {

std::wstring TempPath(const wchar_t* name) {
  return (std::filesystem::temp_directory_path() / name).wstring();
}

// 生成 count 个 BGRA 像素，四个通道各自固定成给定值——用来验证贴回画布时
// 是不是真的逐像素做了 B/G/R/A 顺序转换，而不是被"优化"成了一次 memcpy。
std::vector<uint8_t> SolidBgra(size_t count, uint8_t b, uint8_t g, uint8_t r, uint8_t a) {
  std::vector<uint8_t> v(count * 4);
  for (size_t i = 0; i < count; ++i) {
    v[i * 4 + 0] = b;
    v[i * 4 + 1] = g;
    v[i * 4 + 2] = r;
    v[i * 4 + 3] = a;
  }
  return v;
}

struct Rgba { uint8_t r, g, b, a; };

// canvas 是 FrameRgba 返回的 RGBA 画布，stride = width*4。
Rgba PixelAt(const uint8_t* canvas, uint32_t width, uint32_t x, uint32_t y) {
  const uint8_t* p = canvas + (static_cast<size_t>(y) * width + x) * 4;
  return Rgba{p[0], p[1], p[2], p[3]};
}

}  // namespace

TEST(FrameSource, SwapsBgraToRgbaPerChannel) {
  const std::wstring path = TempPath(L"frame_source_swap.aipmat");
  const uint16_t kW = 2, kH = 2;
  auto frame = SolidBgra(static_cast<size_t>(kW) * kH, /*b=*/10, /*g=*/20, /*r=*/30, /*a=*/255);
  {
    pcmat::Writer w(path, kW, kH, 10000000);
    ASSERT_TRUE(w.ok());
    ASSERT_TRUE(w.AddFrame(frame.data(), frame.size(), 0, 416666, 0, 0, kW, kH));
    ASSERT_TRUE(w.Finish("{}"));
  }

  frame_source::FrameSource fs;
  ASSERT_TRUE(fs.Load(path));
  const uint8_t* canvas = fs.FrameRgba(0);
  ASSERT_NE(canvas, nullptr);

  const Rgba p = PixelAt(canvas, fs.width(), 0, 0);
  // 容器里存的是 BGRA(10,20,30,255)；Flutter 画布要 RGBA，
  // 所以 R 该是 30，G 该是 20，B 该是 10——如果贴回代码退化成直接
  // memcpy，这里会读到 r=10, b=30，测试就会失败。
  EXPECT_EQ(p.r, 30);
  EXPECT_EQ(p.g, 20);
  EXPECT_EQ(p.b, 10);
  EXPECT_EQ(p.a, 255);

  std::filesystem::remove(path);
}

TEST(FrameSource, PlacesCropAtRecordedOffsetAndClearsOutsideIt) {
  const std::wstring path = TempPath(L"frame_source_placement.aipmat");
  const uint32_t kCanvasW = 10, kCanvasH = 10;
  const uint16_t kCropX = 4, kCropY = 5, kCropW = 3, kCropH = 2;
  auto frame = SolidBgra(static_cast<size_t>(kCropW) * kCropH, /*b=*/1, /*g=*/2, /*r=*/3, /*a=*/4);
  {
    pcmat::Writer w(path, kCanvasW, kCanvasH, 10000000);
    ASSERT_TRUE(w.ok());
    ASSERT_TRUE(w.AddFrame(frame.data(), frame.size(), 0, 416666, kCropX, kCropY, kCropW, kCropH));
    ASSERT_TRUE(w.Finish("{}"));
  }

  frame_source::FrameSource fs;
  ASSERT_TRUE(fs.Load(path));
  const uint8_t* canvas = fs.FrameRgba(0);
  ASSERT_NE(canvas, nullptr);

  // 落在 crop 矩形内的每个像素都应该是贴回后的值（RGBA：r=3,g=2,b=1,a=4）。
  for (uint16_t y = 0; y < kCropH; ++y) {
    for (uint16_t x = 0; x < kCropW; ++x) {
      const Rgba p = PixelAt(canvas, kCanvasW, kCropX + x, kCropY + y);
      EXPECT_EQ(p.r, 3) << "x=" << (kCropX + x) << " y=" << (kCropY + y);
      EXPECT_EQ(p.g, 2) << "x=" << (kCropX + x) << " y=" << (kCropY + y);
      EXPECT_EQ(p.b, 1) << "x=" << (kCropX + x) << " y=" << (kCropY + y);
      EXPECT_EQ(p.a, 4) << "x=" << (kCropX + x) << " y=" << (kCropY + y);
    }
  }

  // crop 之外必须是全透明（清零），不能残留任何非零字节。
  auto expectZero = [&](uint32_t x, uint32_t y) {
    const Rgba p = PixelAt(canvas, kCanvasW, x, y);
    EXPECT_EQ(p.r, 0) << "x=" << x << " y=" << y;
    EXPECT_EQ(p.g, 0) << "x=" << x << " y=" << y;
    EXPECT_EQ(p.b, 0) << "x=" << x << " y=" << y;
    EXPECT_EQ(p.a, 0) << "x=" << x << " y=" << y;
  };
  expectZero(0, 0);
  expectZero(kCanvasW - 1, kCanvasH - 1);
  expectZero(kCropX - 1, kCropY);  // 紧贴 crop 左边界外

  std::filesystem::remove(path);
}

TEST(FrameSource, AcceptsCropFlushWithCanvasEdge) {
  const std::wstring path = TempPath(L"frame_source_edge.aipmat");
  const uint32_t kCanvasW = 6, kCanvasH = 4;
  // cropX+cropW == kCanvasW, cropY+cropH == kCanvasH：右/下边界正好贴住
  // 画布边缘，是差一错(off-by-one)最容易出错的地方。
  const uint16_t kCropX = 4, kCropY = 2, kCropW = 2, kCropH = 2;
  auto frame = SolidBgra(static_cast<size_t>(kCropW) * kCropH, 5, 6, 7, 8);
  {
    pcmat::Writer w(path, kCanvasW, kCanvasH, 10000000);
    ASSERT_TRUE(w.ok());
    ASSERT_TRUE(w.AddFrame(frame.data(), frame.size(), 0, 416666, kCropX, kCropY, kCropW, kCropH));
    ASSERT_TRUE(w.Finish("{}"));
  }

  frame_source::FrameSource fs;
  ASSERT_TRUE(fs.Load(path));
  const uint8_t* canvas = fs.FrameRgba(0);
  // 贴边不等于越界：这个 crop 完全合法，守卫不应该拒绝它。
  ASSERT_NE(canvas, nullptr);

  const Rgba p = PixelAt(canvas, kCanvasW, kCanvasW - 1, kCanvasH - 1);
  EXPECT_EQ(p.r, 7);
  EXPECT_EQ(p.g, 6);
  EXPECT_EQ(p.b, 5);
  EXPECT_EQ(p.a, 8);

  std::filesystem::remove(path);
}

TEST(FrameSource, HandlesFullyTransparentPlaceholderFrame) {
  const std::wstring path = TempPath(L"frame_source_placeholder.aipmat");
  const uint32_t kCanvasW = 4, kCanvasH = 4;
  // pet_matte.cpp 对全透明帧的实际写法：1x1 的占位 crop，四通道全 0。
  auto frame = SolidBgra(1, 0, 0, 0, 0);
  {
    pcmat::Writer w(path, kCanvasW, kCanvasH, 10000000);
    ASSERT_TRUE(w.ok());
    ASSERT_TRUE(w.AddFrame(frame.data(), frame.size(), 0, 416666, 0, 0, 1, 1));
    ASSERT_TRUE(w.Finish("{}"));
  }

  frame_source::FrameSource fs;
  ASSERT_TRUE(fs.Load(path));
  const uint8_t* canvas = fs.FrameRgba(0);
  ASSERT_NE(canvas, nullptr);

  for (uint32_t y = 0; y < kCanvasH; ++y) {
    for (uint32_t x = 0; x < kCanvasW; ++x) {
      const Rgba p = PixelAt(canvas, kCanvasW, x, y);
      EXPECT_EQ(p.r, 0);
      EXPECT_EQ(p.g, 0);
      EXPECT_EQ(p.b, 0);
      EXPECT_EQ(p.a, 0);
    }
  }

  std::filesystem::remove(path);
}

TEST(FrameSource, RejectsCropExceedingCanvasWidth) {
  const std::wstring path = TempPath(L"frame_source_oob_width.aipmat");
  const uint32_t kCanvasW = 4, kCanvasH = 4;
  const uint16_t kCropX = 3, kCropY = 0, kCropW = 4, kCropH = 4;  // cropX+cropW = 7 > 4
  auto frame = SolidBgra(static_cast<size_t>(kCropW) * kCropH, 1, 1, 1, 1);
  {
    pcmat::Writer w(path, kCanvasW, kCanvasH, 10000000);
    ASSERT_TRUE(w.ok());
    // pcmat::Writer 本身不校验 crop 是否落在 width/height 之内——那正是
    // FrameSource 的新守卫要补上的地方。这里手工构造一个 Writer 不会拒绝、
    // 但 FrameSource 必须拒绝的越界索引项。
    ASSERT_TRUE(w.AddFrame(frame.data(), frame.size(), 0, 416666, kCropX, kCropY, kCropW, kCropH));
    ASSERT_TRUE(w.Finish("{}"));
  }

  frame_source::FrameSource fs;
  ASSERT_TRUE(fs.Load(path));
  EXPECT_EQ(fs.FrameRgba(0), nullptr);

  std::filesystem::remove(path);
}

TEST(FrameSource, RejectsPayloadSmallerThanCropDeclares) {
  const std::wstring path = TempPath(L"frame_source_oob_payload.aipmat");
  const uint32_t kCanvasW = 8, kCanvasH = 8;
  // 索引项声明的是 4x4 crop（需要 4*4*4=64 字节），但实际只塞进去 1 个像素
  // （4 字节）——模拟 rawSize 与 crop 尺寸对不上的损坏索引。
  auto tinyFrame = SolidBgra(1, 9, 9, 9, 9);
  {
    pcmat::Writer w(path, kCanvasW, kCanvasH, 10000000);
    ASSERT_TRUE(w.ok());
    ASSERT_TRUE(w.AddFrame(tinyFrame.data(), tinyFrame.size(), 0, 416666, 0, 0, 4, 4));
    ASSERT_TRUE(w.Finish("{}"));
  }

  frame_source::FrameSource fs;
  ASSERT_TRUE(fs.Load(path));
  EXPECT_EQ(fs.FrameRgba(0), nullptr);

  std::filesystem::remove(path);
}

TEST(FrameSource, ClearsCanvasBetweenFrames) {
  const std::wstring path = TempPath(L"frame_source_clear.aipmat");
  const uint32_t kCanvasW = 6, kCanvasH = 6;
  // Frame A：铺满整个画布的非零像素。
  auto frameA = SolidBgra(static_cast<size_t>(kCanvasW) * kCanvasH, 100, 100, 100, 200);
  // Frame B：只有左上角一个 2x2 的小 crop。
  const uint16_t kBCropW = 2, kBCropH = 2;
  auto frameB = SolidBgra(static_cast<size_t>(kBCropW) * kBCropH, 50, 60, 70, 80);
  {
    pcmat::Writer w(path, kCanvasW, kCanvasH, 10000000);
    ASSERT_TRUE(w.ok());
    ASSERT_TRUE(w.AddFrame(frameA.data(), frameA.size(), 0, 416666, 0, 0,
                           static_cast<uint16_t>(kCanvasW), static_cast<uint16_t>(kCanvasH)));
    ASSERT_TRUE(w.AddFrame(frameB.data(), frameB.size(), 416666, 416666, 0, 0, kBCropW, kBCropH));
    ASSERT_TRUE(w.Finish("{}"));
  }

  frame_source::FrameSource fs;
  ASSERT_TRUE(fs.Load(path));

  const uint8_t* a = fs.FrameRgba(0);
  ASSERT_NE(a, nullptr);
  {
    const Rgba p = PixelAt(a, kCanvasW, 5, 5);
    EXPECT_EQ(p.r, 100);
    EXPECT_EQ(p.g, 100);
    EXPECT_EQ(p.b, 100);
    EXPECT_EQ(p.a, 200);
  }

  const uint8_t* b = fs.FrameRgba(1);
  ASSERT_NE(b, nullptr);
  // (5,5) 在 A 帧的 crop 内，但在 B 帧的 crop 外：如果 FrameRgba 漏掉了
  // std::fill 清空这一步，这里就会残留 A 帧的 (100,100,100,200)。
  {
    const Rgba p = PixelAt(b, kCanvasW, 5, 5);
    EXPECT_EQ(p.r, 0);
    EXPECT_EQ(p.g, 0);
    EXPECT_EQ(p.b, 0);
    EXPECT_EQ(p.a, 0);
  }
  // B 帧自己的 crop 内应该是 B 的值。
  {
    const Rgba p = PixelAt(b, kCanvasW, 0, 0);
    EXPECT_EQ(p.r, 70);
    EXPECT_EQ(p.g, 60);
    EXPECT_EQ(p.b, 50);
    EXPECT_EQ(p.a, 80);
  }

  std::filesystem::remove(path);
}
