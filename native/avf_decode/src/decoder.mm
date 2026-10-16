// macOS 版 mfd::Decoder：AVAssetReader 解码成 32BGRA，接口与 Windows 的
// Media Foundation 实现（mf_decode/src/decoder.cpp）一致。必须以 ARC 编译：
// AvfReader 里的 Objective-C 成员靠 ARC 管理引用计数。
#include "mf_decode/decoder.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <cstring>
#include <system_error>

#if !__has_feature(objc_arc)
#error "avf_decode/src/decoder.mm must be compiled with -fobjc-arc"
#endif

namespace mfd {

struct AvfReader {
  AVAssetReader* reader = nil;
  AVAssetReaderTrackOutput* output = nil;
  uint64_t fallbackDurTicks = 0;  // 样本自身没有时长时，按标称帧率推算
};

namespace {

constexpr int32_t kTicksPerSecond = 10000000;  // 100ns 单位，与 Windows 一致

uint64_t ToTicks(CMTime t) {
  if (!CMTIME_IS_NUMERIC(t) || t.value < 0) return 0;
  return static_cast<uint64_t>(
      CMTimeConvertScale(t, kTicksPerSecond, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value);
}

}  // namespace

std::optional<Decoder> Decoder::Open(const native_path::Path& path) {
  @autoreleasepool {
    std::error_code ec;
    if (!std::filesystem::is_regular_file(path, ec)) return std::nullopt;

    NSString* str = [NSString stringWithUTF8String:path.c_str()];
    if (!str) return std::nullopt;
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:str] options:nil];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // 同步接口在 macOS 15 起标为弃用，但仍可用；这里本来就是在工作线程上同步解码。
    NSArray<AVAssetTrack*>* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return std::nullopt;
    AVAssetTrack* track = tracks.firstObject;
    const CGSize size = track.naturalSize;
    const float fps = track.nominalFrameRate;
    const CMTime duration = asset.duration;
#pragma clang diagnostic pop

    NSError* err = nil;
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader || err) return std::nullopt;

    NSDictionary* settings = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    };
    AVAssetReaderTrackOutput* output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return std::nullopt;
    [reader addOutput:output];
    if (![reader startReading]) return std::nullopt;

    Decoder d;
    d.reader_ = new AvfReader{reader, output,
                              fps > 0 ? static_cast<uint64_t>(kTicksPerSecond / fps + 0.5) : 0};
    d.info_.width = static_cast<uint32_t>(size.width + 0.5);
    d.info_.height = static_cast<uint32_t>(size.height + 0.5);
    d.info_.durationTicks = ToTicks(duration);
    if (d.info_.width == 0 || d.info_.height == 0) return std::nullopt;  // d 析构时释放 reader_
    return d;
  }
}

Decoder::Decoder(Decoder&& o) noexcept
    : reader_(o.reader_), info_(o.info_), lastPts_(o.lastPts_), hadError_(o.hadError_) {
  o.reader_ = nullptr;
}

Decoder& Decoder::operator=(Decoder&& o) noexcept {
  if (this != &o) {
    delete reader_;
    reader_ = o.reader_; info_ = o.info_; lastPts_ = o.lastPts_; hadError_ = o.hadError_;
    o.reader_ = nullptr;
  }
  return *this;
}

Decoder::~Decoder() {
  if (reader_) {
    @autoreleasepool {
      if (reader_->reader.status == AVAssetReaderStatusReading) [reader_->reader cancelReading];
      delete reader_;
    }
  }
}

bool Decoder::NextFrame(std::vector<uint8_t>& bgra, uint64_t& ptsTicks, uint64_t& durTicks) {
  if (!reader_) return false;
  @autoreleasepool {
    CMSampleBufferRef sample = nullptr;
    CVImageBufferRef image = nullptr;
    // 跳过不带图像的空样本（numSamples 为 0 的标记样本）；带样本却没有图像
    // 缓冲区则算解码失败。
    while (true) {
      sample = [reader_->output copyNextSampleBuffer];
      if (!sample) {
        // 干净结束只有 Completed 一种；其余（Failed / Cancelled / 仍在 Reading）一律置错。
        if (reader_->reader.status != AVAssetReaderStatusCompleted) hadError_ = true;
        return false;
      }
      image = CMSampleBufferGetImageBuffer(sample);
      if (image) break;
      const bool empty = CMSampleBufferGetNumSamples(sample) == 0;
      CFRelease(sample);
      if (!empty) { hadError_ = true; return false; }
    }

    const size_t w = CVPixelBufferGetWidth(image);
    const size_t h = CVPixelBufferGetHeight(image);
    if (w != info_.width || h != info_.height ||
        CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
      hadError_ = true;
      CFRelease(sample);
      return false;
    }
    const uint8_t* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image));
    const size_t stride = CVPixelBufferGetBytesPerRow(image);
    const size_t rowBytes = w * 4;
    if (!base || stride < rowBytes) {
      hadError_ = true;
      CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
      CFRelease(sample);
      return false;
    }

    // 行跨度可能带对齐填充，逐行拷成紧密打包（stride = width*4）。
    bgra.resize(rowBytes * h);
    for (size_t y = 0; y < h; ++y) std::memcpy(bgra.data() + y * rowBytes, base + y * stride, rowBytes);
    for (size_t i = 3; i < bgra.size(); i += 4) bgra[i] = 255;
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);

    ptsTicks = ToTicks(CMSampleBufferGetPresentationTimeStamp(sample));
    const uint64_t dur = ToTicks(CMSampleBufferGetDuration(sample));
    durTicks = dur ? dur : reader_->fallbackDurTicks;
    CFRelease(sample);
    lastPts_ = ptsTicks;
    return true;
  }
}

}  // namespace mfd
