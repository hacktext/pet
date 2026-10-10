# aipet 定制宠物生成程序（petgen pipeline + worker） Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `python -m petgen worker --server URL` 自动向 PHP 领取已付款的定制单，用用户照片经可灵生成参考图与动作视频、成片质检、打包上传，交给后台审核；中断可续跑、重做只做该做的、不超预算。

**Architecture:** 把现有按内置宠物名硬编码的命令拆出可复用的函数（提示词、打包、质检、下载），新建以「任务目录」`<work>/jobs/<id>/` 为单位的流水线 `petgen/pipeline.py`，每步写 `state.json`（可灵任务 id 与结果 URL 在下载前就落盘）。`petgen/server.py` 是内部接口客户端，`petgen/reporter.py` 负责进度 / 心跳 / abort / 停止，`petgen/worker.py` 是领单循环。内置宠物 CLI 行为不变，由快照与回归测试守住。

**Tech Stack:** Python 3.11+（本机 3.14.2）、标准库 `urllib` / `threading` / `signal`（不加 HTTP 依赖）、numpy、Pillow、rembg、ffmpeg / ffprobe、pytest。

**Spec:** `docs/superpowers/specs/2026-10-10-aipet-custom-generation-design.md`（本计划只实现第 5 节 tools/petgen 与 4.5 成本核算；服务端、后台、客户端在别的计划里）

## Global Constraints

- 仓库 `C:\Users\Administrator\code\aipet`，分支 `feat/human-character`，工作区里有大量与本计划无关的未提交改动。**只用显式路径提交**：`git add <本任务改过的文件>`；禁止 `git add -A` / `git add .` / `git stash` / `git reset` / `git checkout -- <file>`。
- `tools/petgen` 里有用户自己未提交的工作：未跟踪的 `petgen/volc.py`、`tests/test_volc.py`，以及 `petgen/__main__.py`（voice 命令，依赖 volc.py）与 `tests/test_cli.py` 的改动。**在工作区上继续改，不回退它们**。不要修改 `volc.py`、`test_volc.py`、`tests/test_cli.py`（新的 CLI 测试写进新文件 `tests/test_cli_paths.py`、`tests/test_cli_worker.py`）。
- `petgen/__main__.py` 第一次要提交（Task 2 Step 8）前**停下来问用户**：(a) 用户先自己提交 voice 改动（volc.py、test_volc.py、__main__.py、test_cli.py）后再继续；或 (b) 本计划所有任务都不提交 `__main__.py`，它的改动留在工作区，最后在报告里列出。没有得到答复就按 (b)。
- 命令都在 `tools/petgen` 下跑（Bash）：`cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest ...`（Linux 服务器上是 `.venv/bin/python`）。开工前基线：`103 passed, 4 skipped`。
- 写文件用 Write / Edit 工具。**不要用 bash heredoc 写含反斜杠的内容**（会吃掉 `\`）。
- 测试全部离线：可灵与 PHP 都用假实现（`tests/fakes.py`），不发真实网络请求；ffmpeg 可用（现有测试已在用）。
- 不加新依赖，`requirements.txt` 不变；HTTP 只用 `urllib`（与 `kling.py` 一致）。
- 密钥：`secrets/kling.env`（`KLING_API_KEY`、`KLING_BASE_URL`）、`secrets/worker.env`（`AIPET_WORKER_KEY`、价格表）。环境变量 `PETGEN_SECRETS` 可指向别的目录（服务器）。**代码、日志、测试输出、对话里都不出现密钥值**；检查时只看长度。
- 可灵（HANDOFF §4）：`Authorization: Bearer`；create 返回 `code == 0` 才算建成，否则不扣费；轮询 `GET <同路径>/<task_id>`，`task_status ∈ submitted|processing|succeed|failed`，`final_unit_deduction` 是实际扣费；参考图 = `kling-v3` + `image_reference: "subject"` + 用户照片 + `resolution: "2k"` + bright 提示词 + `POSE_ASPECT[pose]`；**不让模型直接画绿底**，浅灰底出图后本地 `compose(..., calibrate=True)` 合成到 `#00FF00` 再 gate（不贴边、`blob_core < 200`）；视频 = `kling-v3` `mode: "pro"` `duration: "5"`，`image = image_tail =` 绿底参考图（`REF_POSE_FOR_ACTION`），`external_task_id = aipet-<id>-<action>-<n>`，n 永不复用。估价单位：图 8、pro 视频 4。
- 内部接口（服务端计划 `2026-10-10-aipet-generation-server.md` 实现，**逐字匹配**）：全部 `POST`，`Content-Type: application/json`，头 `X-Worker-Key`。**不用** `{code, message, data}` 信封：成功 = HTTP 200 + 下列 JSON 本体；出错 = HTTP 状态码 + `{"error": "..."}`——401/403（密钥 / IP）、404、**409（单子已不在 generating，body 带 `"abort": true` → 按 abort 处理，停下这一单、不报 fail）**、422（请求体不合法）、500、503。
  - `jobs/claim` `{}` → `{job: null | {id, pet_id, name, species, actions, redo, budget_cents, spent_cents, photos: [{url}]}, paused_reason?}`；`redo` 为 `null | {all: true} | {actions: [...], refs: bool, hint: str}`。重做 / 重新生成时服务端把 `budget_cents` 重置为 `spent + 8000`，生成程序**照单全收**这两个数。
  - `jobs/:id/progress` `{stage, done, total, message, cost: {image_units, video_units, cents}}` → `{abort: bool}`。`cost` 是**距上一次 progress 的增量**，服务端累加（回 `abort: true` 时也照样累加）。`stage` 用步骤类别（`fetch` / `refs` / `propref` / `video` / `package` / `upload`），`done` / `total` 是该类别内的计数，`message` 是当前项（如 `play`）——与服务端示例 `{"stage": "video", "done": 2, "total": 5, "message": "play"}` 一致。
  - `jobs/:id/upload-urls` `{files: [{path, bytes, content_type}]}` → **顶层数组** `[{path, url}]`（顺序同请求）；PUT 时 `Content-Type` 必须等于申请时的 `content_type`；30 分钟有效。路径须匹配 `^(refs/)?[a-z0-9][a-z0-9_-]{0,47}\.(mp4|png|jpg|json)$`，类型 mp4→`video/mp4`、png→`image/png`、jpg→`image/jpeg`、json→`application/json`，单个 ≤ 100MB。
  - `jobs/:id/finish` `{walk_facing, files: [{path, bytes, sha256, qa, deliverable}]}`：服务端 HEAD 每个对象核对存在与大小；历史 + 本次文件的并集须含 `pet.json`、`cover.png` 与每个 `<action>.mp4`。本计划每次都上传并上报**全部**文件（重做时也是，简单且一定满足并集要求）；`refs/*` 服务端总按不下发存。
  - `jobs/:id/fail` `{stage, reason}`（reason ≤ 255 字；`stage` 用步骤键，如 `video:play`、`ref:front`、`claim`）
  - `worker/status` `{paused, reason, balance: {image, video}}`。报过 `paused: true` 后，claim 一直回 `{job: null, paused_reason}`，**直到再报 `paused: false`**——余额恢复后必须报一次。
- `pet.json`：`{schema: 1, id: pet_id, name, species, origin: "custom", blurb: "", cover: "cover.png", actions, walkFacing}`。下发文件：`pet.json`、`cover.png`、`<action>.mp4`；`refs/front.png`、`refs/walk.png`、`refs/lie.png` 以 `deliverable=false` 上传供审核。
- 动作只取 `[stand, walk, feed, play, sleep, lick_paw, act_cute]` 的子集；species 只有 `dog`、`cat`。预算默认 8000 分。
- worker 节奏：每单前查余额，图片 < 32（8×4）或视频 < 28（最大套餐 7 动作 × 4）就上报暂停（原因「生成额度不足」）并 5 分钟后重查；无任务 sleep 15 秒；心跳 60 秒。
- 价格表默认 `AIPET_PRICE_IMAGE_UNIT_CENTS=10`、`AIPET_PRICE_VIDEO_UNIT_CENTS=100`（视频按 HANDOFF「约 1 元/单位」，图片为保守估计）——**上线前按实际购买价改 worker.env**。
- 真实调用可灵（花钱）只在用户明确同意后做（Task 11）。
- commit message 英文 `feat(petgen): ...` / `refactor(petgen): ...`，结尾带 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. **worker 在下载已付费片段时被杀 / 连接断（IncompleteRead）**：重启或重新领取后不得再付费生成，直接用 `state.json` 里的 task id / URL 续传或重下。（Task 4 下载器测试；Task 7 `test_a_paid_still_is_not_paid_again_after_a_crash_mid_download`、`test_a_crash_while_waiting_resumes_the_same_task`；Task 8 `test_a_restart_skips_finished_steps_and_resumes_the_paid_clip`）
2. **重做一个动作不得重生别的动作**；同一个 redo 在上传前崩溃、被重新领取时也不得再生一次。（Task 5 redo 测试；Task 8 `test_redo_of_one_action_remakes_only_that_clip_with_the_hint`、`test_a_redo_interrupted_before_upload_is_not_remade`）
3. **用户照片触发可灵内容审核**：换另一张照片重试一次，仍失败则 `fail`，原因可读（含「参考图 front」与可灵的错误码 / 信息）。（Task 7、Task 10 测试）
4. **单笔预算在中途超出**：下一次可灵调用前就停，不再花钱，`fail` 原因「超出单笔预算」。（Task 7、Task 8、Task 10 测试）
5. **后台在生成中改了单（abort）**：progress 回 `abort: true` 或任何接口回 409 + `abort: true`，都在下一个检查点停下，不上报 fail，已建的可灵任务 id 留在 state.json。两单之间余额跌破阈值：不领单、上报暂停；恢复后报 `paused: false`。（Task 6、Task 8、Task 9、Task 10 测试）

---

## 文件结构

全部相对 `tools/petgen/`：

| 文件 | 职责 |
|---|---|
| `petgen/prompts.py`（改） | 抽出与品种无关的拼接；新增 `custom_pose_prompt`、`custom_action_prompt` |
| `petgen/config.py`（新） | `secrets_dir()`、`read_env()`、`Prices`、`WorkerConfig`、`load_worker_config()` |
| `petgen/kling.py`（改） | 密钥目录走 config；`KlingRejected` / `KlingTaskFailed`；`wait(on_poll=)`；`download` 走重试下载器；`units_left(kind)` |
| `petgen/download.py`（新） | 流式写 `.part`、Range 续传、重试 3 次、改名 |
| `petgen/package.py`（改） | `custom_pet_json()`、`write_pet_dir()` |
| `petgen/qa.py`（新） | `qa_clip()`：格式 / 接缝 / 鬼影，CLI 与 worker 共用 |
| `petgen/jobstate.py`（新） | `Job`（解析 claim）、`JobState`（state.json）、`apply_redo()`、`base_pose()` |
| `petgen/server.py`（新） | 内部接口客户端 `Server`、`ServerError`、`ServerAbort`（409 + abort） |
| `petgen/pipeline.py`（新） | `Env`、`Run`、`generate()`、各步骤、`run_job()`、异常类型 |
| `petgen/reporter.py`（新） | `Reporter`：进度、60 秒心跳线程、abort、停止请求 |
| `petgen/worker.py`（新） | `Worker`：查余额 → 暂停 / 领单 → 跑单 → fail |
| `petgen/__main__.py`（改） | `import-spike --from`、`package --out`、`qa` 用 `qa_clip`、`worker` 命令 |
| `deploy/aipet-worker.service`（新） | systemd 单元示例 |
| `../../secrets/worker.env.example`（新） | worker 配置模板（仓库根 `secrets/`） |
| `tests/data/builtin_prompts.json`（新） | 内置宠物全部提示词快照 |
| `tests/fakes.py`、`tests/conftest.py`（新） | 假可灵、假服务端、假进度、假本地工具、`rig` fixture |
| `tests/test_config.py` `test_download.py` `test_qa.py` `test_jobstate.py` `test_server.py` `test_pipeline_steps.py` `test_pipeline_run.py` `test_reporter.py` `test_worker.py` `test_cli_paths.py` `test_cli_worker.py`（新）；`test_prompts.py` `test_package.py` `test_kling.py` `test_loopcheck.py`（改） | 测试 |

---

### Task 1: 提示词：内置快照回归 + 定制宠物提示词

**Files:**
- Modify: `tools/petgen/petgen/prompts.py:103-137`（`_it` 起到文件末尾）
- Create: `tools/petgen/tests/data/builtin_prompts.json`（生成的快照）
- Test: `tools/petgen/tests/test_prompts.py`

**Interfaces:**
- Consumes: 现有 `PETS`、`POSES`、`_ACTIONS`、`_TAIL`、`BRIGHT`
- Produces:
  - `SPECIES_NOUN: dict[str, str]`（`{"dog": "狗", "cat": "猫"}`）
  - `custom_pose_prompt(species: str, pose: str, bright: bool = True) -> str`
  - `custom_action_prompt(species: str, action: str, hint: str = "") -> str`（hint 非空时末尾追加 `补充要求：<hint>`）
  - `pose_prompt` / `action_prompt` / `source_prompt` 输出与改动前逐字相同

- [ ] **Step 1: 写快照测试（先只加快照部分）**

在 `tests/test_prompts.py` 顶部 import 区改为：

```python
import json
from pathlib import Path

import pytest

from petgen.package import ACTIONS
from petgen.prompts import (BRIGHT, PETS, POSE_ASPECT, PROPS, REF_POSE_FOR_ACTION, action_prompt, pose_prompt,
                            source_prompt)

SNAPSHOT = Path(__file__).parent / "data" / "builtin_prompts.json"


def _all_builtin_prompts() -> dict:
    snap = {}
    for pet in PETS:
        snap[f"source/{pet}"] = source_prompt(pet)
        for pose in POSE_ASPECT:
            for bright in (False, True):
                snap[f"pose/{pet}/{pose}/{int(bright)}"] = pose_prompt(pet, pose, bright=bright)
        for action in ACTIONS:
            snap[f"action/{pet}/{action}"] = action_prompt(pet, action)
    return snap


def test_builtin_prompts_are_unchanged_by_the_custom_refactor():
    assert _all_builtin_prompts() == json.loads(SNAPSHOT.read_text(encoding="utf-8"))
```

（文件里原有的测试函数保持不动。）

- [ ] **Step 2: 用改动前的代码生成快照**

Run:
```bash
cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -c "import json; from tests.test_prompts import _all_builtin_prompts, SNAPSHOT; SNAPSHOT.parent.mkdir(exist_ok=True); SNAPSHOT.write_text(json.dumps(_all_builtin_prompts(), ensure_ascii=False, indent=1) + chr(10), encoding='utf-8')"
.venv/Scripts/python -m pytest tests/test_prompts.py -v
```
Expected: 生成 `tests/data/builtin_prompts.json`（3 个 source + 24 个 pose + 21 个 action = 48 项）；全部 PASS。

- [ ] **Step 3: 写定制提示词的失败测试**

import 区改为（加 `SPECIES_NOUN`、`custom_action_prompt`、`custom_pose_prompt`）：

```python
from petgen.prompts import (BRIGHT, PETS, POSE_ASPECT, PROPS, REF_POSE_FOR_ACTION, SPECIES_NOUN, action_prompt,
                            custom_action_prompt, custom_pose_prompt, pose_prompt, source_prompt)
```

文件末尾追加：

```python
def test_custom_pose_prompt_names_the_species_and_is_bright_by_default():
    dog = custom_pose_prompt("dog", "front")
    assert dog.startswith("参考图中这只狗的全身照片，保持它的脸、毛色和花纹完全一样。正面朝向镜头")
    assert "舌头" in dog and dog.endswith(BRIGHT)
    assert "。。" not in dog
    cat = custom_pose_prompt("cat", "lie", bright=False)
    assert "这只猫" in cat and "趴卧" in cat and BRIGHT not in cat


def test_custom_action_prompt_uses_the_species_text_and_the_fixed_camera():
    feed = custom_action_prompt("cat", "feed")
    assert feed.startswith("这只猫面朝镜头") and "猫粮" in feed and "镜头完全固定" in feed
    assert custom_action_prompt("dog", "walk").startswith("这只狗原地踏步行走")


def test_a_redo_hint_is_appended_and_a_blank_one_is_ignored():
    base = custom_action_prompt("dog", "play")
    assert custom_action_prompt("dog", "play", "尾巴摆慢一点") == base + "补充要求：尾巴摆慢一点"
    assert custom_action_prompt("dog", "play", "   ") == base


def test_only_dogs_and_cats_have_custom_prompts():
    assert set(SPECIES_NOUN) == {"dog", "cat"}
    with pytest.raises(KeyError):
        custom_pose_prompt("other", "front")
```

- [ ] **Step 4: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_prompts.py -v`
Expected: ImportError `cannot import name 'SPECIES_NOUN'`

- [ ] **Step 5: 实现**

把 `petgen/prompts.py` 从 `def _it(pet: str) -> str:` 那一行起到文件末尾整段替换为：

```python
SPECIES_NOUN = {"dog": "狗", "cat": "猫"}


def _it(pet: str) -> str:
    return f"这只{PETS[pet]['breed']}"


def _by_species(text: str | dict, species: str) -> str:
    """A prompt that differs by species is a {species: text} dict."""
    return text[species] if isinstance(text, dict) else text


def source_prompt(pet: str) -> str:
    p = PETS[pet]
    return (f"一只{p['breed']}的写实摄影照片。{p['features']}。"
            "身体侧对镜头四分之三角度站立，从头到尾巴、四条腿全部完整入画。"
            "浅灰色无缝影棚背景，柔和的漫射光，毛发细节清晰锐利，画面里只有这一只动物。")


# Recipe v2 (2026-09-12): bright high-key studio light. Our first references
# came out dim (subject luma ~128) and Kling carries the reference's exposure
# straight into the video.
BRIGHT = "明亮柔和的高调影棚光，整体曝光充足，毛色鲜亮饱满，每一缕毛丝都清晰可见，焦点清晰。"


def _pose_text(noun: str, features: str, species: str, pose: str, bright: bool) -> str:
    feat = f"{features}。" if features else ""
    base = (f"参考图中这只{noun}的全身照片，保持它的脸、毛色和花纹完全一样。{feat}"
            + _by_species(POSES[pose], species) +
            "它只占画面中间大约一半的宽度，四周留出大片空白，尾巴尖离画面边缘很远。"
            "背景是浅灰色的无缝影棚背景纸，颜色均匀中性，没有任何物体，画面没有边框。"
            "柔和的大面积漫射光，几乎没有投影，身下没有明显的影子。"
            "写实摄影，毛发细节清晰锐利，画面里只有这一只动物。")
    return base + BRIGHT if bright else base


def pose_prompt(pet: str, pose: str, bright: bool = False) -> str:
    p = PETS[pet]
    return _pose_text(p["breed"], p["features"], p["species"], pose, bright)


def custom_pose_prompt(species: str, pose: str, bright: bool = True) -> str:
    """A customer's pet has no breed or features on file: the reference photo
    carries its looks. The production recipe is bright (HANDOFF 4)."""
    return _pose_text(SPECIES_NOUN[species], "", species, pose, bright)


def _action_text(it: str, species: str, action: str) -> str:
    return _by_species(_ACTIONS[action], species).format(it=it) + _TAIL


def action_prompt(pet: str, action: str) -> str:
    return _action_text(_it(pet), PETS[pet]["species"], action)


def custom_action_prompt(species: str, action: str, hint: str = "") -> str:
    """hint: the reviewer's one-line note from a redo, appended verbatim."""
    text = _action_text(f"这只{SPECIES_NOUN[species]}", species, action)
    hint = hint.strip()
    return text + f"补充要求：{hint}" if hint else text
```

- [ ] **Step 6: 运行，确认通过（含快照）**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_prompts.py -v`
Expected: 全部 PASS（快照测试证明内置提示词逐字未变）

- [ ] **Step 7: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/prompts.py tools/petgen/tests/test_prompts.py tools/petgen/tests/data/builtin_prompts.json
git commit -m "feat(petgen): species-only prompts for customers' pets; snapshot the built-in ones

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 去掉 Windows 专属假设：密钥目录、import-spike / package 路径参数、ffmpeg 守卫

