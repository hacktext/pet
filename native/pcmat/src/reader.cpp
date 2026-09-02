#include "pcmat/reader.h"
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <system_error>
#include <lz4.h>

namespace pcmat {

namespace {
// 校验 [offset, offset+size) 是否落在 [0, total) 区间内。
// 不能写成 "offset + size > total"：offset/size 都是磁盘上的不可信 64 位字段，
// 加法本身就可能无符号回绕成一个很小的值，从而绕过检查。
bool InBounds(uint64_t offset, uint64_t size, uint64_t total) {
  return offset <= total && size <= total - offset;
}
}  // namespace

std::optional<Reader> Reader::Open(const std::wstring& path) {
  // ftell 在 MSVC/Windows(LLP64) 下返回 32 位 long，无法表示 >= 2GiB 的文件；
  // 用 std::filesystem::file_size 取 64 位真实大小。std::filesystem::path 在
  // Windows 上原生存储宽字符，这里直接传 wstring 不涉及任何编码转换。
  std::error_code ec;
  const uint64_t len = std::filesystem::file_size(path, ec);
  if (ec || len < static_cast<uint64_t>(kHeaderSize)) return std::nullopt;

  // 同样用 _wfopen 保持宽字符，避免经 ANSI 代码页转换丢失非 ASCII 路径。
  FILE* f = _wfopen(path.c_str(), L"rb");
  if (!f) return std::nullopt;

  Reader r;
  r.blob_.resize(static_cast<size_t>(len));
  const size_t got = fread(r.blob_.data(), 1, r.blob_.size(), f);
  fclose(f);
  if (got != r.blob_.size()) return std::nullopt;

  std::memcpy(&r.header_, r.blob_.data(), kHeaderSize);
  if (std::memcmp(r.header_.magic, kMagic, 8) != 0) return std::nullopt;
  if (r.header_.headerSize != kHeaderSize) return std::nullopt;
  if (!InBounds(r.header_.indexOffset, r.header_.indexSize, r.blob_.size())) return std::nullopt;
  if (r.header_.indexSize != static_cast<uint64_t>(r.header_.frameCount) * kIndexEntrySize)
    return std::nullopt;

  r.index_.resize(r.header_.frameCount);
  if (r.header_.frameCount)
    std::memcpy(r.index_.data(), r.blob_.data() + r.header_.indexOffset, r.header_.indexSize);

  if (!InBounds(r.header_.manifestOffset, r.header_.manifestSize, r.blob_.size()))
    return std::nullopt;
  r.manifest_.assign(reinterpret_cast<const char*>(r.blob_.data() + r.header_.manifestOffset),
                     static_cast<size_t>(r.header_.manifestSize));
  return r;
}

bool Reader::ReadFrame(uint32_t i, std::vector<uint8_t>& out) const {
  if (i >= index_.size()) return false;
  const FrameIndex& fi = index_[i];
  if (!InBounds(fi.byteOffset, fi.byteSize, blob_.size())) return false;

  // rawSize 也是磁盘上的不可信字段：损坏的索引条目可能声称解压后有数 GiB，
  // 触发一次失控的大分配并以未捕获的 bad_alloc 崩溃。单帧解压后大小不可能
  // 超过 header 记录的画布容量（BGRA8：width*height*4）。
  const uint64_t maxRaw = static_cast<uint64_t>(header_.width) * header_.height * 4;
  if (static_cast<uint64_t>(fi.rawSize) > maxRaw) return false;

  out.resize(fi.rawSize);
  const int n = LZ4_decompress_safe(
      reinterpret_cast<const char*>(blob_.data() + fi.byteOffset),
      reinterpret_cast<char*>(out.data()),
      static_cast<int>(fi.byteSize), static_cast<int>(fi.rawSize));
  return n == static_cast<int>(fi.rawSize);
}

}  // namespace pcmat
