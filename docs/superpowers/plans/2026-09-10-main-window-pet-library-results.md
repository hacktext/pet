# Task 1 实测结果（多窗口原型）

记录时间：2026-09-11。环境：Flutter 3.47.2（stable）、Dart 3.13.2、Windows 11。
`apps\aipet`，`flutter build windows --debug` 产物 `aipet.exe`，
`AIPET_PROTO_AUTORUN=1` 自动驱动，日志 `%TEMP%\aipet_proto.log`。

只跑了一次 Step 5（构建与运行一次成功，没有因环境原因失败过，因此没有删日志重跑）。

## 完整日志原文

```
[proto] engine windowId=2707be5a-f37c-499f-86b4-c3fc0390ab47 arguments=""
[proto] C2 tray icon + menu set
[proto] C1 frame after 1s = 1
[proto] C3 created main window ad132150-1624-4f4f-8204-b3e016b6d186 (windows now [2707be5a-f37c-499f-86b4-c3fc0390ab47, ad132150-1624-4f4f-8204-b3e016b6d186])
[proto] engine windowId=ad132150-1624-4f4f-8204-b3e016b6d186 arguments="main_window"
[proto] C6 window_manager in sub window: no exception
[proto] pet got ping
[proto] C4 main->pet: pong-from-pet
[proto] main got ping
[proto] C5 pet->main: pong-from-main
[proto] C7 windows before external WM_CLOSE: [2707be5a-f37c-499f-86b4-c3fc0390ab47, ad132150-1624-4f4f-8204-b3e016b6d186]
[proto] C7 windows after external WM_CLOSE: [2707be5a-f37c-499f-86b4-c3fc0390ab47]
[proto] C3 created main window e7961310-1928-49e2-816e-c8dd1df4d269 (windows now [2707be5a-f37c-499f-86b4-c3fc0390ab47, e7961310-1928-49e2-816e-c8dd1df4d269])
[proto] engine windowId=e7961310-1928-49e2-816e-c8dd1df4d269 arguments="main_window"
[proto] C6 window_manager in sub window: no exception
[proto] pet got ping
[proto] C4 main->pet: pong-from-pet
[proto] main got ping
[proto] C7-reopen pet->main: pong-from-main
[proto] C8 pet window hidden
[proto] main got ping
[proto] C8 pet->main: pong-from-main
[proto] C9 quitting
```

WM_CLOSE 脚本输出（在主窗口出现后等 2 秒再发）：

```
posted WM_CLOSE to 1510102
```

25 秒后采集：

```
Get-Content "$env:TEMP\aipet_proto.log"    # 见上
Get-Process aipet -ErrorAction SilentlyContinue | Select-Object Id, @{n='WS_MB';e={[int]($_.WorkingSet64/1MB)}}
   Id WS_MB
   -- -----
60460     0
```

## C1–C9 判定表

| # | 检查 | 结论 | 依据（日志原文） |
|---|---|---|---|
| C1 | 主引擎里 alpha_video 播放 | **通过** | `[proto] C1 frame after 1s = 1`（>0） |
| C2 | 托盘图标 + 菜单设置 | **通过** | `[proto] C2 tray icon + menu set`（点击交互留到 Task 16 真机验收） |
| C3 | 建子窗口 | **通过** | `[proto] C3 created main window ad132150-1624-4f4f-8204-b3e016b6d186 (windows now [...])`（重开后再次出现：`[proto] C3 created main window e7961310-...`） |
| C4 | 主窗口 → 宠物窗 | **通过** | `[proto] C4 main->pet: pong-from-pet`（出现两次，重开后仍通） |
| C5 | 宠物窗 → 主窗口 | **通过** | `[proto] C5 pet->main: pong-from-main` |
| C6 | 子窗口里 window_manager | **通过** | `[proto] C6 window_manager in sub window: no exception`（两次子窗口实例都无异常）；且 WM_CLOSE 脚本按标题 `aipet proto main` 找到了窗口并成功 `posted WM_CLOSE to 1510102` —— 标题确实生效，两个条件都满足 |
| C7 | 点 × 后 | **销毁**，重开后通道仍通 | before：`[2707be5a-..., ad132150-...]`；after：`[2707be5a-...]`——主窗口 id（`ad132150-...`）从列表消失，即 WM_CLOSE 让 desktop_multi_window **销毁**了子窗口而不是隐藏（若是隐藏，id 应该还在列表里）。重开产生了全新 id（`e7961310-...`），随后 `[proto] C7-reopen pet->main: pong-from-main` 证明重开后通道仍然正常 |
| C8 | 宠物窗隐藏时通道 | **通过** | `[proto] C8 pet window hidden` 之后 `[proto] C8 pet->main: pong-from-main`，宠物窗隐藏不影响 `WindowMethodChannel` |
| C9 | 退出 | **字面判据未过，但已确认应用本体已完全退出** | 见下方详细说明 |

### C9 详细说明

`[proto] C9 quitting` 之后按 Step 5 等 25 秒采集，`Get-Process aipet` **没有返回空**，仍能查到
pid 60460（`Id=60460 WS_MB=0`）。按判据表字面要求这一项没有通过。但进一步诊断显示该 pid 已经
不是一个"卡住的活进程"，而是系统尚未回收的残余进程对象：

