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
