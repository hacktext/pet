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
9. `pet_shell` 收到 WM_CLOSE（PowerShell `CloseMainWindow()`）后 5 秒内没有退出，只能强制结束。
   等待期间，它以自己为父进程先后创建了两个 `pet_shell.exe` 子进程（随后退出，0 线程）。
   只观察到一次，未排查；可能和 `setPreventClose` + `onWindowClose` 的 dispose 路径有关。

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
