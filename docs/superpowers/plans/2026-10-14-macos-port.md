# aipet macOS 移植方案（Apple 芯片）

日期：2026-10-14
目标：桌宠在 Apple 芯片（M1 及以后）的 Mac 上功能与 Windows 版一致，产出可分发的 `.app` / `.dmg`。
范围外：Intel Mac、Mac App Store 上架。

## 1. 现状：哪些能复用，哪些要重写

| 模块 | 位置 | Mac 上 |
|---|---|---|
| 抠像算法 matte_core | `native/matte_core` | 纯 C++，直接复用 |
| 缓存格式 pcmat（`.aipmat` 读写，lz4） | `native/pcmat` | 复用；路径从 `std::wstring` + `_wfopen` 改为跨平台 |
| 取帧 frame_source | `native/frame_source` | 复用；同上改路径 |
| 准备队列 prepare_queue | `native/prepare_queue` | 复用；同上改路径 |
| 准备流程 pet_matte | `native/pet_matte` | 复用；C 接口的路径参数按平台区分 |
| **视频解码 mf_decode** | `native/mf_decode` | **重写**：Media Foundation → AVFoundation（`AVAssetReader`），保持 `mfd::Decoder` 接口不变 |
| **Flutter 插件 alpha_video** | `packages/alpha_video/windows` | **新写 macOS 版**：Objective-C++，同一个 MethodChannel 协议（abiVersion / open / play / pause / currentFrame / dispose / prepare） |
| 窗口不抢焦点移动、显示 | `lib/services/native_window.dart`（user32） | 换成 runner 里的一个小 MethodChannel（Swift，NSWindow） |
| 拖拽读鼠标 | `lib/app/pet_window/pet_dragger.dart`（GetCursorPos / GetAsyncKeyState） | 同一个 channel：`NSEvent.mouseLocation` / `pressedMouseButtons` |
| 语音播放 | `lib/services/voice_player.dart`（winmm） | `afplay` 子进程，不加依赖 |
| 数据目录 | `lib/services/app_paths.dart`（`%APPDATA%`） | `~/Library/Application Support/com.aipet/aipet`；内置宠物在 `.app` 包内 `App.framework/Resources/flutter_assets` |
| 托盘图标 | `assets/tray.ico` | 加 PNG（模板图） |
| window_manager / tray_manager / screen_retriever / file_selector / desktop_multi_window | pub 插件 | 均声明支持 macOS；desktop_multi_window 0.3 的 Mac 行为需真机确认 |

工作量集中在两处：AVFoundation 解码器（约 250 行）和 macOS 版插件（约 350 行）。其余是小改动。

## 2. 实施步骤

### 阶段 0：Mac 开发环境（在 Mac 上，约半小时）
1. 安装 Xcode（App Store），首次打开同意协议；`sudo xcode-select -s /Applications/Xcode.app`。
2. `xcode-select --install`（命令行工具）；`brew install cocoapods cmake`。
3. 安装与 Windows 相同版本的 Flutter（`flutter --version` 对齐），`flutter config --enable-macos-desktop`，`flutter doctor` 全绿（Android 项可忽略）。
4. 克隆仓库（仓库目前没有远程，需要先推到私有 Git 仓库或拷贝过去）。

### 阶段 1：原生代码去 Windows 化（Windows 上就能做，Windows ctest 必须保持全绿）
1. 新增 `native/common/native_path.h`：`using NativePath = std::filesystem::path;` 和 `FILE* OpenFile(const NativePath&, const char* mode)`（Windows 走 `_wfopen`，其他走 `fopen`）。
2. `pcmat` / `frame_source` / `prepare_queue` 的 `std::wstring` 路径换成 `NativePath`。
3. `pet_matte_prepare` 的 C 接口：Windows 保持 `const wchar_t*`；macOS 用 `const char*`（UTF-8）。用 `pet_matte_char` typedef 区分，函数名不变。
4. `mf_decode` 的 CMake 只在 WIN32 下参与构建。

### 阶段 2：AVFoundation 解码器（Mac 上做）
1. `native/avf_decode/decoder.mm`：实现 `mfd::Decoder`（同一个头文件 `mf_decode/decoder.h`，把 `IMFSourceReader*` 换成平台无关的不透明指针）。
   - `AVAssetReader` + `AVAssetReaderTrackOutput`，输出 `kCVPixelFormatType_32BGRA`，逐行拷成紧密打包的 BGRA（行跨度可能不等于 width*4）。
   - pts / duration 换算成 100ns 单位，和 Windows 一致。
   - 保持 `hadError()` 的约定：除干净的流结束外，任何 false 返回都置错。
