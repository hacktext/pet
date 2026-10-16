#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "native_path/native_path.h"

#ifdef _WIN32
struct IMFSourceReader;
#endif

namespace mfd {

#ifndef _WIN32
// macOS：AVAssetReader 及其 track output，定义在 avf_decode/src/decoder.mm。
struct AvfReader;
#endif

struct VideoInfo {
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t frameCount = 0;      // 已知则填，未知为 0
  uint64_t durationTicks = 0;   // 100ns 单位
};

class Decoder {
 public:
  static std::optional<Decoder> Open(const native_path::Path& path);
  Decoder(Decoder&&) noexcept;
  Decoder& operator=(Decoder&&) noexcept;
  Decoder(const Decoder&) = delete;
  Decoder& operator=(const Decoder&) = delete;
  ~Decoder();

  const VideoInfo& info() const { return info_; }
  // 输出紧密打包的 BGRA32（stride = width*4）。流结束返回 false。
  bool NextFrame(std::vector<uint8_t>& bgra, uint64_t& ptsTicks, uint64_t& durTicks);

  // NextFrame 对干净的流结束和中途解码失败都返回 false；调用方需要靠这个
  // 区分二者。不变量：除了带 MF_SOURCE_READERF_ENDOFSTREAM 标志的干净结束，
  // NextFrame 的任何其他 false 返回路径都必须先置位 hadError_ 再返回——
  // 无论失败发生在 ReadSample、样本本身、还是样本解出来之后的缓冲区处理
  // 阶段。新增一条退出路径时，先问它是不是干净结束；不是的话就必须置位，
  // 不要在这里为具体机制列举白名单（历史上枚举过两种机制，结果后来新增的
  // 三条退出路径全部被漏掉，见最终评审 C-1）。
  bool hadError() const { return hadError_; }

 private:
  Decoder() = default;
#ifdef _WIN32
  IMFSourceReader* reader_ = nullptr;
#else
  AvfReader* reader_ = nullptr;
#endif
  VideoInfo info_{};
  uint64_t lastPts_ = 0;
  bool hadError_ = false;
};

}  // namespace mfd