- `tasklist /v /fi "PID eq 60460"`：`Status` 显示 `Unknown`，`Mem Usage 132 K`，`CPU Time 0:00:00`。
- `(Get-Process -Id 60460).Threads.Count` = 0（正常运行中的 GUI 进程至少有一条消息泵线程）。
- `Get-Process -Id 60460 | Select HandleCount, WorkingSet64` → `HandleCount=0`，`WorkingSet64=32768`（32KB）。
- 用 `EnumWindows` + `GetWindowThreadProcessId` 枚举系统所有窗口，属于 pid 60460 的窗口数 = **0**。
- `Stop-Process -Id 60460 -Force` 之后该 pid 仍在 `Get-Process` 里出现（说明它已经不是一个可以被
  信号终止的"活"进程）。
- 对照实验：用同样的 `Start-Process` 方式起停一个 `cmd.exe /c exit 0`（一次性短生命周期进程），
  2 秒后 `Get-Process -Id <pid>` 直接返回空——说明本环境下 `Start-Process` 启动的普通短生命周期
  进程不会留下这种残余记录，残余现象是 `aipet.exe` 特有的，不是通用环境噪音。

综合以上：`aipet.exe` 自身的线程、窗口、句柄都已清零，唯独 pid 条目还挂在系统进程表里没被回收——
这是"进程已经跑完自己的清理路径、调用了 `ExitProcess`，但 pid 对象因为某处残留的句柄引用还没被
内核释放"的典型特征，而不是 Dart/C++ 代码卡死。怀疑跟 `windows/runner/main.cpp` 里的
`AttachConsole(ATTACH_PARENT_PROCESS)`（把子进程挂到发起它的 PowerShell 控制台上）以及本次用
一次性 PowerShell 会话跑 `Start-Process` 后该会话立即退出的组合有关，不认为是多窗口原型本身的
缺陷。**Task 15 不应仅凭 `Get-Process` 判断退出是否完成**；如果需要脚本化验收，建议改用应用自己
上报的退出标记（比如日志里的最后一行）或者进程句柄的 `WaitForExit`/`GetExitCodeProcess`，而不是
残留 pid 是否还能被 `Get-Process` 枚举到。

## 判定规则结论

C1、C3、C4、C5 全部通过 → **不触发"停止执行本计划，重新讨论方案"**，继续按当前多窗口设计推进。

**C6、C7 结论（Task 15 据此选分支）：**

- **C6：`window_manager` 在子窗口（`desktop_multi_window` 创建的独立引擎）里可以正常工作**——
  两次创建的子窗口引擎调用 `windowManager.ensureInitialized()` / `waitUntilReadyToShow()` /
  `show()` 都没有抛异常，且设置的英文标题 `aipet proto main` 真的生效（外部脚本用
  `EnumWindows` + `GetWindowText` 按标题精确匹配到了它，而不是误中宠物窗）。Task 15 可以放心
  在主窗口（子窗口）里用 `window_manager` 控制标题栏/尺寸/居中等窗口 chrome，不需要绕开
  `window_manager` 另找方案。
- **C7：点 ×（WM_CLOSE）销毁子窗口，不是隐藏**——`before`/`after` 窗口 id 列表对比证明子窗口
  id 从存活列表里消失，即 `desktop_multi_window` 对 WM_CLOSE 的默认处理是销毁整个子窗口
  （连带其引擎）。重新 `WindowController.create()` 会产生一个全新 id 的窗口实例，且
  `WindowMethodChannel('aipet/pet')` 在新实例上依然正常收发（`C7-reopen pet->main:
  pong-from-main`）。**Task 15 的含义**：主窗口"关闭"在效果上等价于"整个主窗口引擎被销毁"，
  不能假设主窗口里的内存态（比如 `MainWindowModel`）会在下次打开时还在——每次重新打开主窗口都
  需要重新 `create()` 一个子窗口并重新初始化其状态/重新 `setMethodCallHandler`，不能走"`hide()`
  之后 `show()` 复用同一个存活实例"的分支设计。

## 对后续任务的其他参考

- C2（托盘图标 + 菜单）只验证了"设置不抛异常"，真实的点击（左键打开宠物库 / 右键弹出菜单 /
  菜单项点击）没有被自动化验证到，按计划留给 Task 16 的真机点击验收。
- C9 的残余 pid 现象已如上归因为测试手法（`Start-Process` + `AttachConsole` 组合）产生的假象，
  不建议作为"退出流程有 bug"处理；但如果 Task 16 真机验收也观察到退出后进程列表里还有
  `aipet.exe`，需要重新确认是否是同一现象。

# Task 3 实测结果（3 只系统宠物的素材）

记录时间：2026-09-11。环境：`tools/petgen/.venv`（Python 3.14），Kling `kling-v3`，
`ffmpeg`/`ffprobe` 来自 chocolatey。TDD（`tests/test_package.py`）RED→GREEN 之后按 Step 6–11
顺序执行，全程未切换品种、未触发预算停止规则。

## TDD 证据（`test_package.py`）

RED（Step 2，实现前）：

```
tests\test_package.py:3: in <module>
    from petgen.package import COVER_MAX, make_cover, pet_json
E   ModuleNotFoundError: No module named 'petgen.package'
1 error in 0.15s
```

GREEN（Step 5，实现 `petgen/package.py` 与 `petgen/__main__.py` 之后，跑全量测试）：

```
....................................................                     [100%]
52 passed in 0.76s
```

`petgen/package.py`、`petgen/__main__.py` 与简报（task-3-brief.md）代码块逐字符 diff 一致
（`main()` 里 `("video", cmd_video, ("action", ACTIONS))` 这一处元组结构核对过，非
`("video", cmd_video, ACTIONS)`）。

