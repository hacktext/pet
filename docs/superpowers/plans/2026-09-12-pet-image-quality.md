# 宠物画质优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让内置宠物更清晰、更亮：客户端保留 960 细节并只在边缘去溢色；petgen 新增成片处理（抠像后调色 + 高码率编码）；用改进的配方（2k 明亮参考图 + 曝光校准，std/pro 试生成后选定）重新生成金毛，柯基和布偶猫只做成片处理。

**Architecture:** 原生 `matte_core::ApplyDespill` 改为按透明度加权；Dart 侧抠像目标边长提成常量 960、缓存版本升 `p2`。petgen 新增 `finish.py`（纯 numpy/PIL + ffmpeg 管道），复用 `keycheck.alpha_map` 键控；CLI 增加 `finish` 命令和 `--tag/--mode/--resolution/--bright/--calibrate` 选项。付费生成（Task 5–6）由控制器亲自执行。

**Tech Stack:** C++17 / GoogleTest（native）；Flutter 3.47.2 / Dart 3.13.2（apps/aipet）；Python 3 + numpy + Pillow + ffmpeg（tools/petgen，venv 在 `tools\petgen\.venv`）；可灵 API（kling-v3）。

**Spec:** `docs/superpowers/specs/2026-09-12-pet-image-quality-design.md`

## Global Constraints

- 仓库根 `C:\Users\Administrator\code\aipet`，分支 `feat/aipet-main-window`，只做 Windows。
- 可灵密钥只从 `secrets\kling.env` 读，**任何日志都不得打印密钥**。
- 可灵视频余额 34 单位（2026-09-12）；std 5 秒 3 单位；pro 价格未知，以响应里的 `final_unit_deduction` 为准。**额度不够就停下来问用户，不自动降档，不续购。**
- 成片格式：960×960、24 fps、121 帧；背景纯 `#00FF00`；`petgen qa` 的 blob-core < 200、接缝规则照旧通过。
- 画质目标（成片第 30 帧、宠物主体，用 `finish.metrics` 计）：平均亮度 145–165（调色目标 155），95 分位 ≤ 235，清晰度（平均 \|拉普拉斯\|）≥ 9。
- 键控参数与 `pet_matte` 一致：keyCb −0.331、keyCr −0.419、innerT 0.28、outerT 0.45（`petgen/keycheck.py` 已复刻，复用 `alpha_map`，不要另写一份）。
- 抠像缓存目标边长 960；缓存版本 `p2`；原生清单管线标识 `aipet-green-matte-2`。
- 提交信息末尾加 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。
- Flutter 不在 PATH：每个 PowerShell 会话先执行 `$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"`。PowerShell 5.1 没有 `&&`。
- CMake：`$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"`；ctest 同目录；构建目录 `native\build`。
- 用户正在使用这台电脑：**不启动 aipet.exe，不跑会弹窗的集成测试，不发送鼠标键盘输入。** 真机验收在本计划之后另行进行。
- 工作区里有未提交的文件不属于本计划的代码任务：`HANDOFF.md`、`docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`、`tools/dev/shot.ps1`、`tools/dev/click.ps1`。Task 1–4 一律 `git add <具体路径>`，不要 `git add -A`。

---

## File Structure

```
native/matte_core/src/despill.cpp          ApplyDespill 按透明度加权（Task 1）
native/matte_core/include/matte_core/despill.h  注释更新（Task 1）
native/matte_core/tests/test_despill.cpp    新的去溢色测试（Task 1）
native/pet_matte/src/pet_matte.cpp          清单管线标识 aipet-green-matte-2（Task 1）
apps/aipet/lib/services/matte_cache.dart    kMattePipelineVersion 'p2'、kMatteTargetEdge 960（Task 2）
apps/aipet/lib/app/pet_window/pet_window_app.dart  使用 kMatteTargetEdge（Task 2）
apps/aipet/test/services/matte_cache_test.dart     键格式改为 -p2（Task 2）
tools/petgen/petgen/finish.py               成片处理：unmix / lift / solve_gamma / grade_frame / finish_clip / metrics / frame_rgb / calibrate_rgba（Task 3）
tools/petgen/tests/test_finish.py           成片处理测试（Task 3）
tools/petgen/petgen/prompts.py              pose_prompt(bright=...)（Task 4）
tools/petgen/tests/test_prompts.py          bright 提示词测试（Task 4）
tools/petgen/petgen/compose.py              compose(calibrate=...)（Task 4）
tools/petgen/petgen/__main__.py             --tag/--mode/--resolution/--bright/--calibrate、finish 命令、qa/package 用 -final（Task 4）
tools/petgen/tests/test_cli.py              任务 id 唯一性测试（Task 4）
apps/aipet/assets/pets/builtin-*/           重新打包的素材（Task 6，Git LFS）
docs/superpowers/plans/2026-09-12-pet-image-quality-results.md  试生成与全量结果（Task 5–7）
```

---

### Task 1: 去溢色只作用于半透明边缘（原生）

**Files:**
- Modify: `native/matte_core/src/despill.cpp:5-14`
- Modify: `native/matte_core/include/matte_core/despill.h`（`ApplyDespill` 的注释）
- Modify: `native/pet_matte/src/pet_matte.cpp:110`（`aipet-green-matte-1` → `aipet-green-matte-2`）
- Test: `native/matte_core/tests/test_despill.cpp`

**Interfaces:**
- Consumes: 无（`BgraImage` 来自 `matte_core/pixel.h`，alpha 在 `px[3]`；调用顺序 `ApplyChromaKey → ApplyDespill → PremultiplyAlpha` 不变）。
- Produces: `void matte::ApplyDespill(BgraImage img)` 签名不变；新语义：`G' = G − round((1 − a/255) · max(0, G − (R+B)/2))`（整数实现见下）。

- [ ] **Step 1: 改写去溢色测试（先让它失败）**

把 `native/matte_core/tests/test_despill.cpp` 里的两个 `Despill` 测试整体替换为下面四个（`Premultiply` 的三个测试保持不动）：