**Files:**
- Create: `tools/petgen/petgen/config.py`
- Modify: `tools/petgen/petgen/kling.py:12-13,21-28`（`REPO` / `ENV` / `_cfg`）
- Modify: `tools/petgen/petgen/package.py`（加 `custom_pet_json`、`write_pet_dir`）
- Modify: `tools/petgen/petgen/__main__.py`（删 `SPIKE_OUT`；`_rel`；`cmd_import_spike`；`cmd_package`；parser）
- Test: `tools/petgen/tests/test_config.py`（新）、`tools/petgen/tests/test_cli_paths.py`（新）、`tools/petgen/tests/test_package.py`、`tools/petgen/tests/test_loopcheck.py`

**Interfaces:**
- Consumes: `package.make_cover`、`package.pet_json`、`prompts.PETS` / `POSE_ASPECT`
- Produces:
  - `config.REPO: Path`、`config.ConfigError(Exception)`、`config.secrets_dir() -> Path`（`$PETGEN_SECRETS` 或 `<repo>/secrets`）、`config.read_env(path: Path) -> dict[str, str]`
  - `package.custom_pet_json(pet_id: str, name: str, species: str, actions, walk_facing: str) -> dict`
  - `package.write_pet_dir(out: Path, clips: dict[str, Path], cutout: Path, meta: dict) -> Path`
  - CLI：`petgen import-spike --from DIR`（缺省取 `$PETGEN_SPIKE_OUT`，都没有则报错返回 1）；`petgen package <pet> --out DIR`（缺省仍是 `apps/aipet/assets/pets/builtin-<pet>`）

审计结论（不用改代码）：唯一把文件名写进 ffmpeg 滤镜图的是 `loopcheck.psnr_series`，它已用 `cwd=workdir` + 相对的 stats 文件名；其他 ffmpeg 调用只把路径当普通参数，Linux / Windows 都没问题。本任务加一条守卫测试锁住它。

- [ ] **Step 1: 写失败的测试**

`tests/test_config.py`：

```python
from petgen import kling
from petgen.config import REPO, read_env, secrets_dir


def test_secrets_dir_follows_PETGEN_SECRETS(monkeypatch, tmp_path):
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    assert secrets_dir() == tmp_path
    monkeypatch.delenv("PETGEN_SECRETS")
    assert secrets_dir() == REPO / "secrets"


def test_read_env_skips_comments_and_blank_lines(tmp_path):
    p = tmp_path / "x.env"
    p.write_text("# comment\n\nA = 1\nB=two=2\nnot a pair\n", encoding="utf-8")
    assert read_env(p) == {"A": "1", "B": "two=2"}


def test_kling_reads_its_key_from_the_secrets_dir(monkeypatch, tmp_path):
    (tmp_path / "kling.env").write_text("KLING_API_KEY=abc\nKLING_BASE_URL=https://k.invalid/\n", encoding="utf-8")
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    assert kling._cfg() == ("abc", "https://k.invalid")
```

`tests/test_cli_paths.py`：

```python
import json
import sys

from PIL import Image

import petgen.__main__ as cli
from petgen.package import ACTIONS, pet_json
from petgen.prompts import PETS, POSE_ASPECT


def _fake_pet(work, pet="gold"):
    d = work / pet
    d.mkdir(parents=True)
    for k in ACTIONS:
        (d / f"{k}-final.mp4").write_bytes(f"clip {k}".encode())
    Image.new("RGBA", (80, 60), (200, 150, 100, 255)).save(d / "ref-front-cutout.png")
    return d


def test_package_writes_to_out_when_given(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    _fake_pet(tmp_path / "work")
    out = tmp_path / "anywhere" / "gold"
    monkeypatch.setattr(sys, "argv", ["petgen", "package", "gold", "--facing", "left", "--out", str(out)])
    assert cli.main() == 0
    assert json.loads((out / "pet.json").read_text(encoding="utf-8")) == pet_json("gold", "left")
    assert (out / "stand.mp4").read_bytes() == b"clip stand"
    assert (out / "cover.png").exists()
    assert "walkFacing left (--facing)" in capsys.readouterr().out


def test_package_defaults_to_the_app_assets(monkeypatch, tmp_path):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    monkeypatch.setattr(cli, "ASSETS", tmp_path / "assets")
    _fake_pet(tmp_path / "work")
    monkeypatch.setattr(sys, "argv", ["petgen", "package", "gold", "--facing", "right"])
    assert cli.main() == 0
    meta = json.loads((tmp_path / "assets" / "builtin-gold" / "pet.json").read_text(encoding="utf-8"))
    assert meta["walkFacing"] == "right"


def test_package_still_refuses_missing_clips(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    d = _fake_pet(tmp_path / "work")
    (d / "play-final.mp4").unlink()
    monkeypatch.setattr(sys, "argv", ["petgen", "package", "gold", "--out", str(tmp_path / "out")])
    assert cli.main() == 1
    assert "missing clips ['play-final.mp4']" in capsys.readouterr().out


def test_import_spike_reads_the_given_folder(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    src = tmp_path / "spike"
    src.mkdir()
    for pet in PETS:
        (src / f"src-{pet}.png").write_bytes(b"s")
        for pose in POSE_ASPECT:
            (src / f"ref-{pet}-{pose}.png").write_bytes(b"r")
    monkeypatch.setattr(sys, "argv", ["petgen", "import-spike", "--from", str(src)])
    assert cli.main() == 0
    assert (tmp_path / "work" / "gold" / "ref-front.png").read_bytes() == b"r"


def test_import_spike_without_a_folder_says_how(monkeypatch, capsys):
    monkeypatch.delenv("PETGEN_SPIKE_OUT", raising=False)
    monkeypatch.setattr(sys, "argv", ["petgen", "import-spike"])
    assert cli.main() == 1
    assert "--from" in capsys.readouterr().out
```

`tests/test_package.py`：import 区改为

```python
import json
import subprocess

import numpy as np
from PIL import Image

from petgen.package import (COVER_MAX, chosen_facing, custom_pet_json, make_cover, pet_json, walk_facing,
                            write_pet_dir)
```

文件末尾追加：

```python
def test_custom_pet_json_matches_the_delivery_contract():
    assert custom_pet_json("custom-12", "豆豆", "dog", ("stand", "walk"), "left") == {
        "schema": 1, "id": "custom-12", "name": "豆豆", "species": "dog", "origin": "custom", "blurb": "",
        "cover": "cover.png", "actions": ["stand", "walk"], "walkFacing": "left",
    }


def test_write_pet_dir_copies_clips_and_writes_cover_and_json(tmp_path):
    clip = tmp_path / "stand-final.mp4"
    clip.write_bytes(b"clip")
    cut = tmp_path / "cut.png"
    Image.new("RGBA", (120, 80), (200, 150, 100, 255)).save(cut)
    out = write_pet_dir(tmp_path / "out", {"stand": clip}, cut, {"id": "x"})
    assert (out / "stand.mp4").read_bytes() == b"clip"
    assert Image.open(out / "cover.png").mode == "RGBA"
    assert json.loads((out / "pet.json").read_text(encoding="utf-8")) == {"id": "x"}
```

`tests/test_loopcheck.py` 末尾追加：

```python
def test_filtergraphs_never_name_an_absolute_path(monkeypatch, tmp_path):
    """A Windows drive colon breaks filtergraph syntax and a Linux server has
    none: the stats files are named relative to ffmpeg's cwd."""
    import petgen.loopcheck as lc
    calls = []

    def fake_run(args, check, cwd):
        calls.append((args, cwd))
        for name in ("vs_f0.log", "consec.log"):
            (cwd / name).write_text("n:1 psnr_avg:inf\n", encoding="utf-8")

    monkeypatch.setattr(lc.subprocess, "run", fake_run)
    work = tmp_path / "psnr"
    lc.psnr_series(tmp_path / "v.mp4", work)
    assert len(calls) == 2
    for args, cwd in calls:
        graph = args[args.index("-filter_complex") + 1]
        assert cwd == work
        assert str(tmp_path) not in graph and "/" not in graph and "\\" not in graph
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_config.py tests/test_cli_paths.py tests/test_package.py tests/test_loopcheck.py -v`
Expected: `ModuleNotFoundError: No module named 'petgen.config'`；`cannot import name 'custom_pet_json'`；CLI 测试 `unrecognized arguments: --out` / `--from`。`test_filtergraphs_never_name_an_absolute_path` 已经 PASS（守卫现状）。

- [ ] **Step 3: 新建 `petgen/config.py`**

```python
"""Where secrets live, and the worker's settings. Never prints a value."""
from __future__ import annotations

import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]


class ConfigError(Exception):
    pass


def secrets_dir() -> Path:
    """$PETGEN_SECRETS on a server where tools/petgen is not inside the repo;
    the repo's secrets/ otherwise."""
    return Path(os.environ.get("PETGEN_SECRETS") or REPO / "secrets")


def read_env(path: Path) -> dict[str, str]:
    kv: dict[str, str] = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    return kv
```

- [ ] **Step 4: `kling.py` 改读密钥目录**

删掉第 12–13 行：

```python
REPO = Path(__file__).resolve().parents[3]
ENV = REPO / "secrets" / "kling.env"
```

在 `from pathlib import Path` 之后加：

```python

from petgen.config import read_env, secrets_dir
```

`_cfg` 整个替换为：

```python
def _cfg() -> tuple[str, str]:
    kv = read_env(secrets_dir() / "kling.env")
    return kv["KLING_API_KEY"], kv["KLING_BASE_URL"].rstrip("/")
```

- [ ] **Step 5: `package.py` 加两个函数**

import 区改为：

```python
from __future__ import annotations

import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image

from petgen.prompts import PETS
```

`pet_json` 之后插入：

```python
def custom_pet_json(pet_id: str, name: str, species: str, actions, walk_facing: str) -> dict:
    """pet.json for a customer's pet (spec 2026-10-10 5.1 step 6)."""
    return {"schema": 1, "id": pet_id, "name": name, "species": species, "origin": "custom", "blurb": "",
            "cover": "cover.png", "actions": list(actions), "walkFacing": walk_facing}
```

文件末尾追加：

```python
def write_pet_dir(out: Path, clips: dict[str, Path], cutout: Path, meta: dict) -> Path:
    """A pet folder: <action>.mp4 per clip, cover.png from the cutout, pet.json = meta."""
    out.mkdir(parents=True, exist_ok=True)
    for action, clip in clips.items():
        shutil.copy2(clip, out / f"{action}.mp4")
    make_cover(Image.open(cutout).convert("RGBA")).save(out / "cover.png")
    (out / "pet.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out
```

- [ ] **Step 6: `__main__.py` 参数化路径**

1. 第 22 行 import 改为：

```python
from petgen.package import ACTIONS, chosen_facing, pet_json, write_pet_dir  # noqa: E402
```

2. 删除第 27–28 行的 `SPIKE_OUT = Path(r"C:\Users\...\scratchpad\out")` 两行。

3. `pet_dir` 之前插入：

```python
def _rel(p: Path, base: Path = HERE) -> Path:
    """For messages: relative to base when inside it, else as given (--out /
    --from may point anywhere)."""
    try:
        return p.relative_to(base)
    except ValueError:
        return p
```

4. `cmd_import_spike` 整个替换为：

```python
def cmd_import_spike(a) -> int:
    spike = a.src or (Path(os.environ["PETGEN_SPIKE_OUT"]) if os.environ.get("PETGEN_SPIKE_OUT") else None)
    if spike is None:
        print("pass --from <spike out folder> (or set PETGEN_SPIKE_OUT)")
        return 1
    missing = 0
    for pet in PETS:
        pairs = [(spike / f"src-{pet}.png", pet_dir(pet) / "src.png")]
        pairs += [(spike / f"ref-{pet}-{pose}.png", pet_dir(pet) / f"ref-{pose}.png") for pose in POSE_ASPECT]
        for src, dst in pairs:
            if src.exists():
                shutil.copy2(src, dst)
                print(f"imported {_rel(dst)}")
            else:
                missing += 1
                print(f"MISSING {src.name} -> regenerate with the source/pose command")
    return 1 if missing else 0
```

5. `cmd_package` 整个替换为：

```python
def cmd_package(a) -> int:
    d = pet_dir(a.pet, a.tag)
    clips = {k: d / f"{k}-final.mp4" for k in ACTIONS}
    missing = [c.name for c in clips.values() if not c.exists()]
    if missing:
        print(f"missing clips {missing}")
        return 1
    out = a.out or ASSETS / f"builtin-{a.pet}"
    facing = chosen_facing(a.facing, d / "walk-final.mp4")
    write_pet_dir(out, clips, d / "ref-front-cutout.png", pet_json(a.pet, facing))
    print(f"walkFacing {facing}{' (--facing)' if a.facing else ' (detected)'}")
    print(f"packaged {_rel(out, REPO)}")
    return 0
```

6. `main()` 里 `sub.add_parser("import-spike").set_defaults(fn=cmd_import_spike)` 替换为：

```python
    ip = sub.add_parser("import-spike")
    ip.add_argument("--from", dest="src", type=Path, default=None,
                    help="the spike's out folder; default $PETGEN_SPIKE_OUT")
    ip.set_defaults(fn=cmd_import_spike)
```

7. 循环里 `if name == "package":` 分支改为：

```python
        if name == "package":
            p.add_argument("--facing", choices=["left", "right"], default=None)
            p.add_argument("--out", type=Path, default=None,
                           help="pet folder to write; default apps/aipet/assets/pets/builtin-<pet>")
```

- [ ] **Step 7: 运行，确认通过（全量）**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest -q`
Expected: 全部 PASS（基线 103 + 新增），skip 数不变。

- [ ] **Step 8: Commit**

先按 Global Constraints 问用户 `__main__.py` 怎么处理（只问这一次，答案沿用到后面所有任务）。按 (a)：

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/config.py tools/petgen/petgen/kling.py tools/petgen/petgen/package.py tools/petgen/petgen/__main__.py tools/petgen/tests/test_config.py tools/petgen/tests/test_cli_paths.py tools/petgen/tests/test_package.py tools/petgen/tests/test_loopcheck.py
git commit -m "refactor(petgen): secrets dir, spike and package paths are parameters, not this PC's

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

按 (b)：同一条命令去掉 `tools/petgen/petgen/__main__.py` 和 `tools/petgen/tests/test_cli_paths.py`（它测的是 `__main__` 的改动，一起留在工作区）。

---

### Task 3: `qa_clip`：成片质检抽成共用函数

**Files:**
- Create: `tools/petgen/petgen/qa.py`
- Modify: `tools/petgen/petgen/__main__.py`（删 `_frame`，`cmd_qa` 改用 `qa_clip`，精简 import）
- Test: `tools/petgen/tests/test_qa.py`（新）、`tools/petgen/tests/test_cli_paths.py`

**Interfaces:**
- Consumes: `keycheck.FRAME_BLOB_MAX` / `frame_scores` / `score_file`、`loopcheck.probe` / `psnr_series` / `seam_verdict`
- Produces: `qa.FORMAT: dict`、`qa.frame_png(video: Path, out: Path, last: bool) -> Path`、`qa.qa_clip(video: Path, workdir: Path, stem: str) -> dict`，返回 `{"pass": bool, "format": dict, "seam": float, "worst_step": float, "blob_core_first": int, "blob_core_last": int, "blob_core_worst": int}`（可直接 `json.dumps`；中间文件写 `workdir/qa-<stem>*`）

- [ ] **Step 1: 写失败的测试**

`tests/test_qa.py`：

```python
import json
import subprocess

from petgen.qa import FORMAT, qa_clip


def _clip(path, size=960, frames=121):
    """Exact green with a still opaque box: a perfect loop with nothing floating."""
    b = size // 3
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c=0x00FF00:s={size}x{size}:r=24",
                    "-vf", f"drawbox=x={b}:y={b}:w={b}:h={b}:color=0xC89664:t=fill",
                    "-frames:v", str(frames), "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", str(path)],
                   check=True)


def test_a_clean_square_loop_passes_and_reports_every_number(tmp_path):
    v = tmp_path / "stand-final.mp4"
    _clip(v)
    r = qa_clip(v, tmp_path, "stand")
    assert r["pass"] is True
    assert r["format"] == FORMAT
    assert set(r) == {"pass", "format", "seam", "worst_step", "blob_core_first", "blob_core_last", "blob_core_worst"}
    assert (tmp_path / "qa-stand-first.png").exists() and (tmp_path / "qa-stand-last.png").exists()
    json.dumps(r)


def test_the_wrong_format_fails(tmp_path):
    v = tmp_path / "x.mp4"
    _clip(v, size=480, frames=48)
    r = qa_clip(v, tmp_path, "x")
    assert r["pass"] is False and r["format"]["width"] == 480