## Step 6：导入 spike 参考图 + 9 项门槛（不花钱）

`import-spike` 12/12 文件全部命中（3 只宠物 × [src + ref-stand/walk/lie]），无 MISSING，
因此没有跑 `source`/`pose` 补拍，图像单位消耗为 0。9 项门槛全部一次通过，与简报预告的数值一致
（金毛站姿 blob_core 最高但仍 <200）：

```
PASS ragdoll/stand: floating=605 blob_core=21
PASS ragdoll/walk: floating=283 blob_core=1
PASS ragdoll/lie: floating=146 blob_core=1
PASS gold/stand: floating=961 blob_core=142
PASS gold/walk: floating=483 blob_core=27
PASS gold/lie: floating=6 blob_core=0
PASS corgi/stand: floating=472 blob_core=7
PASS corgi/walk: floating=25 blob_core=0
PASS corgi/lie: floating=34 blob_core=0
```

## Step 7：15 个视频生成 + QA（45 视频单位，无重试）

跑之前 `balance`：视频 79/100（online），图像 832/1000（online），足够 45 单位预算，未触发
「不足 45 先停」规则。按简报要求布偶猫先做，逐条 `video` + `qa` 分开执行（每条视频约 70–120s）。
**15/15 一次性通过 QA，全程 0 次重试，未触发"布偶猫 5 个全失败→停下问用户换品种"的分支。**

扣费与剩余（`video` 命令输出的 `final_unit_deduction`/剩余单位行）：

| 宠物 | 动作 | deduction | 单位说明 |
|---|---|---|---|
| ragdoll | stand | 3 | 76 units left |
| ragdoll | walk | 3 | 73 units left |
| ragdoll | sleep | 3 | 70 units left |
| ragdoll | lick_paw | 3 | 67 units left |
| ragdoll | act_cute | 3 | 64 units left |
| gold | stand | 3 | 61 units left |
| gold | walk | 3 | 58 units left |
| gold | sleep | 3 | 55 units left |
| gold | lick_paw | 3 | 52 units left |
| gold | act_cute | 3 | 49 units left |
| corgi | stand | 3 | 46 units left |
| corgi | walk | 3 | 43 units left |
| corgi | sleep | 3 | 40 units left |
| corgi | lick_paw | 3 | 37 units left |
| corgi | act_cute | 3 | 34 units left |

每条 `qa` 的原始 JSON（`pass` 全为 `true`，格式全部 960x960 / 24fps / 121 帧）：

```json
{"pet": "ragdoll", "action": "stand", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 46.03, "worst_step": 39.58, "blob_core_first": 43, "blob_core_last": 27}
{"pet": "ragdoll", "action": "walk", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 33.5, "worst_step": 31.94, "blob_core_first": 25, "blob_core_last": 103}
{"pet": "ragdoll", "action": "sleep", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 48.98, "worst_step": 45.46, "blob_core_first": 1, "blob_core_last": 0}
{"pet": "ragdoll", "action": "lick_paw", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 46.28, "worst_step": 29.08, "blob_core_first": 41, "blob_core_last": 40}
{"pet": "ragdoll", "action": "act_cute", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 45.48, "worst_step": 32.21, "blob_core_first": 46, "blob_core_last": 28}
{"pet": "gold", "action": "stand", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 45.72, "worst_step": 39.47, "blob_core_first": 135, "blob_core_last": 138}
{"pet": "gold", "action": "walk", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 34.46, "worst_step": 31.1, "blob_core_first": 54, "blob_core_last": 50}
{"pet": "gold", "action": "sleep", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 48.61, "worst_step": 42.07, "blob_core_first": 0, "blob_core_last": 0}
{"pet": "gold", "action": "lick_paw", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 44.23, "worst_step": 28.58, "blob_core_first": 134, "blob_core_last": 126}
{"pet": "gold", "action": "act_cute", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 44.68, "worst_step": 31.73, "blob_core_first": 139, "blob_core_last": 123}
{"pet": "corgi", "action": "stand", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 46.37, "worst_step": 38.21, "blob_core_first": 16, "blob_core_last": 13}
{"pet": "corgi", "action": "walk", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 46.53, "worst_step": 31.87, "blob_core_first": 0, "blob_core_last": 0}
{"pet": "corgi", "action": "sleep", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 48.47, "worst_step": 44.55, "blob_core_first": 0, "blob_core_last": 0}
{"pet": "corgi", "action": "lick_paw", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 45.33, "worst_step": 28.48, "blob_core_first": 22, "blob_core_last": 15}
{"pet": "corgi", "action": "act_cute", "pass": true, "format": {"width": 960, "height": 960, "fps": "24/1", "frames": 121}, "seam": 45.1, "worst_step": 25.63, "blob_core_first": 18, "blob_core_last": 5}
```

收尾 `balance`：视频 34/100（online），图像 832/1000（online，未变，因为没有补拍姿态图）。
本次任务实际花费：**视频 45 单位（15 条 × 3）、图像 0 单位**。

## Step 8：抽查（肉眼）结论

逐张查看 `work\<pet>-midframes.png`（每个动作第 60 帧，5 动作横排）：

