#include "pet_matte/pet_matte.h"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "matte_core/chroma_key.h"
#include "matte_core/crop.h"
#include "matte_core/despill.h"
#include "mf_decode/decoder.h"
#include "pcmat/writer.h"

namespace {

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

int32_t pet_matte_prepare(const wchar_t* srcMp4, const wchar_t* dstAipmat, uint32_t targetEdge) {
  g_lastError.clear();

  auto dec = mfd::Decoder::Open(srcMp4);
  if (!dec.has_value()) { g_lastError = "cannot open source video"; return -1; }

  const int sw = static_cast<int>(dec->info().width);
  const int sh = static_cast<int>(dec->info().height);
  if (sw <= 0 || sh <= 0) { g_lastError = "invalid source dimensions"; return -2; }

  const int dw = targetEdge ? static_cast<int>(targetEdge) : sw;
  const int dh = targetEdge ? static_cast<int>(targetEdge) : sh;

  pcmat::Writer writer(std::filesystem::path(dstAipmat).string(),
                       static_cast<uint32_t>(dw), static_cast<uint32_t>(dh), 10000000);
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

  if (frames == 0) { g_lastError = "no frames decoded"; return -2; }

  const std::string manifest =
      std::string("{\"pipeline\":\"aipet-green-matte-1\",\"frames\":") +
      std::to_string(frames) + "}";
  if (!writer.Finish(manifest)) { g_lastError = "finalize failed"; return -3; }
  return 0;
}

}  // extern "C"