2. 把现有 `mf_decode/tests/test_decoder.cpp` 在 Mac 上跑通（同一份测试素材）。
3. 用同一个 mp4 在两个平台各生成一次 `.aipmat`，对比帧数与像素差异（允许解码器之间的微小误差）。

### 阶段 3：alpha_video macOS 插件（Mac 上做）
1. `packages/alpha_video/pubspec.yaml` 增加 `macos: pluginClass: AlphaVideoPlugin`。
2. `packages/alpha_video/macos/alpha_video.podspec`：编译 `native/` 下的 matte_core、pcmat、frame_source、pet_matte、prepare_queue、avf_decode 源文件，以及 vendored 的 `lz4.c/lz4.h`（BSD 许可，放进 `macos/Classes/third_party/lz4`）。只出 arm64。
3. `AlphaVideoPlugin.mm`：
   - 每个 clip 一个对象，实现 `FlutterTexture` 的 `copyPixelBuffer`：从 `FrameSource::FrameRgba` 取帧，RGBA → BGRA 写进复用的 `CVPixelBuffer`（用 `CVPixelBufferPool`）。**需在真机确认 Flutter macOS 外部纹理对预乘 alpha 的处理**，Windows 版透明边缘的效果是基准。
   - 推帧线程与 Windows 版相同的逻辑（按帧时长等待），`textureFrameAvailable:` 可以在任意线程调用。
   - `prepare` 走 `PrepareQueue`，完成回调用 `dispatch_async(dispatch_get_main_queue())` 回到主线程再回复 Dart（替代 Windows 的消息窗口）。
   - 插件销毁时与 Windows 版相同的拆除顺序：先停推帧线程，再注销纹理。

### 阶段 4：Dart 平台层（Windows 上就能做，`flutter test` 保持全绿）
1. `app_paths.dart`：按 `Platform.isMacOS` 返回 Mac 路径；内置宠物目录从 `Platform.resolvedExecutable` 推到 `Contents/Frameworks/App.framework/Resources/flutter_assets/assets/pets`。加单元测试。
2. `native_window.dart` 抽成接口：`WindowsNativeWindow`（现有 user32 实现）和 `MacNativeWindow`（调用 runner channel `aipet/native_window`）。**注意坐标系**：macOS 屏幕原点在左下角，在 Swift 一侧转换，Dart 一侧保持左上角的逻辑坐标。
3. `pet_dragger.dart`：`SystemDragPointer` 按平台取 Windows / Mac 实现。
4. `voice_player.dart`：新增 `AfplayVoicePlayer`（`Process.start('afplay', [path])`，新一句时 kill 上一句）。
5. 托盘图标按平台选 `.ico` / `.png`。

### 阶段 5：macOS runner（Mac 上做）
1. `flutter create --platforms=macos .`（在 `apps/aipet` 下）生成 `macos/`。
2. `MainFlutterWindow.swift`：窗口透明（`isOpaque = false`、`backgroundColor = .clear`、`hasShadow = false`）；注册 `aipet/native_window` channel（按标题找 NSWindow，`setFrameOrigin` / `orderFrontRegardless` 不激活）。
3. desktop_multi_window 的子窗口创建回调里同样注册插件、设透明。
4. `Info.plist`：`LSUIElement = YES`（不在 Dock 显示，对应 Windows 的 skipTaskbar）；最低系统 macOS 11。
5. `*.entitlements`：分发版关闭 App Sandbox（宠物缓存、外部视频路径、网络都更简单）；保留 `com.apple.security.network.client`。
6. 只构建 arm64：Xcode 工程 `ARCHS = arm64`。

### 阶段 6：打包与分发
1. `flutter build macos --release` → `build/macos/Build/Products/Release/aipet.app`。
2. 制作 dmg：`hdiutil create -volname aipet -srcfolder aipet.app -ov -format UDZO aipet.dmg`。
3. 只给自己用：右键「打开」绕过 Gatekeeper 即可。
4. 发给用户：需要 Apple Developer 账号（99 美元/年），用 Developer ID Application 证书签名 + `xcrun notarytool` 公证 + `xcrun stapler staple`。做一个 `scripts/package_macos.sh` 串起来。

## 3. 验证清单（Mac 真机）
- [ ] 原生 ctest 全绿（含新解码器测试）
- [ ] `flutter test` 全绿
- [ ] 首次启动：宠物库打开、领养内置宠物，宠物出现在桌面，边缘透明无绿边
- [ ] 拖拽、右键菜单（含「大小」三档）、散步、悬停面板（不抢焦点）
- [ ] 托盘菜单：打开宠物库、退出
- [ ] 登录、同步、定制下单、微信扫码支付、收到定制宠物并「换它陪我」
- [ ] 语音播放
- [ ] 多显示器、Retina 缩放下位置正确
- [ ] 退出干净，无崩溃报告

