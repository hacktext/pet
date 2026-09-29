# aipet 交接文档

> 新会话请先读这份文件。日期：2026-09-28（四个子项目代码完成、真机验收已跑完；验收发现金毛不是正脸，待用户定夺）

## 0. 当前进行中（2026-09-28 会话切换点）——新会话先看这里

分支 `feat/aipet-main-window`（未合入 master）。四份计划的执行账本（本地、git 忽略，**所有裁定都在里面**）在
`.superpowers/sdd/` 下：`2026-09-10-main-window-pet-library`、`2026-09-12-pet-image-quality`、
`2026-09-19-front-facing-pets`、`2026-09-19-desktop-interaction`。每份计划都有同名的 `-results.md` 结果文件，
记着裁定、数据和验收清单——**要细节先看结果文件，别翻聊天记录**。

**代码层面四个子项目都已完成并通过审查**：

- **A 主窗口 + 宠物库**（`docs/superpowers/plans/2026-09-10-main-window-pet-library.md`）：系统宠物广场、我的、
  领养 / 切换、托盘、右键动作菜单。Task 1–15 完成，最终全分支审查的 4 个问题已修。
- **B 画质优化**（`...2026-09-12-pet-image-quality.md`）：抠像缓存 960 / `p3`、最大值限制去溢色、petgen `finish` 成片处理。全部完成。
- **C 正脸素材**（`...2026-09-19-front-facing-pets.md`）：三只宠物各 7 个动作（待机、走路、睡觉、喂食、玩耍、舔爪子、卖萌），
  **但金毛的正脸没做成，见下面第 1 条**；
  21 段成片全部通过 `qa`，已打包提交（Git LFS，`624d5ae`）。动作幅度 23–29（原侧身待机只有 4–11，竞品 36.7）。
- **E 桌面互动**（`...2026-09-19-desktop-interaction.md`）：悬停状态面板（独立引擎）、轻度养成数值、走路横穿屏幕 + 自动走动。
  Task 1–12 完成；最终全分支审查（opus）的 3 个重要 + 11 个次要已修（`b531727`、`5ec83d3`、`2f13525`），
  针对性复审又找出 1 个重要（退出时藏起来的面板会自己回来）+ 2 个次要 + 6 处测试缺口，也已修（`4033900`、`68b08cb`）；最后一次确认审查判 Clean，收尾提交 `f38cbf0`。

回归（2026-09-29）：`flutter analyze` 零问题、`flutter test` 210、petgen `pytest` 96、原生 `ctest` 59、release 构建成功。

**真机验收已完成（2026-09-28，用户同意后由控制器操作鼠标，约 46 分钟）**，结论写在两份结果文件里。
计划 A 的 A1–A10 全部通过（A6 绿边三只都是 0，09-13 那次布偶猫是 67），桌面互动 16 项里 13 项通过、
2 项未测（面板引擎失败降级需改参数模拟；混合 DPI 需第二块显示器）、1 项部分。
**最关键的一条守住了**：面板弹出和走路期间（窗口每秒被移约 30 次）前台窗口始终不变，焦点一次都没被抢；
拖动期间面板确实会消失（`SC_MOVE` 模态循环里隐藏消息能送达），这是静态审查判不了的一条。

**验收发现、尚未处理的问题**（按轻重）：

1. **金毛不是正脸**——`stand` / `feed` / `play` / `lick_paw` 四段都是侧身，只有 `act_cute` 是正脸；柯基、布偶猫全对。
   根因是金毛的 `work/gold/v3/ref-front.png` 沿用了 9/19 spike 阶段（正脸提示词落地之前）的那张，本身就是侧身。
   **用户提的第 1 条需求对金毛没有兑现。** 质检的每一项都不看朝向，所以一路放行。
   修复要 8 图片单位 + 20 视频单位（余额视频 23 / 图片 752，几乎用光视频额度），**需用户点头**。
   细节见 `docs/superpowers/plans/2026-09-19-front-facing-pets-results.md` 末节。
2. ~~宠物右键菜单被裁~~ **已修**（`f905338`）：改成两级菜单并抽出 `pet_menu.dart`。
   注意 `CheckedPopupMenuItem` 是 `ListTile`、单行最小 56 px，`height` 压不住——第二级必须用 `PopupMenuItem` 自己排版。
3. ~~状态文字与百分比对不上~~ **已修**（`f905338`）：`statusText` 改按面板显示的取整值判阈值。
4. **抠像缓存 9 段片子就占 765 MB**（约 85 MB/段），21 段全播过一遍约 1.8 GB——待办第 17 条（缓存 LRU）该提优先级。
5. 一个 **0 线程的 aipet 进程对象**在第一次退出后长期残留，`Stop-Process` 清不掉（与待办第 9 条同源）。

**下一步**：第 1 条（金毛正脸）用户定的是**先不做**，额度留着；第 2、3 条已修（`f905338`，flutter test 202 → 210）。
剩下的是走 `superpowers:finishing-a-development-branch` 问用户怎么合入。

**可灵额度**：视频 23 单位、图片 752（2026-09-23 用户续购 100 视频单位后，出片用掉 80）。不够就停下问用户，不要降级、不要自己买。

**始终适用**：用户在用这台电脑——不启动 aipet.exe、不发鼠标键盘输入，除非用户明确同意；可灵密钥只从
`secrets\kling.env` 读、不打印；回复用中文。

做一款 Windows 桌面宠物应用：用户付费后上传自己宠物的照片，云端生成该宠物的
真实感动作视频，在桌面上以透明窗口常驻陪伴，可交互，带养成数值。