```cpp
TEST(Despill, TransparentGreenFringeIsPulledDownToNeighbourAverage) {
  // a = 0：与旧公式一致。B=40, G=200, R=60 → G 压到 (40+60)/2 = 50
  std::vector<uint8_t> px{40, 200, 60, 0};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 50);
  EXPECT_EQ(px[0], 40);  // B 不动
  EXPECT_EQ(px[2], 60);  // R 不动
  EXPECT_EQ(px[3], 0);   // alpha 不动
}

TEST(Despill, HalfTransparentFringeIsPulledDownByHalf) {
  // a = 128：超出量 150 只压掉 (150*127+127)/255 = 75 → G = 125
  std::vector<uint8_t> px{40, 200, 60, 128};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 125);
}

TEST(Despill, OpaqueYellowFurKeepsItsGreen) {
  // 金毛的黄色高光：G > (R+B)/2，但完全不透明，不能被压成橙色
  std::vector<uint8_t> px{120, 210, 240, 255};
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 210);
}

TEST(Despill, NonGreenDominantPixelIsUnchanged) {
  std::vector<uint8_t> px{200, 100, 220, 0};  // G 不占优，即使完全透明
  matte::BgraImage img{px.data(), 1, 1, 4};
  matte::ApplyDespill(img);
  EXPECT_EQ(px[1], 100);
}
```

- [ ] **Step 2: 构建并确认失败**

```powershell
$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
& $cmake --build C:\Users\Administrator\code\aipet\native\build --config Debug --target matte_core_tests
& "$(Split-Path $cmake)\ctest.exe" --test-dir C:\Users\Administrator\code\aipet\native\build -C Debug -R Despill --output-on-failure
```

Expected：`HalfTransparentFringeIsPulledDownByHalf`（得到 50 而不是 125）和 `OpaqueYellowFurKeepsItsGreen`（得到 180 而不是 210）失败；另两个通过。

- [ ] **Step 3: 实现**

`native/matte_core/src/despill.cpp` 中 `ApplyDespill` 替换为：

```cpp
void ApplyDespill(BgraImage img) {
  for (int y = 0; y < img.height; ++y) {
    uint8_t* row = img.row(y);
    for (int x = 0; x < img.width; ++x) {
      uint8_t* px = row + x * 4;
      const int limit = (static_cast<int>(px[0]) + static_cast<int>(px[2])) / 2;
      const int excess = static_cast<int>(px[1]) - limit;
      if (excess <= 0) continue;
      // Only see-through pixels carry green spill; an opaque yellow coat
      // (G > (R+B)/2 by nature) must keep its green or it turns orange.
      const int seeThrough = 255 - static_cast<int>(px[3]);
      px[1] = static_cast<uint8_t>(px[1] - (excess * seeThrough + 127) / 255);
    }
  }
}
```

`native/matte_core/include/matte_core/despill.h` 里 `ApplyDespill` 上方的注释改为：

```cpp
// 去溢色：G 超出 (R+B)/2 的部分按透明度压掉——完全透明的像素压到 (R+B)/2，
// 半透明的按 (1 - a/255) 比例压，完全不透明的不动（保护黄色毛发）。
// 需要 alpha 已由 ApplyChromaKey 写入 px[3]。
```

（如果该头文件里 `ApplyDespill` 上方原本没有注释，就把这段加在声明上方。）

`native/pet_matte/src/pet_matte.cpp:110` 的 `aipet-green-matte-1` 改为 `aipet-green-matte-2`。

- [ ] **Step 4: 全量原生构建与测试**

```powershell
& $cmake --build C:\Users\Administrator\code\aipet\native\build --config Debug
& "$(Split-Path $cmake)\ctest.exe" --test-dir C:\Users\Administrator\code\aipet\native\build -C Debug --output-on-failure
```

Expected：全部通过（原 56 个，本任务删 2 加 4，共 58）。若 `pet_matte` 的管线测试因去溢色语义改变而失败，先读懂那个测试断言的是什么再改：只允许调整依赖旧"不透明像素也被压"语义的期望值，不允许削弱测试意图。

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add native/matte_core/src/despill.cpp native/matte_core/include/matte_core/despill.h native/matte_core/tests/test_despill.cpp native/pet_matte/src/pet_matte.cpp
git commit -m "fix(native): despill only see-through pixels so yellow fur keeps its colour" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: 抠像缓存 960 与缓存版本 p2（客户端）

**Files:**
- Modify: `apps/aipet/lib/services/matte_cache.dart:6`
- Modify: `apps/aipet/lib/app/pet_window/pet_window_app.dart:47`
- Test: `apps/aipet/test/services/matte_cache_test.dart:40`

**Interfaces:**
- Consumes: `AlphaVideo.prepare({source, destination, targetEdge})`（原生上限 4096）。
- Produces: `const String kMattePipelineVersion = 'p2'`；`const int kMatteTargetEdge = 960`（都在 `matte_cache.dart`）。

- [ ] **Step 1: 改测试（先失败）**

`apps/aipet/test/services/matte_cache_test.dart` 第 40 行改为：

```dart
    expect(k, matches(RegExp(r'^[0-9a-f]{32}-p2$')));
```

- [ ] **Step 2: 运行确认失败**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter test test/services/matte_cache_test.dart
```

Expected：`key is 32 hex chars of sha256 plus the pipeline version` 失败（键以 `-p1` 结尾）。

- [ ] **Step 3: 实现**

`apps/aipet/lib/services/matte_cache.dart` 第 5–6 行替换为：

```dart
/// Bump when pet_matte's output changes, so old caches are not reused.
/// p2: 960-px caches and edge-only despill (2026-09-12 image quality).
const String kMattePipelineVersion = 'p2';

/// Long edge of the matted cache. Sources are 960x960; keeping every source
/// pixel is what makes the fur read as fur (spec 2026-09-12).
const int kMatteTargetEdge = 960;
```

`apps/aipet/lib/app/pet_window/pet_window_app.dart:47` 改为：

```dart
        AlphaVideo.prepare(source: source, destination: destination, targetEdge: kMatteTargetEdge),
