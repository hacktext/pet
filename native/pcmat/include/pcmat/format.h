#pragma once
#include <cstdint>
#include <cstddef>

namespace pcmat {

inline constexpr char kMagic[8] = {'A','I','P','M','A','T','1','\0'};
inline constexpr uint32_t kHeaderSize = 128;
inline constexpr uint32_t kIndexEntrySize = 48;
inline constexpr uint32_t kSchemaVersion = 1;
inline constexpr uint32_t kFlagLz4 = 1u << 0;

#pragma pack(push, 1)
struct Header {
  char     magic[8];
  uint32_t schemaVersion;
  uint32_t headerSize;
  uint32_t flags;
  uint32_t width;
  uint32_t height;
  uint32_t timeBaseDen;
  uint32_t frameCount;
  uint64_t indexOffset;
  uint64_t indexSize;
  uint64_t manifestOffset;
  uint64_t manifestSize;
  uint8_t  reserved[60];  // 写入时始终清零；读取时忽略
};

struct FrameIndex {
  uint64_t ptsTicks;
  uint64_t durationTicks;
  uint64_t byteOffset;
  uint32_t byteSize;   // 压缩后
  uint32_t rawSize;    // 解压后
  uint16_t cropX, cropY, cropW, cropH;
  uint8_t  reserved[8];   // 写入时始终清零；读取时忽略
};
#pragma pack(pop)

static_assert(sizeof(Header) == kHeaderSize, "Header must be 128 bytes");
static_assert(sizeof(FrameIndex) == kIndexEntrySize, "FrameIndex must be 48 bytes");

}  // namespace pcmat