对标产品「宠伴赛博陪伴」已被完整逆向，结论见
`docs/superpowers/specs/2026-09-02-desktop-pet-design.md` 第 2 节（那些是实测事实，不是推测）。

---

## 1. 现在能跑什么

**产品本体 `apps/aipet` 已经能用**（在 `feat/aipet-main-window` 上，见第 0 节）：
宠物库领养 / 切换、桌面常驻的透明宠物窗、托盘、右键动作菜单、悬停状态面板、轻度养成数值、
走路横穿屏幕 + 自动走动；三只内置宠物各 7 个动作。回归：flutter 210、pytest 96、ctest 59。

**Plan A（渲染内核）已完成并通过多轮审查**，30 个提交已合入 `master`，
55 个测试全绿（49 原生 GoogleTest + 6 Flutter 集成测试）。下面这张分层表讲的是内核。

```
用户照片  ──◐──►  绿幕/纯底动作视频  ──✅──►  桌面上会动的狗
          spike 已用真实调用跑通       Plan A 已跑通
          产品代码还没写
```

已实现的分层：

| 目录 | 职责 |
|---|---|
| `native/pcmat` | `.aipmat` 容器：128B 头 + 48B/帧索引 + LZ4 + JSON 清单，UTF-16 路径 |
| `native/matte_core` | 纯像素运算：YCbCr 色度键控、去溢色、预乘 alpha、包围盒、区域拷贝 |
| `native/mf_decode` | Media Foundation 解码 → 紧密打包 BGRA32 |
| `native/frame_source` | 裁剪展开 + BGRA→RGBA |
| `native/pet_matte` | C ABI，编排 decode→key→despill→premultiply→bounds→copy→write |
| `packages/alpha_video` | Flutter Windows 插件：通道 `aipet.alpha_video/methods`、PixelBufferTexture、推帧线程 |
| `apps/pet_shell` | 验证程序：透明置顶窗端到端跑通 |

### 实测数据（不是估算）

| 指标 | 值 |
|---|---|
| 稳态 CPU | 0.25%（全核）/ 约 4% 单核归一 |
| 内存 | 164 MB，40 秒平稳无增长 |
| 单动作磁盘 | 41.6 MB（竞品同类 92–233 MB） |
| 抠像耗时 | release 2.6 秒 / debug 9.7 秒（每动作，1440→720，121 帧） |
| 启动到首帧 | 4.6 秒 |
| 抠像质量 | 绿色残留 **0 像素**；软边过渡带占主体 2.22%，alpha 在 9–249 间平滑分布 |

外推整只宠物（10 动作）：约 400 MB 磁盘、约 1 分半首次处理。

### 怎么启动

