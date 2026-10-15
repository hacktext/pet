#include "pet_matte/pet_matte.h"

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#include "matte_core/chroma_key.h"
#include "matte_core/crop.h"
#include "matte_core/despill.h"
#include "mf_decode/decoder.h"
#include "pcmat/writer.h"

namespace {

static_assert(kMaxCacheEdge > kDefaultCacheEdge,
              "kMaxCacheEdge must exceed kDefaultCacheEdge -- the ceiling has to leave room "
              "above the default it's meant to bound");

std::string g_lastError;

// 最近邻缩放，BGRA 紧密打包。抠像前做，降低后续所有逐像素运算的成本。
void ResizeNearest(const std::vector<uint8_t>& src, int sw, int sh,
                   std::vector<uint8_t>& dst, int dw, int dh) {
  dst.resize(static_cast<size_t>(dw) * dh * 4);
  for (int y = 0; y < dh; ++y) {
    const int sy = y * sh / dh;
    const uint8_t* srow = src.data() + static_cast<size_t>(sy) * sw * 4;
    uint8_t* drow = dst.data() + static_cast<size_t>(y) * dw * 4;
    for (int x = 0; x < dw; ++x) {
      const int sx = x * sw / dw;
      std::memcpy(drow + static_cast<size_t>(x) * 4,
                  srow + static_cast<size_t>(sx) * 4, 4);
    }
  }
}

}  // namespace

extern "C" {

int32_t pet_matte_abi_version(void) { return 1; }

const char* pet_matte_last_error(void) { return g_lastError.c_str(); }

int32_t pet_matte_prepare(const pet_matte_char* srcMp4, const pet_matte_char* dstAipmat, uint32_t targetEdge) {
  g_lastError.clear();

  // 校验放在最前面，早于打开/解码源视频：这是纯粹的入参校验，不依赖源
  // 视频的任何状态，失败不该先付出打开解码器的代价。越界值（比如 Dart 侧
  // 把负数塞进 uint32_t 后回绕出的 42 亿）如果不在这里挡住，会一路经
  // static_cast<int> 变成负的 dw/dh，让所有逐像素循环全部空转、AlphaBounds
  // 返回空、落地一个 1x1 占位帧，写盘的 header 却记录着那个天文数字宽高，
  // Reader::Open 读到后据此分配画布直接 bad_alloc 崩溃。
  if (targetEdge > kMaxCacheEdge) {
    g_lastError = "targetEdge out of range [0, " + std::to_string(kMaxCacheEdge) + "]";
    return -2;
  }
  const uint32_t edge = targetEdge ? targetEdge : kDefaultCacheEdge;

  auto dec = mfd::Decoder::Open(srcMp4);
  if (!dec.has_value()) { g_lastError = "cannot open source video"; return -1; }

  const int sw = static_cast<int>(dec->info().width);
  const int sh = static_cast<int>(dec->info().height);
  if (sw <= 0 || sh <= 0) { g_lastError = "invalid source dimensions"; return -2; }

  const int dw = static_cast<int>(edge);
  const int dh = static_cast<int>(edge);

  pcmat::Writer writer(dstAipmat, static_cast<uint32_t>(dw), static_cast<uint32_t>(dh), 10000000);
  if (!writer.ok()) { g_lastError = "cannot open destination"; return -3; }

  std::vector<uint8_t> src, work, packed;
  uint64_t pts = 0, dur = 0;
  uint32_t frames = 0;

  while (dec->NextFrame(src, pts, dur)) {
    if (dw != sw || dh != sh) ResizeNearest(src, sw, sh, work, dw, dh);
    else work = src;

    matte::BgraImage img{work.data(), dw, dh, dw * 4};
    matte::ApplyChromaKey(img, matte::KeyParams{});
    matte::ApplyDespill(img);
    matte::PremultiplyAlpha(img);

    matte::Rect r = matte::AlphaBounds(img, 8);
    if (r.w == 0 || r.h == 0) { r = matte::Rect{0, 0, 1, 1}; }  // 全透明帧存 1 像素占位

    packed.resize(static_cast<size_t>(r.w) * r.h * 4);
    matte::CopyRegion(img, r, packed.data());

    if (!writer.AddFrame(packed.data(), packed.size(), pts, dur,
                         static_cast<uint16_t>(r.x), static_cast<uint16_t>(r.y),
                         static_cast<uint16_t>(r.w), static_cast<uint16_t>(r.h))) {
      g_lastError = "frame write failed";
      return -3;
    }
    ++frames;
  }

  // NextFrame() 返回 false 对干净的流结束和中途解码失败一视同仁；hadError()
  // 区分二者。中途失败绝不能被当成"提前结束但成功"，否则会写出一个帧数不全
  // 却报告成功的 .aipmat，且再也不会重试。必须在 Finish() 之前判定，
  // 这样失败时不会落地一个看似完整的部分文件。
  if (dec->hadError()) { g_lastError = "decode failed before end of stream"; return -2; }
  if (frames == 0) { g_lastError = "no frames decoded"; return -2; }

  const std::string manifest =
      std::string("{\"pipeline\":\"aipet-green-matte-3\",\"frames\":") +
      std::to_string(frames) + "}";
  if (!writer.Finish(manifest)) { g_lastError = "finalize failed"; return -3; }
  return 0;
}

}  // extern "C"