- **ragdoll**（`C:\Users\Administrator\code\aipet\tools\petgen\work\ragdoll-midframes.png`）：
  5 张里是同一只猫——奶白色身体、深棕色重点色的脸/耳/尾、蓝眼睛，体型和花纹一致；
  stand/walk/sleep/lick_paw/act_cute 的姿态都能对应各自的名字（尤其 sleep 完全趴下闭眼，
  lick_paw 低头对着前爪，act_cute 抬起一只前爪）；背景 5 帧都是纯绿色，无阴影无地面。
- **gold**（`C:\Users\Administrator\code\aipet\tools\petgen\work\gold-midframes.png`）：
  5 张是同一只金毛——均匀金黄色毛、垂耳、体型一致；stand 站立、walk 迈步、sleep 趴地闭眼、
  lick_paw 低头对着前爪、act_cute 站立歪头，动作与名字对应；背景 5 帧纯绿。
- **corgi**（`C:\Users\Administrator\code\aipet\tools\petgen\work\corgi-midframes.png`）：
  5 张是同一只柯基——橘白相间、大立耳、短腿，花纹一致；stand/walk/sleep/lick_paw/act_cute
  动作分别对应站立、迈步、趴卧、低头舔爪、抬头歪耳，与名字相符；背景 5 帧纯绿。

三只宠物均未观察到"明显不是同一只"或"动作对不上名字"的情况，Step 7 全部 15 条一次通过、
未触发 Step 8 的重做规则。

## 单位与余额小结

| 资源包 | 起始 | 结束 | 本任务消耗 |
|---|---|---|---|
| 视频（试用-视频生成-100-5并发-1个月） | 79/100 | 34/100 | 45 |
| 图像（试用-图像生成-1000-9并发-1个月） | 832/1000 | 832/1000 | 0 |

## Git LFS 与提交

- `.gitattributes` 单独先提交（commit `2becd71` "chore: track built-in pet media with Git LFS"），
  再打包素材、改 `pubspec.yaml`、写本节记录后一并提交
  （commit `a59aeb8` "feat(aipet): built-in golden retriever, corgi and ragdoll (5 actions each)"，
  26 files changed）。
- `git lfs ls-files` 实测 **18 行**（15 个 `.mp4` + 3 个 `cover.png`），与预期一致；抽查
  `builtin-gold/stand.mp4` 在 git 对象里是 LFS 指针（`version https://git-lfs.github.com/spec/v1`
  + `oid sha256:...` + `size 1766550`），磁盘上文件实际大小同样是 1766550 字节，指针生效正确。
- 关注点：`tools/petgen/work/`（含 `qa-*`、`*-midframes.png` 等中间产物）和 `.venv/` 均未加入
  `git add`，未提交进仓库；`git status` 在提交后为空，工作区干净。

# Task 15 烟测

记录时间：2026-09-11（第一轮）/ 2026-09-11（fix round 1，runner 修复后重跑）。环境同上
（Flutter 3.47.2、Windows 11、屏幕缩放 150%）。`flutter build windows --release` 产物
`apps\aipet\build\windows\x64\runner\Release\aipet.exe`。

**第一轮的发现**：全新 APPDATA（无当前宠物）启动后，`aipet pet` 窗口的 `IsWindowVisible()`
一直是 `true`（尽管内容全透明、不影响肉眼观感）。根因是 `windows/runner/flutter_window.cpp`
未改动的 Flutter 模板逻辑 `SetNextFrameCallback([&]() { this->Show(); })`——首帧渲染完成后无
条件调用原生 `Show()`，压过了 Dart 侧 `window_manager` 的 `hide()`。控制者裁定：这必须修，
不能接受——因为一个 Win32 认为"可见、置顶、无边框"的透明窗口仍然会接鼠标点击，首次启动会在
桌面上留一个 360×360 的死区。修复方式见 Fix round 1。以下先记录 fix round 1 之后的完整烟测
结果（即最终状态），第一轮的原始记录见本节末尾的「第一轮记录（供参考）」。

## Fix round 1 之后：烟测 1（全新 APPDATA，应只出现主窗口，关掉后进程退出）

命令（合并成一次 PowerShell 调用，本记录为便于阅读把变量输出拆开展示，实际执行顺序与简报一致）：

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
$fresh = Join-Path $env:TEMP "aipet-smoke-$(Get-Random)"
New-Item -ItemType Directory $fresh | Out-Null
$env:APPDATA = $fresh
Start-Process .\build\windows\x64\runner\Release\aipet.exe
Start-Sleep -Seconds 5
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1 -CloseTitle aipet
Start-Sleep -Seconds 3
@(Get-Process aipet -ErrorAction SilentlyContinue | Where-Object { $_.Threads.Count -gt 0 }).Count
@(Get-Process aipet -ErrorAction SilentlyContinue).Count
```

`windows.ps1`（关闭前）：

```
Title       Visible   W    H Rect
-----       -------   -    - ----
aipet pet     False 540  540 15,15,555,555
aipet          True 630 1110 965,209,1595,1319
MSCTFIME UI   False   0    0 0,0,0,0
Default IME   False   0    0 0,0,0,0
```

`windows.ps1 -CloseTitle aipet`：

```
Title       Visible   W    H Rect
-----       -------   -    - ----
aipet pet     False 540  540 15,15,555,555
aipet          True 630 1110 965,209,1595,1319
MSCTFIME UI   False   0    0 0,0,0,0
Default IME   False   0    0 0,0,0,0