**产品本体是 `apps/aipet`**（桌面宠物 + 宠物库），开发时这样跑：

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
cd C:\Users\Administrator\code\aipet\apps\aipet; flutter run -d windows --release
```

已构建好的 release 在 `apps\aipet\build\windows\x64\runner\Release\aipet.exe`，双击即可。
**必须 `--release`**：debug 下抠像要 9.7 秒且窗口冻住（Dart UI isolate 就在平台线程上）。
首次运行会弹出宠物库；领养一只后宠物出现在桌面，托盘图标常驻。
数据在 `%APPDATA%\com.aipet\aipet\`（`settings.json`、`stats.json`、`pets\`、`matte-cache\`）——
要从全新状态验收就把它整个移走。

`apps/pet_shell` 是渲染内核的验证程序，不是产品，只在排查抠像 / 播放问题时用：

```powershell
$env:AIPET_DEV_CLIP = "$env:APPDATA\com.petcompanion\宠伴赛博陪伴\pets\generated\0af4f2d6-ca2b-4028-80e1-e41944b8edd6\82cd8b28-f904-469e-abac-3ea9433b009f\walk-walk.mp4"
cd C:\Users\Administrator\code\aipet\apps\pet_shell; flutter run -d windows --release
```

本机有 10 个绿幕素材可换：`stand walk run sleep feed play spin lick_paw act_cute pet_head`。

跑测试：

```powershell
$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
& $cmake --build C:\Users\Administrator\code\aipet\native\build --config Debug
& "$(Split-Path $cmake)\ctest.exe" --test-dir C:\Users\Administrator\code\aipet\native\build -C Debug
```

---

## 2. 环境（这台机器的实际情况）

- **Flutter 不在 PATH**：SDK 在 `C:\Users\Administrator\code\envs\flutter`，3.47.2 stable / Dart 3.13.2
- **cmake / cl 不在 PATH**：CMake 4.1.1-msvc1 在
  `C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`，`ctest.exe` 在同目录
- 默认生成器 `Visual Studio 18 2026` 能自己找到 MSVC 工具链，不需要 vcvarsall
- ffmpeg **在** PATH
- 系统代码页 936（GBK）——见下面的坑

---

## 3. 踩过的坑（别重蹈覆辙）

这些是执行期真实付出代价换来的，新会话务必知道：

1. **MSVC + 中文注释 + 无 BOM = 静默破坏结构体布局。**
   系统代码页 936 下，MSVC 会错解 UTF-8 中文注释，曾导致 `FrameIndex` 成员列表被改，
   只因为有 `static_assert` 才暴露。项目级 `/utf-8` 已加在 `native/CMakeLists.txt`，
   插件另有一份（不同 CMake 工程不继承）。

2. **ffmpeg 8.1 的 `drawbox` 坐标表达式不支持逐帧变量 `n`/`t`**，会报
   "Undefined constant" 并静默产出空白画面。测试夹具改用 `overlay`。

3. **Flutter 通过符号链接构建插件**，`CMAKE_CURRENT_SOURCE_DIR` 指向链接路径，
   而 CMake 在 Windows 上 `REALPATH` 是词法解析、不解引用符号链接。
   必须先解析当前目录再做相对遍历。

4. **`UnregisterTexture` 是异步的。** 注销后立刻销毁纹理对象会造成 use-after-free，
   必须用带完成回调的重载并持 `shared_ptr` 保活。

5. **`sleep_for` 不可中断**，`notify_all()` 唤不醒它。定时等待必须用带谓词的
   `cv.wait_for`，否则 `dispose()` 的 `join()` 会卡住 Flutter 平台线程。

6. **Windows 路径原生是 UTF-16。** `filesystem::path::string()` 在 MSVC 上按 ANSI
   代码页转换（不是 UTF-8），`wstring(s.begin(), s.end())` 是逐字节拓宽——两者都会
   损坏非 ASCII 路径。全链路已改为 `_wfopen` + `MultiByteToWideChar(CP_UTF8, ...)`。
   缓存在 `%APPDATA%` 下，路径含用户名，这是真实可达的场景。

7. **"警告即错误"从来不是真的。** `native/` 的 CMakeLists 里没有 `/W4 /WX`，
   插件侧的 `/W4 /WX` 是 PRIVATE 的、不传播到五个静态库。
   `native/frame_source/src/frame_source.cpp:35` 有一句注释错误地声称有——
   那是我在派活时写错、实现者当真了。**要么改注释，要么真的开起来**（会冒出一批警告）。

8. **键控 alpha 不是覆盖率，别拿它给去溢色打折。** `ApplyChromaKey` 的过渡带很陡（innerT 0.28 → outerT 0.45），
   含大量绿幕的毛边常被判成 alpha 255。2026-09-12 把去溢色改成按 `(1 − a/255)` 打折，桌面上每只宠物都多了一圈细绿边，
   单测全绿、要到真机截图才暴露。现在用最大值限制 `G = min(G, max(R,B))`，与 alpha 无关。
   **改抠像像素公式时，先用 Python 按 `pet_matte` 顺序复刻（键控 → 去溢色 → 预乘 → 叠到深色底）数偏绿像素，再上真机。**

9. **window_manager 在 Windows 上会抢焦点，桌面宠物不能用它移窗口 / 显示窗口。**
   `show()` 里直接调 `SetForegroundWindow`，`setPosition()` 是 `SetWindowPos(HWND_TOP)` 且没带 `SWP_NOACTIVATE`。
   走路每秒要移 30 次窗口、悬停要显示面板，用它等于每帧抢一次用户的输入焦点。
   自己用 FFI 调 `SetWindowPos`（`SWP_NOACTIVATE`，显示时再加 `SWP_SHOWWINDOW` + `HWND_TOPMOST`），
   见 `apps/aipet/lib/services/native_window.dart`。**改动任何"移动窗口 / 显示窗口"的代码前，先确认没有绕回 window_manager。**

10. **多引擎里找窗口要惰性 + 重试。** `FindWindowExW` 按标题找本进程的顶层窗口，但启动早期窗口可能还不在。
    启动时查一次、失败就永远不动窗口，而且一声不吭——这种 bug 只有真机才看得见。

11. **`testWidgets` 是在测试体结束时检查残留定时器的，比 `tearDown` 早。**
    所以"保证清理"不能写进 `tearDown`（那样定时器检查先失败），要用 try/finally 包住测试体本身。
    在此之前，任何一个 `expect` 失败都会跳过 dispose，残留定时器再去把**下一个**用例弄挂，真正的第一处失败被盖住。

12. **`await` 前后要重新确认状态，尤其是跨平台通道的往返。** 显示面板前要先问一次窗口位置（一次平台往返），
    这期间用户可能已经开始拖动：结果是"先发 hide 后发 show"，面板留在屏幕上、而程序以为它是隐藏的，从此不再更新也不再收起。

---

## 4. 下一步：M2 生成管线（当前卡点）

> **2026-09-12 更新：需求已拆成四个子项目。**「默认可选系统宠物、付费上传自己宠物照片、
> 服务器做好视频后下发」这个页面需求拆为：
> - **A 主窗口 + 宠物库** —— **已完成**（`apps/aipet`，见第 1 节）：系统宠物广场、我的、领养/切换、
>   托盘、右键动作菜单；「立即定制」目前只弹「即将开放，敬请期待」。
> - **B 生成服务** —— 服务器端把照片变成动作视频。`tools/petgen` 就是它的雏形：参考图生成、
>   可灵视频（kling-v3 std 5 秒，首尾同帧保证无缝循环）、抠图合成、接缝检查、打包成 `pet.json` 目录。
>   本节下面记录的 spike 结论全部适用。
> - **C 定制流程** —— 客户端上传照片、看进度、收到后下载到 `%APPDATA%\com.aipet\aipet\pets\<petId>\`
>   （`PetLibrary` 已按这个路径扫描自定义宠物）。
> - **D 账号与支付**。
>
> **发布前必做：确认可灵生成内容的商用条款**（生成的视频能否用于付费产品、是否需要署名）。

> **画质差距实测（2026-09-12，同为 960×960 的金毛 stand 第 30 帧，只统计宠物主体）：**
>
> | | 我们（kling-v3 std 直出） | 竞品「体验版：金毛」 |
> |---|---|---|
> | 码率 | 2.8 Mbps（H.264 Main） | 8.1 Mbps（Constrained Baseline，说明服务端转码过） |
> | 清晰度（平均 \|拉普拉斯\|） | 5.71 | 10.86 |
> | 平均亮度 / 95 分位 | 118.5 / 190.9 | 162.4 / 221.6 |
>
> - **暗从参考图就开始了**：`ref-stand.png` 亮度 127.9，合成绿幕后 121.0，视频 118.5。
> - **软有两处来源**：参考图只有 1k（1360×768），抠出的狗约 722×837，被 LANCZOS **放大**进 1024 画布
>   （`compose.py:62`）；再加上 std 档的生成与低码率。
> - 客户端不是主因：`targetEdge` 720 会再丢一些细节；`ApplyDespill` 对**所有像素**做
>   `G = min(G, (R+B)/2)`，平均亮度只降约 1，但会把偏黄的毛色压向橙色（竞品金毛有 26–38% 的像素会被它改动）。
> - 竞品"用户自己生成"的宠物（1440×1440，13–17 Mbps）亮度也只有 105–125——体验版金毛是精修素材。
> - 对策（按成本从低到高）：客户端 `targetEdge` 960 + 版本号 `p2`；去溢色只作用于半透明边缘；
>   参考图 2k 出图、提示词要"明亮柔和影棚光、鲜亮金色、清晰毛丝"、出图后自动曝光校准；
>   视频用更高档位生成后缩到 960、以约 8 Mbps 重新编码。只做"亮度 + 锐化"后处理的预览：亮度 118→142、
>   清晰度 5.7→9.7，但锐化只是加强边缘，不会长出新细节，而且必须在抠像后按 alpha 做，否则轮廓出硬边。
>
> **优化后（2026-09-12，已打包进 `apps/aipet/assets/pets`，`570238d`）**——同样的 stand 第 30 帧、同样的统计口径：
>
> | | 金毛（新配方 pro + 成片处理） | 柯基（成片处理） | 布偶猫（成片处理） | 竞品体验版金毛 |
> |---|---|---|---|---|
> | 清晰度 | 11.21 | 11.07 | 9.72 | 10.86 |
> | 平均亮度 / 95 分位 | 154.2 / 209.8 | 153.7 / 207.4 | 161.2 / 213.5 | 162.4 / 221.6 |
> | 成片码率 | 2.3 Mbps | — | — | 8.1 Mbps |
>
> - 新配方 = 2k 明亮参考图 + 曝光校准合成 + kling-v3 **pro**（4 单位 / 5 秒，原片 1440×1440）+ `petgen finish`
>   （抠像后只对宠物做 gamma 提亮、饱和度 ×1.2、USM 1.2/r1.5，合回精确纯绿，CRF 16 `-tune grain`）。
>   新配方从源头就亮（原片亮度约 155），成片处理几乎不再提亮。
> - 码率低于竞品是正常的：精确纯绿背景几乎不占码率；细节看清晰度指标。
> - 运动片段：金毛中位数 9.6–14.2；柯基、布偶猫 7.4–8.7（旧 std 原片只有 3.9–4.6，见第 5 节第 20 条）。
>   竞品的运动片段与 stand 一样清楚，所以差距来自源素材，不是运动模糊。

> **正脸待机 + 喂食 spike（2026-09-19，花 8 图片单位 + 8 视频单位，视频余额 3）**——用户要求"待机正脸朝向我、
> 动作幅度大"和"喂食动作"（对标竞品）。产物在 `tools/petgen/work/gold/v3front/`（git 忽略），脚本是一次性的、不在仓库。
> - 参考图：姿态提示词"正面朝向镜头站立，身体只微微侧转约十五度，头部正对镜头，嘴巴微微张开"，`1:1` / 2k / bright，
>   gate 通过（floating 173，blob-core 3）。实际出图是头正对镜头、身体约 45°。
> - **待机（pro）全部达标**：接缝 40.61 dB ≥ 片内最大跳变 26.42（无缝循环）；逐帧最差 blob-core 25；
>   第 30 帧亮度 153.6、清晰度 9.59；动作幅度（主体上逐帧与首帧的平均差）29.0，现有待机 10.4、竞品 35.7。
>   画面：头向左右转动看四周、最后回到正对镜头。
> - **喂食（pro）**：碗出现 → 低头吃 → 抬头舔嘴 → 碗消失 → 回到正脸站姿，接缝 41.58，全片可用；
>   但**碗是"溶解"出现和消失的**：第 17 帧和第 83–88 帧碗半透明，红色和绿幕混成橄榄绿的"鬼影碗"，
>   blob-core 最高 8072（门槛 200）。碗用哑光红陶瓷（不锈钢会反绿幕）本身抠得干净。
> - 竞品的走路片段也是原地走（主体水平中心全程 0.49–0.53），**"横穿屏幕"是客户端移动窗口**，不需要重生成素材。
> - 竞品本地状态（`shared_preferences.json`）：`stats{intimacy, satiety, health, companionStartedAt, interactionDay,
>   todayInteractions}`、`leveling{growthPoints, level, unlockedActions}`，与父 spec 4.6 一致。

**这是产品的核心，一行代码都还没写。**

### 平台与鉴权（2026-09-10 实测，已不再是未知数）

不是第三方聚合平台，是**可灵官方开放平台**，北京区：

| 项 | 结论 |
|---|---|
| Base URL | `https://api-beijing.klingai.com`。新加坡区 `api-singapore` 返回 `api key not found`，密钥绑区 |
| 鉴权 | `Authorization: Bearer <KLING_API_KEY>`，**不需要自己签 JWT** |
| 已验证 | `GET /v1/videos/image2video`、`GET /account/costs` 都返回 `code:0 SUCCEED` |
| 账户余额 | 两个试用包，都是 2026-10-10 到期：「视频生成-100-5并发」和「图像生成-1000-9并发」。视频包不含图片生成（没有图片包时 `/v1/images/generations` 返回 1102） |

