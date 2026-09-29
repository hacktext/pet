# 正脸素材 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 三只内置宠物换成正脸待机，新增喂食、玩耍两个动作（道具合成进参考图，首末帧都在），舔爪子、卖萌用正脸参考图重做。

**Architecture:** petgen 新增正脸姿态与按物种区分的动作提示词；`compose` 抽出画布摆放 `place` / 合绿 `on_green` 供新模块 `props.py` 复用——
道具单独生成、抠图，按纯函数 `prop_box` 贴到前爪前面；`qa` 增加每 6 帧抽查的 blob-core。付费生成由控制器执行。客户端代码不改。

**Tech Stack:** Python 3 + numpy + Pillow + ffmpeg + rembg（tools/petgen，venv `tools\petgen\.venv`）；可灵 kling-v3；Flutter 3.47.2（只做回归与构建）。

**Spec:** `docs/superpowers/specs/2026-09-19-front-facing-pets-design.md`

## Global Constraints

- 仓库根 `C:\Users\Administrator\code\aipet`，分支 `feat/aipet-main-window`，只做 Windows。PowerShell 5.1 没有 `&&`。
- 可灵密钥只从 `secrets\kling.env` 读，任何日志不得打印密钥。
- 视频 pro 每段 4 单位；**额度不够就停下问用户，不降档、不续购**；gate / qa 失败同配方重来一次，再失败停下报告。
- 成片：960×960、24 fps、121 帧；纯 `#00FF00` 背景；`qa` 的 blob-core（首帧、末帧、每 6 帧抽查）都 < 200；接缝规则照旧。
- 画质（stand 第 30 帧，`finish.metrics`）：亮度 145–165、95 分位 ≤ 235、清晰度 ≥ 9；待机动作幅度 ≥ 20。
- 动作顺序 `stand walk sleep feed play lick_paw act_cute`；参考图：`stand/lick_paw/act_cute → front`、`feed → front-bowl`、`play → front-ball`、`walk → walk`、`sleep → lie`。
- 工作区里 `HANDOFF.md`、`docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`、`tools/dev/*.ps1` 不属于本计划，一律 `git add <具体路径>`。
- 不启动 aipet.exe、不发鼠标键盘输入。提交信息末尾 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。
- 测试命令都在 `tools\petgen` 下：`.\.venv\Scripts\python -m pytest -q`（当前 63 个）。

---

## File Structure

```
tools/petgen/petgen/prompts.py     front 姿态（分猫狗）、stand/feed/play 分猫狗、PROPS 道具提示词、新的动作→参考图映射（Task 1）
tools/petgen/petgen/package.py     ACTIONS 7 个（Task 1）
tools/petgen/petgen/compose.py     抽出 place / on_green，_segment 改名 segment（Task 2）
tools/petgen/petgen/props.py       新建：PROP_REFS、prop_box、paste、compose_prop、cut_prop（Task 2）
tools/petgen/petgen/keycheck.py    frame_scores：每 N 帧的 blob-core（Task 3）
tools/petgen/petgen/__main__.py    prop / propref 命令、qa 逐帧抽查、pro 单价 4、封面取正脸（Task 3）
tools/petgen/tests/                test_prompts、test_package、test_props（新）、test_keycheck（Task 1–3）
apps/aipet/assets/pets/builtin-*/  重新打包（Task 6，Git LFS）
docs/superpowers/plans/2026-09-19-front-facing-pets-results.md   执行结果（Task 4–6）
```

---

### Task 1: 提示词与动作集

**Files:**
- Modify: `tools/petgen/petgen/prompts.py`
- Modify: `tools/petgen/petgen/package.py:8`
- Test: `tools/petgen/tests/test_prompts.py`、`tools/petgen/tests/test_package.py`

**Interfaces:**
- Produces: `prompts.POSES["front"]`（dict，按物种）、`POSE_ASPECT["front"] == "1:1"`、`REF_POSE_FOR_ACTION`（7 个动作，值为参考图名，含 `front-bowl`、`front-ball`）、
  `PROPS: dict[str, str]`（`bowl`、`ball` 的文生图提示词）、`action_prompt(pet, action)` 支持 `feed`、`play`；`package.ACTIONS` 7 个。
- Consumes: Task 2 的 `props.PROP_REFS`（只在测试里交叉检查；Task 1 先于 Task 2 做时，这条测试在 Task 2 完成后才能跑通——所以**本任务的测试文件先不引用 `PROP_REFS`**，交叉检查放在 Task 2 的测试里）。

- [ ] **Step 1: 改测试（先失败）**

`tools/petgen/tests/test_prompts.py` 整体替换为：

