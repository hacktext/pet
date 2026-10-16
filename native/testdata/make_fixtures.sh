#!/bin/sh
# macOS / Linux 版的 make_fixtures.ps1，参数与说明完全相同，见那份文件。
set -e
cd "$(dirname "$0")"
ffmpeg -y -f lavfi -i "color=c=0x00FF00:s=320x320:d=1:r=24" \
  -f lavfi -i "color=c=white:s=100x100:d=1:r=24" \
  -filter_complex "[0:v][1:v]overlay=x='40+n*6':y=40:shortest=1,gblur=sigma=1" \
  -c:v libx264 -pix_fmt yuv420p -an green_box.mp4
ffmpeg -y -f lavfi -i "color=c=0x00FF00:s=1280x1280:d=5:r=24" \
  -f lavfi -i "color=c=white:s=300x300:d=5:r=24" \
  -filter_complex "[0:v][1:v]overlay=x='100+n*6':y=200:shortest=1,gblur=sigma=1" \
  -c:v libx264 -pix_fmt yuv420p -an green_box_long.mp4
echo "wrote green_box.mp4 green_box_long.mp4"