```

（`matte_cache.dart` 已被该文件 import，无需新增 import。）

- [ ] **Step 4: 运行确认通过**

```powershell
flutter test test/services/matte_cache_test.dart
flutter analyze
flutter test
```

Expected：matte_cache 6/6；`No issues found!`；全量 115/115。

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/services/matte_cache.dart apps/aipet/lib/app/pet_window/pet_window_app.dart apps/aipet/test/services/matte_cache_test.dart
git commit -m "feat(aipet): matte caches keep 960 px (pipeline p2)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: petgen 成片处理模块 `finish.py`

**Files:**
- Create: `tools/petgen/petgen/finish.py`
- Test: `tools/petgen/tests/test_finish.py`

**Interfaces:**
- Consumes: `petgen.keycheck.alpha_map(rgb: np.ndarray[H,W,3] uint8) -> np.ndarray[H,W] uint8`；`petgen.loopcheck.probe(video: Path) -> {"width","height","fps","frames"}`。
- Produces（Task 4、5、6 使用）：
  - 常量 `OUT_EDGE = 960`、`TARGET_LUMA = 155.0`、`MAX_P95 = 235.0`
  - `unmix(rgb) -> (fg: float32[H,W,3] 0..1, a: float32[H,W,1] 0..1)`
  - `lift(fg, gamma: float) -> float32[H,W,3]`
  - `solve_gamma(rgb: np.ndarray) -> float`
  - `calibrate_rgba(rgba: np.ndarray[H,W,4] float32 0..255) -> np.ndarray` 同形状
  - `grade_frame(rgb: np.ndarray, gamma: float) -> np.ndarray[H,W,3] uint8`
  - `metrics(rgb: np.ndarray) -> tuple[float, float, float]`（主体平均亮度、95 分位、清晰度）
  - `frame_rgb(video: Path, n: int = 30) -> np.ndarray[960,960,3] uint8`
  - `finish_clip(src: Path, dst: Path, gamma: float) -> int`（返回写出的帧数）
  - `pet_gamma(workdir: Path, override: float | None = None) -> float`（每只宠物一个系数：override 优先，其次 `workdir/grade.json`，否则从同目录 `stand.mp4` 第 30 帧求出并写入 `grade.json`）

- [ ] **Step 1: 写失败的测试**

`tools/petgen/tests/test_finish.py`：

```python
import subprocess

import numpy as np
import pytest

from petgen.finish import (MAX_P95, TARGET_LUMA, calibrate_rgba, finish_clip, frame_rgb, grade_frame, metrics,
                           pet_gamma, solve_gamma)
from petgen.keycheck import alpha_map
from petgen.loopcheck import probe


def _frame(color, size=200, lo=50, hi=150):
    """Exact-green frame with an opaque square of `color`."""
    f = np.zeros((size, size, 3), np.uint8)
    f[...] = (0, 255, 0)
    f[lo:hi, lo:hi] = color
    return f


def test_green_background_stays_exact_green():
    out = grade_frame(_frame((150, 110, 80)), gamma=1.6)
    assert (out[:30, :30] == [0, 255, 0]).all()
    assert (out[-30:, -30:] == [0, 255, 0]).all()


def test_dark_subject_is_lifted_to_the_target_luma():
    f = _frame((150, 110, 80))
    g = solve_gamma(f)
    assert g > 1.0
    luma, _, _ = metrics(grade_frame(f, g))
    assert abs(luma - TARGET_LUMA) < 4


def test_bright_subject_is_left_alone():
    assert solve_gamma(_frame((235, 225, 210))) == 1.0


def test_highlights_cap_the_lift():
    f = _frame((120, 90, 60))
    f[60:80, 60:140] = (228, 228, 228)  # a bright patch, 16 % of the subject
    g = solve_gamma(f)
    assert g < solve_gamma(_frame((120, 90, 60)))  # the patch held the lift back
    _, p95, _ = metrics(grade_frame(f, g))
    assert p95 <= MAX_P95 + 1


def test_calibrate_rgba_brightens_the_subject_and_keeps_alpha():
    rgba = np.zeros((100, 100, 4), np.float32)
    rgba[20:80, 20:80] = (150, 110, 80, 255)
    out = calibrate_rgba(rgba)
    assert out.shape == rgba.shape
    assert (out[..., 3] == rgba[..., 3]).all()
    y = out[20:80, 20:80, :3] @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    assert abs(float(y.mean()) - TARGET_LUMA) < 4


def test_metrics_ignores_the_green_screen():
    luma, p95, sharp = metrics(_frame((100, 100, 100)))
    assert abs(luma - 100) < 0.5 and abs(p95 - 100) < 0.5
    assert sharp < 4  # a flat square: only its outline has any laplacian (~3.3 here)


def test_finish_clip_downscales_to_960_and_keeps_every_frame(tmp_path):
    src = tmp_path / "src.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y",
                    "-f", "lavfi", "-i", "color=c=0x00FF00:s=1280x1280:r=24",
                    "-f", "lavfi", "-i", "color=c=0x966E50:s=400x400:r=24",
                    "-filter_complex", "[0:v][1:v]overlay=440:440", "-frames:v", "121",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(src)], check=True)
    dst = tmp_path / "out.mp4"
    assert finish_clip(src, dst, gamma=1.5) == 121
    assert probe(dst) == {"width": 960, "height": 960, "fps": "24/1", "frames": 121}
    rgb = frame_rgb(dst, 30)
    assert (alpha_map(rgb[:60, :60]) == 0).all()   # background still keys out completely
    assert metrics(rgb)[0] > metrics(frame_rgb(src, 30))[0] + 20  # the square got brighter


def test_finish_clip_rejects_a_non_square_source(tmp_path):
    src = tmp_path / "wide.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x00FF00:s=640x360:r=24",
                    "-frames:v", "24", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(src)],
                   check=True)
    with pytest.raises(ValueError):
        finish_clip(src, tmp_path / "out.mp4", gamma=1.2)
    assert not (tmp_path / "out.mp4").exists()


def test_pet_gamma_is_solved_once_and_reused(tmp_path):
    stand = tmp_path / "stand.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y",
                    "-f", "lavfi", "-i", "color=c=0x00FF00:s=480x480:r=24",
                    "-f", "lavfi", "-i", "color=c=0x966E50:s=200x200:r=24",
                    "-filter_complex", "[0:v][1:v]overlay=140:140", "-frames:v", "40",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(stand)], check=True)
    g = pet_gamma(tmp_path)
    assert g > 1.0
    assert (tmp_path / "grade.json").exists()
    stand.unlink()                        # every later action reuses the saved grade
    assert pet_gamma(tmp_path) == g
    assert pet_gamma(tmp_path, override=1.3) == 1.3