```python
import pytest

from petgen.package import ACTIONS
from petgen.prompts import (BRIGHT, PETS, POSE_ASPECT, PROPS, REF_POSE_FOR_ACTION, action_prompt, pose_prompt,
                            source_prompt)


def test_three_pets_with_pet_json_fields():
    assert set(PETS) == {"gold", "corgi", "ragdoll"}
    for p in PETS.values():
        assert p["species"] in {"dog", "cat"} and p["name"] and p["blurb"] and p["breed"] and p["features"]


def test_every_action_maps_to_a_reference_still():
    assert set(REF_POSE_FOR_ACTION) == set(ACTIONS)
    for ref in REF_POSE_FOR_ACTION.values():
        assert ref.split("-")[0] in POSE_ASPECT


def test_the_idle_family_starts_from_the_front_still():
    # They all begin and end in the idle pose, so switching between them never jumps.
    for a in ("stand", "lick_paw", "act_cute", "feed", "play"):
        assert REF_POSE_FOR_ACTION[a].startswith("front")
    assert REF_POSE_FOR_ACTION["feed"] != REF_POSE_FOR_ACTION["play"] != REF_POSE_FOR_ACTION["stand"]


@pytest.mark.parametrize("pet", ["gold", "corgi", "ragdoll"])
@pytest.mark.parametrize("action", ACTIONS)
def test_action_prompts_pin_camera_and_background(pet, action):
    text = action_prompt(pet, action)
    assert "镜头完全固定" in text and "纯绿色" in text
    assert PETS[pet]["breed"] in text


def test_breed_and_features_reach_every_prompt():
    for pet, p in PETS.items():
        assert p["breed"] in source_prompt(pet)
        assert p["features"] in pose_prompt(pet, "stand")
        assert p["features"] in pose_prompt(pet, "front")


@pytest.mark.parametrize("action", ["stand", "feed", "play", "act_cute"])
def test_cats_and_dogs_get_their_own_prompt(action):
    dog = action_prompt("gold", action).replace(PETS["gold"]["breed"], "X")
    cat = action_prompt("ragdoll", action).replace(PETS["ragdoll"]["breed"], "X")
    assert dog != cat


@pytest.mark.parametrize("pet", ["gold", "ragdoll"])
@pytest.mark.parametrize("action, prop", [("feed", "碗"), ("play", "球")])
def test_prop_clips_keep_the_prop_in_place(pet, action, prop):
    # spike 2026-09-19: a prop the model makes vanish dissolves into the green screen
    text = action_prompt(pet, action)
    assert prop in text and "不消失" in text


def test_front_pose_shows_the_face_and_fits_the_species():
    dog, cat = pose_prompt("gold", "front"), pose_prompt("ragdoll", "front")
    assert "头部正对镜头" in dog and "头部正对镜头" in cat
    assert "舌头" in dog and "舌头" not in cat


def test_every_prop_has_a_prompt():
    assert set(PROPS) == {"bowl", "ball"}
    assert all(PROPS.values())


def test_bright_pose_prompt_adds_the_lighting_and_keeps_the_rest():
    base = pose_prompt("gold", "stand")
    bright = pose_prompt("gold", "stand", bright=True)
    assert BRIGHT not in base
    assert bright == base + BRIGHT
```

`tools/petgen/tests/test_package.py` 第 11 行改为：

```python
        "actions": ["stand", "walk", "sleep", "feed", "play", "lick_paw", "act_cute"],
```

- [ ] **Step 2: 运行确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest tests/test_prompts.py tests/test_package.py -q
```

Expected：收集阶段 `ImportError: cannot import name 'PROPS'`；去掉 `PROPS` 后也会因 `front`、`feed`、`play` 缺失而失败。

- [ ] **Step 3: 实现 `prompts.py`**

`POSES` 字典加一项（放在 `"lie"` 之后）：

```python
    # 2026-09-19: the idle faces the user like the competitor's; dogs grin, cats don't.
    "front": {
        "dog": ("正面朝向镜头站立，身体只微微侧转约十五度，头部正对镜头，嘴巴微微张开、露出一点舌头，"
                "表情开心友好，四条腿都站在地上，尾巴自然翘起。头部、四条腿和尾巴全部完整入画，脚掌贴地，"
                "头顶和尾巴尖离画面上边缘很远。"),
        "cat": ("正面朝向镜头站立，身体只微微侧转约十五度，头部正对镜头，眼睛睁大，表情好奇友好，"
                "四条腿都站在地上，尾巴自然竖起。头部、四条腿和尾巴全部完整入画，脚掌贴地，"
                "头顶和尾巴尖离画面上边缘很远。"),
    },
```

`POSE_ASPECT` 改为：

```python
POSE_ASPECT = {"stand": "16:9", "walk": "16:9", "lie": "21:9", "front": "1:1"}
```

`REF_POSE_FOR_ACTION` 与上方注释替换为：

```python
# The idle family (stand, lick_paw, act_cute, feed, play) starts and ends on the
# front still, so switching between them never jumps. feed / play use the front
# still with their prop pasted in (petgen.props), so the prop is there on the
# first and last frame; walk needs a mid-stride still; sleep the lying still.
REF_POSE_FOR_ACTION = {"stand": "front", "lick_paw": "front", "act_cute": "front",
                       "feed": "front-bowl", "play": "front-ball", "walk": "walk", "sleep": "lie"}