posted WM_CLOSE to 'aipet'
```

3 秒后计数：

```
存活进程数（Threads.Count -gt 0）：0
原始进程数（仅供参考）：7
```

**与 Expected 的对照：**

- 主窗口 `aipet` 可见、物理像素 630×1110（= 420×740 逻辑像素 × 150% 缩放）—— **符合**。
- `aipet pet`（宠物窗）在没有当前宠物时**不可见**（`Visible=False`）—— **符合**（runner 修复
  生效）。
- 关闭主窗口后进程数为 0（`Threads.Count -gt 0` 过滤的存活口径）—— **符合**。
- 原始进程数（7）比存活数高，是历史多次调试/重建过程中遗留的 0-线程/0-句柄残余 pid（与 Task 1
  结果文件 C9 记录的现象一致，`Stop-Process -Force`/`taskkill` 对纯残余 pid 无效），重跑前已确认
  当时没有存活（`Threads.Count -gt 0`）的旧进程，不影响本次判定。

## Fix round 1 之后：烟测 2（预置 settings.json，应只出现宠物，关掉后进程退出）

按 fix round 1 要求，先轮询等待金毛 `stand` 的首次矩化完成（`matte-cache\v1` 下出现 `.aipmat`
且 `.staging` 下没有残留 `*.tmp`），再发 `WM_CLOSE`，并且用 250ms 间隔轮询、记录从 `WM_CLOSE`
到「存活进程数变 0」之间的耗时。命令（同一次 PowerShell 调用）：

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
$seeded = Join-Path $env:TEMP "aipet-smoke-$(Get-Random)"
New-Item -ItemType Directory "$seeded\com.aipet\aipet" -Force | Out-Null
'{"schema":1,"currentPetId":"builtin-gold","adoptedPetIds":["builtin-gold"]}' | Set-Content -Encoding ascii "$seeded\com.aipet\aipet\settings.json"
$env:APPDATA = $seeded
Start-Process .\build\windows\x64\runner\Release\aipet.exe
$cacheDir = "$seeded\com.aipet\aipet\matte-cache\v1"
$stagingDir = "$cacheDir\.staging"
# poll every 250 ms up to 30 s for a *.aipmat with no *.tmp left in .staging
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1
Get-ChildItem $cacheDir -Filter *.aipmat | Select-Object Name, Length
# poll every 250 ms up to 10 s from WM_CLOSE for live count == 0, record elapsed ms
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1 -CloseTitle "aipet pet"
Start-Sleep -Seconds 3
@(Get-Process aipet -ErrorAction SilentlyContinue | Where-Object { $_.Threads.Count -gt 0 }).Count
@(Get-Process aipet -ErrorAction SilentlyContinue).Count
Remove-Item Env:APPDATA
```

矩化就绪轮询：

```
matting ready: True (waited 3957 ms)
```

`windows.ps1`（关闭前）：

```
Title       Visible   W   H Rect
-----       -------   -   - ----
aipet pet      True 540 540 15,15,555,555
MSCTFIME UI   False   0   0 0,0,0,0
Default IME   False   0   0 0,0,0,0
```

缓存目录列表（`matte-cache\v1\*.aipmat`）：

```
Name                                         Length
----                                         ------
3e685ebed97fd730ebbb3b74ca785ef9-p1.aipmat 53686843
```

`windows.ps1 -CloseTitle "aipet pet"`：

```
Title       Visible   W   H Rect
-----       -------   -   - ----
aipet pet      True 540 540 15,15,555,555
MSCTFIME UI   False   0   0 0,0,0,0
Default IME   False   0   0 0,0,0,0

posted WM_CLOSE to 'aipet pet'
```

从 `WM_CLOSE` 到「存活进程数（`Threads.Count -gt 0`）变 0」的耗时（250ms 轮询，最多 10s）：
**3382 ms**。此后再等 3 秒复查，存活进程数仍为 0（原始进程数 8，同样是历史残余 pid）。

**与 Expected 的对照：**

- `aipet pet` 可见、且列表里没有 `aipet` 主窗口 —— **符合**（只有 `aipet pet` 一个有标题的顶层
  窗口）。
- 缓存目录里恰好 1 个 `.aipmat`（金毛 `stand` 动作的矩化结果，53686843 字节）—— **符合**。
- 向宠物窗发 `WM_CLOSE` 后（等待矩化真正完成再关闭、且用精确耗时测量代替固定 3 秒断言）存活
  进程数收敛到 0，耗时 3382 ms —— **符合**（比一次性的固定 3 秒判据略慢一点点，这也解释了
  fix round 1 之前那次烟测 2 偶尔在 3 秒整测到存活数为 1 的现象：不是卡死，是这条退出路径
  ——真播放中的宠物需要走 `AlphaVideoController.dispose()` 等清理——本来就比"无宠物瞬间退出"
  慢，量级在 3.0–3.4 秒左右）。

## Fix round 1 part 2：退出耗时诊断（A9 的 3 秒预算）

Fix round 1 的烟测 2 测得 WM_CLOSE → 存活进程数为 0 耗时 3382 ms，超过 A9 的 3 秒预算。按控制者
要求，先用临时计时代码测量耗时具体花在哪一步，再决定是否要改代码——不能盲目改。

### 测量方法（临时代码，未提交）

在 `quit()`（`pet_window_app.dart`）里加了一个 `Stopwatch` 和四个时间戳标记（`enter` /
`player.dispose done` / `tray destroy done` / `before windowManager.destroy`），同步写入
`%TEMP%\aipet-quit-timing.txt`。复用同一个预置了金毛设置的 APPDATA 目录（先跑一次让
`stand.aipmat` 缓存生效，进入"稳态"），随后做 3 次独立测量：每次单独一个 PowerShell 调用，
启动 → 等 `aipet pet` 出现 → 再等 3 秒 → 发 `WM_CLOSE` 并记录外部耗时（100ms 轮询直到存活进程数
为 0）→ 打印计时文件。