```

- [ ] **Step 2: 运行确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest tests/test_finish.py -q
```

Expected：收集阶段 `ModuleNotFoundError: No module named 'petgen.finish'`。

- [ ] **Step 3: 实现 `tools/petgen/petgen/finish.py`**

```python
"""Finish a Kling clip for packaging: key the animal off the green, brighten /
saturate / sharpen only the animal, put it back on exact #00FF00 and encode at
a bitrate that keeps the fur (spec 2026-09-12 pet image quality)."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

from petgen.keycheck import alpha_map
from petgen.loopcheck import probe

OUT_EDGE = 960
FPS = 24
TARGET_LUMA = 155.0          # subject mean luma after grading (0..255)
MAX_P95 = 235.0              # never push the brightest 5 % past this
SATURATION = 1.10
GAMMA_MAX = 2.5
USM_RADIUS, USM_AMOUNT, USM_THRESHOLD = 1.5, 0.8, 2
CRF = 16
GREEN = np.array([0.0, 1.0, 0.0], dtype=np.float32)
_W = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def unmix(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """uint8 RGB over green -> (animal colour 0..1, alpha 0..1 with a trailing axis)."""
    a = alpha_map(rgb).astype(np.float32)[..., None] / 255.0
    px = rgb.astype(np.float32) / 255.0
    fg = (px - GREEN * (1.0 - a)) / np.maximum(a, 1e-3)
    return np.clip(fg, 0.0, 1.0), a


def lift(fg: np.ndarray, gamma: float) -> np.ndarray:
    """Gamma-brighten, then widen saturation around each pixel's own luma."""
    up = np.power(fg, 1.0 / gamma)
    y = (up @ _W)[..., None]
    return np.clip(y + (up - y) * SATURATION, 0.0, 1.0)


def _core_luma(fg: np.ndarray, core: np.ndarray, gamma: float) -> tuple[float, float]:
    y = (lift(fg, gamma) @ _W)[core] * 255.0
    return float(y.mean()), float(np.percentile(y, 95))


def _solve(fg: np.ndarray, a: np.ndarray) -> float:
    core = a[..., 0] >= 0.999
    if not core.any():
        raise ValueError("no opaque subject to measure")
    if _core_luma(fg, core, 1.0)[0] >= TARGET_LUMA:
        return 1.0
    lo, hi = 1.0, GAMMA_MAX
    for _ in range(30):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if _core_luma(fg, core, mid)[0] < TARGET_LUMA else (lo, mid)
    g = hi
    if _core_luma(fg, core, g)[1] > MAX_P95:
        lo, hi = 1.0, g
        for _ in range(30):
            mid = (lo + hi) / 2
            lo, hi = (lo, mid) if _core_luma(fg, core, mid)[1] > MAX_P95 else (mid, hi)
        g = lo
    return round(g, 4)


def solve_gamma(rgb: np.ndarray) -> float:
    """The gamma that brings the opaque subject to TARGET_LUMA without its
    top 5 % passing MAX_P95; 1.0 when it is already bright enough."""
    return _solve(*unmix(rgb))


def calibrate_rgba(rgba: np.ndarray) -> np.ndarray:
    """Exposure-calibrate a segmented cutout (float32 0..255 RGBA) before it is
    composited onto green: same target as the video grade, alpha untouched."""
    fg = rgba[..., :3] / 255.0
    a = rgba[..., 3:] / 255.0
    out = rgba.copy()
    out[..., :3] = lift(fg, _solve(fg, a)) * 255.0
    return out


def _blur(img01: np.ndarray, radius: float) -> np.ndarray:
    mode = "L" if img01.ndim == 2 else "RGB"
    im = Image.fromarray((np.clip(img01, 0, 1) * 255.0 + 0.5).astype(np.uint8), mode)
    return np.asarray(im.filter(ImageFilter.GaussianBlur(radius)), np.float32) / 255.0


def _sharpen(fg: np.ndarray, a: np.ndarray) -> np.ndarray:
    """Unsharp mask on the animal only. The blur is taken premultiplied (colour
    x alpha, then divided by blurred alpha) so the black 'colour' unmix leaves
    in the background cannot bleed a dark halo into the fur."""
    blurred = _blur(fg * a, USM_RADIUS) / np.maximum(_blur(a[..., 0], USM_RADIUS)[..., None], 1e-3)
    diff = fg - np.clip(blurred, 0.0, 1.0)
    diff[np.abs(diff) * 255.0 < USM_THRESHOLD] = 0.0
    sharp = np.clip(fg + USM_AMOUNT * diff, 0.0, 1.0)
    return fg + (sharp - fg) * a


def grade_frame(rgb: np.ndarray, gamma: float) -> np.ndarray:
    fg, a = unmix(rgb)
    fg = _sharpen(lift(fg, gamma), a)
    out = fg * a + GREEN * (1.0 - a)
    return (np.clip(out, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def metrics(rgb: np.ndarray) -> tuple[float, float, float]:
    """HANDOFF section 4's numbers over the subject (every pixel that is not
    strongly green): mean luma, 95th-percentile luma, mean |laplacian|."""
    f = rgb.astype(np.float32)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    subj = ~((g > r + 40) & (g > b + 40))
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    lap = np.abs(4 * y[1:-1, 1:-1] - y[:-2, 1:-1] - y[2:, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:])
    return float(y[subj].mean()), float(np.percentile(y[subj], 95)), float(lap[subj[1:-1, 1:-1]].mean())


def _scale_args(video: Path) -> list[str]:
    info = probe(video)
    if info["width"] != info["height"]:
        raise ValueError(f"{video.name} is {info['width']}x{info['height']}, not square")
    if info["width"] == OUT_EDGE:
        return []
    return ["-vf", f"scale={OUT_EDGE}:{OUT_EDGE}:flags=area"]


def frame_rgb(video: Path, n: int = 30) -> np.ndarray:
    """Frame n as uint8 RGB at OUT_EDGE x OUT_EDGE."""
    vf = _scale_args(video)
    select = f"select=eq(n\\,{n})"
    vf = ["-vf", f"{select},{vf[1]}"] if vf else ["-vf", select]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(video), *vf, "-frames:v", "1",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(OUT_EDGE, OUT_EDGE, 3).copy()


def finish_clip(src: Path, dst: Path, gamma: float) -> int:
    """Grade every frame of src into dst (960x960, 24 fps, libx264 CRF 16).
    Writes via a temp file so a failure never leaves a half clip behind."""
    vf = _scale_args(src)
    tmp = dst.with_name(dst.stem + ".partial.mp4")
    dec = subprocess.Popen(["ffmpeg", "-v", "error", "-i", str(src), *vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                           stdout=subprocess.PIPE)
    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                            "-s", f"{OUT_EDGE}x{OUT_EDGE}", "-r", str(FPS), "-i", "-",
                            "-c:v", "libx264", "-preset", "slow", "-crf", str(CRF), "-pix_fmt", "yuv420p",
                            "-movflags", "+faststart", str(tmp)], stdin=subprocess.PIPE)
    size = OUT_EDGE * OUT_EDGE * 3
    frames = 0
    try:
        while True:
            buf = dec.stdout.read(size)
            if len(buf) < size:
                break
            rgb = np.frombuffer(buf, np.uint8).reshape(OUT_EDGE, OUT_EDGE, 3)
            enc.stdin.write(grade_frame(rgb, gamma).tobytes())
            frames += 1
    finally:
        enc.stdin.close()
        enc.wait()
        dec.stdout.close()
        dec.wait()
    if dec.returncode or enc.returncode or frames == 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"finish failed for {src.name}: decoder {dec.returncode}, encoder {enc.returncode}, "
                           f"{frames} frames")
    tmp.replace(dst)
    return frames


def pet_gamma(workdir: Path, override: float | None = None) -> float:
    """One grade per pet so every action looks alike: --gamma wins, then the
    saved grade.json, else solve it from this folder's stand.mp4 frame 30 and
    save it for the other actions."""
    if override is not None:
        return override
    grade = workdir / "grade.json"
    if grade.exists():
        return float(json.loads(grade.read_text(encoding="utf-8"))["gamma"])
    stand = workdir / "stand.mp4"
    if not stand.exists():
        raise FileNotFoundError(f"no {stand.name} in {workdir} to derive the pet's grade from")
    g = solve_gamma(frame_rgb(stand, 30))
    grade.write_text(json.dumps({"gamma": g, "from": "stand.mp4 frame 30"}) + "\n", encoding="utf-8")
    return g
```