```

`_ACTIONS` 与 `_ACT_CUTE` 替换为（`walk`、`sleep`、`lick_paw` 原文不变；按物种的写成 dict）：

```python
_ACTIONS = {
    "stand": {
        "dog": ("{it}面朝镜头站在原地，开心地张着嘴。整个五秒里一直在做明显、连续的动作：头向左右转动看看四周，"
                "歪了歪头，尾巴大幅度地左右摇摆，耳朵随之抖动，身体重心轻轻左右移动。"
                "四只脚掌始终踩在原地，不走动，不转身，不坐下，不趴下。最后头回到正对镜头的姿势。"),
        "cat": ("{it}面朝镜头站在原地。整个五秒里一直在做明显、连续的动作：头向左右转动好奇地看看四周，"
                "歪了歪头，慢慢眨眼，耳朵灵活地转动，尾巴大幅度地慢慢摆动，身体重心轻轻左右移动。"
                "四只脚掌始终踩在原地，不走动，不转身，不坐下，不趴下。最后头回到正对镜头的姿势。"),
    },
    "walk": ("{it}原地踏步行走，像在跑步机上一样，四条腿自然交替迈步，"
             "身体始终保持在画面中的同一位置，不向前移动，不转身。头随步伐轻轻晃动，尾巴轻摆。"),
    "sleep": "{it}趴着安静地睡觉，眼睛一直闭着，身体随呼吸缓慢起伏，耳朵偶尔轻轻抖一下。姿态和位置全程不变，不起身。",
    "lick_paw": ("{it}原地站着，低下头舔了几下自己的一只前爪，"
                 "然后抬起头，慢慢恢复到原来的站姿和朝向。身体位置全程不变，不走动。"),
    "act_cute": {
        "dog": "{it}原地站着，开心地歪了歪头，尾巴快速摇了几下，然后恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
        "cat": "{it}原地站着，歪头眨了眨眼，抬起一只前爪轻轻挥了挥，然后放下前爪恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
    },
    "feed": {
        "dog": ("{it}面朝镜头站在原地，两只前爪前面放着一个装满狗粮的红色陶瓷碗。它低下头吃碗里的狗粮，吃了几口，"
                "然后抬起头舔了舔嘴，恢复到原来面朝镜头的站姿。碗始终在原地不动，一直都在，不消失。"
                "身体位置全程不变，不走动，不转身。"),
        "cat": ("{it}面朝镜头站在原地，两只前爪前面放着一个装满猫粮的红色陶瓷碗。它低下头小口地吃碗里的猫粮，吃了几口，"
                "然后抬起头舔了舔嘴，恢复到原来面朝镜头的站姿。碗始终在原地不动，一直都在，不消失。"
                "身体位置全程不变，不走动，不转身。"),
    },
    "play": {
        "dog": ("{it}面朝镜头站在原地，两只前爪前面的地上放着一个红色小球。它开心地低头用鼻子拱了拱球，"
                "用一只前爪轻轻拨了拨，尾巴快速摇摆，然后球回到原来的位置，它抬起头恢复到原来面朝镜头的站姿。"
                "球始终在画面里，不消失。身体位置全程不变，不走动，不转身。"),
        "cat": ("{it}面朝镜头站在原地，两只前爪前面的地上放着一个红色小球。它好奇地歪头看着球，"
                "抬起一只前爪轻轻拍了拍球，然后球回到原来的位置，它放下前爪恢复到原来面朝镜头的站姿。"
                "球始终在画面里，不消失。身体位置全程不变，不走动，不转身。"),
    },
}

# Props are generated once, alone, and pasted into the front still (petgen.props).
# Matte red: stainless steel mirrors the green screen and keys full of holes.
PROPS = {
    "bowl": ("一个哑光的红色陶瓷宠物食碗，碗里装满棕色的颗粒粮，从斜上方约二十度俯视，碗完整入画、居中，"
             "只占画面中间大约一半的宽度。背景是浅灰色的无缝影棚背景纸，颜色均匀中性，柔和的漫射光，几乎没有投影。"
             "写实摄影，画面里只有这一个碗。"),
    "ball": ("一个哑光的红色橡胶小球，表面干净，完整入画、居中，只占画面中间大约三分之一的宽度。"
             "背景是浅灰色的无缝影棚背景纸，颜色均匀中性，柔和的漫射光，几乎没有投影。写实摄影，画面里只有这一个球。"),
}


def _pick(text: str | dict, pet: str) -> str:
    """A prompt that differs by species is a {species: text} dict."""
    return text[PETS[pet]["species"]] if isinstance(text, dict) else text
```

`pose_prompt` 里 `+ POSES[pose] +` 改为 `+ _pick(POSES[pose], pet) +`。

`action_prompt` 替换为：

```python
def action_prompt(pet: str, action: str) -> str:
    return _pick(_ACTIONS[action], pet).format(it=_it(pet)) + _TAIL
