# 桌面宠物（aipet）设计文档

日期：2026-09-02
状态：已确认，待拆实施计划
范围：本文档完整定义 M1（Windows 桌宠客户端），M2/M3 只给出边界与接口约定。

---

## 1. 背景与目标

做一款 Windows 桌面宠物应用：用户上传自己宠物的照片，云端生成该宠物的真实感动作视频，
在桌面上以透明窗口常驻陪伴，可交互（喂食、玩耍、摸头等），带养成数值。

对标产品「宠伴赛博陪伴」已被完整逆向，其技术路线被确认可行，本项目采用同构架构。

## 2. 竞品逆向结论（设计依据）

以下为实测事实，不是推测：

| 项 | 结论 |
|---|---|
| 客户端 | Flutter (Windows desktop)，Dart AOT + 3 个 C++ 插件 DLL |
| 依赖 | flutter_riverpod, flutter_animate, flutter_shaders, window_manager, desktop_multi_window, screen_retriever, tray_manager, video_player_win, file_picker, url_launcher, path_provider, shared_preferences, http, crypto, shortid, json_annotation, ffi |
| 素材 | **AI 生成的纯绿幕 H.264 视频**，960×960 或 1440×1440，24fps，121 帧（约 5s），一个动作一个文件 |
| 抠像 | `pet_matte.dll`：Media Foundation 逐帧解码 → 解析式绿幕键控 → 预乘 BGRA8。pipeline 标识 `offline-green-matte-3.7.0` |
| 帧缓存 | 私有容器 `.pcmat`（magic `PCMATV1`），离线预处理产物，单动作 92–233 MB，实测总占用 **3.0 GB** |
| 渲染 | `alpha_video.dll`：D3D11 纹理环 → Flutter External Texture，通道 `dev.pet_companion.alpha_video/{methods,events,preparation_events}` |
| 窗口 | window_manager 无边框透明置顶 + desktop_multi_window 拆多窗（宠物窗 / HUD 窗 / 气泡窗） |
| 后端 | 腾讯 CloudBase 云函数 `/http/router`，七牛云存储，微信/支付宝支付，uni-id JWT |
| 养成 | 亲密度 / 饱食度 / 健康度 + 成长值 / 等级 / unlockedActions + 陪伴天数 / 今日互动次数 |
| 商业化 | 通用版 / 标准版 / 高级Pro版三档（动作数不同），免费领取额度，宠物广场 |
| 安装体积 | 39.6 MB |

**没有 LLM 对话功能**，只有一个静态「对话气泡」。

## 3. 范围与里程碑

| 里程碑 | 内容 | 依赖 |
|---|---|---|
| **M1** | Windows 桌宠客户端：透明多窗 + 原生抠像插件 + 动作播放 + 养成数值 + 托盘 | 只依赖「一批绿幕 mp4」 |
| **M2** | 生成管线：上传照片 → 图生视频 → 绿幕素材 → 对象存储 → 下发 | — |
| **M3** | 账号与商业化：登录、宠物库/广场、订单、微信/支付宝、版本分档 | M1 + M2 |

M1 开发期使用本机已有的绿幕 mp4 作为开发素材（仅本机验证，不进产品分发），
因此 M1 不被 M2 阻塞。

**本文档只完整定义 M1。**

### 明确的非目标（YAGNI）

- macOS 版本。Media Foundation 是 Windows 专有；macOS 需另写 AVFoundation + Metal 实现，
  Dart 层与全部 UI 可复用。**本期不做。**
- LLM 对话 / 语音
- 宠物之间互动、多宠同屏
- 云端存档同步

## 4. M1 架构

### 4.1 进程与窗口模型

单进程，多 Flutter 窗口（`desktop_multi_window`）：

```
主 isolate ──┬─ 宠物窗   pet      无边框 / 透明 / 置顶 / 可拖 / 逐像素命中测试
             ├─ HUD 窗   hud      状态面板 + 动作按钮宫格，跟随宠物窗定位
             ├─ 气泡窗   bubble   对话气泡，跟随宠物窗定位
             └─ 主窗     main     宠物库 / 设置（默认隐藏，托盘唤起）
托盘 tray_manager 常驻
```

窗口协作规则：

- 宠物窗是**位置权威**。HUD 窗和气泡窗监听宠物窗的 bounds 变化后重新定位。
- HUD 窗出现在宠物窗上方；空间不足时翻转到下方（对应竞品的 `petContextMenuSideForBounds`）。
- 窗口尺寸随「宠物大小」缩放系数变化（`petWindowSizeForScale` / `petHudWindowSizeForScale`）。
- 多显示器：用 `screen_retriever` 取显示器布局，持久化 `window_display_sig`；
  显示器拓扑变化时重新夹取宠物窗到可见区域。