## 4. 风险
| 风险 | 应对 |
|---|---|
| desktop_multi_window 0.3 在 Mac 上的隐藏启动、透明子窗口行为与 Windows 不同 | 阶段 5 先做一个最小验证；不行就改用单窗口 + 弹出 |
| 外部纹理 alpha 处理（预乘/直通）导致边缘发黑或发白 | 阶段 3 用 Windows 截图做基准对比，必要时在拷贝时预乘 |
| 不激活显示窗口在 Mac 上的行为（悬停面板） | Swift 侧用 `orderFrontRegardless`，必要时改用 `NSPanel` + `nonactivatingPanel` |
| 我在 Windows 上无法编译 Mac 代码 | 推荐在 Mac 上直接运行 Claude Code，边写边编译测试 |

## 5. 进度（2026-10-14）

阶段 1、4 已在 Windows 上完成，未提交。Windows：原生 ctest 59/59、`flutter test` 457/457 通过；Debug 版实测重新生成抠像缓存、宠物显示正常。

阶段 1 落地：
- `native/native_path/`：`native_path::Path`（即 `std::filesystem::path`）、`Open()`（Windows `_wfopen_s` / 其他 `fopen`）、`Remove()`。
- pcmat / frame_source / prepare_queue / mf_decode 的路径参数全部改为 `native_path::Path`；`pet_matte_prepare` 的参数类型是 `pet_matte_char`（Windows `wchar_t`，其他 `char`）。
- `native/CMakeLists.txt` 只在 WIN32 下构建 mf_decode。Mac 上 ctest 需要先接上 avf_decode（阶段 2），pet_matte 才能链接。

阶段 4 落地（阶段 5 的 Swift 侧要按这个约定实现）：
- `NativeWindow.find(title)`：Windows 返回 `Win32Window`，macOS 返回 `MacWindow`。坐标统一为**逻辑像素、主屏左上角为原点**。
- `MacWindow` 走 MethodChannel `aipet/native_window`，三个方法，参数都带 `title`，不等待返回：
  - `moveTo {title, x, y}`：移动，不激活、不改层级
  - `setRect {title, x, y, width, height}`：移动并改大小，不激活
  - `showAt {title, x, y}`：显示在最前（置顶），不激活应用
  Swift 侧：按 `title` 在 `NSApp.windows` 里找窗口；y 轴翻转用主屏高度（`NSScreen.screens[0].frame.maxY - y - height`）；每个引擎（宠物窗口、面板、宠物库）都要注册这个 channel。
- 拖拽：macOS 用 `AppKitDragger`（`windowManager.startDragging()`，即 `NSWindow.performDrag`）。需要真机确认它在松开鼠标后才返回；若立即返回，宠物会在拖动中恢复散步。
- 语音：macOS 用 `AfplayVoicePlayer`（`/usr/bin/afplay`）。
- 数据目录 `~/Library/Application Support/com.aipet/aipet`；内置宠物在 `.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/pets`。
- 托盘图标 macOS 用 `assets/tray.png`（44×44，彩色，非模板图）。
- 上报的系统名：macOS 为 `macOS <版本>`。

### 2026-10-16 新增，Mac 侧要补的
- **悬浮面板**：`HudPresenter` 在隐藏前用 `screen_retriever.getCursorScreenPoint()` 确认指针是否还在「宠物窗口 ∪ 面板」里（面板窗口在 Mac 上不是 key window，收不到 mouse-entered）。真机确认从宠物移到面板再点按钮不会消失。
- **开机启动**：`launch_at_startup` 在 macOS 走 MethodChannel `launch_at_startup`（`launchAtStartupIsEnabled` / `launchAtStartupSetEnabled`），需要按该包 README 在 `MainFlutterWindow.swift` 里用 `LaunchAtLogin`（Swift Package）实现。没实现时 `Autostart` 只记日志、不影响运行。
- **快速隐藏快捷键**：`hotkey_manager`，Control+Option+H（Command+Option+H 是系统的「隐藏其他」）。真机确认注册成功、后台时也能触发。
- 托盘菜单新增「隐藏宠物 / 显示宠物」「开机启动（勾选）」；右键菜单新增「隐藏」。

## 6. 建议的执行方式
阶段 1、4 在 Windows 上完成并提交（两边测试都要绿）；阶段 0、2、3、5、6 在 Mac 上用 Claude Code 完成。
