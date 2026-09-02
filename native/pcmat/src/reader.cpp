#include "pcmat/reader.h"
#include <cstdio>
#include <cstring>
#include <lz4.h>

namespace pcmat {

std::optional<Reader> Reader::Open(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return std::nullopt;
  fseek(f, 0, SEEK_END);
  const long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (len < static_cast<long>(kHeaderSize)) { fclose(f); return std::nullopt; }

  Reader r;
  r.blob_.resize(static_cast<size_t>(len));
  const size_t got = fread(r.blob_.data(), 1, r.blob_.size(), f);
  fclose(f);
  if (got != r.blob_.size()) return std::nullopt;

  std::memcpy(&r.header_, r.blob_.data(), kHeaderSize);
  if (std::memcmp(r.header_.magic, kMagic, 8) != 0) return std::nullopt;
  if (r.header_.headerSize != kHeaderSize) return std::nullopt;
  if (r.header_.indexOffset + r.header_.indexSize > r.blob_.size()) return std::nullopt;
  if (r.header_.indexSize != static_cast<uint64_t>(r.header_.frameCount) * kIndexEntrySize)
    return std::nullopt;

  r.index_.resize(r.header_.frameCount);
  if (r.header_.frameCount)
    std::memcpy(r.index_.data(), r.blob_.data() + r.header_.indexOffset, r.header_.indexSize);

  if (r.header_.manifestOffset + r.header_.manifestSize > r.blob_.size()) return std::nullopt;
  r.manifest_.assign(reinterpret_cast<const char*>(r.blob_.data() + r.header_.manifestOffset),
                     static_cast<size_t>(r.header_.manifestSize));
  return r;
}

bool Reader::ReadFrame(uint32_t i, std::vector<uint8_t>& out) const {
  if (i >= index_.size()) return false;
  const FrameIndex& fi = index_[i];
  if (fi.byteOffset + fi.byteSize > blob_.size()) return false;
  out.resize(fi.rawSize);
  const int n = LZ4_decompress_safe(
      reinterpret_cast<const char*>(blob_.data() + fi.byteOffset),
      reinterpret_cast<char*>(out.data()),
      static_cast<int>(fi.byteSize), static_cast<int>(fi.rawSize));
  return n == static_cast<int>(fi.rawSize);
}

}  // namespace pcmat