### 测量结果（3 次，稳态，金毛 `stand`）

| 次数 | 外部耗时（WM_CLOSE → 存活数为 0） | `enter`→`player.dispose done` | →`tray destroy done` | →`before windowManager.destroy` | `windowManager.destroy()` 及之后（差值） |
|---|---|---|---|---|---|
| 1 | 3232 ms | +6 ms | +10 ms | +14 ms | ≈ 3218 ms |
| 2 | 3297 ms | +5 ms | +9 ms | +13 ms | ≈ 3284 ms |
| 3 | 3185 ms | +5 ms | +10 ms | +13 ms | ≈ 3172 ms |

三次的 Dart 侧总耗时（`enter` 到 `before windowManager.destroy`）都在 **13–14 ms**，而外部总耗时
在 **3185–3297 ms**——超过 **99.5%** 的时间都发生在 `await windowManager.destroy()` 这一句调用
本身（等它的 Future 完成）以及/或者它返回之后的引擎关闭、插件析构、进程退出阶段，不在
`player.dispose()` / `trayManager.destroy()` 这两步串行 `await` 里。

### 诊断结论

审阅者提出的候选修复（`player.dispose()` 和 `trayManager.destroy()` 用 `Future.wait` 并发跑）
即使完全生效，最多也只能省下这两步之间的几毫秒（9–10 ms 量级），相对 3.2 秒的总耗时可以忽略
不计——它们不是耗时主因，改了也达不到 ≤2.5 秒的目标。真正的耗时在
`windowManager.destroy()`（原生 `window_manager` 插件的销毁实现）及其之后的引擎收尾 / 进程退出，
这部分代码不属于本任务 Dart 层，按控制者给出的分支规则（"如果 post-destroy 占主导：STOP，不要
在没有裁决的情况下改原生插件或 runner"）——**这里 STOP，不做 Dart 侧的并发改动（因为它救不了
真正的耗时来源），也没有改 `window_manager` 插件或 runner 的销毁逻辑**，如实汇报数字，交给控制者
裁决是否要为此另开任务去看 `window_manager` 插件内部或者换一种退出方式（比如不经过
`window_manager.destroy()`、直接调用更底层的进程退出 API）。

### 本轮改动 vs 未改动

- **改了**：`apps/aipet/windows/runner/flutter_window.cpp` 里 `ForceRedraw()` 上方的注释
  （review Minor 2）——原注释还在说"确保窗口显示"，但窗口现在默认隐藏、可见性完全交给 Dart，
  注释已更新为准确描述（保留一次待渲染的帧，让引擎即使窗口隐藏也能渲染、从而触发
  `SetNextFrameCallback`）。`ForceRedraw()` 调用本身未变。
- **没改**：`quit()` 的实现——诊断显示 Dart 侧三步（`player.dispose` / `trayManager.destroy` /
  两者之间的调度开销）总共只占 13–14 ms，不是瓶颈，所以没有做 `Future.wait` 并发化或任何其他
  quit() 内部改动（那样做不会解决真正的耗时来源，只会遮盖诊断结果）。
- 计时代码（`Stopwatch`、`aipet-quit-timing.txt` 写入）已完全移除，`pet_window_app.dart` 与
  `fix round 1` 提交（`38d8ce4`）时的内容逐字一致（用 `git diff` 核实过没有残留）。

### 最终重跑（非插桩构建）：烟测 2

用移除计时代码后重新构建的 `aipet.exe` 又跑了一遍完整的烟测 2（新的随机 APPDATA 目录，
先轮询等待金毛 `stand` 矩化完成再关闭）：

```
matting ready: True
```

`windows.ps1`（关闭前）：

```
Title       Visible   W   H Rect
-----       -------   -   - ----
aipet pet      True 540 540 15,15,555,555
MSCTFIME UI   False   0   0 0,0,0,0
Default IME   False   0   0 0,0,0,0
```

缓存目录列表：

```
Name                                         Length
----                                         ------
3e685ebed97fd730ebbb3b74ca785ef9-p1.aipmat 53686843
```

`windows.ps1 -CloseTitle "aipet pet"`：

```
Title       Visible   W   H Rect
-----       -------   -   - ----
aipet pet      True 540 540 15,15,555,555
MSCTFIME UI   False   0   0 0,0,0,0
Default IME   False   0   0 0,0,0,0

posted WM_CLOSE to 'aipet pet'
```

从 `WM_CLOSE` 到存活进程数为 0：**3509 ms**（100ms 轮询）；此后再等 3 秒复查仍为 0（原始进程数
11，历史残余 pid，不影响判定）。这个数字与上面 3 次诊断测量（3185–3297 ms）同一量级，
进一步印证退出耗时是这条路径本身稳定的特征，不是偶发抖动。

### 退出耗时对照表（本轮修复前 / 本轮结论后——注意本轮未对 quit() 做代码改动）

| | 外部耗时（WM_CLOSE → 存活数 0） | 说明 |
|---|---|---|
| Fix round 1 烟测 2（改 runner 之后，未诊断） | 3382 ms | 触发本轮诊断的原始读数 |
| 诊断测量 #1（稳态，插桩版） | 3232 ms | Dart 侧仅 14 ms |
| 诊断测量 #2（稳态，插桩版） | 3297 ms | Dart 侧仅 13 ms |
| 诊断测量 #3（稳态，插桩版） | 3185 ms | Dart 侧仅 13 ms |
| 最终重跑（移除插桩后的正式构建） | 3509 ms | 与上面同一量级，未改 quit() 代码 |