- [ ] **Step 4: 运行确认通过**

```powershell
.\.venv\Scripts\python -m pytest tests/test_finish.py -q
.\.venv\Scripts\python -m pytest -q
```

Expected：`test_finish.py` 9 passed（`finish_clip` 的测试需要几十秒）；全量 61 passed（原 52 + 9）。
如果 `test_dark_subject_is_lifted_to_the_target_luma` 的亮度差略超 4，先打印 `metrics` 与 `_core_luma` 的值再判断：`metrics` 用"非绿"掩码、`_solve` 用 alpha==255 的核心掩码，平面方块上两者应几乎相同。

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add tools/petgen/petgen/finish.py tools/petgen/tests/test_finish.py
git commit -m "feat(petgen): finish step -- grade the animal only, keep exact green, encode at CRF 16" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: petgen 命令行接线、明亮提示词与参考图曝光校准

**Files:**
- Modify: `tools/petgen/petgen/prompts.py`（`pose_prompt` 增加 `bright`）
- Modify: `tools/petgen/petgen/compose.py`（`compose` 增加 `calibrate`）
- Modify: `tools/petgen/petgen/__main__.py`
- Test: `tools/petgen/tests/test_prompts.py`（追加）、`tools/petgen/tests/test_cli.py`（新建）

**Interfaces:**
- Consumes: Task 3 的 `calibrate_rgba`、`solve_gamma`、`frame_rgb`、`finish_clip`、`metrics`。
- Produces（Task 5、6 的命令）：
  - `python -m petgen pose <pet> <pose> [--tag T] [--resolution 1k|2k] [--bright]`——参考主体永远取 `work/<pet>/src.png`，输出写到 `work/<pet>[/T]/ref-<pose>.png`
  - `python -m petgen gate <pet> <pose> [--tag T] [--calibrate]`
  - `python -m petgen video <pet> <action> [--tag T] [--mode std|pro]`
  - `python -m petgen finish <pet> <action> [--tag T] [--gamma G]`——系数存 `work/<pet>[/T]/grade.json`，首次从同目录 `stand.mp4` 第 30 帧求得
  - `python -m petgen qa <pet> <action> [--tag T]`——检查 `<action>-final.mp4`
  - `python -m petgen package <pet> [--tag T]`——把 `<k>-final.mp4` 复制为资产目录里的 `<k>.mp4`
  - `prompts.BRIGHT`、`pose_prompt(pet, pose, bright=False)`；`__main__._video_task_id(pet, action, tag, mode) -> str`

- [ ] **Step 1: 写失败的测试**

在 `tools/petgen/tests/test_prompts.py` 末尾追加：

```python
from petgen.prompts import BRIGHT, pose_prompt


def test_bright_pose_prompt_adds_the_lighting_and_keeps_the_rest():
    base = pose_prompt("gold", "stand")
    bright = pose_prompt("gold", "stand", bright=True)
    assert BRIGHT not in base
    assert bright == base + BRIGHT
```

新建 `tools/petgen/tests/test_cli.py`：

```python
from petgen.__main__ import _video_task_id


def test_video_task_ids_are_unique_per_call_and_name_their_inputs(monkeypatch):
    import petgen.__main__ as cli
    monkeypatch.setattr(cli.time, "time", lambda: 1789000000.123)
    a = _video_task_id("gold", "stand", "v2", "pro")
    assert a == "petgen-gold-stand-v2-pro-1789000000123"
    monkeypatch.setattr(cli.time, "time", lambda: 1789000000.456)
    assert _video_task_id("gold", "stand", "v2", "pro") != a
    assert _video_task_id("corgi", "walk", None, "std").startswith("petgen-corgi-walk-main-std-")
```

