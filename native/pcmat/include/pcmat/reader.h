#pragma once
#include <optional>
#include <string>
#include <vector>
#include "native_path/native_path.h"
#include "pcmat/format.h"

namespace pcmat {

class Reader {
 public:
  static std::optional<Reader> Open(const native_path::Path& path);

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