**结论：退出耗时稳定在约 3.2–3.5 秒，未达到 ≤2.5 秒的目标；根因在 `windowManager.destroy()`
本身及其后的引擎/进程收尾，不在本任务 Dart 代码里，按裁决规则本轮不做进一步改动，等待控制者
决定是否要为 `window_manager` 插件或替代退出方式单开任务。**

## 第一轮记录（供参考，问题已在 fix round 1 修复）

烟测 1（关闭前 `windows.ps1`）：

```
Title       Visible   W    H Rect
-----       -------   -    - ----
aipet pet      True 540  540 15,15,555,555
aipet          True 630 1110 965,209,1595,1319
MSCTFIME UI   False   0    0 0,0,0,0
Default IME   False   0    0 0,0,0,0
```

`aipet pet` 当时是 `Visible=True`（应为 `False`），其余（`aipet` 主窗口尺寸、关闭后进程数为 0）
与 fix round 1 后一致。诊断细节、两次未成功的纯 Dart 侧尝试记录在 `task-15-report.md` 的
「Fix round 1」一节。

# Task 16 全量回归（2026-09-11）

分支 `feat/aipet-main-window`，HEAD `f478cf0`（Task 15 完成后）。alpha_video 的集成测试逐个文件跑——四个文件一次性跑在本机偶发 "Unable to start the app on the device"（Task 9 记录），与代码无关。

| 组 | 命令 | 结果 |
|---|---|---|
| aipet 静态检查 | `flutter analyze` | No issues found! |
| aipet 单元/组件测试 | `flutter test` | 97/97 通过 |
| pet_shell | `flutter test` | 26/26 通过 |
| alpha_video 集成测试 | `flutter test integration_test\<file>.dart -d windows` ×4 | plugin_test 1、texture_test 2、playback_test 3、prepare_async_test 3，共 9/9 通过 |
| 原生 | `cmake --build native\build --config Debug` + `ctest -C Debug` | 56/56 通过 |
| tools/petgen | `python -m pytest -q` | 52/52 通过 |

# Task 16 真机验收（2026-09-12，用户同意由控制器操作鼠标）

构建：release，`f478cf0` 的代码（与当时 HEAD 一致）。全新 APPDATA 放在会话临时目录。屏幕 2560×1600，缩放 150%，
所有坐标是物理像素；每次点击前 `click.ps1 -Expect` 核对落点像素（±6），不符则不点。

| # | 结果 | 证据 |
|---|---|---|
| A1 全新启动 | **通过** | `windows.ps1`：`aipet` 可见 630×1110 @ (965,209)，`aipet pet` 不可见；截图里只有主窗口，卡片依次为柯基、金毛、布偶猫 |
| A2 带金毛回家 | **通过** | 点 (1330,835)，核对像素 240,138,60（主强调色）。卡片立即变「正在准备…」；相隔 300 ms 的两张按钮区截图有 221 个像素不同（转圈在动，主窗口没卡）；3 秒后宠物窗可见，金毛出现在桌面、背景透明；卡片变「陪伴中」，主窗口仍开着 |
| A3 分类 | **通过** | 点「猫猫」只剩布偶猫；点「其他小宠」显示「这里还没有小伙伴」 |
| A4 前半：换成布偶猫 | **通过** | 在「猫猫」筛选下点布偶猫「带它回家」（「全部」里该按钮在折叠线以下，脚本不支持滚轮；同一卡片、同一领养路径）。8 秒内 56 帧宠物窗区域对比空桌面：前 9 帧约 6.37 万像素（金毛），之后约 5.1 万（布偶猫），最小 50659——全程没有空白帧；布偶猫卡片「陪伴中」 |
| A4 后半 ~ A10 | 待续 | 做到这里时桌面被使用（主窗口被最小化、宠物被拖走，另一个应用在前台），`click.ps1` 核对像素不符、没有点击，验收暂停。最终审查的修复（`9c921c9..923183f`）完成后在新构建上继续 |

# Task 16 真机验收·续（2026-09-13，画质优化后的新构建）

构建：release，HEAD `8ddf9b3`（画质优化计划 B 全部完成；`app.so`、`alpha_video_plugin.dll` 为 09-12 23:07 重建）。
全新 APPDATA（会话临时目录），预置 A4 前半结束时的状态：`{"schema":1,"currentPetId":"builtin-ragdoll","adoptedPetIds":["builtin-gold","builtin-ragdoll"]}`。

| # | 结果 | 证据 |
|---|---|---|
| 启动（A7 路径） | **通过** | 只出现 `aipet pet`（540×540 @ 1993,936），主窗口不打开；布偶猫 stand 首次抠像 4.6 s 完成，缓存 `ae0eb673…-p2.aipmat` 68 MB（键 = 新素材 sha256 前 32 位，960 px） |
| A5 菜单部分 | **通过** | 在布偶猫身上右键（点前核对像素 204,180,164）：菜单依次为 待机 ✓ / 走路 / 睡觉 / 舔爪子 / 卖萌 / 打开宠物库 / 退出 |
| A6 布偶猫 | **不通过** | 宠物窗矩形内强偏绿（G > R+40 且 G > B+40）**67** 个，放宽到 +15 为 2008 个；放大截图可见整只猫一圈细绿边（背、尾、腿） |
| 其余 | 暂停 | 右键菜单弹出后的截图里微信到了前台、输入框有正在输入的文字——用户在用电脑，停止一切鼠标键盘操作（菜单留在原处，未按 Esc，免得按键落进微信） |