- [ ] **Step 2: 运行确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest tests/test_prompts.py tests/test_cli.py -q
```

Expected：`ImportError: cannot import name 'BRIGHT'` 与 `cannot import name '_video_task_id'`。
（若导入 `petgen.__main__` 在测试环境里因读取密钥而失败，停下来报告——`kling` 模块应在调用时才读密钥。）

- [ ] **Step 3: `prompts.py`**

在 `pose_prompt` 之前加：

```python
# Recipe v2 (2026-09-12): bright high-key studio light. Our first references
# came out dim (subject luma ~128) and Kling carries the reference's exposure
# straight into the video.
BRIGHT = "明亮柔和的高调影棚光，整体曝光充足，毛色鲜亮饱满，每一缕毛丝都清晰可见，焦点清晰。"
```

`pose_prompt` 改为：

```python
def pose_prompt(pet: str, pose: str, bright: bool = False) -> str:
    p = PETS[pet]
    base = (f"参考图中这只{p['breed']}的全身照片，保持它的脸、毛色和花纹完全一样。{p['features']}。"
            + POSES[pose] +
            "它只占画面中间大约一半的宽度，四周留出大片空白，尾巴尖离画面边缘很远。"
            "背景是浅灰色的无缝影棚背景纸，颜色均匀中性，没有任何物体，画面没有边框。"
            "柔和的大面积漫射光，几乎没有投影，身下没有明显的影子。"
            "写实摄影，毛发细节清晰锐利，画面里只有这一只动物。")
    return base + BRIGHT if bright else base
```

- [ ] **Step 4: `compose.py`**

签名改为 `def compose(src: Path, out_dir: Path, stem: str, calibrate: bool = False) -> ComposeResult:`，并把第 57 行

```python
    cut = Image.fromarray(arr[y0:y1, x0:x1].astype(np.uint8), "RGBA")
```

替换为：

```python
    region = arr[y0:y1, x0:x1]
    if calibrate:
        from petgen.finish import calibrate_rgba  # same exposure target as the video grade
        region = calibrate_rgba(region)
    cut = Image.fromarray(np.clip(region + 0.5, 0, 255).astype(np.uint8), "RGBA")
```

- [ ] **Step 5: `__main__.py`**

1. 顶部 import 区加 `import time`；在 `from petgen.package import ...` 之后加：

```python
from petgen.finish import finish_clip, frame_rgb, metrics, pet_gamma  # noqa: E402
```

2. `VIDEO_UNITS = 3` 替换为：

```python
# Pre-flight minimum per 5 s clip. std is 3 units; pro's price is unknown until
# the first call (read final_unit_deduction), so demand a generous floor.
VIDEO_UNITS = {"std": 3, "pro": 10}
```

3. `pet_dir` 替换为：

```python
def pet_dir(pet: str, tag: str | None = None) -> Path:
    d = WORK / pet / tag if tag else WORK / pet
    d.mkdir(parents=True, exist_ok=True)
    return d


def _video_task_id(pet: str, action: str, tag: str | None, mode: str) -> str:
    """Kling rejects a reused external_task_id, and re-generating a clip is the
    whole point of --tag: make every call's id unique."""
    return f"petgen-{pet}-{action}-{tag or 'main'}-{mode}-{int(time.time() * 1000)}"
```

4. `cmd_pose` 替换为：

```python
def cmd_pose(a) -> int:
    body = {"model_name": "kling-v3", "image_reference": "subject",
            "prompt": pose_prompt(a.pet, a.pose, bright=a.bright),
            "image": kling.b64(pet_dir(a.pet) / "src.png"), "aspect_ratio": POSE_ASPECT[a.pose],
            "resolution": a.resolution, "n": 1}
    d = kling.wait("image", kling.create_image(body))
    out = pet_dir(a.pet, a.tag) / f"ref-{a.pose}.png"
    kling.download(d["task_result"]["images"][0]["url"], out)
    print(f"pose {a.pet}/{a.pose} ({a.resolution}{', bright' if a.bright else ''}) -> {out.relative_to(HERE)}: "
          f"deduction {d.get('final_unit_deduction')}")
    return 0
```

5. `cmd_gate` 中两处 `pet_dir(a.pet)` 改为 `pet_dir(a.pet, a.tag)`，`compose(...)` 调用加 `calibrate=a.calibrate`：

```python
        d = pet_dir(a.pet, a.tag)
        r = compose(d / f"ref-{a.pose}.png", d, f"ref-{a.pose}", calibrate=a.calibrate)
```

6. `cmd_video` 替换为：

```python
def cmd_video(a) -> int:
    d = pet_dir(a.pet, a.tag)
    ref = d / f"ref-{REF_POSE_FOR_ACTION[a.action]}-green.png"
    if not ref.exists():
        print(f"no gated reference {ref.relative_to(HERE)}: run gate first")
        return 1
    need = VIDEO_UNITS[a.mode]
    left = _video_units_left()
    if left < need:
        print(f"only {left} video units left, {a.mode} needs {need} -- stopping")
        return 2
    img = kling.b64(ref)
    body = {"model_name": "kling-v3", "image": img, "image_tail": img, "prompt": action_prompt(a.pet, a.action),
            "duration": "5", "mode": a.mode, "external_task_id": _video_task_id(a.pet, a.action, a.tag, a.mode)}
    r = kling.wait("video", kling.create_video(body), every=10)
    out = d / f"{a.action}.mp4"
    kling.download(r["task_result"]["videos"][0]["url"], out)
    print(f"video {a.pet}/{a.action} ({a.mode}) -> {out.relative_to(HERE)}: "
          f"deduction {r.get('final_unit_deduction')}, {_video_units_left():.0f} units left")
    return 0
