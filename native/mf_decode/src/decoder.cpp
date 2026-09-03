#include "mf_decode/decoder.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <cstring>

namespace mfd {
namespace {

struct MfRuntime {
  MfRuntime()  { MFStartup(MF_VERSION); }
  ~MfRuntime() { MFShutdown(); }
};
// 进程内只初始化一次
void EnsureMfStarted() { static MfRuntime rt; }

}  // namespace

std::optional<Decoder> Decoder::Open(const std::wstring& path) {
  EnsureMfStarted();

  IMFAttributes* attrs = nullptr;
  if (FAILED(MFCreateAttributes(&attrs, 1))) return std::nullopt;
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);

  IMFSourceReader* reader = nullptr;
  HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), attrs, &reader);
  attrs->Release();
  if (FAILED(hr) || !reader) return std::nullopt;

  // 输出协商为 BGRA32
  IMFMediaType* outType = nullptr;
  if (FAILED(MFCreateMediaType(&outType))) { reader->Release(); return std::nullopt; }
  outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  outType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  hr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, outType);
  outType->Release();
  if (FAILED(hr)) { reader->Release(); return std::nullopt; }

  IMFMediaType* cur = nullptr;
  if (FAILED(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur))) {
    reader->Release(); return std::nullopt;
  }
  Decoder d;
  d.reader_ = reader;
  UINT32 w = 0, h = 0;
  if (FAILED(MFGetAttributeSize(cur, MF_MT_FRAME_SIZE, &w, &h))) {
    cur->Release();
    return std::nullopt;  // d 析构时会释放 reader_
  }
  cur->Release();
  d.info_.width = w;
  d.info_.height = h;

  PROPVARIANT var;
  if (SUCCEEDED(reader->GetPresentationAttribute(
          MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &var))) {
    d.info_.durationTicks = var.uhVal.QuadPart;
    PropVariantClear(&var);
  }
  return d;
}

Decoder::Decoder(Decoder&& o) noexcept
    : reader_(o.reader_), info_(o.info_), lastPts_(o.lastPts_), hadError_(o.hadError_) {
  o.reader_ = nullptr;
}

Decoder& Decoder::operator=(Decoder&& o) noexcept {
  if (this != &o) {
    if (reader_) reader_->Release();
    reader_ = o.reader_; info_ = o.info_; lastPts_ = o.lastPts_; hadError_ = o.hadError_;
    o.reader_ = nullptr;
  }
  return *this;
}

Decoder::~Decoder() { if (reader_) reader_->Release(); }

bool Decoder::NextFrame(std::vector<uint8_t>& bgra, uint64_t& ptsTicks, uint64_t& durTicks) {
  if (!reader_) return false;
  DWORD flags = 0;
  LONGLONG ts = 0;
  IMFSample* sample = nullptr;
  HRESULT hr = reader_->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                                   nullptr, &flags, &ts, &sample);
  if (FAILED(hr)) { hadError_ = true; return false; }
  if (flags & MF_SOURCE_READERF_ENDOFSTREAM) { if (sample) sample->Release(); return false; }
  if (!sample) { hadError_ = true; return false; }

  IMFMediaBuffer* buf = nullptr;
  if (FAILED(sample->ConvertToContiguousBuffer(&buf))) {
    hadError_ = true; sample->Release(); return false;
  }

  const size_t rowBytes = static_cast<size_t>(info_.width) * 4;

  BYTE* data = nullptr;
  DWORD maxLen = 0, curLen = 0;
  LONG stride = static_cast<LONG>(info_.width) * 4;
  bool lockedWith2D = false;
  bool lockedPlain = false;

  IMF2DBuffer* buf2d = nullptr;
  if (SUCCEEDED(buf->QueryInterface(IID_PPV_ARGS(&buf2d)))) {
    if (SUCCEEDED(buf2d->Lock2D(&data, &stride))) lockedWith2D = true;
  }
  if (!lockedWith2D) {
    if (FAILED(buf->Lock(&data, &maxLen, &curLen))) {
      hadError_ = true;
      if (buf2d) buf2d->Release();
      buf->Release(); sample->Release(); return false;
    }
    lockedPlain = true;
    // 平铺路径假定 stride == width*4；用 curLen 校验缓冲区确实够大，
    // 否则按假定 stride 拷贝会读到锁定范围之外。
    if (static_cast<size_t>(curLen) < rowBytes * info_.height) {
      hadError_ = true;
      buf->Unlock();
      if (buf2d) buf2d->Release();
      buf->Release(); sample->Release(); return false;
    }
  }

  bgra.resize(rowBytes * info_.height);
  // ppbScanline0(data) 始终指向可视上排；stride 的正负号已经编码了行走向
  // （正数向下、负数向上），直接用有符号步长逐行定位即可，无需再手动按
  // 符号分支反向遍历。
  for (uint32_t y = 0; y < info_.height; ++y)
    std::memcpy(bgra.data() + y * rowBytes,
                data + static_cast<ptrdiff_t>(stride) * y, rowBytes);
  // RGB32 的第 4 字节未必是 255，统一置为不透明
  for (size_t i = 3; i < bgra.size(); i += 4) bgra[i] = 255;

  // 清理只解锁实际锁定的那条路径；buf2d 的释放与是否锁定无关。
  if (lockedWith2D) buf2d->Unlock2D();
  else if (lockedPlain) buf->Unlock();
  if (buf2d) buf2d->Release();
  buf->Release();

  LONGLONG dur = 0;
  if (FAILED(sample->GetSampleDuration(&dur))) dur = 0;
  sample->Release();

  ptsTicks = static_cast<uint64_t>(ts);
  durTicks = static_cast<uint64_t>(dur);
  lastPts_ = ptsTicks;
  return true;
}

}  // namespace mfd
