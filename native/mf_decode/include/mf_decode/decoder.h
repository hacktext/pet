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

  // NextFrame 对干净的流结束和中途解码失败都返回 false；调用方需要靠这个
  // 区分二者。干净结束不会置位；ReadSample 失败或拿到不带
  // MF_SOURCE_READERF_ENDOFSTREAM 标志的空样本时置位。
  bool hadError() const { return hadError_; }

 private:
  Decoder() = default;
  IMFSourceReader* reader_ = nullptr;
  VideoInfo info_{};
  uint64_t lastPts_ = 0;
  bool hadError_ = false;
};

}  // namespace mfd
