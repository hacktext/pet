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

  // Explicit uint8_t{0}, not a bare 0: std::fill deduces its value type from
  // the literal (int), then assigns int->uint8_t per element inside MSVC's
  // <xutility> — a narrowing conversion that this project's /W4 /WX turns
  // into a hard build error (C4244) at the library's own source line.
  std::fill(canvas_.begin(), canvas_.end(), uint8_t{0});
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