**逐像素命中测试**：宠物窗默认设置 `WS_EX_TRANSPARENT`（鼠标穿透）。
低频轮询 `GetCursorPos`，落在窗口矩形内时采样当前帧该点的 alpha：
alpha > 阈值则临时取消穿透以接收点击，否则保持穿透。
alpha 采样使用一张 CPU 侧的降采样 alpha 掩码（每帧 1/8 尺寸，由 alpha_video 插件同步产出）。

### 4.2 原生插件层

两个 C++ 插件，与竞品同构：

**`pet_matte`** — 离线抠像

```
输入：绿幕 mp4 路径 + 抠像参数
  Media Foundation IMFSourceReader 逐帧解码 → BGRA32
  → 绿幕键控（YCbCr 色度距离）
  → 去溢色 despill
  → alpha 边缘 1px 收缩 + 羽化
  → 预乘 alpha（BGRA8 premultiplied, sRGB）
  → 逐帧包围盒裁剪（去掉全透明边缘）
  → 逐帧压缩 → 写入 .pcmat
输出：.pcmat 文件 + JSON 清单
进度：通过 EventChannel 上报（解码/抠像/写入三阶段）
```

C ABI（便于 Dart FFI 或插件内直调）：

```c
int32_t pet_matte_abi_version(void);
int32_t pet_matte_prepare_video(const PetMatteRequest*, PetMatteResult*);
const char* pet_matte_last_error(void);
```

**`alpha_video`** — 播放

```
读 .pcmat（内存映射）→ 解压帧 → 上传 D3D11 纹理环（3 帧环形缓冲，避免 GPU 停顿）
→ FlutterDesktopTextureRegistrarRegisterExternalTexture 注册外部纹理
→ MarkTextureFrameAvailable 驱动 Flutter 重绘
```

通道：

- `aipet.alpha_video/methods` — `open` / `play` / `pause` / `setLoop` / `switchClip` / `dispose`
- `aipet.alpha_video/events` — 播放事件（帧号、循环结束、错误）
- `aipet.alpha_video/preparation` — 预处理进度

Dart 侧封装为本地包 `packages/alpha_video`，暴露 `AlphaVideoController` + `AlphaVideoView`。

### 4.3 `.pcmat` 容器格式

自研格式，结构参考竞品但独立实现：

```
[ header 128B ]
  magic "AIPMAT1\0"
  schemaVersion u32, headerSize u32, flags u32
  width u32, height u32
  timeBaseDen u32, frameCount u32
  indexOffset u64, indexSize u64
  manifestOffset u64, manifestSize u64
[ frame blocks ]           逐帧压缩数据，紧密排列
[ index ]                  frameCount × 48B
  ptsTicks u64, durationTicks u64, byteOffset u64      (24B)
  byteSize u32, rawSize u32                            (8B)
  cropX u16, cropY u16, cropW u16, cropH u16           (8B)
  reserved                                             (8B, 对齐用)
[ manifest ]               JSON：源 sha256、抠像参数、pipeline 版本、媒体元数据
```

帧压缩用 LZ4（快速解压优先，压缩比不是瓶颈）。

**缓存分辨率是参数，默认 720×720**（不是源片的 1440×1440）。
桌宠实际显示 200–400 px，720 足够；这一项把磁盘占用降到竞品的约 1/4。
需要更高画质时改常量即可。

### 4.4 缓存与目录布局

```
%APPDATA%/com.aipet/aipet/
  sources/v1/<ab>/<sha256>.mp4        原始绿幕视频
  matte-cache/v1/<ab>/<cd>/<cacheKey>/
      asset.pcmat
      manifest.json
      last_accessed
  matte-cache/v1/.staging/            写入中的临时文件
  matte-cache/v1/.locks/              跨进程写锁
  pets/<petId>/                       宠物元数据
  uploads/                            用户上传的照片
```

`cacheKey = sha256(源视频sha256 + 抠像参数摘要 + pipeline版本)`。
写入走 `.staging` → 校验 → 原子 rename，保证不产生半个文件。
LRU 按 `last_accessed` 清理，总量上限可配置。

### 4.5 Dart 层结构

状态管理用 Riverpod（同竞品）。