```

`tests/test_cli_paths.py` 末尾追加：

```python
def test_qa_command_prints_the_same_report(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    d = tmp_path / "work" / "gold"
    d.mkdir(parents=True)
    (d / "stand-final.mp4").write_bytes(b"x")
    report = {"pass": False, "format": {"width": 960}, "seam": 30.0, "worst_step": 31.0,
              "blob_core_first": 1, "blob_core_last": 2, "blob_core_worst": 3}
    monkeypatch.setattr(cli, "qa_clip", lambda v, workdir, stem: report)
    monkeypatch.setattr(sys, "argv", ["petgen", "qa", "gold", "stand"])
    assert cli.main() == 1
    printed = json.loads(capsys.readouterr().out)
    assert list(printed) == ["pet", "action", "pass", "format", "seam", "worst_step",
                             "blob_core_first", "blob_core_last", "blob_core_worst"]
    assert printed["pet"] == "gold" and printed["blob_core_worst"] == 3
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_qa.py tests/test_cli_paths.py -v`
Expected: `No module named 'petgen.qa'`；`module 'petgen.__main__' has no attribute 'qa_clip'`

- [ ] **Step 3: 新建 `petgen/qa.py`**

```python
"""The finished clip's QA verdict -- format, loop seam, keyed ghosts --
shared by `petgen qa` and the worker."""
from __future__ import annotations

import subprocess
from pathlib import Path

from petgen.keycheck import FRAME_BLOB_MAX, frame_scores, score_file
from petgen.loopcheck import probe, psnr_series, seam_verdict

FORMAT = {"width": 960, "height": 960, "fps": "24/1", "frames": 121}


def frame_png(video: Path, out: Path, last: bool) -> Path:
    seek = ["-sseof", "-0.05"] if last else []
    subprocess.run(["ffmpeg", "-v", "error", "-y", *seek, "-i", str(video), "-update", "1", "-frames:v", "1", str(out)],
                   check=True)
    return out


def qa_clip(video: Path, workdir: Path, stem: str) -> dict:
    fmt = probe(video)
    ok_seam, seam, worst_step = seam_verdict(*psnr_series(video, workdir / f"qa-{stem}"))
    first = score_file(frame_png(video, workdir / f"qa-{stem}-first.png", last=False))
    last = score_file(frame_png(video, workdir / f"qa-{stem}-last.png", last=True))
    worst = max(frame_scores(video))
    passed = fmt == FORMAT and ok_seam and first.passed and last.passed and worst < FRAME_BLOB_MAX
    return {"pass": passed, "format": fmt, "seam": round(seam, 2), "worst_step": round(worst_step, 2),
            "blob_core_first": first.blob_core, "blob_core_last": last.blob_core, "blob_core_worst": worst}
```

- [ ] **Step 4: `__main__.py` 改用它**

1. 第 20–21 行两条 import 替换为：

```python
from petgen.keycheck import score_file  # noqa: E402
from petgen.qa import qa_clip  # noqa: E402
```

2. 删除整个 `def _frame(video: Path, out: Path, last: bool) -> Path:` 函数。

3. `cmd_qa` 整个替换为：

```python
def cmd_qa(a) -> int:
    d = pet_dir(a.pet, a.tag)
    v = d / f"{a.action}-final.mp4"
    if not v.exists():
        print(f"missing {v.relative_to(HERE)}: run finish first")
        return 1
    r = qa_clip(v, d, a.action)
    print(json.dumps({"pet": a.pet, "action": a.action, **r}, ensure_ascii=False))
    return 0 if r["pass"] else 1
```

4. 确认没有残留引用：

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && grep -n "_frame(\|frame_scores\|FRAME_BLOB_MAX\|psnr_series\|seam_verdict\|probe(" petgen/__main__.py; .venv/Scripts/python -c "import petgen.__main__"`
Expected: grep 无输出；import 无报错。

- [ ] **Step 5: 运行，确认通过（全量）**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest -q`
Expected: 全部 PASS

- [ ] **Step 6: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/qa.py tools/petgen/tests/test_qa.py tools/petgen/petgen/__main__.py tools/petgen/tests/test_cli_paths.py
git commit -m "refactor(petgen): one QA verdict for the CLI and the worker

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

（按 (b) 时去掉 `__main__.py` 与 `test_cli_paths.py`。）

---

### Task 4: 可靠下载 + 可灵客户端补强

**Files:**
- Create: `tools/petgen/petgen/download.py`
- Modify: `tools/petgen/petgen/kling.py`（异常子类、`wait(on_poll=)`、`download`、`units_left`）
- Modify: `tools/petgen/petgen/__main__.py`（`_video_units_left` 用 `kling.units_left`）
- Test: `tools/petgen/tests/test_download.py`（新）、`tools/petgen/tests/test_kling.py`、`tools/petgen/tests/test_cli_paths.py`

**Interfaces:**
- Consumes: `config.read_env` / `secrets_dir`（Task 2）
- Produces:
  - `download.DownloadError(Exception)`、`download.fetch(url: str, dest: Path, *, retries: int = 3, opener=None, sleep=time.sleep, timeout: float = 300) -> Path`：写 `dest.part`，失败重试（2、4、8 秒退避），有已下字节时带 `Range: bytes=N-`，206 续写、200 从头写；按 Content-Length 校验完整；4xx（除 408/429）不重试；成功后改名为 dest
  - `kling.KlingRejected(KlingError)`（create 被拒，不扣费：参数、内容审核、无额度）、`kling.KlingTaskFailed(KlingError)`（任务跑完但失败）；其余 `KlingError` 视为暂时性（网络、轮询出错），任务可能还活着
  - `kling.wait(kind, task_id, every=8.0, limit=120, on_poll: Callable[[], None] | None = None) -> dict`（每次轮询前调 `on_poll`）
  - `kling.download(url, dest) -> Path`（= `download.fetch`）
  - `kling.units_left(kind: str) -> float`（`kind` 为 `"image"` / `"video"`；只算 `status == "online"`、名字含「图像 / 图片」或「视频」的资源包）

- [ ] **Step 1: 写失败的测试**

`tests/test_download.py`：

```python
import http.client
import io
import urllib.error

import pytest

from petgen.download import DownloadError, fetch


class Resp:
    """A urlopen response: chunks, a status, Content-Length; optionally drops
    the connection (IncompleteRead) after `fail_after` chunks."""

    def __init__(self, chunks, status=200, length=None, fail_after=None):
        self.status = status
        self._chunks = list(chunks)
        total = sum(len(c) for c in self._chunks)
        self.headers = {"Content-Length": str(total if length is None else length)}
        self._fail_after = fail_after
        self._n = 0

    def read(self, n=-1):
        if self._fail_after is not None and self._n == self._fail_after:
            raise http.client.IncompleteRead(b"", 10)
        self._n += 1
        return self._chunks.pop(0) if self._chunks else b""

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class Opener:
    def __init__(self, *results):
        self.results = list(results)
        self.reqs = []

    def __call__(self, req, timeout=None):
        self.reqs.append(req)
        r = self.results.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def test_writes_via_a_part_file_and_renames(tmp_path):
    dest = tmp_path / "a" / "stand.mp4"
    fetch("https://x.invalid/a", dest, opener=Opener(Resp([b"abc", b"def"])), sleep=lambda s: None)
    assert dest.read_bytes() == b"abcdef"
    assert not dest.with_name("stand.mp4.part").exists()


def test_a_dropped_connection_resumes_with_range(tmp_path):
    sleeps = []
    o = Opener(Resp([b"abc", b"def"], fail_after=1), Resp([b"def"], status=206))
    dest = fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=sleeps.append)
    assert dest.read_bytes() == b"abcdef"
    assert o.reqs[0].get_header("Range") is None
    assert o.reqs[1].get_header("Range") == "bytes=3-"
    assert sleeps == [2]


def test_a_server_that_ignores_range_is_read_from_the_start(tmp_path):
    o = Opener(Resp([b"abc", b"def"], fail_after=1), Resp([b"abcdef"], status=200))
    assert fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None).read_bytes() == b"abcdef"


def test_a_short_body_without_an_error_is_retried(tmp_path):
    o = Opener(Resp([b"abc"], length=6), Resp([b"def"], status=206))
    assert fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None).read_bytes() == b"abcdef"


def test_gives_up_after_three_retries(tmp_path):
    o = Opener(*[urllib.error.URLError("reset")] * 4)
    with pytest.raises(DownloadError, match="4 tries"):
        fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None)
    assert len(o.reqs) == 4
    assert not (tmp_path / "v.mp4").exists()


def test_an_expired_url_is_not_retried(tmp_path):
    o = Opener(urllib.error.HTTPError("https://x.invalid/a", 403, "Forbidden", {}, io.BytesIO(b"")))
    with pytest.raises(DownloadError, match="403"):
        fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None)
    assert len(o.reqs) == 1
```

`tests/test_kling.py` 末尾追加：

```python
class TestWaitHooks:
    def test_on_poll_runs_before_every_poll(self, monkeypatch):
        replies = [{"code": 0, "data": {"task_status": "processing"}},
                   {"code": 0, "data": {"task_status": "succeed"}}]
        monkeypatch.setattr(kling, "_call", lambda *a, **k: replies.pop(0))
        monkeypatch.setattr(kling.time, "sleep", lambda x: None)
        polls = []
        kling.wait("video", "t-1", on_poll=lambda: polls.append(1))
        assert polls == [1, 1]

    def test_a_failed_task_is_a_task_failure(self, monkeypatch):
        monkeypatch.setattr(kling, "_call", lambda *a, **k: {
            "code": 0, "data": {"task_status": "failed", "task_status_msg": "内容审核未通过"}})
        with pytest.raises(kling.KlingTaskFailed, match="内容审核未通过"):
            kling.wait("image", "t-2")

    def test_a_refused_create_is_a_rejection(self, monkeypatch):
        monkeypatch.setattr(kling, "_call", lambda *a, **k: {"code": 1301, "message": "图片审核未通过"})
        with pytest.raises(kling.KlingRejected, match="code=1301 图片审核未通过"):
            kling.create_image({})


def test_units_left_sums_the_online_packs_of_a_kind(monkeypatch):
    monkeypatch.setattr(kling, "balance", lambda: [
        {"resource_pack_name": "视频生成-100-5并发", "remaining_quantity": "40", "status": "online"},
        {"resource_pack_name": "视频生成-50", "remaining_quantity": "9", "status": "expired"},
        {"resource_pack_name": "图像生成-1000-9并发", "remaining_quantity": "968", "status": "online"},
    ])
    assert kling.units_left("video") == 40.0
    assert kling.units_left("image") == 968.0


def test_download_goes_through_the_retrying_fetch(monkeypatch, tmp_path):
    seen = []
    monkeypatch.setattr(kling, "fetch", lambda url, dest: seen.append((url, dest)) or dest)
    kling.download("https://x.invalid/a.mp4", tmp_path / "a.mp4")
    assert seen == [("https://x.invalid/a.mp4", tmp_path / "a.mp4")]
```

`tests/test_cli_paths.py` 末尾追加：

```python
def test_video_command_still_counts_only_video_packs(monkeypatch):
    from petgen import kling
    monkeypatch.setattr(kling, "balance", lambda: [
        {"resource_pack_name": "视频生成-100-5并发", "remaining_quantity": "40", "status": "online"},
        {"resource_pack_name": "图像生成-1000-9并发", "remaining_quantity": "968", "status": "online"},
    ])
    assert cli._video_units_left() == 40.0
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_download.py tests/test_kling.py tests/test_cli_paths.py -v`
Expected: `No module named 'petgen.download'`；`module 'petgen.kling' has no attribute 'KlingTaskFailed'` 等

- [ ] **Step 3: 新建 `petgen/download.py`**

```python
"""Download to a .part file and rename. A dropped connection (an
IncompleteRead once lost a paid clip) is retried, resuming with Range when
the server allows it; an expired / refused URL is not retried."""
from __future__ import annotations

import http.client
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path

RETRIES = 3
CHUNK = 1 << 16


class DownloadError(Exception):
    pass


