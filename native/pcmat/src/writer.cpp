#include "pcmat/writer.h"
#include <cstring>
#include <lz4.h>

namespace pcmat {

Writer::Writer(const std::wstring& path, uint32_t width, uint32_t height, uint32_t timeBaseDen)
    : path_(path) {
  // Windows 路径原生是 UTF-16；用 _wfopen 保持宽字符，避免经 ANSI 代码页
  // 转换丢失路径中的非 ASCII 字符（例如用户名含中文的 %APPDATA% 路径）。
  file_ = _wfopen(path.c_str(), L"wb");
  if (!file_) return;
  std::memset(&header_, 0, sizeof(header_));
  std::memcpy(header_.magic, kMagic, 8);
  header_.schemaVersion = kSchemaVersion;
  header_.headerSize = kHeaderSize;
  header_.flags = kFlagLz4;
  header_.width = width;
  header_.height = height;
  header_.timeBaseDen = timeBaseDen;
  // 头部占位，Finish 时回填。这里也要检查写入是否成功：写不全的话后面
  // AddFrame/Finish 记录的 cursor_ 全部建立在错误的假设上，与其让调用方
  // 之后在一个看起来"打开成功"实则残缺的文件上继续走完整条流水线，不如
  // 现在就让 ok() 返回 false。
  std::vector<uint8_t> zero(kHeaderSize, 0);
  if (fwrite(zero.data(), 1, kHeaderSize, file_) != kHeaderSize) {
    fclose(file_);
    file_ = nullptr;
    _wremove(path_.c_str());
    return;
  }
  cursor_ = kHeaderSize;
}

Writer::~Writer() { if (file_) fclose(file_); }

bool Writer::FailFinish() {
  if (file_) { fclose(file_); file_ = nullptr; }
  _wremove(path_.c_str());
  return false;
}

bool Writer::AddFrame(const uint8_t* bgra, size_t size, uint64_t ptsTicks, uint64_t durTicks,
                      uint16_t cropX, uint16_t cropY, uint16_t cropW, uint16_t cropH) {
  if (!file_ || size == 0) return false;
  const int bound = LZ4_compressBound(static_cast<int>(size));
  std::vector<char> buf(static_cast<size_t>(bound));
  const int n = LZ4_compress_default(reinterpret_cast<const char*>(bgra), buf.data(),
                                     static_cast<int>(size), bound);
  if (n <= 0) return false;
  if (fwrite(buf.data(), 1, static_cast<size_t>(n), file_) != static_cast<size_t>(n)) return false;

  FrameIndex fi{};
  fi.ptsTicks = ptsTicks;
  fi.durationTicks = durTicks;
  fi.byteOffset = cursor_;
  fi.byteSize = static_cast<uint32_t>(n);
  fi.rawSize = static_cast<uint32_t>(size);
  fi.cropX = cropX; fi.cropY = cropY; fi.cropW = cropW; fi.cropH = cropH;
  index_.push_back(fi);
  cursor_ += static_cast<uint64_t>(n);
  return true;
}

bool Writer::Finish(const std::string& manifestJson) {
  if (!file_) return false;
  header_.frameCount = static_cast<uint32_t>(index_.size());
  header_.indexOffset = cursor_;
  header_.indexSize = static_cast<uint64_t>(index_.size()) * kIndexEntrySize;
  if (!index_.empty() &&
      fwrite(index_.data(), kIndexEntrySize, index_.size(), file_) != index_.size()) {
    return FailFinish();
  }
  cursor_ += header_.indexSize;

  header_.manifestOffset = cursor_;
  header_.manifestSize = manifestJson.size();
  if (!manifestJson.empty() &&
      fwrite(manifestJson.data(), 1, manifestJson.size(), file_) != manifestJson.size()) {
    return FailFinish();
  }

  fseek(file_, 0, SEEK_SET);
  if (fwrite(&header_, 1, kHeaderSize, file_) != kHeaderSize) return FailFinish();

  // fclose 才是真正把 stdio 那几 KB 缓冲区落盘的地方；忽略它的返回值会让
  // 磁盘满之类的晚期失败被当成成功——Finish() 返回 true、prepare() 返回 0，
  // 但 .aipmat 其实被截断了，失败要等到之后 open() 读它的时候才会以一个
  // 无法解释的"cannot read aipmat"冒出来，而那时磁盘写入现场早就没了。
  if (fclose(file_) != 0) {
    file_ = nullptr;
    _wremove(path_.c_str());
    return false;
  }
  file_ = nullptr;
  return true;
}

}  // namespace pcmat
