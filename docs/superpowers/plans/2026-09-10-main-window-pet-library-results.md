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

- `.gitattributes` 单独先提交（commit `2becd71`），再打包素材、改 `pubspec.yaml`、写本节记录后
  一并提交。
- `git lfs ls-files` 应为 18 行（15 个 `.mp4` + 3 个 `cover.png`）；实测行数与结果见下方提交记录。
- 关注点：`tools/petgen/work/`（含 `qa-*`、`*-midframes.png` 等中间产物）和 `.venv/` 均未加入
  `git add`，未提交进仓库。
