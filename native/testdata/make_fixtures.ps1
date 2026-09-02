# 合成一个确定性的绿幕测试片：320x320，24fps，1 秒 24 帧，
# 纯绿底 + 一个 100x100 白方块每帧右移 6px。
# 背景用纯绿 0x00FF00：实测真实宠物素材背景就是 (8,239,8)/(2,251,3)，基本纯绿。
# 必须用 overlay 而不是 drawbox：ffmpeg 8.1 的 drawbox 坐标表达式不支持逐帧变量
# (n/t)，写了会报 "Undefined constant"，方块根本画不出来。overlay 的 x/y 支持 n。
# 方块固定在 y=40（不是画面正中）：这样一旦解码上下颠倒，方块会落到完全不同
# 的行区间（[180,279] 而不是 [40,139]），DecodesFrameRightSideUp 测试才测得出
# 真实的垂直翻转，而不是恰好上下对称测不出来。
$ErrorActionPreference = "Stop"
$out = Join-Path $PSScriptRoot "green_box.mp4"
ffmpeg -y -f lavfi -i "color=c=0x00FF00:s=320x320:d=1:r=24" `
  -f lavfi -i "color=c=white:s=100x100:d=1:r=24" `
  -filter_complex "[0:v][1:v]overlay=x='40+n*6':y=40:shortest=1" `
  -c:v libx264 -pix_fmt yuv420p -an $out
Write-Host "wrote $out"