def fetch(url: str, dest: Path, *, retries: int = RETRIES, opener=None, sleep=time.sleep,
          timeout: float = 300) -> Path:
    opener = opener or urllib.request.urlopen
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    part.unlink(missing_ok=True)
    last: object = None
    for attempt in range(retries + 1):
        if attempt:
            sleep(2 ** attempt)
        have = part.stat().st_size if part.exists() else 0
        req = urllib.request.Request(url)
        if have:
            req.add_header("Range", f"bytes={have}-")
        try:
            with opener(req, timeout=timeout) as r:
                resume = bool(have) and getattr(r, "status", 200) == 206
                length = (r.headers or {}).get("Content-Length")
                expect = (have if resume else 0) + int(length) if length else None
                with open(part, "ab" if resume else "wb") as f:
                    while True:
                        buf = r.read(CHUNK)
                        if not buf:
                            break
                        f.write(buf)
            size = part.stat().st_size
            if expect is not None and size != expect:
                raise http.client.IncompleteRead(b"", expect - size)
            part.replace(dest)
            return dest
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
            if e.code == 416:
                part.unlink(missing_ok=True)       # our Range ran past the end: start over
            elif 400 <= e.code < 500 and e.code not in (408, 429):
                raise DownloadError(f"download refused: HTTP {e.code}") from None
        except (http.client.HTTPException, urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
            last = repr(e)
    raise DownloadError(f"download failed after {retries + 1} tries: {last}")
```

- [ ] **Step 4: `kling.py` 补强**

1. import 区（Task 2 之后）改为：

```python
import base64
import json
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

from petgen.config import read_env, secrets_dir
from petgen.download import fetch

_PATHS = {"image": "/v1/images/generations", "video": "/v1/videos/image2video"}
_PACK_NAMES = {"image": ("图像", "图片"), "video": ("视频",)}
```

2. `class KlingError` 之后加：

```python
class KlingRejected(KlingError):
    """The create call was refused (code != 0): bad input, a photo that fails
    content review, no balance. Never charged."""


class KlingTaskFailed(KlingError):
    """The task ran and ended 'failed'."""
```

3. `_create` 里 `raise KlingError(f"create {kind} failed: ...")` 改为 `raise KlingRejected(f"create {kind} failed: code={res.get('code')} {res.get('message')}")`。

4. `wait` 整个替换为：

```python
def wait(kind: str, task_id: str, every: float = 8.0, limit: int = 120,
         on_poll: Callable[[], None] | None = None) -> dict:
    """Poll until the task ends. on_poll runs before every poll -- the
    worker's abort check. A poll error is a plain KlingError: the task may
    still be running, so its id stays worth keeping."""
    for _ in range(limit):
        if on_poll is not None:
            on_poll()
        res = _call("GET", f"{_PATHS[kind]}/{task_id}")
        if res.get("code") != 0:
            raise KlingError(f"{kind} task {task_id} error: code={res.get('code')} {res.get('message')}")
        d = res.get("data") or {}
        if d.get("task_status") == "succeed":
            return d
        if d.get("task_status") == "failed":
            raise KlingTaskFailed(f"{kind} task {task_id} failed: {d.get('task_status_msg')}")
        time.sleep(every)
    raise KlingError(f"{kind} task {task_id} still running after {every * limit:.0f}s")
```

5. `download` 整个替换为：

```python
def download(url: str, dest: Path) -> Path:
    """Streamed to a .part file with retries and Range resume (petgen.download)."""
    return fetch(url, Path(dest))
```

6. 文件末尾追加：

```python
def units_left(kind: str) -> float:
    names = _PACK_NAMES[kind]
    return sum(float(p.get("remaining_quantity") or 0) for p in balance()
               if p.get("status") == "online" and any(n in p.get("resource_pack_name", "") for n in names))
```

- [ ] **Step 5: `__main__.py` 的 `_video_units_left` 改为**

```python
def _video_units_left() -> float:
    return kling.units_left("video")
```

- [ ] **Step 6: 运行，确认通过（全量）**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest -q`
Expected: 全部 PASS（`TestWait` 等原有测试不变：子类仍是 `KlingError`）

- [ ] **Step 7: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/download.py tools/petgen/petgen/kling.py tools/petgen/petgen/__main__.py tools/petgen/tests/test_download.py tools/petgen/tests/test_kling.py tools/petgen/tests/test_cli_paths.py
git commit -m "feat(petgen): resumable downloads; tell refused creates and failed tasks apart

A dropped IncompleteRead once lost a paid clip: downloads now go to a .part
file, retry three times and resume with Range.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

（按 (b) 时去掉 `__main__.py` 与 `test_cli_paths.py`。）

---

### Task 5: 任务与 state.json：解析 claim、续跑记录、重做清标记

**Files:**
- Create: `tools/petgen/petgen/jobstate.py`
- Create: `tools/petgen/tests/fakes.py`（本任务只放 `claim()`；Task 7 整体重写、Task 10 追加）
- Test: `tools/petgen/tests/test_jobstate.py`（新）

**Interfaces:**
- Consumes: `package.ACTIONS`、`prompts.REF_POSE_FOR_ACTION`、`props.PROP_REFS`
- Produces:
  - `jobstate.base_pose(action: str) -> str`（`feed` → `front`，`sleep` → `lie`，`walk` → `walk`）
  - `jobstate.Job`（frozen dataclass）：`id: int, pet_id: str, name: str, species: str, actions: tuple[str, ...]`（按 `ACTIONS` 规范顺序，stand 在前）`, redo: dict | None, budget_cents: int, spent_cents: int, photos: tuple[str, ...]`（照片 URL）；`Job.from_claim(d: dict) -> Job`（不合法抛 `ValueError`，信息是中文可读原因）；`poses() -> list[str]`；`prop_stems() -> list[str]`；`steps() -> list[str]`（如 `["fetch", "ref:front", ..., "propref", "video:stand", ..., "package", "upload"]`）
  - `jobstate.JobState`：`load(path) -> JobState`、`save()`（tmp + replace）、`step(key) -> dict`（缺省 `{"done": False, "attempts": 0, "task": None}`）、`done(key) -> bool`、`next_seq(action) -> int`、`clear(key)`；`data` 键：`steps`、`seq`、`hints`、`redo_seen`
  - `jobstate.apply_redo(state: JobState, job: Job, d: Path) -> None`
  - `tests/fakes.claim(**over) -> dict`（job 12 / `custom-12` / 豆豆 / dog / 标准版 5 个动作 / 两张照片）

规则（spec 5.1 + 本计划的决定）：
- `redo = {all: true}`：除 `fetch` 外全部清掉（参考图、道具图、所有视频、grade.json、hints）。
- `redo = {actions, refs: false, hint}`：只清列出动作的视频；hint 记到这些动作上（之后的视频提示词带它）。
- `refs: true`：清列出动作所用的参考姿态（idle 一族都是 `front`）、`front` 时连带道具图与 grade.json，以及**所有用这些姿态的视频**；别的姿态与视频不动。
- 不论哪种 redo，`package` / `upload` 都清掉。`seq`（external_task_id 序号）永不清。
- 同一个 redo 只应用一次：应用后记 `redo_seen = redo`；上传 finish 成功后 `redo_seen = None`（服务端清了 redo），之后再来一模一样的 redo 是新请求。

- [ ] **Step 1: 写测试替身与失败的测试**

`tests/fakes.py`：

```python
"""Test doubles shared by the pipeline and worker tests."""


def claim(**over) -> dict:
    """A jobs/claim job as the server hands it out (standard plan, two photos)."""
    d = {"id": 12, "pet_id": "custom-12", "name": "豆豆", "species": "dog",
         "actions": ["stand", "walk", "feed", "play", "sleep"], "redo": None,
         "budget_cents": 8000, "spent_cents": 0,
         "photos": [{"url": "https://oss.invalid/p1.jpg"}, {"url": "https://oss.invalid/p2.jpg"}]}
    d.update(over)
    return d
```

`tests/test_jobstate.py`：

```python
import pytest

from petgen.jobstate import Job, JobState, apply_redo, base_pose
from tests.fakes import claim


def test_claim_parses_and_orders_actions_stand_first():
    j = Job.from_claim(claim(actions=["play", "stand", "walk"]))
    assert j.actions == ("stand", "walk", "play")
    assert j.photos == ("https://oss.invalid/p1.jpg", "https://oss.invalid/p2.jpg")
    assert (j.id, j.pet_id, j.name, j.species, j.budget_cents, j.spent_cents) == (12, "custom-12", "豆豆", "dog", 8000, 0)


def test_budget_defaults_when_missing():
    assert Job.from_claim(claim(budget_cents=None)).budget_cents == 8000


@pytest.mark.parametrize("over, msg", [
    ({"species": "other"}, "不支持的类别 other"),
    ({"actions": ["stand", "spin"]}, "未知动作"),
    ({"actions": ["walk"]}, "缺少 stand"),
    ({"photos": []}, "没有用户照片"),
    ({"pet_id": "Custom 12"}, "pet_id"),
    ({"redo": {"actions": ["lick_paw"], "refs": False, "hint": ""}}, "重做的动作不在动作列表里"),
])
def test_claim_rejects_what_the_pipeline_cannot_make(over, msg):
    with pytest.raises(ValueError, match=msg):
        Job.from_claim(claim(**over))


def test_base_pose():
    assert [base_pose(a) for a in ("stand", "feed", "play", "walk", "sleep")] == ["front", "front", "front", "walk", "lie"]


def test_steps_cover_only_the_stills_the_actions_need():
    std = Job.from_claim(claim())
    assert std.poses() == ["front", "walk", "lie"]
    assert std.prop_stems() == ["front-bowl", "front-ball"]
    assert std.steps() == ["fetch", "ref:front", "ref:walk", "ref:lie", "propref",
                           "video:stand", "video:walk", "video:sleep", "video:feed", "video:play",
                           "package", "upload"]
    idle = Job.from_claim(claim(actions=["stand", "lick_paw"]))
    assert idle.steps() == ["fetch", "ref:front", "video:stand", "video:lick_paw", "package", "upload"]


def test_state_round_trips_and_writes_atomically(tmp_path):
    s = JobState.load(tmp_path / "state.json")
    s.step("ref:front")["done"] = True
    assert s.next_seq("stand") == 1 and s.next_seq("stand") == 2
    s.save()
    t = JobState.load(tmp_path / "state.json")
    assert t.done("ref:front") and not t.done("ref:walk")
    assert t.data["seq"] == {"stand": 2} and t.data["redo_seen"] is None
    assert not (tmp_path / "state.json.tmp").exists()


def _finished(tmp_path, job):
    """A job folder where every step is done and every file exists."""
    d = tmp_path / "job"
    d.mkdir()
    s = JobState.load(d / "state.json")
    for step in job.steps():
        s.step(step)["done"] = True
    for p in job.poses():
        for f in (f"ref-{p}.png", f"ref-{p}-green.png", f"ref-{p}-cutout.png"):
            (d / f).write_bytes(b"x")
    for a in job.actions:
        for f in (f"{a}.mp4", f"{a}-final.mp4"):
            (d / f).write_bytes(b"x")
    (d / "grade.json").write_text("{}", encoding="utf-8")
    s.data["seq"] = {a: 1 for a in job.actions}
    s.save()
    return d, s


def _not_done(s, job):
    return {k for k in job.steps() if not s.done(k)}


def test_redo_one_action_clears_only_that_clip(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": False, "hint": "尾巴摆慢一点"}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    assert _not_done(s, job) == {"video:play", "package", "upload"}
    assert not (d / "play.mp4").exists() and not (d / "play-final.mp4").exists()
    assert (d / "feed.mp4").exists() and (d / "grade.json").exists()
    assert s.data["hints"] == {"play": "尾巴摆慢一点"}
    assert s.data["seq"]["play"] == 1


def test_redo_with_refs_also_remakes_every_clip_from_that_still(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": True, "hint": ""}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    assert _not_done(s, job) == {"ref:front", "propref", "video:stand", "video:feed", "video:play", "package", "upload"}
    assert not (d / "ref-front-green.png").exists() and not (d / "grade.json").exists()
    assert (d / "ref-walk-green.png").exists() and (d / "walk.mp4").exists() and (d / "sleep.mp4").exists()


def test_redo_all_starts_over_but_keeps_the_photos(tmp_path):
    job = Job.from_claim(claim(redo={"all": True}))
    d, s = _finished(tmp_path, job)
    s.data["hints"] = {"play": "old"}
    apply_redo(s, job, d)
    assert _not_done(s, job) == set(job.steps()) - {"fetch"}
    assert s.data["hints"] == {} and s.data["seq"]["stand"] == 1


def test_the_same_redo_is_applied_once(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": False, "hint": ""}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    s.step("video:play")["done"] = True      # remade; then the worker died before the upload
    apply_redo(s, job, d)                     # re-claimed with the same redo
    assert s.done("video:play")
    s.data["redo_seen"] = None                # the finish went through and the server cleared it
    apply_redo(s, job, d)                     # an identical redo later is a new request
    assert not s.done("video:play")


def test_no_redo_changes_nothing(tmp_path):
    job = Job.from_claim(claim())
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    assert _not_done(s, job) == set()
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_jobstate.py -v`
Expected: `No module named 'petgen.jobstate'`

- [ ] **Step 3: 新建 `petgen/jobstate.py`**

```python
"""A custom-pet job as the server hands it out (spec 2026-10-10 4.3
jobs/claim) and its resumable <work>/jobs/<id>/state.json (5.1)."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from petgen.package import ACTIONS
from petgen.prompts import REF_POSE_FOR_ACTION
from petgen.props import PROP_REFS

SPECIES = ("dog", "cat")
POSE_ORDER = ("front", "walk", "lie")
DEFAULT_BUDGET_CENTS = 8000


def base_pose(action: str) -> str:
    """The generated still an action's reference comes from (front-bowl -> front)."""
    return REF_POSE_FOR_ACTION[action].split("-")[0]


@dataclass(frozen=True)
class Job:
    id: int
    pet_id: str
    name: str
    species: str
    actions: tuple[str, ...]
    redo: dict | None
    budget_cents: int
    spent_cents: int
    photos: tuple[str, ...]

    @classmethod
    def from_claim(cls, d: dict) -> "Job":
        wanted = list(d.get("actions") or [])
        unknown = sorted(set(wanted) - set(ACTIONS))
        if unknown:
            raise ValueError(f"未知动作 {unknown}")
        # Canonical order puts stand first: its clip sets the pet's grade (finish.pet_gamma).
        actions = tuple(a for a in ACTIONS if a in wanted)
        if "stand" not in actions:
            raise ValueError("动作列表缺少 stand")
        if d.get("species") not in SPECIES:
            raise ValueError(f"不支持的类别 {d.get('species')}")
        pet_id = str(d.get("pet_id") or "")
        if not re.fullmatch(r"[a-z0-9-]+", pet_id):
            raise ValueError(f"pet_id 不合法：{pet_id!r}")
        photos = tuple(p["url"] for p in d.get("photos") or [] if p.get("url"))
        if not photos:
            raise ValueError("没有用户照片")
        redo = d.get("redo") or None
        if redo and not redo.get("all"):
            extra = sorted(set(redo.get("actions") or []) - set(actions))
            if extra:
                raise ValueError(f"重做的动作不在动作列表里 {extra}")
        budget = d.get("budget_cents")
        return cls(int(d["id"]), pet_id, str(d.get("name") or ""), d["species"], actions, redo,
                   int(DEFAULT_BUDGET_CENTS if budget is None else budget), int(d.get("spent_cents") or 0), photos)

    def poses(self) -> list[str]:
        need = {base_pose(a) for a in self.actions} | {"front"}   # front also makes the cover
        return [p for p in POSE_ORDER if p in need]

    def prop_stems(self) -> list[str]:
        return [stem for stem in PROP_REFS if any(REF_POSE_FOR_ACTION[a] == stem for a in self.actions)]

    def steps(self) -> list[str]:
        s = ["fetch"] + [f"ref:{p}" for p in self.poses()]
        if self.prop_stems():
            s.append("propref")
        return s + [f"video:{a}" for a in self.actions] + ["package", "upload"]


class JobState:
    """state.json: steps -> {"done", "attempts", "task", ...}; seq -> the last
    external_task_id number per action (never reset); hints -> redo notes per
    action; redo_seen -> the redo already applied. Written atomically."""

    def __init__(self, path: Path, data: dict):
        self.path, self.data = Path(path), data

    @classmethod
    def load(cls, path: Path) -> "JobState":
        path = Path(path)
        data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        data.setdefault("steps", {})
        data.setdefault("seq", {})
        data.setdefault("hints", {})
        data.setdefault("redo_seen", None)
        return cls(path, data)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.path)

    def step(self, key: str) -> dict:
        return self.data["steps"].setdefault(key, {"done": False, "attempts": 0, "task": None})

    def done(self, key: str) -> bool:
        return bool(self.data["steps"].get(key, {}).get("done"))

    def next_seq(self, action: str) -> int:
        n = int(self.data["seq"].get(action, 0)) + 1
        self.data["seq"][action] = n
        return n

    def clear(self, key: str) -> None:
        self.data["steps"].pop(key, None)


def apply_redo(state: JobState, job: Job, d: Path) -> None:
    redo = job.redo
    if not redo or state.data["redo_seen"] == redo:
        return
    if redo.get("all"):
        poses, actions = job.poses(), list(job.actions)
        state.data["hints"] = {}
    else:
        listed = list(redo.get("actions") or [])
        poses, actions = [], listed
        if redo.get("refs"):
            poses = [p for p in POSE_ORDER if p in {base_pose(a) for a in listed}]
            actions = [a for a in job.actions if base_pose(a) in poses]   # every clip made from a redone still
        hint = (redo.get("hint") or "").strip()
        for a in listed:
            state.data["hints"][a] = hint
    for p in poses:
        state.clear(f"ref:{p}")
        for name in (f"ref-{p}.png", f"ref-{p}-green.png", f"ref-{p}-cutout.png"):
            (d / name).unlink(missing_ok=True)
    if "front" in poses:
        state.clear("propref")
        (d / "grade.json").unlink(missing_ok=True)
    for a in actions:
        state.clear(f"video:{a}")
        for name in (f"{a}.mp4", f"{a}-final.mp4"):
            (d / name).unlink(missing_ok=True)
    state.clear("package")
    state.clear("upload")
    state.data["redo_seen"] = redo
    state.save()
```

- [ ] **Step 4: 运行，确认通过**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_jobstate.py -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/jobstate.py tools/petgen/tests/fakes.py tools/petgen/tests/test_jobstate.py
git commit -m "feat(petgen): a claimed job and its resumable state.json, with redo clearing

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: worker 配置（密钥、价格表）与内部接口客户端

**Files:**
- Modify: `tools/petgen/petgen/config.py`（加 `Prices`、`DEFAULT_PRICES`、`WorkerConfig`、`load_worker_config`）
- Create: `tools/petgen/petgen/server.py`
- Create: `secrets/worker.env.example`（仓库根）
- Test: `tools/petgen/tests/test_config.py`、`tools/petgen/tests/test_server.py`（新）

**Interfaces:**
- Consumes: `config.read_env` / `secrets_dir` / `ConfigError`（Task 2）
- Produces:
  - `config.Prices(image_cents_per_unit: float, video_cents_per_unit: float)`，`.cents(image_units, video_units) -> int`（四舍五入到分）；`config.DEFAULT_PRICES = Prices(10.0, 100.0)`
  - `config.WorkerConfig(key: str, prices: Prices)`；`config.load_worker_config(path: Path | None = None) -> WorkerConfig`（缺省 `<secrets>/worker.env`；缺文件 / 空键 / 模板占位 / 价格非数字 → `ConfigError`，信息只含文件名与键名）
  - `server.ServerError(Exception)`（`.status: int | None`）；`server.ServerAbort(ServerError)`（服务端说这单已不在 generating：HTTP 409 + `abort: true`）
  - `server.Server(base: str, key: str, *, opener=None, sleep=time.sleep, timeout: float = 30)`：
    - `claim() -> dict`（`{"job": ...}` 原样）
    - `progress(job_id, stage, done, total, message, cost: dict) -> bool`（True = abort；409 abort 也返回 True）
    - `upload_urls(job_id, files: list[dict]) -> dict[str, str]`（path → url）
    - `put(url: str, path: Path, content_type: str, retries: int = 3) -> None`（PUT 不带 `X-Worker-Key`；4xx 除 408/429 不重试）
    - `finish(job_id, walk_facing: str, files: list[dict]) -> None`
    - `fail(job_id, stage: str, reason: str) -> None`（reason 截到 255）
    - `status(paused: bool, reason: str, balance: dict) -> None`
    - `repr()` 不含密钥

- [ ] **Step 1: 写失败的测试**

`tests/test_config.py` import 区改为：

```python
import pytest

from petgen import kling
from petgen.config import REPO, ConfigError, Prices, load_worker_config, read_env, secrets_dir
```

末尾追加：

```python
def test_worker_config_reads_the_key_and_prices(tmp_path):
    p = tmp_path / "worker.env"
    p.write_text("AIPET_WORKER_KEY=k-123\nAIPET_PRICE_VIDEO_UNIT_CENTS=90\n", encoding="utf-8")
    cfg = load_worker_config(p)
    assert cfg.key == "k-123"
    assert cfg.prices == Prices(10.0, 90.0)


def test_the_template_key_is_refused_without_echoing_it(tmp_path):
    p = tmp_path / "worker.env"
    p.write_text("AIPET_WORKER_KEY=在这里填 worker 密钥\n", encoding="utf-8")
    with pytest.raises(ConfigError) as e:
        load_worker_config(p)
    assert "AIPET_WORKER_KEY" in str(e.value) and "在这里填" not in str(e.value)


def test_a_missing_worker_env_names_the_file(monkeypatch, tmp_path):
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    with pytest.raises(ConfigError, match="worker.env"):
        load_worker_config()


def test_a_bad_price_is_a_config_error(tmp_path):
    p = tmp_path / "worker.env"
    p.write_text("AIPET_WORKER_KEY=k\nAIPET_PRICE_IMAGE_UNIT_CENTS=ten\n", encoding="utf-8")
    with pytest.raises(ConfigError, match="AIPET_PRICE"):
        load_worker_config(p)


def test_prices_round_to_cents():
    assert Prices(10.0, 100.0).cents(8, 4) == 480
    assert Prices(12.4, 0.0).cents(1, 0) == 12
```

`tests/test_server.py`：

```python
import io
import json
import urllib.error

import pytest

from petgen.server import Server, ServerAbort, ServerError


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def ok(body):
    return Resp(json.dumps(body, ensure_ascii=False).encode("utf-8"))


def http_error(code, body):
    return urllib.error.HTTPError("https://api.invalid/x", code, "err", {},
                                  io.BytesIO(json.dumps(body, ensure_ascii=False).encode("utf-8")))


class Opener:
    def __init__(self, *results):
        self.results = list(results)
        self.reqs = []

    def __call__(self, req, timeout=None):
        self.reqs.append(req)
        r = self.results.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def srv(opener):
    return Server("https://api.invalid/", "secret-key-1", opener=opener, sleep=lambda s: None)


def test_claim_posts_with_the_worker_key_and_returns_the_plain_body():
    o = Opener(ok({"job": None, "paused_reason": "生成额度不足"}))
    assert srv(o).claim() == {"job": None, "paused_reason": "生成额度不足"}
    req = o.reqs[0]
    assert req.full_url == "https://api.invalid/internal/aipet/jobs/claim" and req.get_method() == "POST"
    assert req.get_header("X-worker-key") == "secret-key-1"
    assert req.get_header("Content-type") == "application/json"
    assert json.loads(req.data) == {}


def test_progress_sends_the_step_and_the_cost_increment_and_returns_abort():
    o = Opener(ok({"abort": False}), ok({"abort": True}), http_error(409, {"error": "job is failed", "abort": True}))
    s = srv(o)
    cost = {"image_units": 8, "video_units": 0, "cents": 80}
    assert s.progress(12, "refs", 1, 3, "front", cost) is False
    assert json.loads(o.reqs[0].data) == {"stage": "refs", "done": 1, "total": 3, "message": "front", "cost": cost}
    assert o.reqs[0].full_url == "https://api.invalid/internal/aipet/jobs/12/progress"
    assert s.progress(12, "video", 1, 5, "walk", cost) is True
    assert s.progress(12, "video", 1, 5, "walk", cost) is True


def test_upload_urls_finish_fail_and_status_bodies():
    o = Opener(ok([{"path": "pet.json", "url": "https://oss.invalid/a?sig=1"}]), ok({}), ok({}), ok({}))
    s = srv(o)
    files = [{"path": "pet.json", "bytes": 10, "content_type": "application/json"}]
    assert s.upload_urls(12, files) == {"pet.json": "https://oss.invalid/a?sig=1"}
    done = [{"path": "pet.json", "bytes": 10, "sha256": "ab", "qa": None, "deliverable": True}]
    s.finish(12, "left", done)
    s.fail(12, "video:play", "x" * 300)
    s.status(True, "生成额度不足", {"image": 1000, "video": 27})
    bodies = [json.loads(r.data) for r in o.reqs]
    assert bodies == [{"files": files}, {"walk_facing": "left", "files": done},
                      {"stage": "video:play", "reason": "x" * 255},
                      {"paused": True, "reason": "生成额度不足", "balance": {"image": 1000, "video": 27}}]
    assert [r.full_url.rsplit("/aipet/", 1)[1] for r in o.reqs] == [
        "jobs/12/upload-urls", "jobs/12/finish", "jobs/12/fail", "worker/status"]


def test_an_http_error_carries_status_and_reason_but_never_the_key():
    o = Opener(http_error(401, {"error": "unauthorized"}))
    with pytest.raises(ServerError, match="HTTP 401 unauthorized") as e:
        srv(o).claim()
    assert e.value.status == 401 and not isinstance(e.value, ServerAbort)
    assert "secret-key-1" not in str(e.value)


def test_a_409_abort_is_a_server_abort():
    o = Opener(http_error(409, {"error": "job is refunded", "abort": True}))
    with pytest.raises(ServerAbort, match="job is refunded"):
        srv(o).finish(12, "left", [])


def test_a_422_is_a_plain_error():
    o = Opener(http_error(422, {"error": "content_type 与扩展名不符：stand.mp4"}))
    with pytest.raises(ServerError, match="HTTP 422 content_type") as e:
        srv(o).upload_urls(12, [])
    assert not isinstance(e.value, ServerAbort)


def test_non_json_and_network_errors_raise():
    with pytest.raises(ServerError, match="not JSON"):
        srv(Opener(Resp(b"<html>502</html>"))).claim()
    with pytest.raises(ServerError, match="network error"):
        srv(Opener(urllib.error.URLError("refused"))).claim()


def test_put_uploads_with_the_signed_content_type_and_no_worker_key(tmp_path):
    f = tmp_path / "stand.mp4"
    f.write_bytes(b"MP4")
    o = Opener(urllib.error.URLError("reset"), Resp(b""))
    srv(o).put("https://oss.invalid/stand.mp4?sig=1", f, "video/mp4")
    req = o.reqs[1]
    assert req.get_method() == "PUT" and req.data == b"MP4"
    assert req.get_header("Content-type") == "video/mp4"
    assert req.get_header("X-worker-key") is None


def test_put_does_not_retry_a_refused_signature(tmp_path):
    f = tmp_path / "stand.mp4"
    f.write_bytes(b"MP4")
    o = Opener(urllib.error.HTTPError("https://oss.invalid", 403, "Forbidden", {}, io.BytesIO(b"")))
    with pytest.raises(ServerError, match="upload stand.mp4 failed: HTTP 403"):
        srv(o).put("https://oss.invalid/stand.mp4?sig=1", f, "video/mp4")
    assert len(o.reqs) == 1


def test_repr_hides_the_key():
    assert "secret" not in repr(srv(Opener()))
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_config.py tests/test_server.py -v`
Expected: `cannot import name 'Prices'`；`No module named 'petgen.server'`

- [ ] **Step 3: `config.py` 末尾追加**

import 区加 `from dataclasses import dataclass`（放在 `import os` 之后），然后末尾追加：

```python
@dataclass(frozen=True)
class Prices:
    """Kling price per unit, in cents (spec 4.5): turns units into cost_cents."""
    image_cents_per_unit: float
    video_cents_per_unit: float

    def cents(self, image_units: float, video_units: float) -> int:
        return round(image_units * self.image_cents_per_unit + video_units * self.video_cents_per_unit)


# Video: HANDOFF 4 puts a 5 s std clip (3 units) at 2.5-3.6 yuan, about 1 yuan a unit.
# Image: a cautious guess. Set both from the real purchase price in worker.env.
DEFAULT_PRICES = Prices(image_cents_per_unit=10.0, video_cents_per_unit=100.0)


@dataclass(frozen=True)
class WorkerConfig:
    key: str
    prices: Prices

    def __repr__(self) -> str:  # never show the key
        return f"WorkerConfig(key=<{len(self.key)} chars>, prices={self.prices})"


def load_worker_config(path: Path | None = None) -> WorkerConfig:
    path = Path(path) if path else secrets_dir() / "worker.env"
    if not path.exists():
        raise ConfigError(f"no {path}: copy secrets/worker.env.example there and fill AIPET_WORKER_KEY")
    kv = read_env(path)
    key = kv.get("AIPET_WORKER_KEY", "")
    if not key or not key.isascii() or " " in key:
        raise ConfigError(f"AIPET_WORKER_KEY in {path.name} is empty or still the template text")
    try:
        prices = Prices(float(kv.get("AIPET_PRICE_IMAGE_UNIT_CENTS", DEFAULT_PRICES.image_cents_per_unit)),
                        float(kv.get("AIPET_PRICE_VIDEO_UNIT_CENTS", DEFAULT_PRICES.video_cents_per_unit)))
    except ValueError:
        raise ConfigError(f"AIPET_PRICE_*_UNIT_CENTS in {path.name} must be numbers") from None
    return WorkerConfig(key, prices)
```

- [ ] **Step 4: 新建 `petgen/server.py`**

```python
"""The PHP side's internal worker API (spec 2026-10-10 4.3; contract in the
server plan). POST JSON with X-Worker-Key; success is the plain JSON body,
an error is an HTTP status plus {"error": ...} -- and {"abort": true} when
the job is no longer 'generating'."""
from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path

PREFIX = "/internal/aipet/"


class ServerError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class ServerAbort(ServerError):
    """409 with abort: an admin changed the job; stop it, do not report a failure."""


class Server:
    def __init__(self, base: str, key: str, *, opener=None, sleep=time.sleep, timeout: float = 30):
        self.base = base.rstrip("/")
        self._key = key
        self._open = opener or urllib.request.urlopen
        self._sleep = sleep
        self._timeout = timeout

    def __repr__(self) -> str:
        return f"Server({self.base!r})"

    def _post(self, path: str, body: dict):
        req = urllib.request.Request(self.base + PREFIX + path, method="POST",
                                     data=json.dumps(body, ensure_ascii=False).encode("utf-8"))
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        req.add_header("X-Worker-Key", self._key)
        status = 200
        try:
            with self._open(req, timeout=self._timeout) as r:
                text = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status, text = e.code, e.read().decode("utf-8", "replace")
        except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
            raise ServerError(f"{path}: network error: {getattr(e, 'reason', e)}") from None
        try:
            res = json.loads(text)
        except ValueError:
            raise ServerError(f"{path}: HTTP {status}, not JSON: {text[:200]}", status) from None
        if status != 200:
            err = res.get("error", "") if isinstance(res, dict) else ""
            cls = ServerAbort if status == 409 and isinstance(res, dict) and res.get("abort") else ServerError
            raise cls(f"{path}: HTTP {status} {err}", status)
        return res

    def claim(self) -> dict:
        return self._post("jobs/claim", {}) or {}

    def progress(self, job_id: int, stage: str, done: int, total: int, message: str, cost: dict) -> bool:
        try:
            res = self._post(f"jobs/{job_id}/progress", {"stage": stage, "done": done, "total": total,
                                                         "message": message, "cost": cost})
        except ServerAbort:
            return True
        return bool((res or {}).get("abort"))

    def upload_urls(self, job_id: int, files: list[dict]) -> dict[str, str]:
        res = self._post(f"jobs/{job_id}/upload-urls", {"files": files})
        return {x["path"]: x["url"] for x in res}

    def put(self, url: str, path: Path, content_type: str, retries: int = 3) -> None:
        data = Path(path).read_bytes()
        last = ""
        for attempt in range(retries + 1):
            if attempt:
                self._sleep(2 ** attempt)
            req = urllib.request.Request(url, data=data, method="PUT")
            req.add_header("Content-Type", content_type)   # must equal the type the URL was signed for
            try:
                with self._open(req, timeout=300) as r:
                    r.read()
                return
            except urllib.error.HTTPError as e:
                last = f"HTTP {e.code}"
                if 400 <= e.code < 500 and e.code not in (408, 429):
                    break                                   # signature / expiry: retrying cannot help
            except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
                last = str(getattr(e, "reason", e))
        raise ServerError(f"upload {Path(path).name} failed: {last}")

    def finish(self, job_id: int, walk_facing: str, files: list[dict]) -> None:
        self._post(f"jobs/{job_id}/finish", {"walk_facing": walk_facing, "files": files})

    def fail(self, job_id: int, stage: str, reason: str) -> None:
        self._post(f"jobs/{job_id}/fail", {"stage": stage, "reason": reason[:255]})

    def status(self, paused: bool, reason: str, balance: dict) -> None:
        self._post("worker/status", {"paused": paused, "reason": reason, "balance": balance})
```

- [ ] **Step 5: 新建 `secrets/worker.env.example`**（仓库根，`.gitignore` 已放行 `secrets/*.example`）

```
# 复制为 secrets/worker.env（或 $PETGEN_SECRETS/worker.env）并填入真实值。
# secrets/ 已被 .gitignore 忽略，不会进入版本库。填好后不要把内容贴进任何聊天窗口。

# 与服务端 .env [AIPET] WORKER_KEY 相同的值
AIPET_WORKER_KEY=在这里填 worker 密钥

# 可灵每单位价格（分）：估算 cost_cents、检查单笔预算。按实际购买的资源包价格填写。
AIPET_PRICE_IMAGE_UNIT_CENTS=10
AIPET_PRICE_VIDEO_UNIT_CENTS=100
```

- [ ] **Step 6: 运行，确认通过**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_config.py tests/test_server.py -v`
Expected: 全部 PASS

- [ ] **Step 7: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/config.py tools/petgen/petgen/server.py tools/petgen/tests/test_config.py tools/petgen/tests/test_server.py secrets/worker.env.example
git commit -m "feat(petgen): worker key and price table; client for the internal worker API

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: 流水线（上）：运行上下文、付费调用、照片、参考图、道具图

**Files:**
- Create: `tools/petgen/petgen/pipeline.py`
- Modify: `tools/petgen/tests/fakes.py`（整体替换）
- Create: `tools/petgen/tests/conftest.py`
- Test: `tools/petgen/tests/test_pipeline_steps.py`（新）

**Interfaces:**
- Consumes: `jobstate.Job` / `JobState` / `apply_redo`（Task 5）、`config.Prices`（Task 6）、`kling.b64` / `KlingError` / `KlingRejected` / `KlingTaskFailed`、`download.fetch` / `DownloadError`（Task 4）、`prompts.custom_pose_prompt` / `POSE_ASPECT`（Task 1）、`props.PROP_REFS`
- Produces（`petgen/pipeline.py`）：
  - 常量 `IMAGE_UNITS = 8`、`VIDEO_UNITS = 4`、`VIDEO_MODE = "pro"`、`MAX_GENERATIONS = 2`、`MAX_LOOPS = 5`
  - 异常 `StepFailed`（`str(e)` 即可读的 fail 原因）、`BudgetExceeded`、`JobAborted`、`StopRequested`
  - `Progress` 协议：`begin(step: str, stage: str, done: int, total: int, message: str)`、`end(同上)`、`poll()`、`cost(image_units: float, video_units: float, cents: int)`
  - `Uploader` 协议：`upload_urls(job_id, files) -> dict[str, str]`、`put(url, path, content_type)`、`finish(job_id, walk_facing, files)`
  - `Env(work: Path, props: Path, prices: Prices, uploader: Uploader, kling=petgen.kling, fetch=download.fetch)`
  - `Run(job, env, progress)`：`.dir`（`<work>/jobs/<id>`）、`.state`、`.run_cents`、`photo_paths() -> list[Path]`、`guard_budget(kind)`、`charge(kind, units)`
  - `generate(run, key: str, kind: str, make_body: Callable[[], dict], dest: Path) -> None`
  - 可被测试替换的本地工具：`gate(raw: Path, out_dir: Path, stem: str) -> dict`（`{"pass", "floating", "blob_core", "reason"}`）、`prop_ref(cutout, prop, kind, out) -> dict`
  - 步骤：`step_fetch(run)`、`step_ref(run, pose)`、`step_propref(run)`
- Produces（`tests/`）：`FakeKling`、`FakeProgress`、`FakeUploader`、`install_fake_tools(monkeypatch) -> dict`（knobs：`gate_fail`、`qa_fail`、`prop_fail` 集合，`gated`、`finished` 记录）、`fake_fetch`、`make_env(tmp_path, kling, uploader, prices=None) -> Env`、`claim(**over)`；fixture `rig`（`.fk .up .prog .env .knobs .job(**over) .run(**over)`）

`generate` 的付费规则（Review Focus 1）：
1. 没有进行中的任务 → 预算检查 → 组请求体 → `attempts += 1` 并落盘 → create → 任务 id 落盘。
2. 有任务但没 URL → `wait`（`on_poll = progress.poll`）→ URL 落盘、按 `final_unit_deduction` 记一次花费（`charged` 标记，不重复记）。`KlingTaskFailed` 时清掉任务让调用方重试。
3. 有 URL → 下载 → 清掉任务。网络错 / 轮询错 / 下载失败都**保留任务**，下一轮只重新轮询或重下，不再付费。
4. 每个步骤最多付费生成 `MAX_GENERATIONS = 2` 次（第一次 + 重试一次，计数在 state.json 里，重启也不会多花）；免费的重轮询 / 重下载合计不超过 `MAX_LOOPS`。

- [ ] **Step 1: 写测试替身**

`tests/fakes.py` 整体替换为：

```python
"""Test doubles shared by the pipeline and worker tests."""
from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image

from petgen.config import Prices
from petgen.download import DownloadError
from petgen.kling import KlingTaskFailed
from petgen.pipeline import Env, JobAborted, StopRequested


def claim(**over) -> dict:
    """A jobs/claim job as the server hands it out (standard plan, two photos)."""
    d = {"id": 12, "pet_id": "custom-12", "name": "豆豆", "species": "dog",
         "actions": ["stand", "walk", "feed", "play", "sleep"], "redo": None,
         "budget_cents": 8000, "spent_cents": 0,
         "photos": [{"url": "https://oss.invalid/p1.jpg"}, {"url": "https://oss.invalid/p2.jpg"}]}
    d.update(over)
    return d


def _png(path: Path, rgba) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGBA", (64, 64), rgba).save(path)


def _task_of(path: Path) -> str:
    """FakeKling.download writes the result URL into the file; its tail is the task id."""
    return Path(path).read_text(encoding="utf-8").rsplit("/", 1)[-1]


class FakeKling:
    """petgen.kling's create / wait / download / units_left without a network.
    Task ids are '<kind>-<n>' (n = 1-based count of creates)."""

    def __init__(self):
        self.created: list[tuple[str, dict]] = []
        self.waited: list[str] = []
        self.downloads: list[str] = []
        self.reject: list[Exception] = []        # raised by the next creates, in order
        self.fail_task: set[str] = set()         # wait() reports these tasks failed
        self.crash_wait: set[str] = set()        # wait() dies once: the worker was killed
        self.crash_download: set[str] = set()    # download() dies once
        self.download_errors = 0                 # this many downloads raise DownloadError
        self.balance = {"image": 1000.0, "video": 100.0}
        self.balance_error: Exception | None = None
        self.deduction = {"image": "8", "video": "4"}

    def _create(self, kind, body):
        self.created.append((kind, body))
        if self.reject:
            raise self.reject.pop(0)
        return f"{kind}-{len(self.created)}"

    def create_image(self, body):
        return self._create("image", body)

    def create_video(self, body):
        return self._create("video", body)

    def wait(self, kind, task_id, every=8.0, limit=120, on_poll=None):
        self.waited.append(task_id)
        if on_poll is not None:
            on_poll()
        if task_id in self.crash_wait:
            self.crash_wait.discard(task_id)
            raise RuntimeError("worker killed while waiting")
        if task_id in self.fail_task:
            raise KlingTaskFailed(f"{kind} task {task_id} failed: 内容审核未通过")
        key = "images" if kind == "image" else "videos"
        return {"task_status": "succeed", "final_unit_deduction": self.deduction[kind],
                "task_result": {key: [{"url": f"https://kling.invalid/{task_id}"}]}}

    def download(self, url, dest):
        task_id = url.rsplit("/", 1)[-1]
        if task_id in self.crash_download:
            self.crash_download.discard(task_id)
            raise RuntimeError("worker killed mid-download")
        if self.download_errors:
            self.download_errors -= 1
            raise DownloadError("download failed after 4 tries: IncompleteRead(0 bytes read)")
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(url, encoding="utf-8")
        self.downloads.append(url)
        return dest

    def units_left(self, kind):
        if self.balance_error is not None:
            raise self.balance_error
        return self.balance[kind]


class FakeProgress:
    def __init__(self):
        self.calls: list[tuple] = []          # (kind, step, stage, done, total, message)
        self.costs = [0.0, 0.0, 0]
        self.step = None
        self.abort_step = None                # poll() raises JobAborted while this step runs
        self.stop_before = None               # begin() of this step raises StopRequested

    def begin(self, step, stage, done, total, message):
        if step == self.stop_before:
            raise StopRequested()
        self.step = step
        self.calls.append(("begin", step, stage, done, total, message))

    def end(self, step, stage, done, total, message):
        self.calls.append(("end", step, stage, done, total, message))

    def poll(self):
        if self.step is not None and self.step == self.abort_step:
            raise JobAborted()

    def cost(self, image_units, video_units, cents):
        self.costs[0] += image_units
        self.costs[1] += video_units
        self.costs[2] += cents


class FakeUploader:
    def __init__(self):
        self.requested: list[list[dict]] = []
        self.puts: list[tuple[str, str, str]] = []     # (url, file name, content type)
        self.finished: list[tuple[str, list[dict]]] = []
        self.events: list[tuple] = []
        self.fail_finish = 0

    def upload_urls(self, job_id, files):
        self.requested.append(files)
        return {f["path"]: f"https://oss.invalid/{f['path']}" for f in files}

    def put(self, url, path, content_type):
        self.puts.append((url, Path(path).name, content_type))

    def finish(self, job_id, walk_facing, files):
        if self.fail_finish:
            self.fail_finish -= 1
            raise RuntimeError("server down during finish")
        self.finished.append((walk_facing, files))
        self.events.append(("finish",))


def install_fake_tools(monkeypatch) -> dict:
    """Instant stand-ins for segmentation, prop compositing, finish + QA and
    facing detection. Put Kling task ids (or prop kinds) in the knobs' sets
    to make them fail."""
    from petgen import pipeline
    knobs = {"gate_fail": set(), "qa_fail": set(), "prop_fail": set(), "gated": [], "finished": []}

    def gate(raw, out_dir, stem):
        tid = _task_of(raw)
        knobs["gated"].append(tid)
        if tid in knobs["gate_fail"]:
            return {"pass": False, "floating": 9000, "blob_core": 999, "reason": f"抠像残留 blob_core=999（{tid}）"}
        _png(Path(out_dir) / f"{stem}-green.png", (0, 255, 0, 255))
        _png(Path(out_dir) / f"{stem}-cutout.png", (200, 150, 100, 255))
        return {"pass": True, "floating": 1, "blob_core": 0, "reason": ""}

    def prop_ref(cutout, prop, kind, out):
        if kind in knobs["prop_fail"]:
            return {"pass": False, "floating": 0, "blob_core": 500}
        _png(out, (0, 255, 0, 255))
        return {"pass": True, "floating": 0, "blob_core": 0}

    def finish_and_qa(raw, final, workdir, action):
        tid = _task_of(raw)
        knobs["finished"].append(tid)
        shutil.copy2(raw, final)
        return {"pass": tid not in knobs["qa_fail"], "seam": 40.0, "blob_core_worst": 10}

    monkeypatch.setattr(pipeline, "gate", gate)
    monkeypatch.setattr(pipeline, "prop_ref", prop_ref)
    monkeypatch.setattr(pipeline, "finish_and_qa", finish_and_qa, raising=False)   # added in Task 8
    monkeypatch.setattr(pipeline, "guess_facing", lambda video: "left", raising=False)
    return knobs


def fake_fetch(url, dest):
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(url, encoding="utf-8")
    return dest


def make_env(tmp_path, kling, uploader, prices=None) -> Env:
    props = Path(tmp_path) / "props"
    for kind in ("bowl", "ball"):
        _png(props / f"{kind}-cutout.png", (200, 0, 0, 255))
    return Env(work=Path(tmp_path) / "work", props=props, prices=prices or Prices(10.0, 100.0),
               uploader=uploader, kling=kling, fetch=fake_fetch)
```

`tests/conftest.py`：

```python
from types import SimpleNamespace

import pytest

from petgen.jobstate import Job
from petgen.pipeline import Run
from tests.fakes import FakeKling, FakeProgress, FakeUploader, claim, install_fake_tools, make_env


@pytest.fixture
def rig(tmp_path, monkeypatch):
    """A pipeline on fakes, all sharing one work folder: rig.job(**over) is
    job 12 (claim() + over), rig.run(**over) a fresh Run of it -- a new Run
    over the same folder is what a restarted worker sees."""
    fk, up, prog = FakeKling(), FakeUploader(), FakeProgress()
    knobs = install_fake_tools(monkeypatch)
    env = make_env(tmp_path, fk, up)

    def job(**over):
        return Job.from_claim(claim(**over))

    return SimpleNamespace(fk=fk, up=up, prog=prog, env=env, knobs=knobs, job=job,
                           run=lambda **over: Run(job(**over), env, prog))
```

- [ ] **Step 2: 写失败的测试**

`tests/test_pipeline_steps.py`：

```python
import pytest

from petgen import kling
from petgen.kling import KlingRejected, KlingTaskFailed
from petgen.pipeline import BudgetExceeded, StepFailed, step_fetch, step_propref, step_ref
from petgen.prompts import BRIGHT


def _ready(rig, **over):
    r = rig.run(**over)
    step_fetch(r)
    return r


def test_fetch_downloads_each_photo_once(rig):
    r = _ready(rig)
    assert [p.read_bytes() for p in r.photo_paths()] == [b"https://oss.invalid/p1.jpg", b"https://oss.invalid/p2.jpg"]
    assert r.state.done("fetch")


def test_ref_uses_the_production_recipe_and_records_the_cost(rig):
    r = _ready(rig)
    step_ref(r, "front")
    kind, body = rig.fk.created[0]
    assert kind == "image"
    assert (body["model_name"], body["image_reference"], body["resolution"], body["aspect_ratio"], body["n"]) == \
        ("kling-v3", "subject", "2k", "1:1", 1)
    assert body["image"] == kling.b64(r.photo_paths()[0])
    assert "这只狗" in body["prompt"] and body["prompt"].endswith(BRIGHT)
    assert r.state.done("ref:front") and r.state.data["steps"]["ref:front"]["score"]["pass"] is True
    assert (r.dir / "ref-front-green.png").exists() and (r.dir / "ref-front-cutout.png").exists()
    assert rig.prog.costs == [8.0, 0.0, 80]


def test_a_rejected_photo_is_retried_with_the_next_photo(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 图片审核未通过")]
    r = _ready(rig)
    step_ref(r, "front")
    assert [b["image"] for _, b in rig.fk.created] == [kling.b64(p) for p in r.photo_paths()]
    assert r.state.done("ref:front")


def test_two_failures_fail_the_step_with_a_readable_reason(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 图片审核未通过")] * 2
    r = _ready(rig)
    with pytest.raises(StepFailed, match="参考图 front.*code=1301 图片审核未通过"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 2


def test_a_task_that_fails_review_counts_as_a_try(rig):
    rig.fk.fail_task = {"image-1"}
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 2 and rig.fk.created[1][1]["image"] == kling.b64(r.photo_paths()[1])
    assert rig.prog.costs[0] == 8.0       # the failed task was never charged


def test_one_photo_is_reused_for_the_retry(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 x")]
    r = _ready(rig, photos=[{"url": "https://oss.invalid/only.jpg"}])
    step_ref(r, "front")
    assert [b["image"] for _, b in rig.fk.created] == [kling.b64(r.photo_paths()[0])] * 2


def test_a_still_that_fails_the_gate_is_made_once_more(rig):
    rig.knobs["gate_fail"].add("image-1")
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 2 and rig.knobs["gated"] == ["image-1", "image-2"]
    assert rig.prog.costs[0] == 16.0


def test_two_gate_failures_fail_the_step(rig):
    rig.knobs["gate_fail"].update({"image-1", "image-2"})
    r = _ready(rig)
    with pytest.raises(StepFailed, match="参考图 front.*blob_core=999"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 2


def test_the_budget_is_checked_before_every_kling_call(rig):
    r = _ready(rig, spent_cents=7930)            # 7930 + 80 > 8000
    with pytest.raises(BudgetExceeded, match="超出单笔预算"):
        step_ref(r, "front")
    assert rig.fk.created == []


def test_a_paid_still_is_not_paid_again_after_a_crash_mid_download(rig):
    rig.fk.crash_download.add("image-1")
    r = _ready(rig)
    with pytest.raises(RuntimeError, match="mid-download"):
        step_ref(r, "front")
    step_ref(rig.run(), "front")                 # a restarted worker: fresh Run, same folder
    assert len(rig.fk.created) == 1
    assert rig.fk.downloads == ["https://kling.invalid/image-1"]
    assert rig.prog.costs[0] == 8.0


def test_a_crash_while_waiting_resumes_the_same_task(rig):
    rig.fk.crash_wait.add("image-1")
    r = _ready(rig)
    with pytest.raises(RuntimeError, match="while waiting"):
        step_ref(r, "front")
    step_ref(rig.run(), "front")
    assert len(rig.fk.created) == 1 and rig.fk.waited == ["image-1", "image-1"]
    assert rig.prog.costs[0] == 8.0


def test_dropped_downloads_are_retried_without_paying(rig):
    rig.fk.download_errors = 2
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 1 and r.state.done("ref:front")


def test_propref_puts_the_props_on_the_front_still(rig):
    r = _ready(rig)
    step_ref(r, "front")
    step_propref(r)
    assert (r.dir / "ref-front-bowl-green.png").exists() and (r.dir / "ref-front-ball-green.png").exists()
    assert r.state.done("propref")


def test_a_prop_that_fails_its_gate_needs_a_person(rig):
    rig.knobs["prop_fail"].add("ball")
    r = _ready(rig)
    step_ref(r, "front")
    with pytest.raises(StepFailed, match="道具图 front-ball"):
        step_propref(r)
```

- [ ] **Step 3: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_pipeline_steps.py -v`
Expected: 收集阶段 `No module named 'petgen.pipeline'`（conftest 导入失败）

- [ ] **Step 4: 新建 `petgen/pipeline.py`**

```python
"""One custom-pet job, step by step, in <work>/jobs/<id>/ (spec 2026-10-10 5.1).

Every step records itself in state.json, so a restart or a re-claim skips
what is done. A Kling task's id is saved before waiting and its result URL
before downloading: a crash or a dropped download (an IncompleteRead once
lost a paid clip) resumes the paid task instead of paying again."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from petgen import kling as kling_module
from petgen.config import Prices
from petgen.download import DownloadError
from petgen.download import fetch as http_fetch
from petgen.jobstate import Job, JobState
from petgen.kling import KlingError, KlingTaskFailed
from petgen.prompts import POSE_ASPECT, custom_pose_prompt
from petgen.props import PROP_REFS

IMAGE_UNITS = 8        # one kling-v3 still (HANDOFF 4)
VIDEO_UNITS = 4        # one 5 s pro clip
VIDEO_MODE = "pro"
MAX_GENERATIONS = 2    # a step pays for its first try and one retry, never more
MAX_LOOPS = 5          # plus free re-polls / re-downloads of a task already paid for


class StepFailed(Exception):
    """A step gave up; str(e) is the readable fail_reason."""


class BudgetExceeded(Exception):
    """The next Kling call would pass the job's budget_cents."""


class JobAborted(Exception):
    """The server says the job is no longer ours (an admin changed it)."""


class StopRequested(Exception):
    """Ctrl+C / SIGTERM: leave before the next step and report nothing."""


class Progress(Protocol):
    def begin(self, step: str, stage: str, done: int, total: int, message: str) -> None: ...
    def end(self, step: str, stage: str, done: int, total: int, message: str) -> None: ...
    def poll(self) -> None: ...
    def cost(self, image_units: float, video_units: float, cents: int) -> None: ...


class Uploader(Protocol):
    def upload_urls(self, job_id: int, files: list[dict]) -> dict[str, str]: ...
    def put(self, url: str, path: Path, content_type: str) -> None: ...
    def finish(self, job_id: int, walk_facing: str, files: list[dict]) -> None: ...


@dataclass
class Env:
    work: Path                  # job folders: <work>/jobs/<id>/
    props: Path                 # bowl-cutout.png, ball-cutout.png (shared, made once by `petgen prop`)
    prices: Prices
    uploader: Uploader
    kling: object = kling_module                       # create_image / create_video / wait / download / units_left
    fetch: Callable[[str, Path], Path] = http_fetch    # the user's photos from signed URLs


class Run:
    def __init__(self, job: Job, env: Env, progress: Progress):
        self.job, self.env, self.progress = job, env, progress
        self.dir = Path(env.work) / "jobs" / str(job.id)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.state = JobState.load(self.dir / "state.json")
        self.run_cents = 0

    def photo_paths(self) -> list[Path]:
        return [self.dir / "photos" / f"{i}.jpg" for i in range(1, len(self.job.photos) + 1)]

    def guard_budget(self, kind: str) -> None:
        est = self.env.prices.cents(IMAGE_UNITS, 0) if kind == "image" else self.env.prices.cents(0, VIDEO_UNITS)
        spent = self.job.spent_cents + self.run_cents
        if spent + est > self.job.budget_cents:
            raise BudgetExceeded(f"超出单笔预算（已花 {spent / 100:.2f} 元，下一步约 {est / 100:.2f} 元，"
                                 f"预算 {self.job.budget_cents / 100:.2f} 元）")

    def charge(self, kind: str, units: float) -> None:
        image, video = (units, 0.0) if kind == "image" else (0.0, units)
        cents = self.env.prices.cents(image, video)
        self.run_cents += cents
        self.progress.cost(image, video, cents)


def generate(run: Run, key: str, kind: str, make_body: Callable[[], dict], dest: Path) -> None:
    """One Kling result at dest. Raises KlingRejected / KlingTaskFailed (no
    task left: the caller may pay for a retry) or KlingError / DownloadError
    (transient: the task is kept and the next call only re-polls or
    re-downloads)."""
    st = run.state.step(key)
    if st.get("task") is None:
        run.guard_budget(kind)
        body = make_body()
        st["attempts"] += 1              # counted before the call: a refused create still uses up the try
        run.state.save()
        create = run.env.kling.create_image if kind == "image" else run.env.kling.create_video
        task_id = create(body)
        st["task"] = {"id": task_id, "url": None, "charged": False}
        run.state.save()
    task = st["task"]
    if task["url"] is None:
        try:
            d = run.env.kling.wait(kind, task["id"], every=8.0 if kind == "image" else 10.0,
                                   on_poll=run.progress.poll)
        except KlingTaskFailed:
            st["task"] = None
            run.state.save()
            raise
        task["url"] = d["task_result"]["images" if kind == "image" else "videos"][0]["url"]
        if not task["charged"]:
            units = d.get("final_unit_deduction")
            run.charge(kind, float(units) if units not in (None, "") else
                       float(IMAGE_UNITS if kind == "image" else VIDEO_UNITS))
            task["charged"] = True
        run.state.save()
    run.env.kling.download(task["url"], dest)
    st["task"] = None
    run.state.save()


def gate(raw: Path, out_dir: Path, stem: str) -> dict:
    """Segment the still off its grey backdrop onto exact green, exposure-
    calibrated like the production recipe, and score it like `petgen gate`."""
    from petgen.compose import EdgeError, compose
    from petgen.keycheck import score_file
    try:
        r = compose(raw, out_dir, stem, calibrate=True)
    except EdgeError as e:
        return {"pass": False, "floating": 0, "blob_core": 0, "reason": f"主体被画框截断 {e.sides}"}
    except ValueError as e:
        return {"pass": False, "floating": 0, "blob_core": 0, "reason": f"没分割出主体：{e}"}
    s = score_file(r.green)
    return {"pass": s.passed, "floating": s.floating, "blob_core": s.blob_core,
            "reason": "" if s.passed else f"抠像残留 blob_core={s.blob_core}"}


def prop_ref(cutout: Path, prop: Path, kind: str, out: Path) -> dict:
    from petgen.keycheck import score_file
    from petgen.props import compose_prop
    s = score_file(compose_prop(cutout, prop, kind, out))
    return {"pass": s.passed, "floating": s.floating, "blob_core": s.blob_core}


def step_fetch(run: Run) -> None:
    for url, dest in zip(run.job.photos, run.photo_paths()):
        if not dest.exists():
            run.env.fetch(url, dest)
    run.state.step("fetch")["done"] = True
    run.state.save()


def step_ref(run: Run, pose: str) -> None:
    """A full-body still of the customer's pet in this pose. The retry uses
    the next photo: a photo Kling's review refuses, or one that yields a
    cropped animal, is not worth paying for twice."""
    key = f"ref:{pose}"
    st = run.state.step(key)
    raw = run.dir / f"ref-{pose}.png"
    photos = run.photo_paths()
    last = "未知原因"
    for _ in range(MAX_LOOPS):
        if not raw.exists():
            if st["task"] is None and st["attempts"] >= MAX_GENERATIONS:
                break
            photo = photos[st["attempts"] % len(photos)]

            def body() -> dict:
                st["photo"] = photo.name
                return {"model_name": "kling-v3", "image_reference": "subject",
                        "prompt": custom_pose_prompt(run.job.species, pose), "image": kling_module.b64(photo),
                        "aspect_ratio": POSE_ASPECT[pose], "resolution": "2k", "n": 1}

            try:
                generate(run, key, "image", body, raw)
            except (KlingError, DownloadError) as e:
                last = str(e)
                continue
        verdict = gate(raw, run.dir, f"ref-{pose}")
        if verdict["pass"]:
            st.update(done=True, score=verdict)
            run.state.save()
            return
        last = verdict["reason"]
        raw.unlink()
    raise StepFailed(f"参考图 {pose} 未能生成（换照片重试后仍失败）：{last}"[:255])


def step_propref(run: Run) -> None:
    """The shared bowl / ball pasted in front of the paws. Deterministic, so
    a failure is not retried: it needs a person."""
    scores = {}
    for stem in run.job.prop_stems():
        kind = PROP_REFS[stem]
        s = prop_ref(run.dir / "ref-front-cutout.png", Path(run.env.props) / f"{kind}-cutout.png", kind,
                     run.dir / f"ref-{stem}-green.png")
        if not s["pass"]:
            raise StepFailed(f"道具图 {stem} 未通过质检 blob_core={s['blob_core']}")
        scores[stem] = s
    run.state.step("propref").update(done=True, scores=scores)
    run.state.save()
```

- [ ] **Step 5: 运行，确认通过（全量）**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest -q`
Expected: 全部 PASS（conftest 对所有测试生效，原有测试不受影响）

- [ ] **Step 6: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/pipeline.py tools/petgen/tests/fakes.py tools/petgen/tests/conftest.py tools/petgen/tests/test_pipeline_steps.py
git commit -m "feat(petgen): job pipeline: photos, reference stills, props; never pay twice for a task

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: 流水线（下）：动作视频、打包、上传、`run_job`

**Files:**
- Modify: `tools/petgen/petgen/pipeline.py`（追加）
- Test: `tools/petgen/tests/test_pipeline_run.py`（新）

**Interfaces:**
- Consumes: Task 7 的一切；`jobstate.apply_redo`；`prompts.custom_action_prompt` / `REF_POSE_FOR_ACTION`；`package.custom_pet_json` / `write_pet_dir` / `walk_facing`（Task 2）；`finish.finish_clip` / `pet_gamma`；`qa.qa_clip`（Task 3）
- Produces（`petgen/pipeline.py`）：
  - 可被测试替换：`finish_and_qa(raw: Path, final: Path, workdir: Path, action: str) -> dict`（qa_clip 的结果）、`guess_facing(video: Path) -> str`
  - `step_video(run, action)`、`step_package(run)`、`step_upload(run)`、`manifest(run) -> list[dict]`
  - `CONTENT_TYPES = {".json": "application/json", ".png": "image/png", ".mp4": "video/mp4", ".jpg": "image/jpeg"}`
  - `SERVER_STAGES = {"fetch": "fetch", "ref": "refs", "propref": "propref", "video": "video", "package": "package", "upload": "upload"}`
  - `run_job(job: Job, env: Env, progress: Progress) -> Run`：先 `apply_redo`，再按 `job.steps()` 跑没做完的步骤；每步前 `progress.begin(step, stage, done, total, message)`、步后 `progress.end(...)`，其中 `stage = SERVER_STAGES[类别]`，`done` / `total` 是**同类别**内已完成数 / 总数，`message` 是当前项（如 `play`、`front`）或中文标签；**`upload` 步之后不再发 progress**（finish 后单子已归服务端，再报会收到 abort）

规则：
- 视频按 `job.actions`（stand 在前）逐个做：create → wait → 下载 `<action>.mp4` → `finish_and_qa` 出 `<action>-final.mp4`。质检不过：删掉、重新付费生成一次（external_task_id 序号 +1）；第二次仍不过就**保留并标 `qa.pass = false`**，交给人工审核决定是否重做（不 fail 整单）。stand 被丢弃时连带删 `grade.json`，让新的 stand 重新定曝光。
- 打包到 `<dir>/out/`：`pet.json`、`cover.png`（来自 `ref-front-cutout.png`）、`<action>.mp4`、`refs/<pose>.png`（绿底参考图，即喂给可灵的那张）；`walkFacing` 有 walk 时由 `guess_facing` 猜，否则 `right`。
- 上传：每次都申请并上传 `out/` 下**全部**文件，`finish` 报全部文件；`refs/` 下的 `deliverable = false`，其余 true；`qa`：视频为质检结果、参考图为 gate 分数、其他为 null。finish 成功后 `redo_seen = None`。

- [ ] **Step 1: 写失败的测试**

`tests/test_pipeline_run.py`：

```python
import hashlib
import json

import pytest

from petgen import kling
from petgen.pipeline import BudgetExceeded, JobAborted, StopRequested, run_job

STD = ("stand", "walk", "sleep", "feed", "play")


def _videos(rig, start=0):
    return [b for k, b in rig.fk.created[start:] if k == "video"]


def test_a_standard_job_runs_to_upload(rig):
    run = run_job(rig.job(), rig.env, rig.prog)
    assert [k for k, _ in rig.fk.created] == ["image"] * 3 + ["video"] * 5
    vids = _videos(rig)
    assert [b["external_task_id"] for b in vids] == [f"aipet-12-{a}-1" for a in STD]
    assert all(b["mode"] == "pro" and b["duration"] == "5" and b["model_name"] == "kling-v3" for b in vids)
    assert all(b["image"] == b["image_tail"] for b in vids)
    assert vids[3]["image"] == kling.b64(run.dir / "ref-front-bowl-green.png")
    assert vids[1]["image"] == kling.b64(run.dir / "ref-walk-green.png")
    assert vids[2]["image"] == kling.b64(run.dir / "ref-lie-green.png")
    assert "这只狗" in vids[0]["prompt"] and "补充要求" not in vids[0]["prompt"]
    assert rig.prog.costs == [24.0, 20.0, 2240]

    walk_facing, files = rig.up.finished[0]
    assert walk_facing == "left"
    by_path = {f["path"]: f for f in files}
    assert set(by_path) == {"pet.json", "cover.png", *(f"{a}.mp4" for a in STD),
                            "refs/front.png", "refs/walk.png", "refs/lie.png"}
    assert {p for p, f in by_path.items() if not f["deliverable"]} == {"refs/front.png", "refs/walk.png", "refs/lie.png"}
    assert by_path["stand.mp4"]["qa"]["pass"] is True
    assert by_path["refs/front.png"]["qa"]["pass"] is True
    assert by_path["pet.json"]["qa"] is None and by_path["cover.png"]["qa"] is None
    pj = run.dir / "out" / "pet.json"
    assert json.loads(pj.read_text(encoding="utf-8")) == {
        "schema": 1, "id": "custom-12", "name": "豆豆", "species": "dog", "origin": "custom", "blurb": "",
        "cover": "cover.png", "actions": list(STD), "walkFacing": "left"}
    assert by_path["pet.json"]["sha256"] == hashlib.sha256(pj.read_bytes()).hexdigest()
    assert by_path["pet.json"]["bytes"] == pj.stat().st_size

    types = {url.split("oss.invalid/", 1)[1]: ct for url, _, ct in rig.up.puts}
    assert types["pet.json"] == "application/json" and types["stand.mp4"] == "video/mp4"
    assert types["cover.png"] == "image/png" and types["refs/front.png"] == "image/png"
    assert rig.up.requested[0] == [{"path": f["path"], "bytes": f["bytes"], "content_type": types[f["path"]]}
                                   for f in files]


def test_progress_reports_stage_counts_and_nothing_after_the_finish(rig):
    run_job(rig.job(), rig.env, rig.prog)
    begins = [c[1:] for c in rig.prog.calls if c[0] == "begin"]
    assert begins[:2] == [("fetch", "fetch", 0, 1, "下载照片"), ("ref:front", "refs", 0, 3, "front")]
    assert ("video:feed", "video", 3, 5, "feed") in begins
    ends = [c[1:] for c in rig.prog.calls if c[0] == "end"]
    assert ("video:play", "video", 5, 5, "play") in ends
    assert rig.prog.calls[-1] == ("begin", "upload", "upload", 0, 1, "上传成品")
    assert [c[1] for c in rig.prog.calls if c[0] == "begin"] == rig.job().steps()


def test_a_restart_skips_finished_steps_and_resumes_the_paid_clip(rig):
    rig.fk.crash_download.add("video-7")         # feed: the worker is killed mid-download
    with pytest.raises(RuntimeError, match="mid-download"):
        run_job(rig.job(), rig.env, rig.prog)
    run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 8
    assert rig.prog.costs[1] == 20.0
    assert len(rig.up.finished) == 1


def test_a_clip_that_fails_qa_is_made_once_more(rig):
    rig.knobs["qa_fail"].add("video-4")
    run_job(rig.job(), rig.env, rig.prog)
    assert [b["external_task_id"] for b in _videos(rig)][:2] == ["aipet-12-stand-1", "aipet-12-stand-2"]
    files = {f["path"]: f for f in rig.up.finished[0][1]}
    assert files["stand.mp4"]["qa"]["pass"] is True


def test_a_clip_that_fails_qa_twice_goes_to_review_marked(rig):
    rig.knobs["qa_fail"].update({"video-4", "video-5"})
    run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 9
    files = {f["path"]: f for f in rig.up.finished[0][1]}
    assert files["stand.mp4"]["qa"]["pass"] is False


def test_redo_of_one_action_remakes_only_that_clip_with_the_hint(rig):
    run_job(rig.job(), rig.env, rig.prog)
    redo = {"actions": ["play"], "refs": False, "hint": "尾巴摆慢一点"}
    run_job(rig.job(redo=redo), rig.env, rig.prog)
    new = rig.fk.created[8:]
    assert [(k, b["external_task_id"]) for k, b in new] == [("video", "aipet-12-play-2")]
    assert new[0][1]["prompt"].endswith("补充要求：尾巴摆慢一点")
    assert len(rig.up.finished) == 2


def test_a_redo_interrupted_before_upload_is_not_remade(rig):
    run_job(rig.job(), rig.env, rig.prog)
    redo = {"actions": ["play"], "refs": False, "hint": ""}
    rig.up.fail_finish = 1
    with pytest.raises(RuntimeError, match="server down"):
        run_job(rig.job(redo=redo), rig.env, rig.prog)
    run_job(rig.job(redo=redo), rig.env, rig.prog)   # re-claimed with the same redo
    assert len(rig.fk.created) == 9
    assert len(rig.up.finished) == 2


def test_redo_with_refs_remakes_the_still_and_the_clips_made_from_it(rig):
    run_job(rig.job(), rig.env, rig.prog)
    run_job(rig.job(redo={"actions": ["play"], "refs": True, "hint": ""}), rig.env, rig.prog)
    new = rig.fk.created[8:]
    assert [k for k, _ in new] == ["image", "video", "video", "video"]
    assert [b["external_task_id"] for b in _videos(rig, 8)] == ["aipet-12-stand-2", "aipet-12-feed-2", "aipet-12-play-2"]


def test_redo_all_remakes_everything(rig):
    run_job(rig.job(), rig.env, rig.prog)
    run_job(rig.job(redo={"all": True}), rig.env, rig.prog)
    assert len(rig.fk.created) == 16
    assert [b["external_task_id"] for b in _videos(rig, 8)] == [f"aipet-12-{a}-2" for a in STD]


def test_the_budget_stops_the_job_mid_way(rig):
    # stills 3 x 80 = 240, then 400 a clip: 240 + 3 x 400 = 1440; the 4th clip would reach 1840
    with pytest.raises(BudgetExceeded, match="超出单笔预算"):
        run_job(rig.job(budget_cents=1490), rig.env, rig.prog)
    assert [k for k, _ in rig.fk.created] == ["image"] * 3 + ["video"] * 3


def test_an_abort_stops_inside_the_wait_and_keeps_the_task(rig):
    rig.prog.abort_step = "video:walk"
    with pytest.raises(JobAborted):
        run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 5
    state = json.loads((rig.env.work / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["steps"]["video:walk"]["task"]["id"] == "video-5"
    assert rig.up.finished == []


def test_a_stop_request_ends_between_steps(rig):
    rig.prog.stop_before = "video:walk"
    with pytest.raises(StopRequested):
        run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 4
    state = json.loads((rig.env.work / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["steps"]["video:stand"]["done"] is True and "video:walk" not in state["steps"]


def test_cat_jobs_use_cat_prompts(rig):
    run_job(rig.job(species="cat"), rig.env, rig.prog)
    assert all("这只猫" in b["prompt"] for _, b in rig.fk.created)
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_pipeline_run.py -v`
Expected: `cannot import name 'run_job'`

- [ ] **Step 3: 实现**

`petgen/pipeline.py` 顶部 import 区改为：

```python
import hashlib
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from petgen import kling as kling_module
from petgen.config import Prices
from petgen.download import DownloadError
from petgen.download import fetch as http_fetch
from petgen.jobstate import Job, JobState, apply_redo
from petgen.kling import KlingError, KlingTaskFailed
from petgen.prompts import POSE_ASPECT, REF_POSE_FOR_ACTION, custom_action_prompt, custom_pose_prompt
from petgen.props import PROP_REFS
```

文件末尾追加：

```python
def finish_and_qa(raw: Path, final: Path, workdir: Path, action: str) -> dict:
    """Grade the raw clip with the pet's one gamma (solved from stand.mp4 and
    saved to grade.json, so every action looks alike), then QA it."""
    from petgen.finish import finish_clip, pet_gamma
    from petgen.qa import qa_clip
    finish_clip(raw, final, pet_gamma(workdir))
    return qa_clip(final, workdir, action)


def step_video(run: Run, action: str) -> None:
    key = f"video:{action}"
    st = run.state.step(key)
    raw, final = run.dir / f"{action}.mp4", run.dir / f"{action}-final.mp4"
    ref = run.dir / f"ref-{REF_POSE_FOR_ACTION[action]}-green.png"
    last = "未知原因"
    for _ in range(MAX_LOOPS):
        if not raw.exists():
            if st["task"] is None and st["attempts"] >= MAX_GENERATIONS:
                break

            def body() -> dict:
                n = run.state.next_seq(action)          # never reused: Kling rejects a repeated external_task_id
                img = kling_module.b64(ref)
                hint = run.state.data["hints"].get(action, "")
                return {"model_name": "kling-v3", "image": img, "image_tail": img,
                        "prompt": custom_action_prompt(run.job.species, action, hint),
                        "duration": "5", "mode": VIDEO_MODE,
                        "external_task_id": f"aipet-{run.job.id}-{action}-{n}"}

            try:
                generate(run, key, "video", body, raw)
            except (KlingError, DownloadError) as e:
                last = str(e)
                continue
        qa = finish_and_qa(raw, final, run.dir, action)
        if qa["pass"] or st["attempts"] >= MAX_GENERATIONS:
            st.update(done=True, qa=qa)                 # a second miss goes to review marked; a person decides
            run.state.save()
            return
        last = "成片质检未通过"
        raw.unlink()
        final.unlink(missing_ok=True)
        if action == "stand":
            (run.dir / "grade.json").unlink(missing_ok=True)
    raise StepFailed(f"动作 {action} 未能生成：{last}"[:255])


def guess_facing(video: Path) -> str:
    from petgen.package import walk_facing
    return walk_facing(video)


def step_package(run: Run) -> None:
    from petgen.package import custom_pet_json, write_pet_dir
    out = run.dir / "out"
    shutil.rmtree(out, ignore_errors=True)
    facing = guess_facing(run.dir / "walk-final.mp4") if "walk" in run.job.actions else "right"
    meta = custom_pet_json(run.job.pet_id, run.job.name, run.job.species, run.job.actions, facing)
    write_pet_dir(out, {a: run.dir / f"{a}-final.mp4" for a in run.job.actions},
                  run.dir / "ref-front-cutout.png", meta)
    refs = out / "refs"
    refs.mkdir()
    for pose in run.job.poses():
        shutil.copy2(run.dir / f"ref-{pose}-green.png", refs / f"{pose}.png")
    run.state.step("package").update(done=True, walk_facing=facing)
    run.state.save()


CONTENT_TYPES = {".json": "application/json", ".png": "image/png", ".mp4": "video/mp4", ".jpg": "image/jpeg"}


def manifest(run: Run) -> list[dict]:
    """Every file under out/, with what upload-urls and finish need; 'local' is the file itself."""
    steps = run.state.data["steps"]
    qa = {f"{a}.mp4": steps[f"video:{a}"].get("qa") for a in run.job.actions}
    qa.update({f"refs/{p}.png": steps[f"ref:{p}"].get("score") for p in run.job.poses()})
    out = run.dir / "out"
    files = []
    for f in sorted(p for p in out.rglob("*") if p.is_file()):
        rel = f.relative_to(out).as_posix()
        data = f.read_bytes()
        files.append({"path": rel, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "content_type": CONTENT_TYPES[f.suffix], "qa": qa.get(rel),
                      "deliverable": not rel.startswith("refs/"), "local": f})
    return files


def step_upload(run: Run) -> None:
    files = manifest(run)
    up = run.env.uploader
    urls = up.upload_urls(run.job.id, [{"path": f["path"], "bytes": f["bytes"], "content_type": f["content_type"]}
                                       for f in files])
    for f in files:
        run.progress.poll()
        up.put(urls[f["path"]], f["local"], f["content_type"])
    up.finish(run.job.id, run.state.data["steps"]["package"]["walk_facing"],
              [{k: f[k] for k in ("path", "bytes", "sha256", "qa", "deliverable")} for f in files])
    run.state.step("upload")["done"] = True
    run.state.data["redo_seen"] = None          # the server cleared the redo with the finish
    run.state.save()


SERVER_STAGES = {"fetch": "fetch", "ref": "refs", "propref": "propref", "video": "video",
                 "package": "package", "upload": "upload"}
_LABELS = {"fetch": "下载照片", "propref": "合成道具图", "package": "打包", "upload": "上传成品"}
_STEPS = {"fetch": step_fetch, "ref": step_ref, "propref": step_propref, "video": step_video,
          "package": step_package, "upload": step_upload}


def run_job(job: Job, env: Env, progress: Progress) -> Run:
    """Apply the job's redo once, then every step not yet done. The upload
    step ends with jobs/:id/finish, after which the job is the server's
    again -- no progress follows it."""
    run = Run(job, env, progress)
    apply_redo(run.state, job, run.dir)
    steps = job.steps()
    for step in steps:
        if run.state.done(step):
            continue
        kind, _, arg = step.partition(":")
        same = [s for s in steps if s.partition(":")[0] == kind]
        done = sum(run.state.done(s) for s in same)
        stage, message = SERVER_STAGES[kind], arg or _LABELS[kind]
        progress.begin(step, stage, done, len(same), message)
        _STEPS[kind](run, *([arg] if arg else []))
        if kind != "upload":
            progress.end(step, stage, done + 1, len(same), message)
    return run
```

- [ ] **Step 4: 运行，确认通过（全量）**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest -q`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/pipeline.py tools/petgen/tests/test_pipeline_run.py
git commit -m "feat(petgen): job pipeline: clips with one QA retry, package, upload, resumable run_job

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Reporter：进度、60 秒心跳、abort、停止请求

**Files:**
- Create: `tools/petgen/petgen/reporter.py`
- Test: `tools/petgen/tests/test_reporter.py`（新）

**Interfaces:**
- Consumes: `pipeline.JobAborted` / `StopRequested`（Task 7）、`server.ServerError`（Task 6；`Server.progress` 已把 409 abort 变成 True）
- Produces: `reporter.HEARTBEAT = 60.0`；`reporter.Reporter(server, job_id: int, stop: threading.Event, *, interval: float = HEARTBEAT, clock=time.monotonic)`，实现 `pipeline.Progress`：
  - `start() -> Reporter`（起心跳线程）、`close()`（停线程）
  - `begin(step, stage, done, total, message)`：`stop` 已置位 → 抛 `StopRequested`（不发）；否则记下并立即上报，收到 abort → 抛 `JobAborted`
  - `end(...)`：上报，收到 abort → 抛 `JobAborted`
  - `poll()`：`aborted` 为真 → 抛 `JobAborted`（心跳线程收到 abort 也会置位）
  - `cost(image_units, video_units, cents)`：累加到待报增量；上报成功才清零，失败留到下一次
  - 属性 `step`（最近一次 begin 的步骤键，worker 用它作 fail 的 stage，初值 `"claim"`）、`aborted`

- [ ] **Step 1: 写失败的测试**

`tests/test_reporter.py`：

```python
import threading
import time

import pytest

from petgen.pipeline import JobAborted, StopRequested
from petgen.reporter import Reporter
from petgen.server import ServerError


class Srv:
    def __init__(self):
        self.calls = []
        self.abort = False
        self.down = False

    def progress(self, job_id, stage, done, total, message, cost):
        if self.down:
            raise ServerError("jobs/12/progress: network error: down")
        self.calls.append({"job": job_id, "stage": stage, "done": done, "total": total,
                           "message": message, "cost": dict(cost)})
        return self.abort


ZERO = {"image_units": 0, "video_units": 0, "cents": 0}


def test_begin_and_end_report_the_stage_and_the_cost_since_the_last_report():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.cost(8, 0, 80)
    r.begin("ref:front", "refs", 0, 3, "front")
    r.end("ref:front", "refs", 1, 3, "front")
    assert s.calls[0] == {"job": 12, "stage": "refs", "done": 0, "total": 3, "message": "front",
                          "cost": {"image_units": 8, "video_units": 0, "cents": 80}}
    assert s.calls[1]["done"] == 1 and s.calls[1]["cost"] == ZERO
    assert r.step == "ref:front"


def test_cost_survives_a_failed_report():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.cost(0, 4, 400)
    s.down = True
    r.begin("video:stand", "video", 0, 5, "stand")
    s.down = False
    r.end("video:stand", "video", 1, 5, "stand")
    assert s.calls == [{"job": 12, "stage": "video", "done": 1, "total": 5, "message": "stand",
                        "cost": {"image_units": 0, "video_units": 4, "cents": 400}}]


def test_a_server_abort_stops_at_once_and_at_every_later_check():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    s.abort = True
    with pytest.raises(JobAborted):
        r.begin("video:walk", "video", 1, 5, "walk")
    with pytest.raises(JobAborted):
        r.poll()


def test_a_stop_request_lets_the_step_finish_and_stops_before_the_next():
    s = Srv()
    stop = threading.Event()
    r = Reporter(s, 12, stop, interval=3600)
    r.begin("video:stand", "video", 0, 5, "stand")
    stop.set()
    r.poll()                                     # mid-step: carry on
    r.end("video:stand", "video", 1, 5, "stand")
    with pytest.raises(StopRequested):
        r.begin("video:walk", "video", 1, 5, "walk")
    assert [c["message"] for c in s.calls] == ["stand", "stand"]


def test_the_heartbeat_repeats_the_last_progress_while_a_step_runs():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=0.05).start()
    try:
        r.begin("video:stand", "video", 0, 5, "stand")
        time.sleep(0.4)
    finally:
        r.close()
    assert len([c for c in s.calls if c["message"] == "stand"]) >= 3


def test_an_abort_seen_by_the_heartbeat_reaches_poll():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=0.05).start()
    try:
        r.begin("video:stand", "video", 0, 5, "stand")
        s.abort = True
        time.sleep(0.3)
        with pytest.raises(JobAborted):
            r.poll()
    finally:
        r.close()


def test_close_stops_the_heartbeat():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=0.05).start()
    r.close()
    n = len(s.calls)
    time.sleep(0.2)
    assert len(s.calls) == n
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_reporter.py -v`
Expected: `No module named 'petgen.reporter'`

- [ ] **Step 3: 新建 `petgen/reporter.py`**

```python
"""Progress to the server (spec 2026-10-10 5.2): at every step's start and
end, and every 60 s in between as the job's heartbeat (the reaper hands a
job back after 20 silent minutes). {abort: true} stops the job at the next
check; a stop request (Ctrl+C / SIGTERM) only before a step begins, so the
step in hand -- maybe a paid clip -- is finished first."""
from __future__ import annotations

import logging
import threading
import time

from petgen.pipeline import JobAborted, StopRequested
from petgen.server import ServerError

log = logging.getLogger("petgen.worker")
HEARTBEAT = 60.0


class Reporter:
    def __init__(self, server, job_id: int, stop: threading.Event, *, interval: float = HEARTBEAT,
                 clock=time.monotonic):
        self._server, self._job_id, self._stop = server, job_id, stop
        self._interval, self._clock = interval, clock
        self._lock = threading.Lock()
        self._halt = threading.Event()
        self._thread: threading.Thread | None = None
        self.step = "claim"
        self._report_args = ("claim", 0, 0, "")          # stage, done, total, message
        self._pending = [0.0, 0.0, 0]                    # image units, video units, cents not yet reported
        self._sent_at = clock()
        self.aborted = False

    def start(self) -> "Reporter":
        self._thread = threading.Thread(target=self._beat, name=f"heartbeat-{self._job_id}", daemon=True)
        self._thread.start()
        return self

    def close(self) -> None:
        self._halt.set()
        if self._thread is not None:
            self._thread.join(timeout=5)

    def begin(self, step: str, stage: str, done: int, total: int, message: str) -> None:
        if self._stop.is_set():
            raise StopRequested()
        self._report(step, stage, done, total, message)

    def end(self, step: str, stage: str, done: int, total: int, message: str) -> None:
        self._report(step, stage, done, total, message)

    def poll(self) -> None:
        if self.aborted:
            raise JobAborted()

    def cost(self, image_units: float, video_units: float, cents: int) -> None:
        with self._lock:
            self._pending[0] += image_units
            self._pending[1] += video_units
            self._pending[2] += cents

    def _report(self, step: str, stage: str, done: int, total: int, message: str) -> None:
        with self._lock:
            self.step = step
            self._report_args = (stage, done, total, message)
        self._send()
        self.poll()

    def _beat(self) -> None:
        while not self._halt.wait(min(5.0, self._interval)):
            if self._clock() - self._sent_at >= self._interval:
                self._send()

    def _send(self) -> None:
        with self._lock:
            image, video, cents = self._pending
            cost = {"image_units": round(image), "video_units": round(video), "cents": int(cents)}
            try:
                abort = self._server.progress(self._job_id, *self._report_args, cost)
            except ServerError as e:
                log.warning("progress for job %s not sent, kept for the next one: %s", self._job_id, e)
                return
            # The server adds the increment; keep only what rounding left behind.
            self._pending = [image - cost["image_units"], video - cost["video_units"], cents - cost["cents"]]
            self._sent_at = self._clock()
            if abort:
                self.aborted = True
```

- [ ] **Step 4: 运行，确认通过**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_reporter.py -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/reporter.py tools/petgen/tests/test_reporter.py
git commit -m "feat(petgen): progress reports double as a 60 s heartbeat; abort and stop checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Worker 循环与 `petgen worker` 命令

**Files:**
- Create: `tools/petgen/petgen/worker.py`
- Modify: `tools/petgen/petgen/__main__.py`（`cmd_worker` + parser）
- Modify: `tools/petgen/tests/fakes.py`（追加 `FakeServer`）
- Test: `tools/petgen/tests/test_worker.py`（新）、`tools/petgen/tests/test_cli_worker.py`（新）

**Interfaces:**
- Consumes: `pipeline.run_job` / `Env` / 异常（Task 7–8）、`reporter.Reporter` / `HEARTBEAT`（Task 9）、`server.Server` / `ServerError` / `ServerAbort`、`config.load_worker_config` / `ConfigError`（Task 6）、`jobstate.Job`、`kling.KlingError`
- Produces:
  - `worker.IMAGE_NEED = 32`、`VIDEO_NEED = 28`、`IDLE_WAIT = 15.0`、`PAUSE_WAIT = 300.0`、`ERROR_WAIT = 60.0`、`STATUS_EVERY = 300.0`、`LOW_BALANCE = "生成额度不足"`
  - `worker.Worker(server, env: Env, stop: threading.Event, *, heartbeat: float = HEARTBEAT, clock=time.monotonic, wait=None)`（`wait` 缺省 `stop.wait`）：
    - `tick() -> str`：一轮，返回 `"balance-error" | "paused" | "server-error" | "idle" | "done" | "failed" | "aborted" | "stopped"`
    - `process(raw_job: dict) -> str`
    - `run(once: bool = False) -> int`
  - CLI：`python -m petgen worker --server URL [--config FILE] [--work DIR] [--props DIR] [--once]`
  - `tests/fakes.FakeServer(jobs=())`（继承 `FakeUploader`；`claim / progress / fail / status`；`abort_at`（某 stage+message 时回 abort）、`on_progress` 回调、`progress_calls`、`failed`、`statuses`）

规则：
- 每轮先查余额（`env.kling.units_left`）。不够 → `worker/status {paused: true, reason: "生成额度不足"}`，等 5 分钟；够 → 若上次报的是暂停（或从没报过）就报 `{paused: false}`（服务端靠它恢复派单），再 `claim`。状态没变时最多 5 分钟重报一次（后台显示余额）。
- claim 无单 → 等 15 秒（带 `paused_reason` 时记日志）。
- 一次一单。`StepFailed` / `BudgetExceeded` / 任何未捕获异常 → `fail(stage = reporter.step, reason)` 后继续下一轮；`JobAborted` / `ServerAbort`（409）→ 不报 fail；`StopRequested` → 不报 fail，`run` 退出（卡单回收会把单交回 paid，下次续跑）。
- claim 数据不合法 → `fail(stage="claim", reason="任务数据不合法：...")`。
- 信号：第一次 Ctrl+C / SIGTERM 只置 `stop`，当前步骤做完再走；第二次直接 `KeyboardInterrupt`（退出码 130）。

- [ ] **Step 1: 追加 `FakeServer`，写失败的测试**

`tests/fakes.py` 末尾追加：

```python
class FakeServer(FakeUploader):
    """The PHP internal worker API in memory."""

    def __init__(self, jobs=()):
        super().__init__()
        self.jobs = list(jobs)
        self.progress_calls: list[tuple] = []     # (job_id, stage, done, total, message, cost)
        self.failed: list[tuple] = []             # (job_id, stage, reason)
        self.statuses: list[tuple] = []           # (paused, reason, balance)
        self.abort_at = None                      # (stage, message) that answers abort
        self.on_progress = None

    def claim(self):
        return {"job": self.jobs.pop(0) if self.jobs else None}

    def progress(self, job_id, stage, done, total, message, cost):
        self.progress_calls.append((job_id, stage, done, total, message, dict(cost)))
        self.events.append(("progress", stage, message))
        if self.on_progress is not None:
            self.on_progress(stage, message)
        return (stage, message) == self.abort_at

    def fail(self, job_id, stage, reason):
        self.failed.append((job_id, stage, reason))

    def status(self, paused, reason, balance):
        self.statuses.append((paused, reason, dict(balance)))
```

`tests/test_worker.py`：

```python
import json
import threading

import pytest

from petgen import pipeline
from petgen.kling import KlingError, KlingRejected
from petgen.server import ServerAbort
from petgen.worker import ERROR_WAIT, IDLE_WAIT, LOW_BALANCE, PAUSE_WAIT, Worker
from tests.fakes import FakeKling, FakeServer, claim, install_fake_tools, make_env


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


@pytest.fixture
def w(tmp_path, monkeypatch):
    """Worker on fakes: w.make(*jobs) -> (worker, server, kling, waits)."""
    knobs = install_fake_tools(monkeypatch)

    class Kit:
        pass

    kit = Kit()
    kit.knobs, kit.clock, kit.stop, kit.waits = knobs, Clock(), threading.Event(), []
    kit.fk = FakeKling()

    def make(*jobs):
        kit.srv = FakeServer(jobs)
        kit.env = make_env(tmp_path, kit.fk, kit.srv)
        return Worker(kit.srv, kit.env, kit.stop, heartbeat=3600, clock=kit.clock, wait=kit.waits.append)

    kit.make = make
    return kit


def test_low_balance_pauses_without_claiming(w):
    w.fk.balance = {"image": 1000.0, "video": 27.0}
    worker = w.make(claim())
    assert worker.tick() == "paused"
    assert w.srv.statuses == [(True, LOW_BALANCE, {"image": 1000, "video": 27})]
    assert len(w.srv.jobs) == 1
    assert w.waits == [PAUSE_WAIT]


def test_balance_back_reports_unpaused_then_claims(w):
    w.fk.balance = {"image": 31.0, "video": 100.0}
    worker = w.make(claim())
    assert worker.tick() == "paused"
    w.fk.balance = {"image": 1000.0, "video": 100.0}
    assert worker.tick() == "done"
    assert w.srv.statuses[1] == (False, "", {"image": 1000, "video": 100})
    assert len(w.srv.finished) == 1


def test_status_is_resent_only_on_change_or_every_five_minutes(w):
    worker = w.make()
    assert worker.tick() == "idle"
    assert worker.tick() == "idle"
    assert len(w.srv.statuses) == 1
    w.clock.t += 301
    worker.tick()
    assert len(w.srv.statuses) == 2


def test_a_failed_balance_check_waits_and_claims_nothing(w):
    w.fk.balance_error = KlingError("network error: timed out")
    worker = w.make(claim())
    assert worker.tick() == "balance-error"
    assert w.waits == [ERROR_WAIT] and len(w.srv.jobs) == 1


def test_no_job_waits_fifteen_seconds(w):
    worker = w.make()
    assert worker.tick() == "idle"
    assert w.waits == [IDLE_WAIT]


def test_a_job_runs_to_review_and_nothing_is_reported_after_the_finish(w):
    worker = w.make(claim())
    assert worker.tick() == "done"
    assert w.srv.failed == []
    assert w.srv.finished[0][0] == "left"
    assert w.srv.events[-1] == ("finish",)
    assert ("progress", "video", "play") in w.srv.events
    total = {"image_units": 0, "video_units": 0, "cents": 0}
    for *_, cost in w.srv.progress_calls:
        for k in total:
            total[k] += cost[k]
    assert total == {"image_units": 24, "video_units": 20, "cents": 2240}


def test_a_refused_photo_twice_fails_with_a_readable_reason(w):
    w.fk.reject = [KlingRejected("create image failed: code=1301 图片审核未通过")] * 2
    worker = w.make(claim())
    assert worker.tick() == "failed"
    [(job_id, stage, reason)] = w.srv.failed
    assert (job_id, stage) == (12, "ref:front")
    assert "参考图 front" in reason and "code=1301 图片审核未通过" in reason


def test_a_crash_is_reported_with_its_stage_and_the_worker_carries_on(w, monkeypatch):
    def boom(raw, final, workdir, action):
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setattr(pipeline, "finish_and_qa", boom)
    worker = w.make(claim(), claim(id=13, pet_id="custom-13"))
    assert worker.tick() == "failed"
    assert w.srv.failed == [(12, "video:stand", "RuntimeError: ffmpeg exploded")]
    install_fake_tools(monkeypatch)
    assert worker.tick() == "done"


def test_a_server_abort_drops_the_job_without_failing_it(w):
    worker = w.make(claim())
    w.srv.abort_at = ("video", "walk")
    assert worker.tick() == "aborted"
    assert w.srv.failed == [] and w.srv.finished == []
    assert len(w.fk.created) == 4


def test_a_409_during_upload_is_an_abort_too(w, monkeypatch):
    worker = w.make(claim())

    def gone(job_id, walk_facing, files):
        raise ServerAbort("jobs/12/finish: HTTP 409 job is refunded", 409)

    monkeypatch.setattr(w.srv, "finish", gone)
    assert worker.tick() == "aborted"
    assert w.srv.failed == []


def test_stop_finishes_the_step_then_leaves_the_job_for_the_reaper(w, tmp_path):
    worker = w.make(claim())
    w.srv.on_progress = lambda stage, message: w.stop.set() if (stage, message) == ("refs", "walk") else None
    assert worker.tick() == "stopped"
    assert w.srv.failed == []
    state = json.loads((tmp_path / "work" / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["steps"]["ref:walk"]["done"] is True and "ref:lie" not in state["steps"]


def test_a_budget_overrun_fails_the_job_before_any_call(w):
    worker = w.make(claim(spent_cents=7990))
    assert worker.tick() == "failed"
    [(job_id, stage, reason)] = w.srv.failed
    assert stage == "ref:front" and reason.startswith("超出单笔预算")
    assert w.fk.created == []


def test_bad_job_data_fails_at_claim(w):
    worker = w.make(claim(species="other"))
    assert worker.tick() == "failed"
    assert w.srv.failed == [(12, "claim", "任务数据不合法：不支持的类别 other")]


def test_run_returns_at_once_when_stopped(w):
    worker = w.make(claim())
    w.stop.set()
    assert worker.run() == 0
    assert len(w.srv.jobs) == 1


def test_once_exits_after_one_job(w):
    worker = w.make(claim(), claim(id=13, pet_id="custom-13"))
    assert worker.run(once=True) == 0
    assert len(w.srv.finished) == 1 and len(w.srv.jobs) == 1
```

`tests/test_cli_worker.py`：

```python
import signal
import sys

import petgen.__main__ as cli
import petgen.worker as worker_mod


def _props(tmp_path):
    props = tmp_path / "work" / "props"
    props.mkdir(parents=True)
    for kind in ("bowl", "ball"):
        (props / f"{kind}-cutout.png").write_bytes(b"png")
    return props


def test_worker_without_config_names_the_file(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    monkeypatch.setattr(sys, "argv", ["petgen", "worker", "--server", "https://example.invalid"])
    assert cli.main() == 1
    assert "worker.env" in capsys.readouterr().out


def test_worker_refuses_to_start_without_the_props(monkeypatch, tmp_path, capsys):
    (tmp_path / "worker.env").write_text("AIPET_WORKER_KEY=k-1\n", encoding="utf-8")
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    monkeypatch.setattr(sys, "argv", ["petgen", "worker", "--server", "https://example.invalid",
                                      "--work", str(tmp_path / "work")])
    assert cli.main() == 1
    assert "bowl-cutout.png" in capsys.readouterr().out


def test_worker_starts_with_its_settings_and_never_prints_the_key(monkeypatch, tmp_path, capsys):
    (tmp_path / "worker.env").write_text("AIPET_WORKER_KEY=sekrit-value-123\n", encoding="utf-8")
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    _props(tmp_path)
    handlers = []
    monkeypatch.setattr(signal, "signal", lambda sig, fn: handlers.append(sig))
    seen = {}

    def fake_run(self, once=False):
        seen.update(server=self.server, env=self.env, once=once)
        return 0

    monkeypatch.setattr(worker_mod.Worker, "run", fake_run)
    monkeypatch.setattr(sys, "argv", ["petgen", "worker", "--server", "https://example.invalid/",
                                      "--work", str(tmp_path / "work"), "--once"])
    assert cli.main() == 0
    assert seen["server"].base == "https://example.invalid" and seen["once"] is True
    assert seen["env"].work == tmp_path / "work" and seen["env"].props == tmp_path / "work" / "props"
    assert signal.SIGINT in handlers
    out = capsys.readouterr()
    assert "sekrit-value-123" not in out.out + out.err
```

- [ ] **Step 2: 运行，确认失败**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest tests/test_worker.py tests/test_cli_worker.py -v`
Expected: `No module named 'petgen.worker'`

- [ ] **Step 3: 新建 `petgen/worker.py`**

```python
"""python -m petgen worker: claim a paid custom-pet job, make it, upload it,
repeat (spec 2026-10-10 5.2). One job at a time."""
from __future__ import annotations

import logging
import threading
import time

from petgen.jobstate import Job
from petgen.kling import KlingError
from petgen.pipeline import BudgetExceeded, Env, JobAborted, StepFailed, StopRequested, run_job
from petgen.reporter import HEARTBEAT, Reporter
from petgen.server import ServerAbort, ServerError

log = logging.getLogger("petgen.worker")
IMAGE_NEED = 8 * 4       # four stills' worth (spec 4.5)
VIDEO_NEED = 7 * 4       # the largest plan: 7 actions x 4 units -- the plan is unknown before the claim
IDLE_WAIT = 15.0
PAUSE_WAIT = 300.0
ERROR_WAIT = 60.0
STATUS_EVERY = 300.0
LOW_BALANCE = "生成额度不足"


class Worker:
    def __init__(self, server, env: Env, stop: threading.Event, *, heartbeat: float = HEARTBEAT,
                 clock=time.monotonic, wait=None):
        self.server, self.env, self.stop = server, env, stop
        self.heartbeat, self.clock = heartbeat, clock
        self.wait = wait or stop.wait
        self._last_status: tuple[bool, str] | None = None
        self._status_at = float("-inf")

    def run(self, once: bool = False) -> int:
        while not self.stop.is_set():
            r = self.tick()
            if r == "stopped" or (once and r in ("done", "failed", "aborted")):
                break
        return 0

    def tick(self) -> str:
        try:
            balance = {"image": self.env.kling.units_left("image"), "video": self.env.kling.units_left("video")}
        except KlingError as e:
            log.warning("balance check failed: %s", e)
            self.wait(ERROR_WAIT)
            return "balance-error"
        low = balance["image"] < IMAGE_NEED or balance["video"] < VIDEO_NEED
        self._status(low, LOW_BALANCE if low else "", balance)
        if low:
            self.wait(PAUSE_WAIT)
            return "paused"
        try:
            res = self.server.claim()
        except ServerError as e:
            log.warning("claim failed: %s", e)
            self.wait(IDLE_WAIT)
            return "server-error"
        if not res.get("job"):
            if res.get("paused_reason"):
                log.info("server holds jobs back: %s", res["paused_reason"])
            self.wait(IDLE_WAIT)
            return "idle"
        return self.process(res["job"])

    def _status(self, paused: bool, reason: str, balance: dict) -> None:
        now = self.clock()
        if (paused, reason) == self._last_status and now - self._status_at < STATUS_EVERY:
            return
        try:
            self.server.status(paused, reason, {k: round(v) for k, v in balance.items()})
        except ServerError as e:
            log.warning("worker/status not sent: %s", e)
            return
        self._last_status, self._status_at = (paused, reason), now

    def process(self, raw: dict) -> str:
        try:
            job = Job.from_claim(raw)
        except (KeyError, TypeError, ValueError) as e:
            self._fail(raw.get("id"), "claim", f"任务数据不合法：{e}")
            return "failed"
        log.info("job %s (%s, %s) claimed", job.id, job.species, ",".join(job.actions))
        rep = Reporter(self.server, job.id, self.stop, interval=self.heartbeat, clock=self.clock).start()
        try:
            run_job(job, self.env, rep)
            log.info("job %s uploaded for review", job.id)
            return "done"
        except StopRequested:
            log.info("stopping: job %s is left for the reaper to hand back", job.id)
            return "stopped"
        except (JobAborted, ServerAbort):
            log.info("job %s was changed on the server; dropped", job.id)
            return "aborted"
        except (StepFailed, BudgetExceeded) as e:
            self._fail(job.id, rep.step, str(e))
            return "failed"
        except Exception as e:  # noqa: BLE001 -- any crash fails this job, the worker carries on
            log.exception("job %s crashed in %s", job.id, rep.step)
            self._fail(job.id, rep.step, f"{type(e).__name__}: {e}")
            return "failed"
        finally:
            rep.close()

    def _fail(self, job_id, stage: str, reason: str) -> None:
        if job_id is None:
            return
        try:
            self.server.fail(job_id, stage, reason[:255])
        except ServerError as e:
            log.error("could not report the failure of job %s: %s", job_id, e)
```

- [ ] **Step 4: `__main__.py` 加 `worker` 命令**

`cmd_voice` 之后（`main` 之前）插入：

```python
def cmd_worker(a) -> int:
    import logging
    import signal
    import threading
    from petgen.config import ConfigError, load_worker_config
    from petgen.pipeline import Env
    from petgen.server import Server
    from petgen.worker import Worker
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        cfg = load_worker_config(a.config)
    except ConfigError as e:
        print(f"FAIL worker: {e}")
        return 1
    work = a.work or WORK
    props = a.props or work / "props"
    missing = [f"{k}-cutout.png" for k in ("bowl", "ball") if not (props / f"{k}-cutout.png").exists()]
    if missing:
        print(f"FAIL worker: no {', '.join(missing)} in {props}: run `petgen prop bowl` / `petgen prop ball` "
              f"or copy work/props there")
        return 1
    stop = threading.Event()

    def on_signal(_signum, _frame):
        if stop.is_set():
            raise KeyboardInterrupt
        print("stopping after the current step (signal again to quit now)", flush=True)
        stop.set()

    signal.signal(signal.SIGINT, on_signal)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, on_signal)
    server = Server(a.server, cfg.key)
    env = Env(work=work, props=props, prices=cfg.prices, uploader=server)
    try:
        return Worker(server, env, stop).run(once=a.once)
    except KeyboardInterrupt:
        return 130
```

`main()` 里 `vp.set_defaults(fn=cmd_voice)` 之后插入：

```python
    wp = sub.add_parser("worker", help="claim paid custom-pet jobs from the server and make them")
    wp.add_argument("--server", required=True, help="e.g. https://aipei.pixpickai.com")
    wp.add_argument("--config", type=Path, default=None, help="worker.env; default <secrets>/worker.env")
    wp.add_argument("--work", type=Path, default=None, help="job folders go to <work>/jobs/<id>; default tools/petgen/work")
    wp.add_argument("--props", type=Path, default=None, help="bowl-cutout.png / ball-cutout.png; default <work>/props")
    wp.add_argument("--once", action="store_true", help="exit after one job (manual checks)")
    wp.set_defaults(fn=cmd_worker)
```

- [ ] **Step 5: 运行，确认通过（全量）**

Run: `cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest -q`
Expected: 全部 PASS

- [ ] **Step 6: Commit**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/petgen/worker.py tools/petgen/petgen/__main__.py tools/petgen/tests/fakes.py tools/petgen/tests/test_worker.py tools/petgen/tests/test_cli_worker.py
git commit -m "feat(petgen): worker command: balance check, claim, make, upload, fail with the stage

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

（按 (b) 时去掉 `__main__.py` 与 `test_cli_worker.py`。）

---

### Task 11: 部署文件与真机验收

**Files:**
- Create: `tools/petgen/deploy/aipet-worker.service`
- 无其他代码改动（验收中发现问题按 superpowers:systematic-debugging 修，修完补测试再提交）

**Interfaces:**
- Consumes: `python -m petgen worker`（Task 10）、`secrets/worker.env.example`（Task 6）

- [ ] **Step 1: 写 systemd 单元**

`tools/petgen/deploy/aipet-worker.service`：

```ini
# aipet 定制宠物生成程序（spec 2026-10-10 5.2）。
# 安装：复制到 /etc/systemd/system/，按服务器实际路径改 User / 路径，然后
#   systemctl daemon-reload && systemctl enable --now aipet-worker
# 停止时 SIGTERM：做完当前步骤再退出（一个视频步骤最长约 20 分钟），所以 TimeoutStopSec 给足。
# 宝塔「进程守护」等价配置：启动命令同 ExecStart，环境变量同 Environment。
[Unit]
Description=aipet custom-pet generation worker (petgen)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=aipet
WorkingDirectory=/opt/aipet/tools/petgen
Environment=PETGEN_SECRETS=/opt/aipet/secrets
Environment=U2NET_HOME=/opt/aipet/u2net
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/aipet/tools/petgen/.venv/bin/python -m petgen worker --server https://aipei.pixpickai.com --work /opt/aipet/work
KillSignal=SIGTERM
TimeoutStopSec=1800
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

服务器准备（写在这里给部署的人，不在本机执行）：Python 3.11+、`ffmpeg` / `ffprobe` 在 PATH、`python -m venv .venv && .venv/bin/pip install -r requirements.txt`；`/opt/aipet/secrets/` 放 `kling.env` 与 `worker.env`（权限 600）；`/opt/aipet/work/props/` 放 `bowl-cutout.png`、`ball-cutout.png`（从本机 `tools/petgen/work/props/` 复制）；`/opt/aipet/u2net` 第一次运行会下载 rembg 模型（约 224 MB），要可写且持久。

- [ ] **Step 2: 全量测试与静态检查**

Run:
```bash
cd /c/Users/Administrator/code/aipet/tools/petgen && .venv/Scripts/python -m pytest -q
.venv/Scripts/python -m petgen worker --help
.venv/Scripts/python -m petgen package --help
.venv/Scripts/python -m petgen import-spike --help
```
Expected: 全部 PASS（基线 103 + 本计划新增，skip 仍为 4）；三个 help 正常列出 `--server/--config/--work/--props/--once`、`--out`、`--from`。

- [ ] **Step 3: Commit 部署文件**

```bash
cd /c/Users/Administrator/code/aipet
git add tools/petgen/deploy/aipet-worker.service
git commit -m "chore(petgen): systemd unit for the generation worker

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: 真机演练（花钱，先问用户）**

前提：服务端计划已部署并执行迁移；用户已填 `secrets/worker.env`；有一张 0.01 元测试套餐付款成功、状态 `paid` 的狗或猫定制单；可灵图片 ≥ 32、视频 ≥ 28 单位。**问用户同意后**再跑（标准版约 24 图片单位 + 20 视频单位，质检重试最多翻倍）。

Run（PowerShell，在 `tools\petgen`）：
```powershell
.venv\Scripts\python -m petgen worker --server https://aipei.pixpickai.com --once
```
核对：
1. 日志依次出现 claim → 每步 begin/end；后台详情页进度随之变化（`refs 1/3 · front` … `video 3/5 · feed`），心跳时间每分钟刷新。
2. 跑到某个 `video` 步骤时按一次 Ctrl+C：打印「stopping after the current step」，该步做完后退出，后台状态仍是生成中、没有 fail。再执行同一命令：已完成步骤全部跳过，**可灵没有为已完成 / 已建任务再扣费**（`python -m petgen balance` 前后对比）。
3. 跑完：后台变「待审核」，每个动作可预览、质检分数可见，`refs/` 三张参考图可看；`cost_cents` 与本地 `work/jobs/<id>/state.json` 记的单位 × 价格一致。
4. 后台对一个动作点「重做」并填提示 → 再跑一次 `--once`：只新建了这一个视频任务（`state.json` 的 `seq` 只有它 +1），其他文件未重生。
5. 把 `worker.env` 临时改成错误密钥再跑：打印 HTTP 401，不崩溃、不输出密钥；改回。

- [ ] **Step 5: 报告**

列出每个 Task 的提交（或按 (b) 留在工作区的文件）、本机验证了什么、**没验证什么**（真机演练若未获同意或服务端未部署，则端到端、OSS 实传、可灵真实审核拒绝均未验证）。

---

## Self-Review（写计划时已做）

- **Spec 覆盖**：5.1 拆分与 `pipeline.py` / `Job` / 步骤与产物 / state.json 跳过 / redo 清标记（含 `refs: true` 连带视频）/ 每步重试一次 / 下载流式 + 重试 + 先落盘任务 id 与 URL → Task 4、5、7、8；5.2 worker 命令、密钥文件、余额 → 暂停 / 5 分钟重查、15 秒领单、一次一单、进度即心跳 + 60 秒、abort、未捕获异常 fail 带步骤、Ctrl+C / SIGTERM、部署 → Task 6、9、10、11；5.3 SPIKE_OUT / package 路径参数 / ffmpeg 不依赖盘符 / 内置 CLI 回归 → Task 1、2、3、4；4.5 预算每次调用前检查、余额阈值、价格表 → Task 6、7、10。
- **类型一致**：`Progress.begin/end(step, stage, done, total, message)` 在 pipeline、FakeProgress、Reporter 三处一致；`Server.progress(job_id, stage, done, total, message, cost)` 在 server、FakeServer、Reporter 一致；`install_fake_tools` 替换的 `gate` / `prop_ref` / `finish_and_qa` / `guess_facing` 签名与 pipeline 定义一致。
- **Review Focus**：五条都已落到对应任务的测试里（见各条括号）。

## 本计划替规格做的决定

1. `progress` 的 `stage` 用步骤类别、`done/total` 为类别内计数、`message` 为当前项（对齐服务端示例）；`fail` 的 `stage` 用更细的步骤键（如 `video:play`）。
2. 视频质检重试一次后仍不过：保留并标 `qa.pass = false` 交人工审核，不 fail 整单；参考图两次都过不了 gate 才 fail。道具图合成是确定性的，不重试。
3. `refs: true` 只重生列出动作所用的姿态（idle 一族是 front）及其道具图、grade.json 和所有用这些姿态的视频；hint 只加到列出动作的视频提示词末尾。
4. 同一个 redo 只应用一次（`redo_seen`），finish 成功后清除；失败过的步骤已用完两次付费机会，没有 redo 的重新领取会直接再 fail，不会继续花钱。
5. 余额阈值按最大套餐算（图片 32、视频 28），因为领单前不知道动作数。
6. 每次上传都报全部文件（满足服务端「并集须完整」，实现最简单）。
7. 动作按规范顺序处理、stand 必须在列表里（它定全片曝光）；`walkFacing` 没有 walk 时为 `right`。
8. `import-spike` 不再有硬编码默认目录（`--from` 或 `$PETGEN_SPIKE_OUT`）；服务器上用 `$PETGEN_SECRETS` 指定密钥目录；道具抠图从 `<work>/props` 读，缺了 worker 拒绝启动。
9. 价格默认图片 10 分 / 单位、视频 100 分 / 单位，写在 `worker.env`，上线前按购买价改。

