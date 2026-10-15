#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
#include "pcmat/reader.h"

namespace frame_source {

class FrameSource {
 public:
  bool Load(const native_path::Path& path);
  uint32_t width() const { return reader_ ? reader_->header().width : 0; }
  uint32_t height() const { return reader_ ? reader_->header().height : 0; }
  uint32_t frameCount() const { return reader_ ? reader_->header().frameCount : 0; }

  // 把第 i 帧展开成整幅 RGBA 画布；返回内部缓冲，下次调用即失效。
  // 越界的帧号、解压失败，或索引项的 crop 矩形对不上画布/负载大小
  // （文件损坏或手工构造的异常索引），一律返回 nullptr 而不是越界写入。
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

}  // namespace frame_source
