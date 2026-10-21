#pragma once
#include <cstdint>
#include <vector>

namespace frame_source {

// A coarse copy of one frame's alpha, for asking "is the pet under this
// point?" without touching the frame again: the pet window passes clicks on
// its transparent pixels through to whatever is behind it.
//
// Capture() runs on the render thread with the frame it just drew;
// OpaqueAt() runs on the platform thread. HitMask itself is not locked --
// the plugin holds a mutex around both.
class HitMask {
 public:
  // Every step-th pixel's alpha of a w x h RGBA frame (alpha at byte 3).
  void Capture(const uint8_t* rgba, uint32_t w, uint32_t h, uint32_t step);

  // (u, v) in [0, 1] across the frame, left to right and top to bottom.
  // True when a sample with alpha >= threshold lies within radius (a
  // fraction of the frame's width) of it. Empty or outside: false.
  bool OpaqueAt(double u, double v, double radius, uint8_t threshold = 32) const;

  bool empty() const { return alpha_.empty(); }
  uint32_t width() const { return w_; }
  uint32_t height() const { return h_; }

 private:
  std::vector<uint8_t> alpha_;
  uint32_t w_ = 0;
  uint32_t h_ = 0;
};

}  // namespace frame_source
