#pragma once
#include <cstdio>
#include <string>
#include <vector>
#include "pcmat/format.h"

namespace pcmat {

class Writer {
 public:
  Writer(const std::wstring& path, uint32_t width, uint32_t height, uint32_t timeBaseDen);
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