**当前状态：三步管线都已用真实调用验证可行（见下面三节 spike 结果），但产品代码一行没写。**下一步是为 M2 写 spec 和计划。
注意 1102 在参数校验之前返回，余额不足时连请求格式都验证不了。

### 已修正的路线（原方案有一步是错的）

原文写的 `用户照片 ──► 单图抠像 ──► 合成到纯色底` **走不通**：
用户照片通常是头胸特写（竞品那张实测就是 678×452 的头部特写），
抠像合成只会得到「一颗头贴在绿底上」，不是全身狗。

竞品实测：源照片是头部特写，10 个动作的输出**全是全身狗**，其中 9 个首帧姿态几乎一致
（只有 walk 是另一张）。所以他们先**生成一张全身纯绿底参考图**，再拿它去图生视频。

正确管线（2026-09-10 实测跑通）：

```
用户照片 ──► /v1/images/generations              ──► 全身狗，浅灰底，16:9
              (kling-v3 + image_reference:subject)       │
                                                         ▼
                              本地分割 BiRefNet-lite + alpha matting
                              合成到精确 #00FF00，居中到 1024 方图
                                                         │
                                                         ▼
                  /v1/videos/image2video (kling-v3 std, image = image_tail = 参考图)
                                                         │
                                                         ▼
                                       绿幕动作视频 ──► 已跑通的 pet_matte 管线
```

