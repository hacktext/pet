#include <gtest/gtest.h>
#include "pcmat/format.h"

TEST(Format, HeaderIsExactly128Bytes) {
  EXPECT_EQ(sizeof(pcmat::Header), 128u);
  EXPECT_EQ(pcmat::kHeaderSize, 128u);
}

TEST(Format, IndexEntryIsExactly48Bytes) {
  EXPECT_EQ(sizeof(pcmat::FrameIndex), 48u);
  EXPECT_EQ(pcmat::kIndexEntrySize, 48u);
}

TEST(Format, MagicIsAipmat1) {
  EXPECT_EQ(std::string(pcmat::kMagic, 8), std::string("AIPMAT1\0", 8));
}