### A6 根因（离线复现，未改代码）

按 `pet_matte` 的顺序（键控 → 去溢色 → 预乘 → 叠到截图里的桌面底色 24,24,24）用 Python 复刻，stand 第 30 帧：

| | 旧去溢色（全部压到 (R+B)/2） | 计划 B Task 1 的"只压边缘"（现行） | 提议：`G = min(G, max(R,B))` |
|---|---|---|---|
| 布偶猫旧素材 偏绿 +15 | 0 | **5534** | 0 |
| 布偶猫新素材 偏绿 +15 | 0 | **6197** | 0 |
| 金毛新素材 偏绿 +15 | 0 | **2579** | 0 |
| 柯基新素材 偏绿 +15 | 0 | **4851** | 0 |
| 不透明毛色被改动的比例 | 3.9–10.7% | 0% | 0.5–2.6%（金毛 0.5%，平均 ΔG 0.04） |

- 换素材几乎不影响结果（5534 → 6197），换去溢色公式从 0 变成几千——**原因是计划 B Task 1 的去溢色公式，不是新素材**。
- 公式的错在设计（spec 2026-09-12 ①）：它按 `(1 − a/255)` 比例去溢色，等于把键控 alpha 当成真实覆盖率。但键控的过渡带很陡（innerT 0.28 → outerT 0.45），
  含大量绿幕的毛边像素已经拿到很高甚至 255 的 alpha，于是绿色几乎没被去掉（旧素材里 alpha = 255 且绿色超出 > 30 的像素就有 1285 个，新公式一个都不动）。
- 复刻里 +40 为 0、真机为 67：真机截的是任意一帧，又经过纹理采样与合成，差距留到修复后在真机上一起复查；方向不受影响。
- 提议的"最大值限制"去溢色是常见做法：绿色只要超过 R、B 中较大者就压到该值——绿溢色全部去掉，而金黄毛色（R ≥ G）天然不受影响，
  比旧公式改动的毛色还少。按规则不在本任务里改代码，交用户决定是否另开修复任务。

# Task 16 真机验收·完成（2026-09-28，用户同意由控制器操作鼠标，全程约 46 分钟）

构建：release，HEAD `a7164b8`（`data/app.so` 20:00 重建）。全新 APPDATA（原目录移走后还原）。
屏幕 2560x1600、缩放 150%，坐标全是物理像素；每次点击前 `click.ps1 -Expect` 核对落点像素。

| # | 结果 | 证据 |
|---|---|---|
| A1 全新启动 | **通过** | 只有 `aipet` 可见（630x1110 @ 965,209）；`aipet pet`、`aipet hud` 都已创建但隐藏——面板引擎提前创建的改动生效 |
| A2 带金毛回家 | **通过** | 卡片立即「正在准备…」，相隔 300 ms 的两张截图在转圈区域有 189 个像素不同（主窗口没卡）；随后宠物出现在桌面、背景透明，卡片变「陪伴中」，主窗口仍开着 |
| A3 分类 | **通过** | 猫猫只剩布偶猫；其他小宠显示「这里还没有小伙伴」 |
| A4 换宠物（双向） | **通过** | 领养布偶猫、再换回金毛，各连拍 40 帧 / 8 秒对比空桌面：最小 79136 / 78286 个非背景像素，**全程无空白帧**；两只都在「我的」 |
| A5 右键菜单 | **通过（有缺陷）** | 7 个动作齐全、当前项打勾。但**菜单被裁到宠物窗高度**（360 逻辑像素），`打开宠物库` / `退出` 要滚动才看得到——从 5 个动作加到 7 个导致 |
| A6 绿边（三只） | **通过** | 强偏绿（G>R+40 且 G>B+40）：金毛 **0**、布偶猫 **0**（去掉窗口边框 4 px，边框外那 5 个在 x=0 列，是编辑器语法高亮透出来的）、柯基 **0**。09-13 时布偶猫是 67 |
| A7 重启 | **通过** | 3.8 秒出现宠物窗，**宠物库完全不打开** |
| A8 托盘打开宠物库 | **通过** | 托盘图标在溢出区（就是 `tray.ico` 那个橙色圆点），单击后宠物库打开 |
| A9 退出 | **通过（有残留）** | 从「退出程序」：两个窗口 **0.44 秒**消失、最后一个活线程 **2.92 秒**结束；托盘溢出区再无橙色圆点（无幽灵图标）。残留：一个 **0 线程、0.4 MB 的 aipet 进程对象**（16:06:59 第一次退出时产生），`Stop-Process` 也清不掉——与待办第 9 条同源 |
| A10 稳态 60 秒 | **记录** | CPU **0.31%**（16 核全核）/ 约 4.9% 单核，与 Plan A 的 0.25% 一致；工作集 **316 MB**、私有 420 MB、93 线程。HANDOFF 里 164 MB 是单引擎 720px 的 pet_shell，口径不同 |

补充观测：**抠像缓存 9 段片子就占 765 MB**（约 85 MB/段）。三只宠物 21 段全部播过一遍会到约 1.8 GB，
待办第 17 条（缓存 LRU）的优先级应该提高。