```

- [ ] **Step 4: `package.py`**

第 8 行改为：

```python
ACTIONS = ["stand", "walk", "sleep", "feed", "play", "lick_paw", "act_cute"]
```

- [ ] **Step 5: 运行确认通过**

```powershell
.\.venv\Scripts\python -m pytest tests/test_prompts.py tests/test_package.py -q
.\.venv\Scripts\python -m pytest -q
```

Expected：两文件全过；全量全过（数量会因参数化变化，以实际为准，无失败）。

- [ ] **Step 6: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add tools/petgen/petgen/prompts.py tools/petgen/petgen/package.py tools/petgen/tests/test_prompts.py tools/petgen/tests/test_package.py
git commit -m "feat(petgen): front idle pose, feed and play prompts, seven actions" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: 道具合成（`props.py`）与画布摆放复用

**Files:**
- Modify: `tools/petgen/petgen/compose.py`（抽出 `place`、`on_green`；`_segment` 改名 `segment`）
- Create: `tools/petgen/petgen/props.py`
- Test: `tools/petgen/tests/test_props.py`

**Interfaces:**
- Consumes: `edges.subject_bbox(alpha, threshold=10) -> (x0, x1, y0, y1)`（x1、y1 为开区间）、`edges.edge_touches`、`compose.EdgeError`；`prompts.REF_POSE_FOR_ACTION`（交叉检查）。
- Produces:
  - `compose.place(cut: Image.Image) -> np.ndarray`（float32 `EDGE×EDGE×4`，0..255，直通 alpha）
  - `compose.on_green(canvas: np.ndarray, out: Path) -> Path`
  - `compose.segment(src: Path) -> np.ndarray`（float32 RGBA）
  - `props.PROP_REFS = {"front-bowl": "bowl", "front-ball": "ball"}`
  - `props.prop_box(alpha: np.ndarray, kind: str, prop_w: int, prop_h: int) -> tuple[int, int, int, int]`（left, top, w, h）
  - `props.paste(canvas: np.ndarray, prop: Image.Image, box) -> np.ndarray`
  - `props.compose_prop(cutout: Path, prop_cutout: Path, kind: str, out: Path) -> Path`
  - `props.cut_prop(src: Path, out: Path) -> Path`（碰边抛 `EdgeError`）

- [ ] **Step 1: 写失败的测试**

新建 `tools/petgen/tests/test_props.py`：

```python
import numpy as np
from PIL import Image

from petgen.compose import EDGE, on_green, place
from petgen.edges import subject_bbox
from petgen.prompts import REF_POSE_FOR_ACTION
from petgen.props import PROP_REFS, compose_prop, paste, prop_box


def _animal():
    """1024 canvas alpha: a head block on top of a wider body; height 800."""
    a = np.zeros((EDGE, EDGE), np.uint8)
    a[100:300, 200:401] = 255   # head, columns 200..400 -> centre 300
    a[300:900, 200:800] = 255   # body
    return a


def test_every_prop_reference_is_used_by_an_action():
    assert set(PROP_REFS) <= set(REF_POSE_FOR_ACTION.values())


def test_bowl_sits_under_the_head_in_front_of_the_paws():
    # H = 800: width 0.35*H = 280, height 280*100/200 = 140, bottom 900 + 0.03*H = 924, centred on x = 300
    assert prop_box(_animal(), "bowl", 200, 100) == (160, 784, 280, 140)


def test_ball_is_smaller():
    # width 0.14*800 = 112, square prop -> 112 high, left 300 - 56 = 244, top 924 - 112 = 812
    assert prop_box(_animal(), "ball", 100, 100) == (244, 812, 112, 112)


def test_a_raised_tail_barely_moves_the_prop():
    a = _animal()
    a[120:160, 780:800] = 255   # tail tip inside the top band
    left, _, w, _ = prop_box(a, "bowl", 200, 100)
    assert abs(left + w / 2 - 300) < 15


def test_prop_is_kept_on_the_canvas():
    a = np.zeros((EDGE, EDGE), np.uint8)
    a[710:1010, 0:61] = 255    # H = 300 at the bottom-left corner
    left, top, w, h = prop_box(a, "bowl", 100, 100)
    assert (left, w, h) == (8, 105, 105)
    assert top + h == EDGE - 8


def test_paste_puts_the_prop_in_front_and_keeps_the_rest():
    canvas = np.zeros((20, 20, 4), np.float32)
    canvas[5:15, 5:15] = (200, 150, 100, 255)
    prop = np.zeros((4, 4, 4), np.uint8)
    prop[:, :2] = (255, 0, 0, 255)       # left half opaque red, right half clear
    out = paste(canvas, Image.fromarray(prop, "RGBA"), (8, 8, 4, 4))
    assert (out[8:12, 8:10] == (255, 0, 0, 255)).all()
    assert (out[8:12, 10:12] == (200, 150, 100, 255)).all()
    assert (out[0:5] == 0).all()
    assert (canvas[8:12, 8:10] == (200, 150, 100, 255)).all()   # input untouched


def test_place_scales_to_fill_and_centres():
    # 400x200 -> scale 0.78*1024/400: 799 x 399, offset ((1024-799)//2, (1024-399)//2) = (112, 312)
    canvas = place(Image.new("RGBA", (400, 200), (10, 20, 30, 255)))
    assert canvas.shape == (EDGE, EDGE, 4)
    assert subject_bbox(canvas[..., 3].astype(np.uint8)) == (112, 911, 312, 711)