注意：参考图**不能**让模型直接画绿底，见「第一步 spike 结果」。

### 素材实测（拿竞品自己的产物量出来的，没花钱）

- **背景色 = 纯绿 `#00FF00`**。角点采样 `(1,252,7)`、`(0,252,7)`、`(8,243,9)`。
- **绿色随时间漂移**：`stand` 的 G 通道从 252 掉到 232，`walk` 从 243 掉到 230。
  按首帧调出来的紧阈值到片尾会失效。pet_matte 现有容差够用（绿色残留 0 像素），
  但 M2 不能假设背景是恒定色。
- **竞品的循环动作根本不循环。** `stand` 五秒内狗从侧身转成正面朝镜头，
  首帧↔末帧 PSNR 11.5 dB，跟首帧↔中间帧的 11.6 dB 没区别——
  他们的桌宠每 5 秒跳一次。`walk` 是例外（全程侧身、位置尺度稳定，PSNR 19.7），
  Plan A 正好选中了这个好片子，所以没暴露。
- 这给我们一个**免费的质量优势**：可灵的 `image_tail`（尾帧控制）能把末帧钉死成首帧，
  无缝循环是结构上保证的，不靠运气。

### 接口要点（已查文档确认）

- `POST /v1/images/generations`：`model_name`（最新到 `kling-v3`）、
  `image` + `image_reference: subject|face`、`aspect_ratio`（参考图用 `16:9`，侧身长条狗用 `1:1` 尾巴会碰画框）、
  `resolution: 1k|2k`、`n: 1..9`。
  **图生图场景不支持 `negative_prompt`**，负面要写成正面提示里的否定句。
- `POST /v1/videos/image2video`：`image`、`image_tail`、`prompt`、`duration`、
  `mode: std(720P) | pro(1080P) | 4k`、`cfg_scale`（v2.x 起不支持）、`external_task_id`。
- 两者都是异步任务：返回 `task_id`，轮询 `GET <同路径>/<task_id>`，
  `task_status ∈ submitted|processing|succeed|failed`，
  完成后 `final_unit_deduction` 是实际扣费。

### spike 结果（2026-09-10，花了 6 单位）

两次调用都是 std / 5s，各扣 3 单位，每次生成约 70 秒：

| | A：图生视频循环 | B：从头部特写生成全身 |
|---|---|---|
| 接口 | `image2video`，`kling-v3` std | `omni-video`，`kling-video-o1` std |
| 输入 | 竞品 stand 首帧，`image = image_tail` | 竞品源照片（头部特写）做 `image_list` 主体参考 |
| 格式 | 960×960 / 24fps / 121 帧 / 5.04s，与竞品及 spec 契约一致 | 同左 |
| 背景 | 纯绿。6 个采样点 G 244–251、R/B ≤ 8，全片稳定 | **失败**：真实影棚绿布，有褶皱、墙地交界、阴影，采样 (40,106,74)–(102,149,125) |
| 同一只狗 | 首帧对输入参考 PSNR 34.8 dB，还原度高 | **失败**：源是红金色，生成的是黑棕双色腊肠 |
| 循环 | 接缝（末→首）45.7 dB，比片内最大相邻跳变 35.8 dB 还小，肉眼看不出 | 首↔末 20.0 dB，不循环 |
| 动作 | 很轻的待机动作，集中在前 2 秒（第 42 帧偏离最大，30.2 dB），后 3 秒几乎定格 | 正脸站立 |

结论：

- **第二步（参考图 → 循环动作视频）已验证可行。** `kling-v3` std 支持 `image_tail`，接缝结构上无缝，3 单位 / 5s。
- **第一步（头部特写 → 全身绿底参考图）**：视频包里的 `kling-video-o1` 主体参考失败（生成了绿布影棚背景，毛色也不对）。
  买了图片包后已找到可行做法，见下面「第一步 spike 结果」。
- A 的待机动作偏「静」，后 3 秒几乎定格，stand 可能要调提示词或改 10s。
- A **已过 pet_matte 实跑**（pet_shell release，`AIPET_DEV_CLIP` 指向 A）：桌面截图里狗周围 239,200 像素，
  偏绿像素 0 个（阈值 G>R+40 且 G>B+40 为 0，放宽到 +15 也是 0）；尾巴长毛边缘半透明过渡干净，无绿色光晕；
  进程内存 186 MB。注意 `pet_matte_tests` 写死了自带夹具 `green_box.mp4`，不能直接喂外部片子，实跑只能走 pet_shell。
