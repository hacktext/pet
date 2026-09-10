# aipet 交接文档

> 新会话请先读这份文件。日期：2026-09-10

做一款 Windows 桌面宠物应用：用户付费后上传自己宠物的照片，云端生成该宠物的
真实感动作视频，在桌面上以透明窗口常驻陪伴，可交互，带养成数值。

对标产品「宠伴赛博陪伴」已被完整逆向，结论见
`docs/superpowers/specs/2026-09-02-desktop-pet-design.md` 第 2 节（那些是实测事实，不是推测）。

---

## 1. 现在能跑什么

**Plan A（渲染内核）已完成并通过多轮审查**，30 个提交已合入 `master`，
55 个测试全绿（49 原生 GoogleTest + 6 Flutter 集成测试）。

```
用户照片  ──✗──►  绿幕/纯底动作视频  ──✅──►  桌面上会动的狗
          还没做                      Plan A 已跑通
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

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
$env:AIPET_DEV_CLIP = "$env:APPDATA\com.petcompanion\宠伴赛博陪伴\pets\generated\0af4f2d6-ca2b-4028-80e1-e41944b8edd6\82cd8b28-f904-469e-abac-3ea9433b009f\walk-walk.mp4"
cd C:\Users\Administrator\code\aipet\apps\pet_shell; flutter run -d windows --release
```

**必须加 `--release`**（debug 下抠像 9.7 秒且窗口冻住）。
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

---

## 4. 下一步：M2 生成管线（当前卡点）

**这是产品的核心，一行代码都还没写。**

### 平台与鉴权（2026-09-10 实测，已不再是未知数）

不是第三方聚合平台，是**可灵官方开放平台**，北京区：

| 项 | 结论 |
|---|---|
| Base URL | `https://api-beijing.klingai.com`。新加坡区 `api-singapore` 返回 `api key not found`，密钥绑区 |
| 鉴权 | `Authorization: Bearer <KLING_API_KEY>`，**不需要自己签 JWT** |
| 已验证 | `GET /v1/videos/image2video`、`GET /account/costs` 都返回 `code:0 SUCCEED` |
| 账户余额 | 已充值「试用-视频生成-100-5并发-1个月」：100 单位，2026-10-10 到期。**只含视频、不含图片生成**，`/v1/images/generations` 仍返回 1102 |

**当前卡点：第一步（头部特写 → 全身绿底参考图）还没有可用方案。** 见下面「spike 结果」。
注意 1102 在参数校验之前返回，余额不足时连请求格式都验证不了。

### 已修正的路线（原方案有一步是错的）

原文写的 `用户照片 ──► 单图抠像 ──► 合成到纯色底` **走不通**：
用户照片通常是头胸特写（竞品那张实测就是 678×452 的头部特写），
抠像合成只会得到「一颗头贴在绿底上」，不是全身狗。

竞品实测：源照片是头部特写，10 个动作的输出**全是全身狗**，其中 9 个首帧姿态几乎一致
（只有 walk 是另一张）。所以他们先**生成一张全身纯绿底参考图**，再拿它去图生视频。

正确管线：

```
用户照片 ──► /v1/images/generations           ──► 全身纯绿底参考图
              (image + image_reference:subject)        │
                                                       ▼
                            /v1/videos/image2video (image = image_tail = 参考图)
                                                       │
                                                       ▼
                                     绿幕动作视频 ──► 已跑通的 pet_matte 管线
```

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
  `image` + `image_reference: subject|face`、`aspect_ratio`（要 `1:1`）、
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
- **第一步（头部特写 → 全身绿底参考图）没解决。** `kling-video-o1` 的主体参考既守不住纯绿，也守不住毛色。
  候选：买可灵图片包走 `/v1/images/generations` + `image_reference: subject`（原计划，未验证，图片便宜）；
  试 `kling-v3-omni`；或 Vidu（`secrets/vidu.env` 已有密钥）。
- A 的待机动作偏「静」，后 3 秒几乎定格，stand 可能要调提示词或改 10s。
- A **已过 pet_matte 实跑**（pet_shell release，`AIPET_DEV_CLIP` 指向 A）：桌面截图里狗周围 239,200 像素，
  偏绿像素 0 个（阈值 G>R+40 且 G>B+40 为 0，放宽到 +15 也是 0）；尾巴长毛边缘半透明过渡干净，无绿色光晕；
  进程内存 186 MB。注意 `pet_matte_tests` 写死了自带夹具 `green_box.mp4`，不能直接喂外部片子，实跑只能走 pet_shell。
- spike 脚本在会话临时目录，**不在仓库**，属一次性代码。

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
2. **`prepare` 阻塞平台线程 2.6 秒**（release）——抠像时整个应用冻住，
   超 5 秒会被 Windows 打上"无响应"。正确修法需要 spec 4.2 已规定的进度
   EventChannel。**定为下一个计划的第一个任务**。
3. **一次性动作每次 `open` 只能播一遍** —— 播完卡在末帧，再 `play` 立刻又停，
   且没有 `seek`。Plan A 只用循环所以没暴露，`feed`/`play`/`spin` 会立刻撞上。

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

---

## 6. Plan B 的范围（还没写计划）

真正的应用（spec 4.1/4.5/4.6）：

- 四个独立窗口：宠物窗（位置权威）/ HUD 面板窗 / 气泡窗 / 主窗，托盘常驻
- 逐像素命中测试（透明处鼠标穿透）
- 养成数值：亲密度 / 饱食度 / 健康度 / 成长值 / 等级 / 解锁动作 / 陪伴天数
- 缓存目录与 LRU（spec 4.4）
- 动作状态机：循环型 vs 一次性

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