def test_compose_prop_keeps_the_animal_exactly_and_adds_the_prop(tmp_path):
    cut = np.zeros((500, 300, 4), np.uint8)
    cut[:, :] = (180, 120, 60, 255)
    Image.fromarray(cut, "RGBA").save(tmp_path / "cut.png")
    Image.new("RGBA", (60, 30), (230, 20, 20, 255)).save(tmp_path / "bowl.png")
    out = compose_prop(tmp_path / "cut.png", tmp_path / "bowl.png", "bowl", tmp_path / "g.png")
    got = np.asarray(Image.open(out).convert("RGB")).astype(int)
    plain = np.asarray(Image.open(on_green(place(Image.open(tmp_path / "cut.png")), tmp_path / "p.png"))).astype(int)
    left, top, w, h = prop_box(place(Image.open(tmp_path / "cut.png"))[..., 3].astype(np.uint8), "bowl", 60, 30)
    assert (got[:8, :8] == (0, 255, 0)).all()                                   # background stays exact green
    assert abs(got[top + h // 2, left + w // 2] - (230, 20, 20)).max() <= 2    # the bowl is there
    outside = np.ones((EDGE, EDGE), bool)
    outside[top:top + h, left:left + w] = False
    assert (got[outside] == plain[outside]).all()                              # the animal is untouched
```

- [ ] **Step 2: 运行确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest tests/test_props.py -q
```

Expected：`ImportError: cannot import name 'on_green' from 'petgen.compose'`（或 `No module named 'petgen.props'`）。

- [ ] **Step 3: `compose.py` 抽出 `place` / `on_green`**

`_segment` 改名 `segment`（定义与 `compose` 里的调用都改）。在 `compose` 之前加：

```python
def place(cut: Image.Image) -> np.ndarray:
    """The cutout scaled to FILL of the canvas and centred: float32 RGBA, EDGE x EDGE."""
    scale = FILL * EDGE / max(cut.width, cut.height)
    cut = cut.convert("RGBA").resize((round(cut.width * scale), round(cut.height * scale)), Image.LANCZOS)
    canvas = np.zeros((EDGE, EDGE, 4), dtype=np.float32)
    ox, oy = (EDGE - cut.width) // 2, (EDGE - cut.height) // 2
    canvas[oy:oy + cut.height, ox:ox + cut.width] = np.asarray(cut, dtype=np.float32)
    return canvas


def on_green(canvas: np.ndarray, out: Path) -> Path:
    """Soft fur edges blend into key green, exactly like a real screen edge."""
    a = canvas[..., 3:] / 255.0
    rgb = canvas[..., :3] * a + KEY * (1.0 - a)
    Image.fromarray(np.clip(rgb + 0.5, 0, 255).astype(np.uint8), "RGB").save(out)
    return out
```

`compose` 里从 `scale = FILL * EDGE / ...` 到 `Image.fromarray(...).save(green)` 的整段替换为：

```python
    green = on_green(place(cut), out_dir / f"{stem}-green.png")
```

（`cut` 的宽高就是 `x1 - x0`、`y1 - y0`，缩放与居中和原来逐像素相同。）

- [ ] **Step 4: 新建 `props.py`**

```python
"""Props (bowl, ball) pasted in front of the animal's front paws on the front
still, so a feed / play clip starts and ends with the prop already there.
Spike 2026-09-19: a prop the model makes appear or vanish dissolves into the
green screen and keys as a half-transparent ghost."""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

from petgen.compose import EDGE, EdgeError, on_green, place, segment
from petgen.edges import edge_touches, subject_bbox

PROP_REFS = {"front-bowl": "bowl", "front-ball": "ball"}  # reference stem -> prop
PROP_WIDTH = {"bowl": 0.35, "ball": 0.14}                 # of the animal's height
HEAD_BAND = 0.20   # top share of the animal whose columns locate the head
DROP = 0.03        # prop bottom below the paws: it stands in front of them
MARGIN = 8


def prop_box(alpha: np.ndarray, kind: str, prop_w: int, prop_h: int) -> tuple[int, int, int, int]:
    """(left, top, w, h) of the prop on the canvas: under the head (a front-facing
    animal's front legs are below it), pixel-weighted so a raised tail tip in the
    top band barely pulls it, and clamped inside the canvas."""
    x0, x1, y0, y1 = subject_bbox(alpha)
    h = y1 - y0
    _, xs = np.nonzero(alpha[y0:y0 + max(1, round(HEAD_BAND * h))] > 10)
    cx = float(xs.mean())
    w = max(1, round(PROP_WIDTH[kind] * h))
    ph = max(1, round(w * prop_h / prop_w))
    bottom = min(round(y1 + DROP * h), EDGE - MARGIN)
    top = max(bottom - ph, MARGIN)
    left = min(max(round(cx - w / 2), MARGIN), EDGE - MARGIN - w)
    return left, top, w, ph


def paste(canvas: np.ndarray, prop: Image.Image, box: tuple[int, int, int, int]) -> np.ndarray:
    """The prop over the animal (straight-alpha 'over'); returns a new canvas."""
    left, top, w, h = box
    p = np.asarray(prop.convert("RGBA").resize((w, h), Image.LANCZOS), dtype=np.float32)
    out = canvas.copy()
    region = out[top:top + h, left:left + w]
    pa, ba = p[..., 3:] / 255.0, region[..., 3:] / 255.0
    oa = pa + ba * (1.0 - pa)
    region[..., :3] = (p[..., :3] * pa + region[..., :3] * ba * (1.0 - pa)) / np.maximum(oa, 1e-6)
    region[..., 3:] = oa * 255.0
    return out


def compose_prop(cutout: Path, prop_cutout: Path, kind: str, out: Path) -> Path:
    """The front still with the prop in front of its paws, on exact green. The
    animal is placed exactly as compose() placed it, so only the prop differs."""
    canvas = place(Image.open(cutout))
    prop = Image.open(prop_cutout).convert("RGBA")
    box = prop_box(np.clip(canvas[..., 3], 0, 255).astype(np.uint8), kind, prop.width, prop.height)
    return on_green(paste(canvas, prop, box), out)


def cut_prop(src: Path, out: Path) -> Path:
    """Segment a generated prop photo and crop it to its alpha bounding box."""
    arr = segment(src)
    alpha = arr[..., 3].astype(np.uint8)
    sides = edge_touches(alpha)
    if sides:
        raise EdgeError(sides)
    x0, x1, y0, y1 = subject_bbox(alpha)
    Image.fromarray(np.clip(arr[y0:y1, x0:x1] + 0.5, 0, 255).astype(np.uint8), "RGBA").save(out)
    return out
```

- [ ] **Step 5: 运行确认通过**

```powershell
.\.venv\Scripts\python -m pytest tests/test_props.py -q
.\.venv\Scripts\python -m pytest -q
```

Expected：`test_props.py` 9 passed；全量无失败（`compose` 的既有测试 `test_calibration.py` 等照旧通过）。

- [ ] **Step 6: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add tools/petgen/petgen/compose.py tools/petgen/petgen/props.py tools/petgen/tests/test_props.py
git commit -m "feat(petgen): props pasted in front of the paws on the front still" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: 逐帧质检与命令行接线

**Files:**
- Modify: `tools/petgen/petgen/keycheck.py`（`frame_scores`）
- Modify: `tools/petgen/petgen/__main__.py`
- Test: `tools/petgen/tests/test_keycheck.py`（追加）

**Interfaces:**
- Consumes: Task 1 的 `PROPS`；Task 2 的 `PROP_REFS`、`compose_prop`、`cut_prop`；`loopcheck.probe`。
- Produces:
  - `keycheck.frame_scores(video: Path, step: int = 6) -> list[int]`（第 0、step、2·step… 帧的 blob-core，打分方式与 `score_file` 相同）
  - `python -m petgen prop bowl|ball` → `work/props/<kind>.png`、`work/props/<kind>-cutout.png`
  - `python -m petgen propref <pet> [--tag T]` → `ref-front-bowl-green.png`、`ref-front-ball-green.png`（各打 gate 分）
  - `qa` 的输出多一个 `blob_core_worst`，并纳入通过条件；`package` 的封面取 `ref-front-cutout.png`；`VIDEO_UNITS["pro"] == 4`

- [ ] **Step 1: 写失败的测试**

`tools/petgen/tests/test_keycheck.py` 末尾追加：

```python
import subprocess

from petgen.keycheck import frame_scores


def test_frame_scores_catch_a_ghost_in_the_middle_of_a_clip(tmp_path):
    # 13 frames: an opaque red square throughout; frame 6 also carries a
    # half-keyed olive patch (100,160,0 keys to alpha ~115) away from it --
    # the dissolving-bowl ghost of the 2026-09-19 spike.
    frames = np.zeros((13, 240, 240, 3), np.uint8)
    frames[...] = (0, 255, 0)
    frames[:, 80:160, 80:160] = (220, 40, 40)
    frames[6, 10:50, 170:230] = (100, 160, 0)
    video = tmp_path / "ghost.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "240x240", "-r", "24",
                    "-i", "-", "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", str(video)],
                   input=frames.tobytes(), check=True)
    scores = frame_scores(video, step=6)
    assert len(scores) == 3                     # frames 0, 6, 12
    assert scores[1] >= BLOB_CORE_MAX
    assert scores[0] < 50 and scores[2] < 50
```

- [ ] **Step 2: 运行确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest tests/test_keycheck.py -q
```

Expected：`ImportError: cannot import name 'frame_scores'`。

- [ ] **Step 3: `keycheck.py`**

顶部 import 加 `import subprocess`，并在 `from PIL import Image` 之后加 `from petgen.loopcheck import probe`。文件末尾加：

```python
def frame_scores(video: Path, step: int = 6) -> list[int]:
    """blob_core of every step-th frame, scored exactly like score_file. First
    and last frames are not enough: a prop dissolving mid-clip keys as a ghost
    (spike 2026-09-19)."""
    info = probe(video)
    w, h = info["width"], info["height"]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(video), "-vf", f"select=not(mod(n\\,{step}))",
                          "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         check=True, capture_output=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3)
    return [score_rgb(np.asarray(Image.fromarray(f).resize((SCORE_EDGE, SCORE_EDGE), Image.BILINEAR))).blob_core
            for f in frames]
```

- [ ] **Step 4: `__main__.py`**

1. import 行改为：

```python
from petgen.keycheck import BLOB_CORE_MAX, frame_scores, score_file  # noqa: E402
from petgen.prompts import (PETS, POSE_ASPECT, PROPS, REF_POSE_FOR_ACTION, action_prompt, pose_prompt,  # noqa: E402
                            source_prompt)
```

（替换原来的 `from petgen.keycheck import score_file` 与 `from petgen.prompts import ...` 两行。）

2. `VIDEO_UNITS` 与注释替换为：

```python
# Pre-flight minimum per 5 s clip: std 3 units, pro 4 (measured 2026-09-12).
VIDEO_UNITS = {"std": 3, "pro": 4}
PROP_DIR = WORK / "props"
```

3. 在 `cmd_video` 之前加：

```python
def cmd_prop(a) -> int:
    from petgen.compose import EdgeError
    from petgen.props import cut_prop
    body = {"model_name": "kling-v3", "prompt": PROPS[a.kind],
            "negative_prompt": "动物，人，文字，水印，边框，多个物体", "aspect_ratio": "1:1", "resolution": "1k", "n": 1}
    d = kling.wait("image", kling.create_image(body))
    src = PROP_DIR / f"{a.kind}.png"
    kling.download(d["task_result"]["images"][0]["url"], src)
    print(f"prop {a.kind} -> {src.relative_to(HERE)}: deduction {d.get('final_unit_deduction')}")
    try:
        out = cut_prop(src, PROP_DIR / f"{a.kind}-cutout.png")
    except EdgeError as e:
        print(f"FAIL prop {a.kind}: {e}")
        return 1
    print(f"PASS prop {a.kind} -> {out.relative_to(HERE)}")
    return 0


def cmd_propref(a) -> int:
    from petgen.props import PROP_REFS, compose_prop
    d = pet_dir(a.pet, a.tag)
    cut = d / "ref-front-cutout.png"
    if not cut.exists():
        print(f"no {cut.relative_to(HERE)}: run pose / gate front first")
        return 1
    ok = True
    for stem, kind in PROP_REFS.items():
        prop = PROP_DIR / f"{kind}-cutout.png"
        if not prop.exists():
            print(f"no {prop.relative_to(HERE)}: run prop {kind} first")
            return 1
        s = score_file(compose_prop(cut, prop, kind, d / f"ref-{stem}-green.png"))
        ok = ok and s.passed
        print(f"{'PASS' if s.passed else 'FAIL'} {a.pet}/{stem}: floating={s.floating} blob_core={s.blob_core}")
    return 0 if ok else 1
```

4. `cmd_qa` 中 `last = score_file(...)` 之后、`passed = ...` 替换为：

```python
    worst = max(frame_scores(v))
    passed = fmt_ok and ok_seam and first.passed and last.passed and worst < BLOB_CORE_MAX
```

并在打印的 JSON 里 `"blob_core_last": last.blob_core` 之后加 `, "blob_core_worst": worst`。

5. `cmd_package` 的封面行改为：

```python
    make_cover(Image.open(d / "ref-front-cutout.png").convert("RGBA")).save(out / "cover.png")
```

6. `main()`：在 `sub.add_parser("import-spike")...` 之后加

```python
    pp = sub.add_parser("prop")
    pp.add_argument("kind", choices=list(PROPS))
    pp.set_defaults(fn=cmd_prop)
```

并在子命令列表里 `("package", cmd_package, None)` 之前加 `("propref", cmd_propref, None),`。

- [ ] **Step 5: 运行确认通过**

```powershell
.\.venv\Scripts\python -m pytest -q
.\.venv\Scripts\python -m petgen prop --help
.\.venv\Scripts\python -m petgen propref --help
.\.venv\Scripts\python -m petgen pose --help
```

Expected：全量无失败；`prop --help` 列出 `{bowl,ball}`；`propref --help` 有 `pet` 与 `--tag`；`pose --help` 的姿态里有 `front`。**不要**运行任何会调用可灵的命令。

- [ ] **Step 6: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add tools/petgen/petgen/keycheck.py tools/petgen/petgen/__main__.py tools/petgen/tests/test_keycheck.py
git commit -m "feat(petgen): prop and propref commands, qa checks every 6th frame, pro floor 4, front cover" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: 道具与参考图（控制器执行，花图片额度，约 32）

**Files:**
- Create: `docs/superpowers/plans/2026-09-19-front-facing-pets-results.md`
- 产物（不入库）：`tools/petgen/work/props/`、`tools/petgen/work/<pet>/v3/`

- [ ] **Step 1: 道具**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m petgen balance
.\.venv\Scripts\python -m petgen prop bowl
.\.venv\Scripts\python -m petgen prop ball
```

FAIL（碰边）时重生成一次。看 `work/props/*-cutout.png`：碗是红色、有粮、边缘干净；球是红色圆球。

- [ ] **Step 2: 金毛沿用 spike**

```powershell
New-Item -ItemType Directory -Force work\gold\v3 | Out-Null
Copy-Item work\gold\v3front\ref-front.png, work\gold\v3front\ref-front-cutout.png, work\gold\v3front\ref-front-green.png, work\gold\v3front\stand.mp4, work\gold\v3front\grade.json work\gold\v3\
Copy-Item work\gold\v2pro\walk-final.mp4, work\gold\v2pro\sleep-final.mp4 work\gold\v3\
.\.venv\Scripts\python -m petgen finish gold stand --tag v3
.\.venv\Scripts\python -m petgen qa gold stand --tag v3
```

- [ ] **Step 3: 柯基、布偶猫的正脸参考图**

```powershell
foreach ($pet in 'corgi', 'ragdoll') {
  .\.venv\Scripts\python -m petgen pose $pet front --tag v3 --resolution 2k --bright
  .\.venv\Scripts\python -m petgen gate $pet front --tag v3 --calibrate
  Copy-Item work\$pet\walk-final.mp4, work\$pet\sleep-final.mp4 work\$pet\v3\
}
```

gate FAIL 时对该宠物重生成一次 pose。

- [ ] **Step 4: 带道具的参考图**

```powershell
foreach ($pet in 'gold', 'corgi', 'ragdoll') { .\.venv\Scripts\python -m petgen propref $pet --tag v3 }
```

- [ ] **Step 5: 肉眼检查**

三只宠物 × {`ref-front-green`、`ref-front-bowl-green`、`ref-front-ball-green`} 拼一张图（每格缩到 320）存会话临时目录并查看：头正对镜头；碗、球在前爪前、大小合理、没有压住脸。
不合理（比如碗压在身体中间）就调 `props.py` 的常量并补测试后重跑 Step 4。结果写进结果文件（余额、gate 分数、图片说明）。

---

### Task 5: 视频（控制器执行，视频额度 56，需用户续购后开始）

- [ ] **Step 1: 额度检查**

`petgen balance` 的视频余额 ≥ 56 才整批开始；不足就停下告诉用户差多少。

- [ ] **Step 2: 生成、成片、质检**

先生成柯基、布偶猫的 `stand`（调色系数取自它），再做其余：

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
$jobs = @('corgi stand', 'ragdoll stand',
          'gold feed', 'gold play', 'gold lick_paw', 'gold act_cute',
          'corgi feed', 'corgi play', 'corgi lick_paw', 'corgi act_cute',
          'ragdoll feed', 'ragdoll play', 'ragdoll lick_paw', 'ragdoll act_cute')
foreach ($j in $jobs) {
  $pet, $act = $j.Split(' ')
  .\.venv\Scripts\python -m petgen video $pet $act --tag v3 --mode pro
  if ($LASTEXITCODE -ne 0) { "STOP at $j (video)"; break }
  .\.venv\Scripts\python -m petgen finish $pet $act --tag v3
  .\.venv\Scripts\python -m petgen qa $pet $act --tag v3
  if ($LASTEXITCODE -ne 0) { "QA FAIL $j" }
}
```

qa FAIL 的片段：记下原因，同配方重生成一次；再失败停下报告。

- [ ] **Step 3: 指标与动作幅度**

每只宠物 stand 第 30 帧的 `metrics`，与动作幅度（主体上逐帧与首帧的平均差，同 spike 算法），写进结果文件；逐条对照 Global Constraints。

---

### Task 6: 打包、回归、文档（控制器执行）

- [ ] **Step 1: 并排检查**

每只宠物 7 个动作各取首帧、中间帧，按客户端流程（键控 → 最大值限制去溢色 → 预乘）叠到深色底，拼图查看：同一只宠物、动作对得上名字、道具无鬼影。

- [ ] **Step 2: 打包与提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
foreach ($pet in 'gold', 'corgi', 'ragdoll') { .\.venv\Scripts\python -m petgen package $pet --tag v3 }
Set-Location C:\Users\Administrator\code\aipet
git lfs status
git add apps/aipet/assets/pets
git commit -m "feat(assets): front-facing idle, feed and play for the built-in pets" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

资产里的 mp4 与各 `-final.mp4` 做哈希比对。

- [ ] **Step 3: 回归与构建**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet; flutter analyze; flutter test; flutter build windows --release
Set-Location C:\Users\Administrator\code\aipet\tools\petgen; .\.venv\Scripts\python -m pytest -q
```

Expected：analyze 零问题，flutter 115/115，pytest 全过，release 构建成功。

- [ ] **Step 4: 文档**

结果文件补全；`HANDOFF.md` 第 0 节写进度、第 4 节在 spike 块后补"全量结果"。

```powershell
git add docs/superpowers/plans/2026-09-19-front-facing-pets-results.md
git commit -m "docs: front-facing pets results" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