- spike 脚本在会话临时目录，**不在仓库**，属一次性代码。

### 第一步 spike 结果（2026-09-10 晚，买了图片包之后）

`kling-v3` 图片生成接受 `image_reference: subject`，每张 **8 单位**、约 15–20 秒。

| 版本 | 做法 | 像不像源照片 | 抠像：漂浮半透明像素（竞品参考帧 911） | 问题 |
|---|---|---|---|---|
| G | 直接生成绿底（1:1） | 好，奶白斑纹保住 | **27,472** | 绿幕把毛映绿 + 身下接触阴影，肚子和腿会被抠成半透明 |
| W1 | 浅灰底生成 + 本地抠图合成 #00FF00 | 中，斑纹变淡 | 157 | 模型把尾巴画到图片边缘，尾巴尖被切平 |
| W2 | W1 + 提示词写明面部斑纹 | **最好** | 145 | 狗被画大，尾巴被画框截断 |
| W3 | W2 + **16:9 宽画幅** | 好 | lite 197 / **lite + matting 387** / 完整版 700 | lite 丢了尾巴末端的飘毛、后腿饰毛有绿缝；matting 修好 |

结论：

- **参考图不要让模型直接画绿底。** 狗站在绿布前，毛被映绿是物理上的必然，提示词压不住。
  改为浅灰底生成 → 本地分割 → 合成到精确的 `#00FF00`。背景是我们自己画的，没有阴影和反光。
- **提示词里写明这只狗最有辨识度的特征**（W2 起加了「额头到口鼻一道奶白色的毛」），像不像明显提升。
  M2 可以考虑先让多模态模型把源照片的特征描述出来，再自动填进提示词。
- **侧身的长条狗要用 16:9 生成**，否则尾巴会碰画框。流程里加了自动碰边检查：原图四条边出现任何前景像素就判失败。
- **长毛狗的抠图，alpha matting 比换大模型更管用。** BiRefNet-lite（224 MB）+ pymatting
  胜过完整版 BiRefNet（973 MB）不加 matting。两个模型都是 MIT 许可。
- 抠像打分是把 pet_matte 的键控公式逐像素复刻（`matte_core/src/chroma_key.cpp` 的 KeyParams 默认值），
  指标为「附近 2 像素内没有不透明像素的半透明像素数」，能直接抓出阴影和反光团块。竞品参考帧是 911。
- 本地环境：系统 Python 3.14.2 能直接装 `rembg[cpu]`（onnxruntime 1.29.0 有 cp314 安装包），不需要 uv 或另装 Python。

### 全链路 spike 结果（我们自己的参考图 → 循环视频 → 桌面）

| 项 | 结果 |
|---|---|
| 输入 | W3 + lite + matting 合成的参考图，`kling-v3` std，`image = image_tail`，3 单位 |
| 格式 | 960×960 / 24fps / 121 帧 / 5.04s |
| 背景 | (6,245,3) → (5,245,0)，全片几乎不漂 |
| 同一只狗 | 首、中、末帧的姿态、位置、大小一致；视频帧打分 507 / 477（竞品 911），视频模型没把反光和阴影加回来 |
| 循环 | 接缝 47.4 dB，高于片内最大相邻跳变 39.1 dB，看不出来 |
| 动作 | 眨眼、半眯眼、头部微动，分布在第 30–80 帧。提示词要求「整个五秒持续有细微动作」起了作用（A 是前 2 秒动、后 3 秒定格） |
| pet_matte 实跑 | pet_shell 桌面截图，狗所在的 124,800 像素里偏绿像素 0（+40 和 +15 两个阈值都是 0）；尾巴飘毛过渡干净，无绿边 |

结论：**头部特写 → 全身参考图 → 循环绿幕视频 → 桌面透明窗口，整条链路在真实调用下跑通了。**
每个动作的边际成本 3 视频单位（std 5s）；参考图每只宠物生成一次，8 图片单位，不达标就重试。

还没验证的：

- **只做了 stand 一个动作。** 第四项验收「两个动作是不是同一只狗」还没测；walk、run 这类需要位移的动作
  用首尾同帧能不能自然循环，也没测。
- 提示词和特征描述只在这一只狗上试过。

本轮花费：视频 9 / 100 单位（A、B、C 各 3），图片 32 / 1000 单位（G、W1、W2、W3 各 8）。

四项验收：绿幕/纯底干不干净、两个动作是不是同一只狗、动作对不对、能不能循环。

**测试输入已经有了，不必等用户的狗**：竞品那张源照片就在本机
`%APPDATA%\com.petcompanion\...\user-upload-*.jpg`，
配上他们 10 个输出可以直接做 A/B 对照。

成本参考：Vidu 参考生视频 2.34 元/5秒 1080p；可灵约 2.5–3.6 元/5秒。
一只宠物 10 动作粗估 23–36 元，算上重试 50–70 元。这是定价地板。

**不要让用户把密钥贴进对话**——聊天记录会长期保留。检查密钥时只打印长度和首尾两位。

---

## 5. 待办（按优先级）

### 阻塞产品的

