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
