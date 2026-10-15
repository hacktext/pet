#pragma once
#include <cstdio>
#include <string>
#include <vector>
#include "native_path/native_path.h"
#include "pcmat/format.h"

namespace pcmat {

class Writer {
 public:
  Writer(const native_path::Path& path, uint32_t width, uint32_t height, uint32_t timeBaseDen);
  ~Writer();
  Writer(const Writer&) = delete;
  Writer& operator=(const Writer&) = delete;

  bool ok() const { return file_ != nullptr; }
  bool AddFrame(const uint8_t* bgra, size_t size, uint64_t ptsTicks, uint64_t durTicks,
                uint16_t cropX, uint16_t cropY, uint16_t cropW, uint16_t cropH);
  bool Finish(const std::string& manifestJson);

 private:
  // 关闭（如果还开着）当前文件句柄并删除 path_ 指向的文件，然后返回 false。
  // Finish() 的每一条失败路径都要走这里：写到一半失败的 .aipmat 不能留在
  // 磁盘上冒充一个完整文件。
  bool FailFinish();

  FILE* file_ = nullptr;
  native_path::Path path_;
  Header header_{};
  std::vector<FrameIndex> index_;
  uint64_t cursor_ = 0;
};

}  // namespace pcmat