1. **M2 生成管线** —— 见上。这是"上传照片复活狗狗"的全部内容。
2. ~~**`prepare` 阻塞平台线程**~~ **已解决（子项目 A 的 Task 8–9，`3c8cd65..99b1fff`）**：
   抠像移到 `native/prepare_queue` 的单工作线程，结果经消息窗口回到平台线程再应答。
   排查中发现：**Flutter 3.47 在 Windows 上把 Dart UI isolate 放在平台线程上**
   （引擎头文件里"目前在独立线程"的注释已过时），所以原来的阻塞连动画、菜单、定时器都会停，
   比这里原先写的更严重。验证"不阻塞"要数 Dart 定时器在期间跳了几次，不能 ping 另一个方法
   （计时代码自己也被冻住）。进度 EventChannel 仍未做。
3. **一次性动作每次 `open` 只能播一遍** —— 插件仍没有 `seek` 和结束事件。
   `apps/aipet` 的 `AlphaClipPlayer` 用"每次播放重新 `open` + 每 100 ms 轮询帧号判断播完"绕过
   （`apps/aipet/lib/app/pet_window/clip_player.dart`）；插件层的根治仍待做。

### 该定但不急的

4. **`Reader` 整文件载入内存**，与 spec 4.3 写的"内存映射"不符。
   Plan B 的 LRU 缓存要建在这上面，先定方案再动手。
5. **发布构建依赖网络**（`FetchContent` 会 clone googletest）。CI 或断网会挂。
   最小改法：把 gtest 拉取放在 `if(AIPET_BUILD_TESTS)` 后面，插件侧置 OFF。
6. **`/W4 /WX` 那句假话**（见坑 7）——改注释还是真开，是构建策略决定。

### 已知小问题

7. `open()` 里 `RegisterTexture` 成功后、`clips_` 插入前若 `StartTicker` 抛异常，
   会留下悬空的已注册纹理。触发条件是线程句柄耗尽，很窄。
   修法：把 `clips_` 插入挪到 `RegisterTexture` 之后、`StartTicker` 之前。