```

7. 新增 `cmd_finish`（放在 `cmd_qa` 之前）：

```python
def cmd_finish(a) -> int:
    d = pet_dir(a.pet, a.tag)
    src = d / f"{a.action}.mp4"
    if not src.exists():
        print(f"missing {src.relative_to(HERE)}")
        return 1
    try:
        gamma = pet_gamma(d, a.gamma)
    except FileNotFoundError as e:
        print(f"{e}: pass --gamma")
        return 1
    dst = d / f"{a.action}-final.mp4"
    frames = finish_clip(src, dst, gamma)
    before, after = metrics(frame_rgb(src, 30)), metrics(frame_rgb(dst, 30))
    kbps = dst.stat().st_size * 8 / (frames / 24) / 1000
    print(json.dumps({"pet": a.pet, "action": a.action, "tag": a.tag, "gamma": gamma, "frames": frames,
                      "kbps": round(kbps), "luma": [round(before[0], 1), round(after[0], 1)],
                      "p95": [round(before[1], 1), round(after[1], 1)],
                      "sharpness": [round(before[2], 2), round(after[2], 2)]}, ensure_ascii=False))
    return 0
```

8. `cmd_qa` 中 `d = pet_dir(a.pet)` 改为 `d = pet_dir(a.pet, a.tag)`，`v = d / f"{a.action}.mp4"` 改为：

```python
    v = d / f"{a.action}-final.mp4"
    if not v.exists():
        print(f"missing {v.relative_to(HERE)}: run finish first")
        return 1
```

9. `cmd_package` 中 `d = pet_dir(a.pet)` 改为 `d = pet_dir(a.pet, a.tag)`；`clips = [d / f"{k}.mp4" for k in ACTIONS]` 改为 `clips = [d / f"{k}-final.mp4" for k in ACTIONS]`；复制那一行改为：

```python
    for k, c in zip(ACTIONS, clips):
        shutil.copy2(c, out / f"{k}.mp4")
```

10. `main()` 的子命令循环替换为：

```python
    for name, fn, extra in [("source", cmd_source, None), ("pose", cmd_pose, ("pose", list(POSE_ASPECT))),
                            ("gate", cmd_gate, ("pose", list(POSE_ASPECT))), ("video", cmd_video, ("action", ACTIONS)),
                            ("finish", cmd_finish, ("action", ACTIONS)), ("qa", cmd_qa, ("action", ACTIONS)),
                            ("package", cmd_package, None)]:
        p = sub.add_parser(name)
        p.add_argument("pet", choices=list(PETS))
        if extra:
            p.add_argument(extra[0], choices=extra[1])
        if name != "source":
            p.add_argument("--tag", default=None, help="work/<pet>/<tag>/ instead of work/<pet>/")
        if name == "pose":
            p.add_argument("--resolution", choices=["1k", "2k"], default="1k")
            p.add_argument("--bright", action="store_true")
        if name == "gate":
            p.add_argument("--calibrate", action="store_true")
        if name == "video":
            p.add_argument("--mode", choices=list(VIDEO_UNITS), default="std")
        if name == "finish":
            p.add_argument("--gamma", type=float, default=None)
        p.set_defaults(fn=fn)
```

- [ ] **Step 6: 运行测试**

```powershell
.\.venv\Scripts\python -m pytest -q
.\.venv\Scripts\python -m petgen --help
.\.venv\Scripts\python -m petgen video --help
```

Expected：pytest 63 passed（61 + 2）；两个 help 正常打印，`video --help` 里有 `--tag` 和 `--mode {std,pro}`。**不要**运行任何会调用可灵的命令。

- [ ] **Step 7: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add tools/petgen/petgen/prompts.py tools/petgen/petgen/compose.py tools/petgen/petgen/__main__.py tools/petgen/tests/test_prompts.py tools/petgen/tests/test_cli.py
git commit -m "feat(petgen): tags, std/pro, 2k bright references, calibrated gate, finish command" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: 试生成金毛 stand 并挑配方（控制器执行，花额度）

**Files:**
- Create: `docs/superpowers/plans/2026-09-12-pet-image-quality-results.md`
- 产物（不入库）：`tools/petgen/work/gold/v2/`、`tools/petgen/work/gold/v2pro/`、会话临时目录里的对比图

**Interfaces:**
- Consumes: Task 3–4 的命令。
- Produces: 选定的配方（`std` 或 `pro`）与 pro 的实际单价，写入结果文件；`work/gold/<tag>/grade.json`。

- [ ] **Step 1: 现状 + 成片处理（不花钱）**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m petgen finish gold stand
```

（在 `work/gold/` 下生成 `stand-final.mp4` 与 `grade.json`，打印前后亮度、95 分位、清晰度。）

- [ ] **Step 2: 2k 明亮参考图 + 校准合成（约 8+ 图片单位）**

```powershell
.\.venv\Scripts\python -m petgen balance
.\.venv\Scripts\python -m petgen pose gold stand --tag v2 --resolution 2k --bright
.\.venv\Scripts\python -m petgen gate gold stand --tag v2 --calibrate
```

gate 必须 PASS；FAIL（碰边或 blob-core 超标）时重新生成一次 pose，再失败就停下报告。
然后给 pro 准备同一张参考图（本地复制，不花钱）：

```powershell
New-Item -ItemType Directory -Force work\gold\v2pro | Out-Null
Copy-Item work\gold\v2\ref-stand.png work\gold\v2pro\ref-stand.png
.\.venv\Scripts\python -m petgen gate gold stand --tag v2pro --calibrate
```

- [ ] **Step 3: 生成两段视频（std 3 单位 + pro 实价）**

```powershell
.\.venv\Scripts\python -m petgen video gold stand --tag v2 --mode std
.\.venv\Scripts\python -m petgen video gold stand --tag v2pro --mode pro
```

记下两次的 `deduction` 和剩余单位。

- [ ] **Step 4: 成片处理与质检**

```powershell
foreach ($t in 'v2', 'v2pro') {
  .\.venv\Scripts\python -m petgen finish gold stand --tag $t
  .\.venv\Scripts\python -m petgen qa gold stand --tag $t
}
.\.venv\Scripts\python -m petgen qa gold stand
```

- [ ] **Step 5: 对比图**

五段第 30 帧：现状原片、现状成片、v2 成片、v2pro 成片、竞品体验版金毛 stand。整体缩到 480 并排一张，主体左上角起 360×360 原尺寸并排一张（头部），存到会话临时目录，并打印五段的 `metrics`：