```
lib/
  main.dart                    窗口路由分发（按 window id 决定挂载哪个 App）
  app/
    pet_window/                宠物窗 UI
    hud_window/                HUD 面板 UI
    bubble_window/             气泡窗 UI
    main_window/               宠物库 / 设置
  domain/
    pet.dart                   宠物模型
    action.dart                动作定义与解锁规则
    stats.dart                 养成数值
  services/
    window_sync.dart           多窗位置同步
    hit_test.dart              逐像素命中测试
    asset_cache.dart           素材下载 + 抠像调度
    persistence.dart           shared_preferences 存取
packages/
  alpha_video/                 自研包（Dart + windows/ C++ 插件）
  pet_matte/                   自研包（windows/ C++ 插件）
```

### 4.6 领域模型

**动作集**（键名取自竞品实测）：

```
基础   stand walk feed play sleep
进阶   spin lick_paw act_cute pet_head run
解锁   beg peek toilet parkour giant mischief runaway
       tilt_head chase_butterfly drink stretch shake bye lure headpat
```

每个动作对应一个绿幕 mp4。动作分**循环型**（stand/walk/sleep）和**一次性**
（feed/play/spin/…）：一次性动作播完自动回到 idle 循环。

**养成数值**：

```
stats     intimacy 0-100      亲密度，互动增长
          satiety  0-100      饱食度，随时间衰减，喂食恢复
          health   0-100      健康度，饱食度过低时下降
          companionStartedAt  陪伴起始时间戳
          interactionDay      今日计数所属日期
          todayInteractions   今日互动次数
leveling  growthPoints        成长值
          level               等级
          unlockedActions[]   已解锁动作键
```

数值随时间的衰减在应用运行时按 tick 计算，冷启动时按 `now - lastSavedAt` 补算。
持久化到 `shared_preferences`（同竞品，够用且零依赖）。

### 4.7 错误处理

抠像与素材是主要失败面，全部需要用户可见且可恢复：

| 场景 | 处理 |
|---|---|
| 源视频缺失/损坏 | 标记该动作不可用，UI 置灰按钮，提供重试 |
| 抠像失败 | 保留原视频，记录错误，可重试；不污染缓存目录 |
| 缓存文件校验失败 | 移入 `.quarantine`，下次重新抠图 |
| 并发抠同一素材 | `.locks` 目录文件锁，后来者等待而非重复计算 |
| 磁盘空间不足 | 先跑 LRU 清理，仍不足则明确报错 |
| 宠物资源未就绪 | 宠物窗显示占位动画，不放出未完成的宠物 |

### 4.8 测试策略

- **原生层**：`pet_matte` 用固定输入 mp4 + 黄金输出帧做回归；
  `.pcmat` 读写做往返测试（写入 → 读出 → 逐帧比对）。
- **Dart 领域层**：数值衰减、等级解锁、动作状态机全部纯函数化，单元测试覆盖。
  尤其是跨天/跨时区的今日互动计数重置，和长时间离线后的数值补算。
- **窗口层**：多窗位置同步、多显示器夹取、DPI 变化——手动验证清单，不做自动化。
- **命中测试**：给定 alpha 掩码和坐标的纯函数，单元测试覆盖。

## 5. 已确定的假设

1. **只做 Windows**。macOS 不在本期范围。
2. **后端用 FastAPI**（M2 才动）。不用腾讯云开发：生成是长任务且要跑 ffmpeg/matting，
   云函数模型不合适；FastAPI + Python 是既有技术栈。
3. **抠像在客户端运行时做**（同竞品）。已知代价是磁盘占用和首次可用延迟；
   服务端预烤 alpha 是更优解，但按「先做出来，后期再优化」的决定，本期不做。
4. **HUD 中文动作名到动作键的映射需在实现时确认**——「后空翻」对应哪个素材键
   尚未从竞品完全确证。

## 6. M2 / M3 接口边界

M1 对外只依赖一个抽象：

```dart
abstract class PetAssetSource {
  Future<List<PetAction>> listActions(String petId);
  Future<File> resolveVideo(String petId, String actionKey);
}
```

M1 用本地目录实现它；M2 用「云端下载 + 缓存」实现它。M1 不感知网络、账号、订单。

M2 产出的契约：每只宠物一组绿幕 mp4，命名 `<actionKey>.mp4`，
960×960 或更高，24fps，纯绿背景，动作首尾可循环。

## 7. 待办前置条件

- Flutter SDK 已装到 `C:\Users\Administrator\code\envs\flutter`
- VS Build Tools 已具备 VCTools 工作负载 + VC.Tools.x86.x64 + CMake + Windows 10 SDK
- 开发素材：本机已有绿幕 mp4（1440×1440 / 24fps / 121 帧）可直接用