8. `pet_shell` 的 `AIPET_DEV_CLIP` 是**开发钩子**，不是产品行为。
   真实应用从 `%APPDATA%\com.aipet\` 读宠物数据。
9. `pet_shell` 收到 WM_CLOSE（PowerShell `CloseMainWindow()`）后 5 秒内没有退出，只能强制结束。
   等待期间，它以自己为父进程先后创建了两个 `pet_shell.exe` 子进程（随后退出，0 线程）。
   只观察到一次，未排查；可能和 `setPreventClose` + `onWindowClose` 的 dispose 路径有关。
   子项目 A 测到了同类现象，见第 10 条——很可能同源。

### 子项目 A 留下的（2026-09-12，最终审查后未在本计划内修）

10. **退出时原生收尾约 3.2–3.5 秒**（WM_CLOSE → 没有存活的 aipet 进程）。Dart 侧 `quit()` 只用 13–14 ms；
    99.5% 以上在 `windowManager.destroy()` 之后——window_manager 0.5.2 的 `destroy()` 只是
    `PostQuitMessage`，引擎和插件在 `FlutterWindow::OnDestroy` 里销毁，之后才 `DestroyWindow`。
    现在 `quit()` 先隐藏两个窗口，用户看不到这段等待；进程本身仍要晚 3 秒多结束。
    排查法（别猜）：在"WM_QUIT 出循环"、`FlutterWindow::OnDestroy` 进/出、`~AlphaVideoPlugin` 进/出、
    `wWinMain` 返回处用 `OutputDebugString` 打时间戳二分；再加一组"宠物窗显示但从不打开片段"的对照。
    稳态退出不走 Media Foundation（缓存命中，整个进程不调 `pet_matte_prepare`），这条线索可以排除。
11. **抠像队列按引擎各一份**：每个引擎的插件实例各持有一个 `PrepareQueue`。
    "只有一个线程调 `pet_matte_prepare`"（`pet_matte_last_error()` 是进程级全局）之所以成立，
    是因为主窗口引擎从不调 `prepare`。以后第二个引擎要抠像，得共享队列或加进程级互斥。
    另：抠像中途退出会等这次抠像做完（`~PrepareQueue` join 正在跑的任务）。
12. **`.staging` 里的孤儿临时文件没人清理**：抠像中途退出会留下约 50 MB 的 `<key>.<pid>.tmp`，
    pid 不会复用，永远留着。启动时应尽力删掉别的 pid、且较旧的临时文件。
13. **宠物窗先拒绝的领养要等 3 秒才报错，还丢了错误码**：`unknown_pet` / `missing_assets` / `busy`
    在推送"正在准备"之前就抛出，主窗口却先等确认，3 秒后变成超时、一律显示「切换失败，请重试」，
    映射成「素材缺失」的分支实际走不到。修法：领养调用若先于确认完成就直接用它的结果。
14. **没有单实例保护**：连开两次 exe 会出现两个宠物窗、两个托盘图标、两个写 `settings.json` 的进程
    （spec 4.3"宠物窗是唯一写入方"其实是按进程说的）。
15. **每次 `playAction` 都重新哈希整段源视频**（`MatteCache.ensure`）：内置片段 2–3 MB，
    在宠物窗 UI 线程上约几十毫秒，现在不成问题；C 子项目的大文件应按"路径 + 大小 + mtime"缓存 key。
16. 次要：一次性动作如果恰在"另一个准备进行中"时播完，回待机会被忽略；若那次准备随后失败，
    宠物会停在末帧（只影响观感）。`PetWindowBridge` 的 `getState` / `mainWindowClosing` 分支没有
    try/catch（两个调用方都已兜住，不会卡死或半退出）。
    收尾修复留下的两个小口子：关主窗口的那几毫秒里如果首次领养恰好失败，宠物库会"重新打开又被
    隐藏"（托盘仍能打开）；`quit()` 的 2 秒时限由各步骤共用，某个隐藏步骤一直不返回时会跳过释放
    播放器（之后照常 destroy，进程照常退出）。
    宠物窗侧的 55 秒上限只能拦住"会返回但很慢"的抠像；原生调用真卡死时 Dart 的超时触发不了
    （Dart 与平台线程是同一个），超时后原生抠像也还在后台跑完。
17. **旧版本的抠像缓存不会被清理**：画质优化把缓存升到 `p2`（960 px + 边缘去溢色），修绿边时又升到 `p3`
    （最大值限制去溢色），`matte-cache\v1` 下旧的 `*-p1.aipmat`、`*-p2.aipmat`（每个动作约 42–68 MB）永远留着。
    现在一只宠物有 7 个动作，换一次配方就多占几百 MB。做缓存 LRU 时按"后缀不是当前版本的一律删"一并清掉。
18. `alpha_video` 的 `AlphaVideo.prepare` 默认 `targetEdge` 仍是 720（`packages/alpha_video/lib/alpha_video.dart`）。
    唯一的生产调用方显式传 `kMatteTargetEdge`（960）；以后新的调用方若省略参数，会悄悄回到 720。
19. `pet_matte` 的管线测试不覆盖去溢色：`FringePixelsArePremultiplied` 只断言预乘的不变式，去溢色公式只由
    `matte_core` 的 `test_despill` 单测覆盖。
20. **柯基、布偶猫的走路和睡觉偏软**（2026-09-23 缩小了范围）：C 子项目重做了三只宠物的
    待机 / 喂食 / 玩耍 / 舔爪子 / 卖萌（正脸、2k 参考图、pro），但 **walk 和 sleep 是沿用的旧片**——
    金毛的来自 v2 pro，柯基、布偶猫的还是最早的 std 1k 配方，原片清晰度只有 3.9–4.6，成片处理翻倍也补不出源里没有的细节。
    现状（成片第 30 帧 / 片内中位数）：柯基 walk 7.17 / 7.46、sleep 11.70；布偶猫 walk 8.77 / 7.84、sleep 9.00；
    对照金毛 walk 9.80 / 10.08、sleep 14.09。
    追平要重做的只剩这四段：每只 walk / lie 两张 2k 参考图（2 只 × 2 张 × 8 = **32 图片单位**）
    + 4 段 pro 视频（**16 视频单位**）。余额（视频 23 / 图片 752）够，但要用户点头再花。
    命令见 `docs/superpowers/plans/2026-09-12-pet-image-quality.md` Task 5–6，配方按 C 子项目的
    `docs/superpowers/plans/2026-09-19-front-facing-pets.md`。

---

## 6. Plan B 的范围（还没写计划）

真正的应用（spec 4.1/4.5/4.6）：

- 四个独立窗口：宠物窗（位置权威）/ HUD 面板窗 / 气泡窗 / 主窗，托盘常驻
- 逐像素命中测试（透明处鼠标穿透）
- 养成数值：亲密度 / 饱食度 / 健康度 / 成长值 / 等级 / 解锁动作 / 陪伴天数
- 缓存目录与 LRU（spec 4.4）
- 动作状态机：循环型 vs 一次性

> 子项目 A 已经做掉其中一部分：主窗（宠物库）+ 宠物窗双引擎、托盘常驻、动作切换
> （循环型 / 一次性播完回待机）、自定义宠物目录扫描。还没做：HUD 面板窗、气泡窗、
> 逐像素命中测试（现在宠物窗整块 360×360 矩形都接收鼠标，透明处不穿透）、养成数值、
> 缓存 LRU（`matte-cache\v1` 目前只增不减）。

写计划前先跑 brainstorming skill。

---

## 7. 流程说明

本项目用 superpowers 的 spec → plan → subagent-driven-development 流程走完了 Plan A。
执行期我（控制器）做了 23 条裁决，**其中 8 条是在修正计划本身的错误**——
无解的测试集、画不出图的夹具脚本、方向反了的指针算术、检测不出画面翻转的夹具、
会在宠物身上打洞的色键透明方案等。

这说明一件事对新会话有用：**派活前自己重读一遍计划里的代码**，
不要直接把 brief 丢给实现者。同一类 bug 会从系统不同侧面反复长出来
（路径编码那条就在原生侧修好后，又从 Flutter 侧长了回来）。

**子项目 A（2026-09-10 → 09-12）** 同样走 spec → plan → subagent-driven-development：16 个任务，
控制器记了约 40 条裁决。对新会话有用的几条：

- **派发前的"预检"很值**：提前核对简报引用的接口、第三方 API 源码和测试环境，抓到了
  "测试画布 800×600 让按钮落在屏幕外点不到"、"首帧自动 `Show()` 让隐藏的宠物窗变可见"等问题。
- **计划里的代码也会错，且错得很隐蔽**：`whenComplete(() => map.remove(key))` 的箭头函数会返回被移除的
  Future——正是它自己——于是永远等不完；"再调一个方法看是否被卡"测不出平台线程阻塞，因为 Dart 本身
  就跑在平台线程上。遇到"测试莫名超时"或"本该失败却通过"，先怀疑测试本身。
- **先测量再裁决，而且裁决的每个前提都要有证据**：退出耗时先打点量出 99.5% 在原生收尾，才决定不动
  Dart 代码；但"窗口在 destroy() 时就消失"这个前提当时没测，被最终审查推翻。
- **最终全分支审查找到了 4 个跨任务的生命周期问题**（逐任务审查各看一侧，看不到）：首次领养准备中
  关库就退出、宠物窗侧没有 60 秒上限、双击托盘开出两个主窗口、退出时窗口滞留。修复情况见第 1 节。
- 执行记录与验收证据在 `docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`。