```powershell
$env:SP = 'C:\Users\Administrator\AppData\Local\Temp\claude\c--Users-Administrator-code-aipet\4fbc451a-51c9-48a5-9f6b-54b7e4f439b7\scratchpad'
.\.venv\Scripts\python -c @'
import os, pathlib
from PIL import Image
from petgen.finish import frame_rgb, metrics
W = pathlib.Path('work/gold')
comp = (pathlib.Path(os.environ['APPDATA']) / 'com.petcompanion' / '宠伴赛博陪伴' / 'pets' / 'claimed'
        / '6cb9cea0-c245-4d93-80ad-36304da7f764' / '3f8960e1-dc22-48a5-8723-6b92a98504c0' / 'stand-stand.mp4')
clips = [('now', W / 'stand.mp4'), ('now+finish', W / 'stand-final.mp4'), ('v2 std', W / 'v2' / 'stand-final.mp4'),
         ('v2 pro', W / 'v2pro' / 'stand-final.mp4'), ('competitor', comp)]
full, heads = Image.new('RGB', (480 * 5, 480)), Image.new('RGB', (360 * 5, 360))
for i, (name, p) in enumerate(clips):
    rgb = frame_rgb(p, 30)
    print(name, [round(v, 2) for v in metrics(rgb)])
    im = Image.fromarray(rgb)
    full.paste(im.resize((480, 480), Image.LANCZOS), (480 * i, 0))
    ys, xs = (rgb[..., 1] < rgb[..., 0] + 40).nonzero()   # not-green pixels = the animal
    x0, y0 = max(int(xs.min()) - 20, 0), max(int(ys.min()) - 20, 0)
    heads.paste(im.crop((x0, y0, x0 + 360, y0 + 360)), (360 * i, 0))
sp = pathlib.Path(os.environ['SP'])
full.save(sp / 'quality_full.png')
heads.save(sp / 'quality_heads.png')
'@
```

- [ ] **Step 6: 记录并交用户挑选**

新建 `docs/superpowers/plans/2026-09-12-pet-image-quality-results.md`，写入：五段的亮度 / 95 分位 / 清晰度 / 码率、std 与 pro 的实际扣费、qa 结果、对比图说明。
把对比图和推荐交给用户，由用户选 std 或 pro（spec 第 3 节）。选定后在结果文件记下选择与理由。

---

### Task 6: 全量生成、成片、打包（控制器执行，花额度）

**Files:**
- Modify: `apps/aipet/assets/pets/builtin-gold/*`、`builtin-corgi/*`、`builtin-ragdoll/*`（mp4 与 cover.png，Git LFS）
- Modify: `docs/superpowers/plans/2026-09-12-pet-image-quality-results.md`

**Interfaces:**
- Consumes: Task 5 选定的模式 `$mode`（std 或 pro）和对应 tag `$tag`（`v2` 或 `v2pro`）。

- [ ] **Step 1: 额度检查**

金毛还需 4 段视频（walk、sleep、lick_paw、act_cute）。`petgen balance` 的剩余单位必须 ≥ 4 × 该模式实价；不够就停下来问用户（不降档、不续购）。

- [ ] **Step 2: 金毛其余参考图（walk、lie）**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
foreach ($pose in 'walk', 'lie') {
  .\.venv\Scripts\python -m petgen pose gold $pose --tag $tag --resolution 2k --bright
  .\.venv\Scripts\python -m petgen gate gold $pose --tag $tag --calibrate
}
```

gate FAIL 时对该姿态重新生成一次，再失败就停下报告。

- [ ] **Step 3: 金毛其余视频 + 成片 + 质检**

```powershell
foreach ($act in 'walk', 'sleep', 'lick_paw', 'act_cute') {
  .\.venv\Scripts\python -m petgen video gold $act --tag $tag --mode $mode
  .\.venv\Scripts\python -m petgen finish gold $act --tag $tag
  .\.venv\Scripts\python -m petgen qa gold $act --tag $tag
}
```

qa FAIL 的动作：记下原因，同一配方重新生成一次；再失败就停下报告，不打包金毛。

- [ ] **Step 4: 柯基、布偶猫只做成片**

```powershell
foreach ($pet in 'corgi', 'ragdoll') {
  foreach ($act in 'stand', 'walk', 'sleep', 'lick_paw', 'act_cute') {
    .\.venv\Scripts\python -m petgen finish $pet $act
    .\.venv\Scripts\python -m petgen qa $pet $act
  }
}
```

- [ ] **Step 5: 打包与提交**

```powershell
.\.venv\Scripts\python -m petgen package gold --tag $tag
.\.venv\Scripts\python -m petgen package corgi
.\.venv\Scripts\python -m petgen package ragdoll
Set-Location C:\Users\Administrator\code\aipet
git lfs status
git add apps/aipet/assets/pets
git commit -m "feat(assets): brighter, sharper built-in pets (finished clips; gold regenerated with recipe v2)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

`git lfs status` 必须显示这些 mp4/png 走 LFS。每只宠物第 30 帧的 `metrics` 写入结果文件，逐条对照 Global Constraints 的画质目标。

---

### Task 7: 整体验证与文档（控制器执行）

**Files:**
- Modify: `docs/superpowers/plans/2026-09-12-pet-image-quality-results.md`
- Modify: `HANDOFF.md`（第 4 节画质实测补上"已优化后的数值"；第 5 节加一条：旧 `p1` 缓存文件不会自动清理）

- [ ] **Step 1: 回归（不弹窗）**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet;  flutter analyze; flutter test
Set-Location C:\Users\Administrator\code\aipet\tools\petgen; .\.venv\Scripts\python -m pytest -q
$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
& $cmake --build C:\Users\Administrator\code\aipet\native\build --config Debug
& "$(Split-Path $cmake)\ctest.exe" --test-dir C:\Users\Administrator\code\aipet\native\build -C Debug
Set-Location C:\Users\Administrator\code\aipet\apps\aipet; flutter build windows --release
```

Expected：analyze 零问题；flutter 115/115；pytest 63；ctest 58/58；release 构建成功（若 aipet.exe 正在运行导致覆盖失败，先征得用户同意再关闭它）。

- [ ] **Step 2: 文档与提交**

结果文件补上回归数字；HANDOFF 按上面两处更新。

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add docs/superpowers/plans/2026-09-12-pet-image-quality-results.md
git commit -m "docs: pet image quality results" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

（`HANDOFF.md` 与主计划 Task 16 的文件一起在 Task 16 收尾时提交。）
