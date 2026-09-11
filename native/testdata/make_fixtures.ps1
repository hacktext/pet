# 合成一个确定性的绿幕测试片：320x320，24fps，1 秒 24 帧，
# 纯绿底 + 一个 100x100 白方块每帧右移 6px。
# 背景用纯绿 0x00FF00：实测真实宠物素材背景就是 (8,239,8)/(2,251,3)，基本纯绿。
# 必须用 overlay 而不是 drawbox：ffmpeg 8.1 的 drawbox 坐标表达式不支持逐帧变量
# (n/t)，写了会报 "Undefined constant"，方块根本画不出来。overlay 的 x/y 支持 n。
# 方块固定在 y=40（不是画面正中）：这样一旦解码上下颠倒，方块会落到完全不同
# 的行区间（[180,279] 而不是 [40,139]），DecodesFrameRightSideUp 测试才测得出
# 真实的垂直翻转，而不是恰好上下对称测不出来。
# overlay 之后再过一道很轻的 gblur（sigma=1）：overlay 的两路输入都已经是
# yuv420p（"color=" 源直接产出 yuv420p，从不经过 RGB 中间层），合成只是整块
# 覆盖，色度子采样边界从不会真正跨越方块的硬边——实测无论方块坐标取奇数
# 偶数，全画布 alpha 都是死板的 0/255 二值，Pipeline.FringePixelsArePremultiplied
# 想测的"0 < a < 255 过渡像素"永远不会出现。gblur 在 RGB 硬边上真正掺入
# 相邻像素，制造出接近真实素材（真实拍摄/合成素材边缘都有类似的反走样）
# 的渐变色度，chroma-key 才会算出介于 0 和 255 之间的 alpha。sigma=1 足够小，
# 不影响 BackgroundIsKeyedOutAndBoxSurvives 的包围盒容差（80~130）。
$ErrorActionPreference = "Stop"
$out = Join-Path $PSScriptRoot "green_box.mp4"
ffmpeg -y -f lavfi -i "color=c=0x00FF00:s=320x320:d=1:r=24" `
  -f lavfi -i "color=c=white:s=100x100:d=1:r=24" `
  -filter_complex "[0:v][1:v]overlay=x='40+n*6':y=40:shortest=1,gblur=sigma=1" `
  -c:v libx264 -pix_fmt yuv420p -an $out
Write-Host "wrote $out"

# A slow fixture for the async-prepare test: 1280x1280, 5 s, so a blocking
# prepare holds the platform thread long enough to measure.
$long = Join-Path $PSScriptRoot "green_box_long.mp4"
ffmpeg -y -f lavfi -i "color=c=0x00FF00:s=1280x1280:d=5:r=24" `
  -f lavfi -i "color=c=white:s=300x300:d=5:r=24" `
  -filter_complex "[0:v][1:v]overlay=x='100+n*6':y=200:shortest=1,gblur=sigma=1" `
  -c:v libx264 -pix_fmt yuv420p -an $long
Write-Host "wrote $long"
