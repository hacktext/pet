# 子项目 A：主窗口 + 宠物库 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建正式应用 `apps/aipet`：透明置顶的宠物窗 + 宠物广场主窗口 + 托盘；3 只系统宠物（金毛、柯基、布偶猫）× 5 个动作可领养、切换；抠像不再卡住平台线程。

**Architecture:** 一个进程两个 Flutter 引擎。宠物窗是主引擎（`window_manager` 负责透明/置顶/拖动，`alpha_video` 播放），主窗口是 `desktop_multi_window` 子窗口，两者经 `WindowMethodChannel('aipet/pet')` 交换小消息；`settings.json` 只由宠物窗读写。原生侧新增 `native/prepare_queue`（单工作线程 + 同目标合并 + 结果经消息窗口回平台线程），插件接入它。系统宠物素材由仓库内 `tools/petgen/`（Python）按 spike 验证过的配方生产，打进安装包。

**Tech Stack:** Flutter 3.47.2 / Dart 3.13.2、desktop_multi_window ≥0.3.1、window_manager、tray_manager ^0.5.3、crypto、C++17 + GoogleTest v1.15.2、Python 3.14 + rembg 2.0.84（BiRefNet-lite）+ numpy + pytest、可灵开放平台 API、Git LFS

**Spec:** `docs/superpowers/specs/2026-09-10-main-window-pet-library-design.md`（上位：`docs/superpowers/specs/2026-09-02-desktop-pet-design.md`）

## Global Constraints

- 只做 Windows。仓库根 `C:\Users\Administrator\code\aipet`。
- Flutter 不在 PATH：每个 PowerShell 会话先执行 `$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"`。
- CMake：`$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"`；`ctest.exe` 在同目录。原生构建目录 `native\build`。
- 原生代码 C++17，MSVC 必须带 `/utf-8`（`native/CMakeLists.txt` 已全局加；插件 CMake 另有一份）。
- `.ps1` 文件只写 ASCII（PowerShell 5.1 按 GBK 读无 BOM 文件，中文字面量会损坏）。
- 应用：`apps/aipet`，Dart 包名 `aipet`，org `com.aipet`，窗口标题 `aipet`，主窗口 420×740 逻辑像素。
- 主窗口子窗口的参数字符串固定为 `main_window`；主引擎（宠物窗）的 `arguments` 为空串。
- 通道 `WindowMethodChannel('aipet/pet')`（默认 bidirectional）。方法：`getState` / `adopt` / `stateChanged` / `mainWindowClosing` / `quit`。主窗口请求的确认超时 **3 秒**；`adopt` 总时长上限 **60 秒**。
- 路径：设置 `%APPDATA%\com.aipet\aipet\settings.json`；缓存 `%APPDATA%\com.aipet\aipet\matte-cache\v1\<key>.aipmat`，临时文件在 `matte-cache\v1\.staging\`；定制宠物 `%APPDATA%\com.aipet\aipet\pets\<petId>\`；系统宠物运行时路径 `<exe 目录>\data\flutter_assets\assets\pets\<petId>\`，源码路径 `apps\aipet\assets\pets\<petId>\`。
- `pet.json`：`schema` = 1；`species` ∈ `dog|cat|other`；`origin` ∈ `builtin|custom`；`actions` 必含 `stand`。系统宠物 id：`builtin-gold`、`builtin-corgi`、`builtin-ragdoll`；动作固定 `stand walk sleep lick_paw act_cute`。循环型：`stand walk sleep`，其余一次性（播完回 `stand`）。
- 缓存键：`sha256(源视频内容)` 十六进制前 32 位 + `-` + 管线版本 `p1`。抠像 `targetEdge` = 720。
- 配色：页面 `#FFF8F0`、卡片 `#FFFFFF`、主强调 `#F08A3C`、强调浅底 `#FDEBD9`、主文字 `#3D2B1F`、次文字 `#8A6E5A`。
- 界面文案逐字：`宠物广场` `我的` `全部` `狗狗` `猫猫` `其他小宠` `定制专属宠物` `上传您的爱宠照片，生成桌面伙伴` `立即定制` `即将开放，敬请期待` `带它回家` `换它陪我` `陪伴中` `正在准备…` `素材缺失` `这里还没有小伙伴` `还没有领养小伙伴，去广场看看吧` `退出程序` `切换失败，请重试` `打开宠物库` `退出`。
- 素材（`apps/aipet/assets/pets/**` 下的 mp4/png）走 Git LFS。
- 可灵：密钥只从 `secrets\kling.env` 读，**任何日志都不得打印密钥**；视频只用 `kling-v3` `std` 5 秒，不自动升 `pro`；图片 `kling-v3` 1k。
- 抠像线程：`prepare_queue` 只有**一个**工作线程——`pet_matte_last_error()` 是进程级全局字符串，只有串行调用 `pet_matte_prepare` 时才可靠。
- 真机点击验证（移动用户鼠标）前必须先告知用户并得到同意。
- **与 spec 的有意偏离 1（抠像门槛）**：spec 第 9 节写「漂浮半透明像素 < 911」。该指标把长毛犬的细毛边也算进去（金毛站姿 961 却是合格图）。改用「漂浮像素做一次 3×3 腐蚀后剩下的 blob-core < 200」。标定（800×800 评分）：腊肠绿底直出（不合格）21173；竞品参考帧（合格）62；金毛站姿细毛边 142；其余合格参考图 2–27；运动模糊视频帧（不合格）251。原指标仍打印供参考。
- **与 spec 的有意偏离 2（状态管理）**：不引入 Riverpod。A 只有两个小模型，用 Flutter 自带 `ChangeNotifier` + `ListenableBuilder`；Riverpod 2→3 的 API 迁移（`ChangeNotifierProvider` 挪进 `legacy.dart`）只增加风险。HUD/气泡窗子项目再评估。

---

## File Structure

```
.gitattributes                                  LFS 规则（Task 3）
apps/aipet/                                     flutter create 生成（Task 1）
  pubspec.yaml
  assets/tray.ico
  assets/pets/builtin-{gold,corgi,ragdoll}/     pet.json + 5×mp4 + cover.png（Task 3）
  windows/runner/flutter_window.cpp             子窗口引擎注册插件（Task 1）
  lib/main.dart                                 按窗口参数路由（Task 1 原型 → Task 15 正式）
  lib/domain/pet.dart                           Pet、pet.json 解析、循环策略、中文名（Task 4）
  lib/domain/library_state.dart                 LibraryState、CardStatus、分类筛选（Task 5）
  lib/services/settings_store.dart              settings.json（Task 6）
  lib/services/app_paths.dart                   各目录（Task 7）
  lib/services/pet_library.dart                 扫描宠物文件夹（Task 7）
  lib/services/matte_cache.dart                 内容哈希缓存 + 按需抠像（Task 10）
  lib/services/window_bridge.dart               通道协议两端（Task 11）
  lib/app/pet_window/pet_window_controller.dart 宠物窗逻辑（Task 12）
  lib/app/pet_window/clip_player.dart           AlphaVideo 播放封装（Task 15）
  lib/app/pet_window/pet_window_app.dart        宠物窗 UI、右键菜单、托盘（Task 15）
  lib/app/pet_window/library_launcher.dart      打开/重建主窗口（Task 15）
  lib/app/main_window/theme.dart                配色与主题（Task 13）
  lib/app/main_window/pet_card.dart             卡片五种状态（Task 13）
  lib/app/main_window/main_window_model.dart    主窗口状态（Task 14）
  lib/app/main_window/main_window_app.dart      广场/我的/导航（Task 14）
  lib/app/main_window/main_window_entry.dart    主窗口引擎入口、关闭即隐藏（Task 15）
  test/...                                      与 lib/ 同构
native/prepare_queue/                           抠像任务队列（Task 8）
native/testdata/green_box_long.mp4              慢 prepare 夹具（Task 9）
packages/alpha_video/windows/alpha_video_plugin.{h,cpp}   接入队列（Task 9）
packages/alpha_video/example/integration_test/prepare_async_test.dart（Task 9）
tools/petgen/                                   素材生产（Task 2、3）
tools/dev/windows.ps1                           列窗口 / 按标题发 WM_CLOSE（Task 15）
tools/dev/{shot.ps1,click.ps1}                  DPI 感知截图/点击（Task 16）
docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md   原型与验收记录
```

---

### Task 1: 多窗口原型（`apps/aipet` 骨架）

spec 3.4：`desktop_multi_window` 0.3.1 与 Flutter 3.47 的配合没验证过，业务代码之前先跑通。原型**自动驱动**，结果写日志文件，不需要人点鼠标。

**Files:**
- Create: `apps/aipet/`（`flutter create`）、`apps/aipet/assets/tray.ico`、`docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`
- Modify: `apps/aipet/pubspec.yaml`、`apps/aipet/windows/runner/flutter_window.cpp`、`apps/aipet/lib/main.dart`（原型，Task 15 整体替换）

**Interfaces:**
- Produces: 应用骨架；结果文件中 C1–C9 的结论。**Task 15 按 C6、C7 的结论选分支。**

- [ ] **Step 1: 生成应用并加依赖**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet
flutter create --platforms=windows --org com.aipet --project-name aipet apps\aipet
Set-Location apps\aipet
flutter pub add desktop_multi_window window_manager tray_manager crypto
```

在 `apps/aipet/pubspec.yaml` 的 `dependencies:` 下手动加（不用 `pub add` 的 JSON 写法——PowerShell 5.1 把 `\"` 传给原生程序时会弄坏引号）：

```yaml
  alpha_video:
    path: ../../packages/alpha_video
```

```powershell
flutter pub get
flutter pub deps --style=compact | Select-String "desktop_multi_window|tray_manager|window_manager|alpha_video"
```

Expected：`desktop_multi_window 0.3.1`（或更高）、`alpha_video 0.0.1`。低于 0.3.1 就停下报告。

- [ ] **Step 2: 托盘图标**

```powershell
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
New-Item -ItemType Directory -Force assets | Out-Null
python -c "from PIL import Image, ImageDraw; im=Image.new('RGBA',(64,64),(0,0,0,0)); d=ImageDraw.Draw(im); d.ellipse((4,4,60,60),fill=(240,138,60,255)); im.save('assets/tray.ico',sizes=[(16,16),(32,32),(48,48),(64,64)])"
```

在 `pubspec.yaml` 的 `flutter:` 段加：

```yaml
  assets:
    - assets/tray.ico
```

- [ ] **Step 3: 子窗口引擎注册插件**

`apps/aipet/windows/runner/flutter_window.cpp`：在 `#include "flutter/generated_plugin_registrant.h"` 下一行加

```cpp
#include "desktop_multi_window/desktop_multi_window_plugin.h"
```

把 `OnCreate()` 里的 `RegisterPlugins(flutter_controller_->engine());` 替换为：

```cpp
  RegisterPlugins(flutter_controller_->engine());
  // desktop_multi_window: every sub window is its own engine; register the
  // same plugins there, or its method channels have no native handlers.
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    RegisterPlugins(view_controller->engine());
  });
```

- [ ] **Step 4: 原型 `lib/main.dart`（整体替换）**

```dart
// Task 1 prototype: exercises the multi-window assumptions spec 3.4 lists.
// Replaced wholesale in Task 15. Every finding goes to %TEMP%\aipet_proto.log
// as "[proto] C<n> ..." so the run needs no mouse.
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const kMainWindowArgs = 'main_window';
const kChannel = WindowMethodChannel('aipet/pet');
final bool kAutorun = Platform.environment['AIPET_PROTO_AUTORUN'] == '1';

void protoLog(String line) {
  debugPrint('[proto] $line');
  File('${Directory.systemTemp.path}${Platform.pathSeparator}aipet_proto.log')
      .writeAsStringSync('[proto] $line\n', mode: FileMode.append, flush: true);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await WindowController.fromCurrentEngine();
  protoLog('engine windowId=${self.windowId} arguments="${self.arguments}"');
  if (self.arguments == kMainWindowArgs) {
    await _setUpMainWindowChrome();
    runApp(const ProtoMainWindow());
    return;
  }
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(360, 360),
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(false);
      await windowManager.setPreventClose(true);
      await windowManager.show();
    },
  );
  runApp(const ProtoPetWindow());
}

// C6: does window_manager, called from the sub window's own engine, act on
// the sub window (and not on the pet window)? ASCII title so tools can find it.
Future<void> _setUpMainWindowChrome() async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(420, 740), center: true, title: 'aipet proto main'),
      () async => windowManager.show(),
    );
    protoLog('C6 window_manager in sub window: no exception');
  } catch (e) {
    protoLog('C6 window_manager in sub window threw: $e');
  }
}

class ProtoPetWindow extends StatefulWidget {
  const ProtoPetWindow({super.key});
  @override
  State<ProtoPetWindow> createState() => _ProtoPetWindowState();
}

class _ProtoPetWindowState extends State<ProtoPetWindow> with TrayListener, WindowListener {
  AlphaVideoController? _clip;
  WindowController? _main;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    kChannel.setMethodCallHandler((call) async {
      protoLog('pet got ${call.method}');
      return call.method == 'ping' ? 'pong-from-pet' : null;
    });
    _start();
  }

  Future<void> _start() async {
    final src = '${Directory.current.path}\\..\\..\\native\\testdata\\green_box.mp4';
    final dst = '${Directory.systemTemp.path}\\aipet_proto.aipmat';
    await AlphaVideo.prepare(source: src, destination: dst, targetEdge: 320);
    final c = await AlphaVideoController.open(dst);
    setState(() => _clip = c);
    await c.play(loop: true);
    try {
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: '打开宠物库'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
      protoLog('C2 tray icon + menu set');
    } catch (e) {
      protoLog('C2 tray FAILED: $e');
    }
    if (kAutorun) _autorun();
  }

  Future<List<String>> _ids() async =>
      (await WindowController.getAll()).map((w) => w.windowId).toList();

  Future<void> _openLibrary() async {
    final before = await _ids();
    final alive = _main != null && before.contains(_main!.windowId);
    if (alive) {
      await _main!.show();
      protoLog('C7 re-showed existing main window ${_main!.windowId}');
      return;
    }
    _main = await WindowController.create(
        WindowConfiguration(arguments: kMainWindowArgs, hiddenAtLaunch: false));
    await _main!.show();
    protoLog('C3 created main window ${_main!.windowId} (windows now ${await _ids()})');
  }

  Future<void> _pingMain(String tag) async {
    try {
      final r = await kChannel.invokeMethod<String>('ping').timeout(const Duration(seconds: 3));
      protoLog('$tag pet->main: $r');
    } catch (e) {
      protoLog('$tag pet->main FAILED: $e');
    }
  }

  Future<void> _autorun() async {
    Future<void> at(int s) => Future<void>.delayed(Duration(seconds: s));
    await at(1);
    protoLog('C1 frame after 1s = ${await _clip?.currentFrame()}');
    await _openLibrary();
    await at(3);
    await _pingMain('C5');
    protoLog('C7 windows before external WM_CLOSE: ${await _ids()}');
    await at(8); // tools step 5 posts WM_CLOSE to "aipet proto main" in this gap
    protoLog('C7 windows after external WM_CLOSE: ${await _ids()}');
    await _openLibrary();
    await at(3);
    await _pingMain('C7-reopen');
    await windowManager.hide();
    protoLog('C8 pet window hidden');
    await at(1);
    await _pingMain('C8');
    await windowManager.show();
    await at(1);
    protoLog('C9 quitting');
    await _quit();
  }

  Future<void> _quit() async {
    try {
      await _clip?.dispose();
      await trayManager.destroy();
    } finally {
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() => _openLibrary();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') _openLibrary();
    if (menuItem.key == 'quit') _quit();
  }

  @override
  void onWindowClose() => _quit();

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: GestureDetector(
            onPanStart: (_) => windowManager.startDragging(),
            child: Center(child: _clip == null ? const SizedBox.shrink() : AlphaVideoView(controller: _clip!)),
          ),
        ),
      );
}

class ProtoMainWindow extends StatefulWidget {
  const ProtoMainWindow({super.key});
  @override
  State<ProtoMainWindow> createState() => _ProtoMainWindowState();
}

class _ProtoMainWindowState extends State<ProtoMainWindow> {
  final _lines = <String>[];

  void _add(String s) {
    protoLog(s);
    if (mounted) setState(() => _lines.add(s));
  }

  @override
  void initState() {
    super.initState();
    kChannel.setMethodCallHandler((call) async {
      _add('main got ${call.method}');
      return call.method == 'ping' ? 'pong-from-main' : null;
    });
    if (kAutorun) Future<void>.delayed(const Duration(seconds: 1), _pingPet);
  }

  Future<void> _pingPet() async {
    try {
      final r = await kChannel.invokeMethod<String>('ping').timeout(const Duration(seconds: 3));
      _add('C4 main->pet: $r');
    } catch (e) {
      _add('C4 main->pet FAILED: $e');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('aipet proto main')),
          body: ListView(children: [
            ElevatedButton(onPressed: _pingPet, child: const Text('Ping pet window')),
            for (final l in _lines) Text(l),
          ]),
        ),
      );
}
```

- [ ] **Step 5: 构建并自动运行**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter build windows --debug
Remove-Item "$env:TEMP\aipet_proto.log" -ErrorAction SilentlyContinue
$env:AIPET_PROTO_AUTORUN = '1'
Start-Process .\build\windows\x64\runner\Debug\aipet.exe -WorkingDirectory (Get-Location)
```

紧接着在**另一条命令**里运行下面的脚本（等主窗口出现 → 2 秒后发 `WM_CLOSE`，与点 × 等价）：

```powershell
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
$script:target = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds(30)
while ($script:target -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
  [void][W]::EnumWindows({ param($h, $l)
    $sb = New-Object System.Text.StringBuilder 256
    [void][W]::GetWindowText($h, $sb, 256)
    if ($sb.ToString() -eq 'aipet proto main' -and [W]::IsWindowVisible($h)) { $script:target = $h; return $false }
    return $true }, [IntPtr]::Zero)
  if ($script:target -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 300 }
}
if ($script:target -eq [IntPtr]::Zero) { "main window not found by title (C6 title not applied?)"; exit 1 }
Start-Sleep -Seconds 2
[void][W]::PostMessage($script:target, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
"posted WM_CLOSE to $($script:target)"
```

等 25 秒后收集：

```powershell
Get-Content "$env:TEMP\aipet_proto.log"
Get-Process aipet -ErrorAction SilentlyContinue | Select-Object Id, @{n='WS_MB';e={[int]($_.WorkingSet64/1MB)}}
```

- [ ] **Step 6: 判定并记录**

创建 `docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`，照下表逐项填「结论 / 日志原文」：

| # | 检查 | 通过条件 |
|---|---|---|
| C1 | 主引擎里 alpha_video 播放 | `C1 frame after 1s` 的值 > 0 |
| C2 | 托盘 | `C2 tray icon + menu set`（点击交互留到 Task 16 真机验收） |
| C3 | 建子窗口 | `C3 created main window` |
| C4 | 主窗口 → 宠物窗 | `C4 main->pet: pong-from-pet` |
| C5 | 宠物窗 → 主窗口 | `C5 pet->main: pong-from-main` |
| C6 | 子窗口里 window_manager | `C6 ... no exception`，且脚本按标题找到了窗口（标题生效） |
| C7 | 点 × 后 | 记录 before/after 的窗口 id：**销毁**（after 少了主窗口 id）还是**隐藏**（id 还在）；`C7-reopen pet->main: pong-from-main` 表示重开后通道仍通 |
| C8 | 宠物窗隐藏时通道 | `C8 pet->main: pong-from-main` |
| C9 | 退出 | `C9 quitting` 之后 `Get-Process aipet` 为空 |

**判定规则**：C1、C3、C4、C5 任一不过 → **停止执行本计划**，把日志和结果文件交给用户，重新讨论方案（spec 3.4 的候选：主窗口做成宠物窗引擎里的第二个原生窗口）。C6、C7 的结论决定 Task 13、15 走哪个分支，必须写清楚。

- [ ] **Step 7: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md
git commit -m "feat(aipet): multi-window prototype (pet window primary, main window sub window, tray)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 2: `tools/petgen` 素材库（门槛、循环检查、抠图合成、可灵客户端、提示词）

把 spike 临时目录里的脚本整理成可测的 Python 包。纯函数全部 pytest 覆盖；抠图和可灵调用是薄 IO 层，Task 3 实跑验证。

**Files:**
- Create: `tools/petgen/requirements.txt`、`tools/petgen/requirements-dev.txt`、`tools/petgen/pytest.ini`、`tools/petgen/.gitignore`
- Create: `tools/petgen/petgen/__init__.py`、`keycheck.py`、`edges.py`、`loopcheck.py`、`compose.py`、`kling.py`、`prompts.py`
- Test: `tools/petgen/tests/test_keycheck.py`、`test_edges.py`、`test_loopcheck.py`、`test_calibration.py`、`test_prompts.py`

**Interfaces:**
- Produces（Task 3 使用）:
  - `keycheck.score_file(path: Path) -> Score`；`Score.floating: int`、`Score.blob_core: int`、`Score.passed: bool`（`blob_core < 200`）
  - `edges.subject_bbox(alpha: np.ndarray, threshold=10) -> tuple[int,int,int,int]`（x0, x1, y0, y1，右/下开区间）；`edges.edge_touches(alpha, *, threshold=10, margin=2) -> list[str]`（取值 `left/top/right/bottom`）
  - `loopcheck.probe(video: Path) -> dict`（`width`、`height`、`fps`、`frames`）；`loopcheck.psnr_series(video, workdir) -> (vs_first, consecutive)`；`loopcheck.seam_verdict(vs_first, consecutive) -> (ok, seam, worst_step)`
  - `compose.compose(src: Path, out_dir: Path, stem: str) -> ComposeResult`，写 `<stem>-green.png`（1024 方图，#00FF00 底）和 `<stem>-cutout.png`（裁到主体的 RGBA）；主体碰边抛 `EdgeError`
  - `kling.create_image(body) / create_video(body) -> task_id`、`kling.wait(kind, task_id) -> dict`、`kling.download(url, dest)`、`kling.balance() -> list[dict]`、`kling.b64(path)`
  - `prompts.PETS`、`prompts.source_prompt(pet)`、`prompts.pose_prompt(pet, pose)`、`prompts.action_prompt(pet, action)`、`prompts.REF_POSE_FOR_ACTION`、`prompts.POSE_ASPECT`

- [ ] **Step 1: 包骨架与环境**

`tools/petgen/requirements.txt`：

```
rembg[cpu]==2.0.84
numpy
pillow
```

`tools/petgen/requirements-dev.txt`：

```
-r requirements.txt
pytest
```

`tools/petgen/pytest.ini`：

```ini
[pytest]
pythonpath = .
testpaths = tests
```

`tools/petgen/.gitignore`：

```
.venv/
work/
__pycache__/
```

`tools/petgen/petgen/__init__.py`：

```python
"""Built-in pet asset production (sub-project A, spec section 9)."""
```

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
python -m venv .venv
.\.venv\Scripts\python -m pip install --disable-pip-version-check -q -r requirements-dev.txt
# Reuse the BiRefNet-lite model the spike already downloaded (224 MB) if it is still there.
$spike = "C:\Users\Administrator\AppData\Local\Temp\claude\c--Users-Administrator-code-aipet\4fbc451a-51c9-48a5-9f6b-54b7e4f439b7\scratchpad\u2net"
if (Test-Path $spike) { New-Item -ItemType Directory -Force work | Out-Null; Copy-Item $spike work\u2net -Recurse -Force }
```

- [ ] **Step 2: 写失败的测试**

`tools/petgen/tests/test_keycheck.py`：

```python
import numpy as np

from petgen.keycheck import BLOB_CORE_MAX, Score, alpha_map, blob_core_mask, floating_mask


def rgb(color, h=4, w=4):
    return np.full((h, w, 3), color, dtype=np.uint8)


def test_pure_green_is_fully_transparent():
    assert (alpha_map(rgb((0, 255, 0))) == 0).all()


def test_red_is_fully_opaque():
    assert (alpha_map(rgb((255, 0, 0))) == 255).all()


def test_greenish_grey_is_partial():
    a = int(alpha_map(rgb((60, 150, 60)))[0, 0])
    assert 0 < a < 255


def test_isolated_blob_floats_and_keeps_a_core():
    a = np.zeros((40, 40), np.uint8)
    a[10:15, 10:15] = 128
    fl = floating_mask(a)
    assert fl.sum() == 25
    assert blob_core_mask(fl).sum() == 9


def test_thin_fringe_line_floats_but_has_no_core():
    a = np.zeros((40, 40), np.uint8)
    a[20, 5:25] = 128
    fl = floating_mask(a)
    assert fl.sum() == 20
    assert blob_core_mask(fl).sum() == 0


def test_partial_pixel_next_to_opaque_is_not_floating():
    a = np.zeros((40, 40), np.uint8)
    a[30:36, 30:36] = 255
    a[30, 28] = 128
    assert not floating_mask(a)[30, 28]


def test_pass_threshold_is_strict():
    assert Score(floating=5000, blob_core=BLOB_CORE_MAX - 1).passed
    assert not Score(floating=0, blob_core=BLOB_CORE_MAX).passed
```

`tools/petgen/tests/test_edges.py`：

```python
import numpy as np
import pytest

from petgen.edges import edge_touches, subject_bbox


def alpha_with(y0, y1, x0, x1, h=100, w=100):
    a = np.zeros((h, w), np.uint8)
    a[y0:y1, x0:x1] = 255
    return a


def test_bbox_is_half_open():
    assert subject_bbox(alpha_with(10, 20, 30, 40)) == (30, 40, 10, 20)


def test_centered_subject_touches_nothing():
    assert edge_touches(alpha_with(10, 90, 10, 90)) == []


def test_subject_on_left_edge():
    assert edge_touches(alpha_with(10, 90, 0, 50)) == ["left"]


def test_margin_counts_as_touching():
    assert edge_touches(alpha_with(10, 90, 2, 50), margin=2) == ["left"]
    assert edge_touches(alpha_with(10, 90, 3, 50), margin=2) == []


def test_bottom_right_corner():
    assert edge_touches(alpha_with(50, 100, 50, 100)) == ["right", "bottom"]


def test_faint_pixels_below_threshold_are_ignored():
    a = alpha_with(40, 60, 40, 60)
    a[0, :] = 5
    assert edge_touches(a) == []


def test_empty_alpha_raises():
    with pytest.raises(ValueError):
        edge_touches(np.zeros((10, 10), np.uint8))
```

`tools/petgen/tests/test_loopcheck.py`：

```python
import subprocess

from petgen.loopcheck import probe, psnr_series, seam_verdict


def test_seam_inside_normal_motion_is_ok():
    ok, seam, worst = seam_verdict([48.0, 40.0, 47.4], [55.8, 39.1, 60.0])
    assert ok and seam == 47.4 and worst == 39.1


def test_seam_below_every_step_is_visible():
    ok, _, _ = seam_verdict([48.0, 20.0, 11.5], [55.0, 35.8, 60.0])
    assert not ok


def make_static_video(path):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=red:s=32x32:d=1:r=10",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path)], check=True)


def test_probe_reads_format(tmp_path):
    v = tmp_path / "static.mp4"
    make_static_video(v)
    assert probe(v) == {"width": 32, "height": 32, "fps": "10/1", "frames": 10}


def test_static_video_loops_perfectly(tmp_path):
    v = tmp_path / "static.mp4"
    make_static_video(v)
    vs_first, consecutive = psnr_series(v, tmp_path / "psnr")
    assert len(vs_first) == 10 and len(consecutive) == 9
    assert seam_verdict(vs_first, consecutive)[0]
```

`tools/petgen/tests/test_calibration.py`（把门槛钉在已知结论的图上；spike 临时目录不在时跳过）：

```python
from pathlib import Path

import pytest

from petgen.keycheck import score_file

SPIKE_OUT = Path(r"C:\Users\Administrator\AppData\Local\Temp\claude\c--Users-Administrator-code-aipet"
                 r"\4fbc451a-51c9-48a5-9f6b-54b7e4f439b7\scratchpad\out")
CASES = [
    ("ref-0-crop800.png", False),         # dachshund generated straight on green: spill + shadow
    ("comp800.png", True),                # competitor reference frame
    ("ref-gold-stand-green.png", True),   # golden retriever: thin fur fringe only
    ("walkf100.png", False),              # motion-blurred video frame
]


@pytest.mark.parametrize("name,expected", CASES)
def test_gate_matches_known_verdict(name, expected):
    p = SPIKE_OUT / name
    if not p.exists():
        pytest.skip(f"spike artefact {p} is gone")
    assert score_file(p).passed is expected
```

`tools/petgen/tests/test_prompts.py`：

```python
import pytest

from petgen.prompts import PETS, POSE_ASPECT, REF_POSE_FOR_ACTION, action_prompt, pose_prompt, source_prompt

ACTIONS = ["stand", "walk", "sleep", "lick_paw", "act_cute"]


def test_three_pets_with_pet_json_fields():
    assert set(PETS) == {"gold", "corgi", "ragdoll"}
    for p in PETS.values():
        assert p["species"] in {"dog", "cat"} and p["name"] and p["blurb"] and p["breed"] and p["features"]


def test_every_action_maps_to_a_reference_pose():
    assert set(REF_POSE_FOR_ACTION) == set(ACTIONS)
    assert set(REF_POSE_FOR_ACTION.values()) <= set(POSE_ASPECT)


@pytest.mark.parametrize("pet", ["gold", "corgi", "ragdoll"])
@pytest.mark.parametrize("action", ACTIONS)
def test_action_prompts_pin_camera_and_background(pet, action):
    text = action_prompt(pet, action)
    assert "镜头完全固定" in text and "纯绿色" in text


def test_breed_and_features_reach_every_prompt():
    for pet, p in PETS.items():
        assert p["breed"] in source_prompt(pet)
        assert p["features"] in pose_prompt(pet, "stand")


def test_cats_and_dogs_act_cute_differently():
    dog = action_prompt("gold", "act_cute").replace(PETS["gold"]["breed"], "X")
    cat = action_prompt("ragdoll", "act_cute").replace(PETS["ragdoll"]["breed"], "X")
    assert dog != cat
```

- [ ] **Step 3: 运行，确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest -q
```

Expected：全部因 `ModuleNotFoundError: No module named 'petgen.keycheck'`（等）失败。

- [ ] **Step 4: 实现 `keycheck.py`**

```python
"""pet_matte's chroma key replicated with numpy, and the reference-still gate.

Mirrors native/matte_core/src/chroma_key.cpp with its KeyParams defaults.
Scores are taken at SCORE_EDGE x SCORE_EDGE so numbers compare across sizes.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

KEY_CB, KEY_CR, INNER_T, OUTER_T = -0.331, -0.419, 0.28, 0.45
SCORE_EDGE = 800
BLOB_CORE_MAX = 200  # calibrated, see the plan's Global Constraints
FLOATING_REF = 911   # competitor reference frame; context only


def alpha_map(rgb: np.ndarray) -> np.ndarray:
    """uint8 HxWx3 RGB -> uint8 HxW alpha, as pet_matte would key it."""
    f = rgb.astype(np.float32) / 255.0
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    cb = -0.168736 * r - 0.331264 * g + 0.5 * b
    cr = 0.5 * r - 0.418688 * g - 0.081312 * b
    d = np.sqrt((cb - KEY_CB) ** 2 + (cr - KEY_CR) ** 2)
    a = np.clip((d - INNER_T) / (OUTER_T - INNER_T), 0.0, 1.0)
    return (a * 255.0 + 0.5).astype(np.uint8)


def _shift(m: np.ndarray, dy: int, dx: int) -> np.ndarray:
    """out[y, x] = m[y + dy, x + dx]; zero where that falls outside m."""
    out = np.zeros_like(m)
    h, w = m.shape
    src_y, dst_y = slice(max(dy, 0), h + min(dy, 0)), slice(max(-dy, 0), h + min(-dy, 0))
    src_x, dst_x = slice(max(dx, 0), w + min(dx, 0)), slice(max(-dx, 0), w + min(-dx, 0))
    out[dst_y, dst_x] = m[src_y, src_x]
    return out


def floating_mask(alpha: np.ndarray) -> np.ndarray:
    """Partial-alpha pixels with no opaque pixel on the {-2,0,2}^2 grid around
    them: shadow/spill leftovers, and also wispy fur fringe."""
    partial = (alpha > 0) & (alpha < 255)
    opaque = alpha == 255
    near = np.zeros_like(opaque)
    for dy in (-2, 0, 2):
        for dx in (-2, 0, 2):
            near |= _shift(opaque, dy, dx)
    m = partial & ~near
    m[:2, :] = False
    m[-2:, :] = False
    m[:, :2] = False
    m[:, -2:] = False
    return m


def blob_core_mask(floating: np.ndarray) -> np.ndarray:
    """3x3 erosion of the floating mask: 1-2 px fur fringe disappears,
    shadow and spill blobs keep a core."""
    core = floating.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            core &= _shift(floating, dy, dx)
    return core


@dataclass(frozen=True)
class Score:
    floating: int
    blob_core: int

    @property
    def passed(self) -> bool:
        return self.blob_core < BLOB_CORE_MAX


def score_rgb(rgb: np.ndarray) -> Score:
    fl = floating_mask(alpha_map(rgb))
    return Score(int(fl.sum()), int(blob_core_mask(fl).sum()))


def score_file(path: Path) -> Score:
    im = Image.open(path).convert("RGB").resize((SCORE_EDGE, SCORE_EDGE), Image.BILINEAR)
    return score_rgb(np.asarray(im))
```

- [ ] **Step 5: 实现 `edges.py`**

```python
"""Did the frame cut the subject off? Judged on the segmentation alpha --
a colour heuristic reads any mid-grey backdrop as foreground (spike lesson)."""
from __future__ import annotations

import numpy as np


def subject_bbox(alpha: np.ndarray, threshold: int = 10) -> tuple[int, int, int, int]:
    ys, xs = np.nonzero(alpha > threshold)
    if len(xs) == 0:
        raise ValueError("segmentation found no subject")
    return int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1


def edge_touches(alpha: np.ndarray, *, threshold: int = 10, margin: int = 2) -> list[str]:
    x0, x1, y0, y1 = subject_bbox(alpha, threshold)
    h, w = alpha.shape
    hits = [("left", x0 <= margin), ("top", y0 <= margin),
            ("right", x1 >= w - margin), ("bottom", y1 >= h - margin)]
    return [side for side, hit in hits if hit]
```

- [ ] **Step 6: 实现 `loopcheck.py`**

```python
"""Clip format and loop-seam checks (ffmpeg / ffprobe must be on PATH)."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


def probe(video: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate,nb_frames", "-of", "json", str(video)],
        check=True, capture_output=True, text=True).stdout
    s = json.loads(out)["streams"][0]
    return {"width": int(s["width"]), "height": int(s["height"]),
            "fps": s["r_frame_rate"], "frames": int(s["nb_frames"])}


def _psnr_avgs(stats: Path) -> list[float]:
    vals = []
    for line in stats.read_text(encoding="utf-8").splitlines():
        m = re.search(r"psnr_avg:(\S+)", line)
        if m:
            vals.append(99.0 if m.group(1) == "inf" else float(m.group(1)))
    return vals


def psnr_series(video: Path, workdir: Path) -> tuple[list[float], list[float]]:
    """Per-frame PSNR against frame 0, and between consecutive frames.

    ffmpeg runs with cwd=workdir and relative stats-file names: a Windows
    path's drive colon would break the filtergraph syntax."""
    workdir.mkdir(parents=True, exist_ok=True)
    video = Path(video).resolve()

    def run(args: list[str]) -> None:
        subprocess.run(["ffmpeg", "-v", "error", *args], check=True, cwd=workdir)

    run(["-y", "-i", str(video), "-frames:v", "1", "f0.png"])
    run(["-i", str(video), "-loop", "1", "-i", "f0.png", "-filter_complex",
         "[1:v]format=yuv420p[r];[0:v]format=yuv420p[m];[m][r]psnr=stats_file=vs_f0.log:shortest=1",
         "-f", "null", "-"])
    run(["-i", str(video), "-filter_complex",
         "[0:v]split[a][b];[b]trim=start_frame=1,setpts=PTS-STARTPTS[b1];[a][b1]psnr=stats_file=consec.log:shortest=1",
         "-f", "null", "-"])
    return _psnr_avgs(workdir / "vs_f0.log"), _psnr_avgs(workdir / "consec.log")


def seam_verdict(vs_first: list[float], consecutive: list[float]) -> tuple[bool, float, float]:
    """A loop's seam (last -> first) is invisible when it is no bigger a jump
    than the largest step the clip already makes between neighbouring frames."""
    seam, worst = vs_first[-1], min(consecutive)
    return seam >= worst, seam, worst
```

- [ ] **Step 7: 实现 `prompts.py`**

```python
"""Built-in pets and every prompt used to make them (recipe from the M2 spike)."""
from __future__ import annotations

PETS = {
    "gold": {"species": "dog", "name": "金毛", "blurb": "温柔的大暖男，走到哪跟到哪",
             "breed": "金毛寻回犬",
             "features": "毛色是均匀的金黄色，胸前、腿后和尾巴上有长长的饰毛，耳朵下垂，表情温和"},
    "corgi": {"species": "dog", "name": "柯基", "blurb": "小短腿大耳朵，家里的开心果",
              "breed": "彭布罗克威尔士柯基犬",
              "features": "橘黄色和白色相间，白色的口鼻、脖子和胸口，一对大耳朵直立，四肢很短"},
    "ragdoll": {"species": "cat", "name": "布偶猫", "blurb": "蓝眼睛的小仙女，安静又粘人",
                "breed": "布偶猫",
                "features": "蓝色的眼睛，脸、耳朵和尾巴是深棕色的重点色，身体是奶白色的蓬松长毛"},
}

POSES = {
    "stand": "站立姿势，身体侧对镜头四分之三角度，头部、四条腿和尾巴全部完整入画，脚掌贴地。",
    "walk": ("正在走路的姿势，身体完全侧对镜头，一只前腿和对侧的后腿向前迈出，另外两条腿在后，"
             "四个脚掌都贴着地面，尾巴自然放松，从头到尾巴、四条腿全部完整入画。"),
    "lie": ("趴卧着睡觉的姿势，身体侧对镜头，四肢收在身下，下巴枕在前爪上，眼睛闭着，"
            "尾巴自然地弯过来收在身体旁边，不向外伸展，从头到尾巴完整入画。"),
}
# 1:1 and 16:9 let long bodies' tails touch the frame; lying needs 21:9 (spike).
POSE_ASPECT = {"stand": "16:9", "walk": "16:9", "lie": "21:9"}

# Stand-based one-shots start and end standing, so they hand back to idle
# seamlessly; walk needs a mid-stride still (a standing still gives
# stand -> walk -> stand); sleep needs the lying still.
REF_POSE_FOR_ACTION = {"stand": "stand", "lick_paw": "stand", "act_cute": "stand",
                       "walk": "walk", "sleep": "lie"}

_TAIL = "镜头完全固定，不推拉不摇移。背景始终是均匀的纯绿色，没有影子，没有地面。"
_ACTIONS = {
    "stand": ("{it}原地安静站立。整个五秒里一直有细微、连续的自然动作：胸口随呼吸缓慢起伏，"
              "耳朵偶尔轻轻抖动，尾巴慢慢小幅摆动，眨一两次眼。"
              "身体朝向和在画面中的位置全程保持不变，不走动，不转身，不坐下，不低头。"),
    "walk": ("{it}原地踏步行走，像在跑步机上一样，四条腿自然交替迈步，"
             "身体始终保持在画面中的同一位置，不向前移动，不转身。头随步伐轻轻晃动，尾巴轻摆。"),
    "sleep": "{it}趴着安静地睡觉，眼睛一直闭着，身体随呼吸缓慢起伏，耳朵偶尔轻轻抖一下。姿态和位置全程不变，不起身。",
    "lick_paw": ("{it}原地站着，低下头舔了几下自己的一只前爪，"
                 "然后抬起头，慢慢恢复到原来的站姿和朝向。身体位置全程不变，不走动。"),
}
_ACT_CUTE = {
    "dog": "{it}原地站着，开心地歪了歪头，尾巴快速摇了几下，然后恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
    "cat": "{it}原地站着，歪头眨了眨眼，抬起一只前爪轻轻挥了挥，然后放下前爪恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
}


def _it(pet: str) -> str:
    return f"这只{PETS[pet]['breed']}"


def source_prompt(pet: str) -> str:
    p = PETS[pet]
    return (f"一只{p['breed']}的写实摄影照片。{p['features']}。"
            "身体侧对镜头四分之三角度站立，从头到尾巴、四条腿全部完整入画。"
            "浅灰色无缝影棚背景，柔和的漫射光，毛发细节清晰锐利，画面里只有这一只动物。")


def pose_prompt(pet: str, pose: str) -> str:
    p = PETS[pet]
    return (f"参考图中这只{p['breed']}的全身照片，保持它的脸、毛色和花纹完全一样。{p['features']}。"
            + POSES[pose] +
            "它只占画面中间大约一半的宽度，四周留出大片空白，尾巴尖离画面边缘很远。"
            "背景是浅灰色的无缝影棚背景纸，颜色均匀中性，没有任何物体，画面没有边框。"
            "柔和的大面积漫射光，几乎没有投影，身下没有明显的影子。"
            "写实摄影，毛发细节清晰锐利，画面里只有这一只动物。")


def action_prompt(pet: str, action: str) -> str:
    template = _ACT_CUTE[PETS[pet]["species"]] if action == "act_cute" else _ACTIONS[action]
    return template.format(it=_it(pet)) + _TAIL
```

- [ ] **Step 8: 实现 `compose.py`**

```python
"""Segment the animal off its neutral backdrop and composite it onto exact
#00FF00. Spike lesson: generating straight on green paints green bounce light
onto the fur, which pet_matte then keys as semi-transparent."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from petgen.edges import edge_touches, subject_bbox

MODEL = "birefnet-general-lite"
EDGE = 1024
FILL = 0.78
KEY = np.array([0, 255, 0], dtype=np.float32)
_sessions: dict = {}


class EdgeError(Exception):
    def __init__(self, sides: list[str]):
        super().__init__(f"subject touches {sides}: the frame cut it off")
        self.sides = sides


@dataclass(frozen=True)
class ComposeResult:
    green: Path
    cutout: Path
    bbox: tuple[int, int, int, int]


def _segment(src: Path) -> np.ndarray:
    from rembg import new_session, remove  # heavy import, only when composing

    if MODEL not in _sessions:
        _sessions[MODEL] = new_session(MODEL)
    # alpha matting re-solves the mask's unknown band as a soft matte: it keeps
    # wispy tail fur the plain segmenter drops (spike: lite+matting beat the
    # full 973 MB model without matting).
    rgba = remove(Image.open(src).convert("RGB"), session=_sessions[MODEL],
                  alpha_matting=True, alpha_matting_foreground_threshold=240,
                  alpha_matting_background_threshold=10, alpha_matting_erode_size=10)
    return np.asarray(rgba, dtype=np.float32)


def compose(src: Path, out_dir: Path, stem: str) -> ComposeResult:
    arr = _segment(src)
    alpha_u8 = arr[..., 3].astype(np.uint8)
    sides = edge_touches(alpha_u8)
    if sides:
        raise EdgeError(sides)
    x0, x1, y0, y1 = subject_bbox(alpha_u8)
    out_dir.mkdir(parents=True, exist_ok=True)

    cut = Image.fromarray(arr[y0:y1, x0:x1].astype(np.uint8), "RGBA")
    cutout = out_dir / f"{stem}-cutout.png"
    cut.save(cutout)

    scale = FILL * EDGE / max(x1 - x0, y1 - y0)
    cut = cut.resize((round((x1 - x0) * scale), round((y1 - y0) * scale)), Image.LANCZOS)
    canvas = np.zeros((EDGE, EDGE, 4), dtype=np.float32)
    ox, oy = (EDGE - cut.width) // 2, (EDGE - cut.height) // 2
    canvas[oy:oy + cut.height, ox:ox + cut.width] = np.asarray(cut, dtype=np.float32)
    a = canvas[..., 3:] / 255.0
    # Soft fur edges blend into key green, exactly like a real screen edge.
    out = canvas[..., :3] * a + KEY * (1.0 - a)
    green = out_dir / f"{stem}-green.png"
    Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGB").save(green)
    return ComposeResult(green, cutout, (x0, x1, y0, y1))
```

- [ ] **Step 9: 实现 `kling.py`**

```python
"""Minimal Kling open-platform client. Reads secrets/kling.env; never prints the key."""
from __future__ import annotations

import base64
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ENV = REPO / "secrets" / "kling.env"
_PATHS = {"image": "/v1/images/generations", "video": "/v1/videos/image2video"}


class KlingError(Exception):
    pass


def _cfg() -> tuple[str, str]:
    kv = {}
    for line in ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    return kv["KLING_API_KEY"], kv["KLING_BASE_URL"].rstrip("/")


def _call(method: str, path: str, body: dict | None = None) -> dict:
    key, base = _cfg()
    req = urllib.request.Request(base + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode("utf-8", "replace") or "{}")


def b64(path: Path) -> str:
    return base64.b64encode(Path(path).read_bytes()).decode("ascii")


def _create(kind: str, body: dict) -> str:
    res = _call("POST", _PATHS[kind], body)
    if res.get("code") != 0:  # a rejected create is never charged
        raise KlingError(f"create {kind} failed: code={res.get('code')} {res.get('message')}")
    return res["data"]["task_id"]


def create_image(body: dict) -> str:
    return _create("image", body)


def create_video(body: dict) -> str:
    return _create("video", body)


def wait(kind: str, task_id: str, every: float = 8.0, limit: int = 120) -> dict:
    for _ in range(limit):
        d = _call("GET", f"{_PATHS[kind]}/{task_id}").get("data") or {}
        if d.get("task_status") == "succeed":
            return d
        if d.get("task_status") == "failed":
            raise KlingError(f"{kind} task {task_id} failed: {d.get('task_status_msg')}")
        time.sleep(every)
    raise KlingError(f"{kind} task {task_id} still running after {every * limit:.0f}s")


def download(url: str, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=300) as r:
        dest.write_bytes(r.read())
    return dest


def balance() -> list[dict]:
    now = int(time.time() * 1000)
    res = _call("GET", f"/account/costs?start_time={now - 90 * 86400 * 1000}&end_time={now}")
    return (res.get("data") or {}).get("resource_pack_subscribe_infos", [])
```

- [ ] **Step 10: 运行，确认通过**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest -q
```

Expected：全部通过（spike 临时目录已清掉时 `test_calibration` 显示 skipped，这是允许的）。

- [ ] **Step 11: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add tools/petgen
git commit -m "feat(petgen): gate, loop check, compose, Kling client and prompts for built-in pets" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: 生产 3 只系统宠物的素材

spike 期间 9 张姿态参考图已经生成并付过费（在 spike 临时目录里），先导入复用；只有缺失或过不了门槛的才重新生成。视频 15 个 × 3 单位 = 45 视频单位。**布偶猫先做**（spec 第 10 节：猫的管线风险最大）。

**Files:**
- Create: `tools/petgen/petgen/package.py`、`tools/petgen/petgen/__main__.py`、`tools/petgen/tests/test_package.py`、`.gitattributes`
- Create: `apps/aipet/assets/pets/builtin-{gold,corgi,ragdoll}/{pet.json,cover.png,stand.mp4,walk.mp4,sleep.mp4,lick_paw.mp4,act_cute.mp4}`
- Modify: `apps/aipet/pubspec.yaml`（assets）、`docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`

**Interfaces:**
- Consumes: Task 2 的 `keycheck`、`loopcheck`、`compose`、`kling`、`prompts`。
- Produces: 三个宠物文件夹，格式见 spec 4.1；Task 7 的 `PetLibrary` 和 Task 16 的真机验收读取它们。

- [ ] **Step 1: 写失败的测试**

`tools/petgen/tests/test_package.py`：

```python
from PIL import Image

from petgen.package import COVER_MAX, make_cover, pet_json


def test_pet_json_matches_spec_schema():
    j = pet_json("ragdoll")
    assert j == {
        "schema": 1, "id": "builtin-ragdoll", "name": "布偶猫", "species": "cat",
        "origin": "builtin", "blurb": "蓝眼睛的小仙女，安静又粘人", "cover": "cover.png",
        "actions": ["stand", "walk", "sleep", "lick_paw", "act_cute"],
    }


def test_cover_is_bounded_and_keeps_a_transparent_margin():
    cut = Image.new("RGBA", (1200, 600), (200, 120, 60, 255))
    cover = make_cover(cut)
    assert max(cover.size) == COVER_MAX
    assert cover.mode == "RGBA"
    assert cover.getpixel((0, 0))[3] == 0                         # margin is transparent
    assert cover.getpixel((cover.width // 2, cover.height // 2))[3] == 255


def test_small_cutout_is_not_upscaled_past_its_padding():
    cover = make_cover(Image.new("RGBA", (100, 50), (0, 0, 0, 255)))
    assert max(cover.size) <= COVER_MAX and max(cover.size) >= 100
```

- [ ] **Step 2: 运行，确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest -q tests/test_package.py
```

Expected：`ModuleNotFoundError: No module named 'petgen.package'`。

- [ ] **Step 3: 实现 `package.py`**

```python
"""pet.json and cover.png for a built-in pet folder (spec 4.1)."""
from __future__ import annotations

from PIL import Image

from petgen.prompts import PETS

ACTIONS = ["stand", "walk", "sleep", "lick_paw", "act_cute"]
COVER_MAX = 512
COVER_PAD = 0.06


def pet_json(pet: str) -> dict:
    p = PETS[pet]
    return {"schema": 1, "id": f"builtin-{pet}", "name": p["name"], "species": p["species"],
            "origin": "builtin", "blurb": p["blurb"], "cover": "cover.png", "actions": list(ACTIONS)}


def make_cover(cutout: Image.Image) -> Image.Image:
    """Transparent-padded, at most COVER_MAX on its long side. The cutout comes
    from the segmentation (not the green composite), so no key-green fringe."""
    pad = round(max(cutout.size) * COVER_PAD)
    canvas = Image.new("RGBA", (cutout.width + 2 * pad, cutout.height + 2 * pad), (0, 0, 0, 0))
    canvas.paste(cutout, (pad, pad))
    canvas.thumbnail((COVER_MAX, COVER_MAX), Image.LANCZOS)
    return canvas
```

- [ ] **Step 4: 实现命令行 `petgen/__main__.py`**

```python
"""python -m petgen <command>   (run from tools/petgen with .venv\\Scripts\\python)"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]  # tools/petgen
WORK = HERE / "work"
REPO = HERE.parents[1]
ASSETS = REPO / "apps" / "aipet" / "assets" / "pets"
os.environ.setdefault("U2NET_HOME", str(WORK / "u2net"))  # before rembg is imported

from petgen import kling  # noqa: E402
from petgen.keycheck import score_file  # noqa: E402
from petgen.loopcheck import probe, psnr_series, seam_verdict  # noqa: E402
from petgen.package import ACTIONS, make_cover, pet_json  # noqa: E402
from petgen.prompts import PETS, POSE_ASPECT, REF_POSE_FOR_ACTION, action_prompt, pose_prompt, source_prompt  # noqa: E402

SPIKE_OUT = Path(r"C:\Users\Administrator\AppData\Local\Temp\claude\c--Users-Administrator-code-aipet"
                 r"\4fbc451a-51c9-48a5-9f6b-54b7e4f439b7\scratchpad\out")
VIDEO_UNITS = 3


def pet_dir(pet: str) -> Path:
    d = WORK / pet
    d.mkdir(parents=True, exist_ok=True)
    return d


def _video_units_left() -> float:
    packs = [p for p in kling.balance() if "视频" in p["resource_pack_name"] and p["status"] == "online"]
    return sum(float(p["remaining_quantity"]) for p in packs)


def cmd_balance(_a) -> int:
    for p in kling.balance():
        print(f"{p['resource_pack_name']} | {p['remaining_quantity']}/{p['total_quantity']} | {p['status']}")
    return 0


def cmd_import_spike(_a) -> int:
    missing = 0
    for pet in PETS:
        pairs = [(SPIKE_OUT / f"src-{pet}.png", pet_dir(pet) / "src.png")]
        pairs += [(SPIKE_OUT / f"ref-{pet}-{pose}.png", pet_dir(pet) / f"ref-{pose}.png") for pose in POSE_ASPECT]
        for src, dst in pairs:
            if src.exists():
                shutil.copy2(src, dst)
                print(f"imported {dst.relative_to(HERE)}")
            else:
                missing += 1
                print(f"MISSING {src.name} -> regenerate with the source/pose command")
    return 1 if missing else 0


def cmd_source(a) -> int:
    body = {"model_name": "kling-v3", "prompt": source_prompt(a.pet),
            "negative_prompt": "卡通，插画，3D 渲染，多只动物，残缺肢体，文字，水印，边框",
            "aspect_ratio": "16:9", "resolution": "1k", "n": 1}
    d = kling.wait("image", kling.create_image(body))
    kling.download(d["task_result"]["images"][0]["url"], pet_dir(a.pet) / "src.png")
    print(f"source {a.pet}: deduction {d.get('final_unit_deduction')}")
    return 0


def cmd_pose(a) -> int:
    body = {"model_name": "kling-v3", "image_reference": "subject", "prompt": pose_prompt(a.pet, a.pose),
            "image": kling.b64(pet_dir(a.pet) / "src.png"), "aspect_ratio": POSE_ASPECT[a.pose],
            "resolution": "1k", "n": 1}
    d = kling.wait("image", kling.create_image(body))
    kling.download(d["task_result"]["images"][0]["url"], pet_dir(a.pet) / f"ref-{a.pose}.png")
    print(f"pose {a.pet}/{a.pose}: deduction {d.get('final_unit_deduction')}")
    return 0


def cmd_gate(a) -> int:
    from petgen.compose import EdgeError, compose
    try:
        r = compose(pet_dir(a.pet) / f"ref-{a.pose}.png", pet_dir(a.pet), f"ref-{a.pose}")
    except EdgeError as e:
        print(f"FAIL {a.pet}/{a.pose}: {e}")
        return 1
    s = score_file(r.green)
    print(f"{'PASS' if s.passed else 'FAIL'} {a.pet}/{a.pose}: floating={s.floating} blob_core={s.blob_core}")
    return 0 if s.passed else 1


def cmd_video(a) -> int:
    ref = pet_dir(a.pet) / f"ref-{REF_POSE_FOR_ACTION[a.action]}-green.png"
    if not ref.exists():
        print(f"no gated reference {ref.name}: run gate first")
        return 1
    left = _video_units_left()
    if left < VIDEO_UNITS:
        print(f"only {left} video units left -- stopping")
        return 2
    img = kling.b64(ref)
    body = {"model_name": "kling-v3", "image": img, "image_tail": img, "prompt": action_prompt(a.pet, a.action),
            "duration": "5", "mode": "std", "external_task_id": f"petgen-{a.pet}-{a.action}"}
    d = kling.wait("video", kling.create_video(body), every=10)
    kling.download(d["task_result"]["videos"][0]["url"], pet_dir(a.pet) / f"{a.action}.mp4")
    print(f"video {a.pet}/{a.action}: deduction {d.get('final_unit_deduction')}, {left - VIDEO_UNITS:.0f} units left")
    return 0


def _frame(video: Path, out: Path, last: bool) -> Path:
    seek = ["-sseof", "-0.05"] if last else []
    subprocess.run(["ffmpeg", "-v", "error", "-y", *seek, "-i", str(video), "-update", "1", "-frames:v", "1", str(out)],
                   check=True)
    return out


def cmd_qa(a) -> int:
    d = pet_dir(a.pet)
    v = d / f"{a.action}.mp4"
    fmt = probe(v)
    fmt_ok = fmt == {"width": 960, "height": 960, "fps": "24/1", "frames": 121}
    ok_seam, seam, worst = seam_verdict(*psnr_series(v, d / f"qa-{a.action}"))
    first = score_file(_frame(v, d / f"qa-{a.action}-first.png", last=False))
    last = score_file(_frame(v, d / f"qa-{a.action}-last.png", last=True))
    passed = fmt_ok and ok_seam and first.passed and last.passed
    print(json.dumps({"pet": a.pet, "action": a.action, "pass": passed, "format": fmt,
                      "seam": round(seam, 2), "worst_step": round(worst, 2),
                      "blob_core_first": first.blob_core, "blob_core_last": last.blob_core}, ensure_ascii=False))
    return 0 if passed else 1


def cmd_package(a) -> int:
    from PIL import Image
    d = pet_dir(a.pet)
    clips = [d / f"{k}.mp4" for k in ACTIONS]
    missing = [c.name for c in clips if not c.exists()]
    if missing:
        print(f"missing clips {missing}")
        return 1
    out = ASSETS / f"builtin-{a.pet}"
    out.mkdir(parents=True, exist_ok=True)
    for c in clips:
        shutil.copy2(c, out / c.name)
    make_cover(Image.open(d / "ref-stand-cutout.png").convert("RGBA")).save(out / "cover.png")
    (out / "pet.json").write_text(json.dumps(pet_json(a.pet), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"packaged {out.relative_to(REPO)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="petgen")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("balance").set_defaults(fn=cmd_balance)
    sub.add_parser("import-spike").set_defaults(fn=cmd_import_spike)
    for name, fn, extra in [("source", cmd_source, None), ("pose", cmd_pose, ("pose", list(POSE_ASPECT))),
                            ("gate", cmd_gate, ("pose", list(POSE_ASPECT))), ("video", cmd_video, ("action", ACTIONS)),
                            ("qa", cmd_qa, ("action", ACTIONS)), ("package", cmd_package, None)]:
        p = sub.add_parser(name)
        p.add_argument("pet", choices=list(PETS))
        if extra:
            p.add_argument(extra[0], choices=extra[1])
        p.set_defaults(fn=fn)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: 运行测试，确认通过**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
.\.venv\Scripts\python -m pytest -q
```

Expected：全部通过。

- [ ] **Step 6: 导入 spike 参考图并过门槛（不花钱）**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
$env:PYTHONIOENCODING = 'utf-8'
.\.venv\Scripts\python -m petgen import-spike
foreach ($pet in 'ragdoll','gold','corgi') { foreach ($pose in 'stand','walk','lie') { .\.venv\Scripts\python -m petgen gate $pet $pose } }
```

Expected：9 行 `PASS`（spike 实测：金毛站姿 blob_core≈142，其余 ≤ 30）。某张 `MISSING` 或 `FAIL`：先 `python -m petgen pose <pet> <pose>`（8 图片单位）重新生成再 `gate`，同一张最多重试 2 次；还不过就停下，把该图和输出交给用户。`source` 只在 `src.png` 缺失时才跑。

- [ ] **Step 7: 生成并质检 15 个视频（约 45 视频单位）**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
$env:PYTHONIOENCODING = 'utf-8'
.\.venv\Scripts\python -m petgen balance
foreach ($pet in 'ragdoll','gold','corgi') {
  foreach ($action in 'stand','walk','sleep','lick_paw','act_cute') {
    .\.venv\Scripts\python -m petgen video $pet $action
    if ($LASTEXITCODE -eq 2) { Write-Output "STOP: out of video units"; break }
    .\.venv\Scripts\python -m petgen qa $pet $action
  }
}
```

规则：`balance` 显示视频少于 45 单位就先停下告诉用户。某个 `qa` 输出 `"pass": false`：同一个动作只重做 1 次（再 3 单位）；仍不过就记下 JSON，继续其他动作，全部跑完后把失败清单交给用户。**布偶猫 5 个都失败时立刻停下**——说明猫走不通，按 spec 第 10 节换品种前要先问用户。

- [ ] **Step 8: 抽查（肉眼）**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen\work
foreach ($pet in 'ragdoll','gold','corgi') {
  ffmpeg -v error -y -i "$pet\stand.mp4" -i "$pet\walk.mp4" -i "$pet\sleep.mp4" -i "$pet\lick_paw.mp4" -i "$pet\act_cute.mp4" `
    -filter_complex "[0:v]trim=start_frame=60,scale=240:240[a];[1:v]trim=start_frame=60,scale=240:240[b];[2:v]trim=start_frame=60,scale=240:240[c];[3:v]trim=start_frame=60,scale=240:240[d];[4:v]trim=start_frame=60,scale=240:240[e];[a][b][c][d][e]hstack=5[o]" `
    -map "[o]" -frames:v 1 "$pet-midframes.png"
}
```

逐张看 `work\<pet>-midframes.png`（每个动作第 60 帧）：5 个动作是不是同一只动物（毛色、花纹、脸）、动作是否对得上名字、背景是否纯绿。有明显不是同一只或动作错的，重做该动作（算进 Step 7 的重试次数）。

- [ ] **Step 9: Git LFS 规则（先于素材提交）**

仓库根新建 `.gitattributes`：

```
apps/aipet/assets/pets/**/*.mp4 filter=lfs diff=lfs merge=lfs -text
apps/aipet/assets/pets/**/*.png filter=lfs diff=lfs merge=lfs -text
```

```powershell
Set-Location C:\Users\Administrator\code\aipet
git lfs install --local
git add .gitattributes
git commit -m "chore: track built-in pet media with Git LFS" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 10: 打包进应用**

```powershell
Set-Location C:\Users\Administrator\code\aipet\tools\petgen
foreach ($pet in 'ragdoll','gold','corgi') { .\.venv\Scripts\python -m petgen package $pet }
```

`apps/aipet/pubspec.yaml` 的 `assets:` 段改为（Flutter 的目录条目只收该目录下的文件，所以每只宠物一行）：

```yaml
  assets:
    - assets/tray.ico
    - assets/pets/builtin-gold/
    - assets/pets/builtin-corgi/
    - assets/pets/builtin-ragdoll/
```

- [ ] **Step 11: 记录并提交**

把 Step 6 的 9 行门槛结果、Step 7 每个动作的 `qa` JSON 与扣费、Step 8 的结论写进 `docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md` 的「素材」一节。

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add tools/petgen apps/aipet/assets/pets apps/aipet/pubspec.yaml docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md
git lfs ls-files | Measure-Object -Line
git commit -m "feat(aipet): built-in golden retriever, corgi and ragdoll (5 actions each)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

Expected：`git lfs ls-files` 为 18 行（15 个 mp4 + 3 个 cover.png）。

---

### Task 4: 领域模型 `Pet` 与 `pet.json` 解析

移植 pet_shell `actions.dart` 里的循环策略和中文名，加上 spec 4.1 的 `pet.json` 校验。

**Files:**
- Create: `apps/aipet/lib/domain/pet.dart`
- Test: `apps/aipet/test/domain/pet_test.dart`

**Interfaces:**
- Produces:
  - `const String kIdleAction = 'stand'`；`bool isLooping(String key)`；`String labelFor(String key)`
  - `enum Species { dog, cat, other }`；`enum PetOrigin { builtin, custom }`
  - `class Pet { String id; String name; Species species; PetOrigin origin; String blurb; Directory dir; String cover; List<String> actions; File get coverFile; File actionFile(String key); bool get isComplete; }`
  - `Pet parsePet(String jsonText, Directory dir)`——任何不合法都抛 `FormatException`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/domain/pet_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:aipet/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> valid() => {
      'schema': 1,
      'id': 'builtin-gold',
      'name': '金毛',
      'species': 'dog',
      'origin': 'builtin',
      'blurb': '温柔的大暖男，走到哪跟到哪',
      'cover': 'cover.png',
      'actions': ['stand', 'walk', 'sleep', 'lick_paw', 'act_cute'],
    };

void main() {
  final dir = Directory('C:\\pets\\builtin-gold');

  test('parses a valid pet.json', () {
    final p = parsePet(jsonEncode(valid()), dir);
    expect(p.id, 'builtin-gold');
    expect(p.name, '金毛');
    expect(p.species, Species.dog);
    expect(p.origin, PetOrigin.builtin);
    expect(p.blurb, '温柔的大暖男，走到哪跟到哪');
    expect(p.actions, ['stand', 'walk', 'sleep', 'lick_paw', 'act_cute']);
    expect(p.actionFile('walk').path, 'C:\\pets\\builtin-gold\\walk.mp4');
    expect(p.coverFile.path, 'C:\\pets\\builtin-gold\\cover.png');
  });

  test('blurb is optional', () {
    final j = valid()..remove('blurb');
    expect(parsePet(jsonEncode(j), dir).blurb, '');
  });

  final broken = <String, Map<String, Object?> Function()>{
    'not json': () => {},
    'schema 2': () => valid()..['schema'] = 2,
    'missing id': () => valid()..remove('id'),
    'id with spaces': () => valid()..['id'] = 'Gold Dog',
    'empty name': () => valid()..['name'] = '  ',
    'unknown species': () => valid()..['species'] = 'dragon',
    'unknown origin': () => valid()..['origin'] = 'stolen',
    'cover with a path': () => valid()..['cover'] = '..\\x.png',
    'actions not a list': () => valid()..['actions'] = 'stand',
    'action with a dash': () => valid()..['actions'] = ['stand', 'lick-paw'],
    'duplicate action': () => valid()..['actions'] = ['stand', 'walk', 'walk'],
    'no stand': () => valid()..['actions'] = ['walk', 'sleep'],
  };
  for (final e in broken.entries) {
    test('rejects ${e.key}', () {
      final text = e.key == 'not json' ? '{nope' : jsonEncode(e.value());
      expect(() => parsePet(text, dir), throwsFormatException);
    });
  }

  test('isComplete needs the cover and every listed clip', () {
    final tmp = Directory.systemTemp.createTempSync('pet_complete_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final p = parsePet(jsonEncode(valid()), tmp);
    expect(p.isComplete, isFalse);
    p.coverFile.writeAsBytesSync([0]);
    for (final k in p.actions) {
      p.actionFile(k).writeAsBytesSync([0]);
    }
    expect(p.isComplete, isTrue);
    p.actionFile('sleep').deleteSync();
    expect(p.isComplete, isFalse);
  });

  test('loop policy follows the parent spec 4.6', () {
    for (final k in ['stand', 'walk', 'sleep']) {
      expect(isLooping(k), isTrue, reason: k);
    }
    for (final k in ['lick_paw', 'act_cute', 'feed', 'unknown']) {
      expect(isLooping(k), isFalse, reason: k);
    }
    expect(kIdleAction, 'stand');
  });

  test('Chinese labels with key fallback', () {
    expect(labelFor('stand'), '待机');
    expect(labelFor('lick_paw'), '舔爪子');
    expect(labelFor('act_cute'), '卖萌');
    expect(labelFor('backflip'), 'backflip');
  });
}
```

- [ ] **Step 2: 运行，确认失败**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter test test/domain/pet_test.dart
```

Expected：编译失败，`Error when reading 'lib/domain/pet.dart'`。

- [ ] **Step 3: 实现 `lib/domain/pet.dart`**

```dart
import 'dart:convert';
import 'dart:io';

/// Parent spec 4.6: these loop; every other action plays once and then
/// hands back to [kIdleAction].
const Set<String> kLoopingActions = {'stand', 'walk', 'sleep'};
const String kIdleAction = 'stand';

const Map<String, String> _labels = {
  'stand': '待机',
  'walk': '走路',
  'run': '跑步',
  'sleep': '睡觉',
  'feed': '吃饭',
  'play': '玩耍',
  'spin': '转圈',
  'lick_paw': '舔爪子',
  'act_cute': '卖萌',
  'pet_head': '摸摸头',
};

bool isLooping(String key) => kLoopingActions.contains(key);

String labelFor(String key) => _labels[key] ?? key;

enum Species { dog, cat, other }

enum PetOrigin { builtin, custom }

/// One pet folder (spec 4.1): pet.json + one <actionKey>.mp4 per action + cover.
class Pet {
  const Pet({
    required this.id,
    required this.name,
    required this.species,
    required this.origin,
    required this.blurb,
    required this.dir,
    required this.cover,
    required this.actions,
  });

  final String id;
  final String name;
  final Species species;
  final PetOrigin origin;
  final String blurb;
  final Directory dir;
  final String cover;
  final List<String> actions;

  File get coverFile => File('${dir.path}${Platform.pathSeparator}$cover');

  File actionFile(String key) => File('${dir.path}${Platform.pathSeparator}$key.mp4');

  /// A half-installed or half-downloaded folder shows as 素材缺失 (spec 7).
  bool get isComplete => coverFile.existsSync() && actions.every((k) => actionFile(k).existsSync());
}

final _idPattern = RegExp(r'^[a-z0-9-]+$');
final _actionPattern = RegExp(r'^[a-z_]+$');

Pet parsePet(String jsonText, Directory dir) {
  final Object? raw;
  try {
    raw = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw FormatException('pet.json is not JSON: ${e.message}');
  }
  if (raw is! Map<String, Object?>) throw const FormatException('pet.json must be an object');

  T field<T>(String key) {
    final v = raw[key];
    if (v is! T) throw FormatException('pet.json "$key" is missing or has the wrong type');
    return v;
  }

  if (field<int>('schema') != 1) throw const FormatException('pet.json schema must be 1');
  final id = field<String>('id');
  if (!_idPattern.hasMatch(id)) throw FormatException('bad pet id "$id"');
  final name = field<String>('name');
  if (name.trim().isEmpty) throw const FormatException('pet name is empty');
  final species = Species.values.asNameMap()[field<String>('species')] ??
      (throw const FormatException('unknown species'));
  final origin = PetOrigin.values.asNameMap()[field<String>('origin')] ??
      (throw const FormatException('unknown origin'));
  final blurb = raw['blurb'] is String ? raw['blurb']! as String : '';
  final cover = field<String>('cover');
  if (cover.isEmpty || cover.contains('/') || cover.contains('\\') || cover.contains('..')) {
    throw FormatException('cover must be a bare file name, got "$cover"');
  }
  final actions = <String>[];
  for (final a in field<List<Object?>>('actions')) {
    if (a is! String || !_actionPattern.hasMatch(a)) throw FormatException('bad action key $a');
    if (actions.contains(a)) throw FormatException('duplicate action $a');
    actions.add(a);
  }
  if (!actions.contains(kIdleAction)) throw const FormatException('actions must include stand');
  return Pet(
    id: id,
    name: name,
    species: species,
    origin: origin,
    blurb: blurb,
    dir: dir,
    cover: cover,
    actions: List.unmodifiable(actions),
  );
}
```

- [ ] **Step 4: 运行，确认通过**

```powershell
flutter test test/domain/pet_test.dart
```

Expected：`All tests passed!`

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/domain/pet.dart apps/aipet/test/domain/pet_test.dart
git commit -m "feat(aipet): Pet model and pet.json validation" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: 领养状态、卡片状态、分类

**Files:**
- Create: `apps/aipet/lib/domain/library_state.dart`
- Test: `apps/aipet/test/domain/library_state_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `Pet`、`Species`。
- Produces:
  - `class LibraryState { String? currentPetId; List<String> adoptedPetIds; String? preparingPetId; static const empty; bool isAdopted(String id); LibraryState preparing(String? petId); LibraryState adopted(String petId); Map<String, Object?> toJson(); factory LibraryState.fromJson(Map<Object?, Object?> j); }`（值相等）
  - `enum CardStatus { adoptable, switchable, companion, preparing, missing }`
  - `CardStatus cardStatusFor({required String petId, required bool complete, required LibraryState state})`
  - `enum Category { all, dog, cat, other }`，`Category.label`
  - `List<Pet> filterPets(Iterable<Pet> pets, Category c)`；`List<Pet> adoptedPets(Iterable<Pet> pets, LibraryState s)`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/domain/library_state_test.dart`：

```dart
import 'dart:io';

import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

Pet pet(String id, Species s) => Pet(
      id: id,
      name: id,
      species: s,
      origin: PetOrigin.builtin,
      blurb: '',
      dir: Directory('C:\\pets\\$id'),
      cover: 'cover.png',
      actions: const ['stand'],
    );

void main() {
  const s = LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b'], preparingPetId: 'c');

  group('cardStatusFor', () {
    CardStatus of(String id, {bool complete = true}) =>
        cardStatusFor(petId: id, complete: complete, state: s);
    test('incomplete folders are missing, whatever else is true', () => expect(of('a', complete: false), CardStatus.missing));
    test('preparing wins over adoption state', () => expect(of('c'), CardStatus.preparing));
    test('current pet is the companion', () => expect(of('a'), CardStatus.companion));
    test('adopted but not current can be switched to', () => expect(of('b'), CardStatus.switchable));
    test('never adopted can be adopted', () => expect(of('z'), CardStatus.adoptable));
  });

  test('adopted() makes the pet current, records it once, clears preparing', () {
    final a = s.adopted('c');
    expect(a, const LibraryState(currentPetId: 'c', adoptedPetIds: ['a', 'b', 'c']));
    expect(a.adopted('b').adoptedPetIds, ['a', 'b', 'c']);
  });

  test('preparing() only touches preparingPetId', () {
    expect(LibraryState.empty.preparing('x'), const LibraryState(preparingPetId: 'x'));
    expect(s.preparing(null), const LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b']));
  });

  test('json round trip, including the channel map type', () {
    final Map<Object?, Object?> wire = Map<Object?, Object?>.from(s.toJson());
    expect(LibraryState.fromJson(wire), s);
    expect(LibraryState.fromJson(const {}), LibraryState.empty);
  });

  test('categories filter by species and carry their labels', () {
    final pets = [pet('d1', Species.dog), pet('c1', Species.cat), pet('d2', Species.dog)];
    expect(filterPets(pets, Category.all).map((p) => p.id), ['d1', 'c1', 'd2']);
    expect(filterPets(pets, Category.dog).map((p) => p.id), ['d1', 'd2']);
    expect(filterPets(pets, Category.cat).map((p) => p.id), ['c1']);
    expect(filterPets(pets, Category.other), isEmpty);
    expect(Category.values.map((c) => c.label), ['全部', '狗狗', '猫猫', '其他小宠']);
  });

  test('adoptedPets keeps adoption order and skips unknown ids', () {
    final pets = [pet('a', Species.dog), pet('b', Species.cat)];
    const st = LibraryState(adoptedPetIds: ['b', 'gone', 'a']);
    expect(adoptedPets(pets, st).map((p) => p.id), ['b', 'a']);
  });
}
```

- [ ] **Step 2: 运行，确认失败**

```powershell
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter test test/domain/library_state_test.dart
```

Expected：编译失败，找不到 `library_state.dart`。

- [ ] **Step 3: 实现 `lib/domain/library_state.dart`**

```dart
import 'pet.dart';

/// Who is on the desktop, who has been adopted, who is being prepared.
/// Travels over the window channel as [toJson]; settings.json stores the
/// first two fields only.
class LibraryState {
  const LibraryState({this.currentPetId, this.adoptedPetIds = const [], this.preparingPetId});

  static const empty = LibraryState();

  final String? currentPetId;
  final List<String> adoptedPetIds;
  final String? preparingPetId;

  bool isAdopted(String id) => adoptedPetIds.contains(id);

  LibraryState preparing(String? petId) =>
      LibraryState(currentPetId: currentPetId, adoptedPetIds: adoptedPetIds, preparingPetId: petId);

  LibraryState adopted(String petId) => LibraryState(
        currentPetId: petId,
        adoptedPetIds: isAdopted(petId) ? adoptedPetIds : [...adoptedPetIds, petId],
      );

  Map<String, Object?> toJson() =>
      {'currentPetId': currentPetId, 'adoptedPetIds': adoptedPetIds, 'preparingPetId': preparingPetId};

  factory LibraryState.fromJson(Map<Object?, Object?> j) => LibraryState(
        currentPetId: j['currentPetId'] as String?,
        adoptedPetIds: [for (final v in (j['adoptedPetIds'] as List<Object?>?) ?? const <Object?>[]) v! as String],
        preparingPetId: j['preparingPetId'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is LibraryState &&
      other.currentPetId == currentPetId &&
      other.preparingPetId == preparingPetId &&
      other.adoptedPetIds.length == adoptedPetIds.length &&
      Iterable<int>.generate(adoptedPetIds.length).every((i) => other.adoptedPetIds[i] == adoptedPetIds[i]);

  @override
  int get hashCode => Object.hash(currentPetId, preparingPetId, Object.hashAll(adoptedPetIds));

  @override
  String toString() => 'LibraryState(${toJson()})';
}

/// Spec 5: the five card states.
enum CardStatus { adoptable, switchable, companion, preparing, missing }

CardStatus cardStatusFor({required String petId, required bool complete, required LibraryState state}) {
  if (!complete) return CardStatus.missing;
  if (state.preparingPetId == petId) return CardStatus.preparing;
  if (state.currentPetId == petId) return CardStatus.companion;
  if (state.isAdopted(petId)) return CardStatus.switchable;
  return CardStatus.adoptable;
}

enum Category {
  all('全部'),
  dog('狗狗'),
  cat('猫猫'),
  other('其他小宠');

  const Category(this.label);
  final String label;
}

List<Pet> filterPets(Iterable<Pet> pets, Category c) => switch (c) {
      Category.all => pets.toList(),
      Category.dog => pets.where((p) => p.species == Species.dog).toList(),
      Category.cat => pets.where((p) => p.species == Species.cat).toList(),
      Category.other => pets.where((p) => p.species == Species.other).toList(),
    };

List<Pet> adoptedPets(Iterable<Pet> pets, LibraryState s) => [
      for (final id in s.adoptedPetIds) ...pets.where((p) => p.id == id),
    ];
```

- [ ] **Step 4: 运行，确认通过**

```powershell
flutter test test/domain/library_state_test.dart
```

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/domain/library_state.dart apps/aipet/test/domain/library_state_test.dart
git commit -m "feat(aipet): library state, card statuses and categories" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: 设置文件 `settings.json`

spec 4.3：只有宠物窗读写；写入走临时文件 + 原子改名；损坏时改名为 `.bad` 保留并按首次启动处理。

**Files:**
- Create: `apps/aipet/lib/services/settings_store.dart`
- Test: `apps/aipet/test/services/settings_store_test.dart`

**Interfaces:**
- Consumes: Task 5 的 `LibraryState`。
- Produces: `class SettingsStore { SettingsStore(Directory root); File get file; LibraryState load(); void save(LibraryState s); }`——`load` 不会抛异常；`preparingPetId` 从不落盘。

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/settings_store_test.dart`：

```dart
import 'dart:io';

import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late SettingsStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('settings_');
    store = SettingsStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('missing file means first run', () => expect(store.load(), LibraryState.empty));

  test('round trip without the transient preparing field', () {
    store.save(const LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b'], preparingPetId: 'b'));
    expect(store.load(), const LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b']));
    expect(store.file.readAsStringSync(), isNot(contains('preparing')));
  });

  test('saving again replaces the file and leaves no temp file behind', () {
    store.save(const LibraryState(currentPetId: 'a', adoptedPetIds: ['a']));
    store.save(const LibraryState(currentPetId: 'b', adoptedPetIds: ['a', 'b']));
    expect(store.load().currentPetId, 'b');
    expect(root.listSync().map((e) => e.uri.pathSegments.last), ['settings.json']);
  });

  test('creates the directory on first save', () {
    final nested = SettingsStore(Directory('${root.path}\\a\\b'));
    nested.save(const LibraryState(currentPetId: 'x', adoptedPetIds: ['x']));
    expect(nested.load().currentPetId, 'x');
  });

  for (final bad in ['{nope', '[]', '{"schema":2,"currentPetId":"a","adoptedPetIds":["a"]}',
                     '{"schema":1,"currentPetId":3,"adoptedPetIds":[]}']) {
    test('corrupt content is quarantined as .bad: $bad', () {
      store.file.writeAsStringSync(bad);
      expect(store.load(), LibraryState.empty);
      expect(store.file.existsSync(), isFalse);
      expect(File('${store.file.path}.bad').readAsStringSync(), bad);
    });
  }

  test('a current pet missing from the adopted list is added back', () {
    store.file.writeAsStringSync('{"schema":1,"currentPetId":"a","adoptedPetIds":["b"]}');
    expect(store.load(), const LibraryState(currentPetId: 'a', adoptedPetIds: ['b', 'a']));
  });
}
```

- [ ] **Step 2: 运行，确认失败**

```powershell
flutter test test/services/settings_store_test.dart
```

- [ ] **Step 3: 实现 `lib/services/settings_store.dart`**

```dart
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/library_state.dart';

/// settings.json (spec 4.3). Only the pet window (primary engine) may use
/// this: two engines writing one file would overwrite each other.
class SettingsStore {
  SettingsStore(this.root);

  final Directory root;

  File get file => File('${root.path}${Platform.pathSeparator}settings.json');

  /// Never throws. A missing file is a first run; an unreadable one is kept
  /// as settings.json.bad for diagnosis and also treated as a first run.
  LibraryState load() {
    if (!file.existsSync()) return LibraryState.empty;
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map<String, Object?> || j['schema'] != 1) throw const FormatException('bad schema');
      final current = j['currentPetId'];
      final adopted = j['adoptedPetIds'];
      if (current != null && current is! String) throw const FormatException('bad currentPetId');
      if (adopted is! List<Object?> || adopted.any((v) => v is! String)) throw const FormatException('bad adoptedPetIds');
      final ids = adopted.cast<String>().toList();
      if (current is String && !ids.contains(current)) ids.add(current);
      return LibraryState(currentPetId: current as String?, adoptedPetIds: ids);
    } catch (e) {
      developer.log('settings.json unreadable ($e); quarantined as .bad', name: 'aipet.settings');
      final bad = File('${file.path}.bad');
      if (bad.existsSync()) bad.deleteSync();
      file.renameSync(bad.path);
      return LibraryState.empty;
    }
  }

  void save(LibraryState s) {
    root.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      jsonEncode({'schema': 1, 'currentPetId': s.currentPetId, 'adoptedPetIds': s.adoptedPetIds}),
      flush: true,
    );
    tmp.renameSync(file.path); // replaces the old file; never a half-written settings.json
  }
}
```

- [ ] **Step 4: 运行，确认通过**

```powershell
flutter test test/services/settings_store_test.dart
```

Expected：通过。若 `saving again replaces the file` 失败在 `renameSync`（目标已存在），把 `save` 的最后一行改成先 `if (file.existsSync()) file.deleteSync();` 再改名，并在结果文件里记一笔——这说明本机 Dart 的 `rename` 不覆盖已存在文件。

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/services/settings_store.dart apps/aipet/test/services/settings_store_test.dart
git commit -m "feat(aipet): settings.json with atomic save and .bad quarantine" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: 目录与宠物库扫描

**Files:**
- Create: `apps/aipet/lib/services/app_paths.dart`、`apps/aipet/lib/services/pet_library.dart`、`apps/aipet/test/support/pet_fixtures.dart`
- Test: `apps/aipet/test/services/app_paths_test.dart`、`apps/aipet/test/services/pet_library_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `parsePet`、`Pet`、`PetOrigin`。
- Produces:
  - `Directory appDataRoot([Map<String, String>? env])`；`Directory customPetsRoot(Directory appData)`；`Directory matteCacheRoot(Directory appData)`；`Directory builtinPetsRoot([String? executable])`
  - `class PetLibrary { PetLibrary({required Directory builtinRoot, required Directory customRoot}); List<Pet> scan(); static Pet? byId(Iterable<Pet> pets, String id); }`
  - 测试辅助 `Directory writePet(Directory root, {required String id, String species, String origin, List<String> actions, bool complete, String name})`（Task 12、15 复用）

- [ ] **Step 1: 测试辅助 `test/support/pet_fixtures.dart`**

```dart
import 'dart:convert';
import 'dart:io';

/// A real 1x1 transparent PNG, so Image.file has something decodable.
final kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

const kFiveActions = ['stand', 'walk', 'sleep', 'lick_paw', 'act_cute'];

/// Writes <root>/<id>/ with pet.json, cover.png and one dummy mp4 per action.
/// complete: false leaves out the last clip (a half-downloaded folder).
Directory writePet(
  Directory root, {
  required String id,
  String species = 'dog',
  String origin = 'builtin',
  List<String> actions = kFiveActions,
  bool complete = true,
  String name = '测试宠物',
}) {
  final dir = Directory('${root.path}${Platform.pathSeparator}$id')..createSync(recursive: true);
  File('${dir.path}${Platform.pathSeparator}pet.json').writeAsStringSync(jsonEncode({
    'schema': 1,
    'id': id,
    'name': name,
    'species': species,
    'origin': origin,
    'blurb': '$name 的简介',
    'cover': 'cover.png',
    'actions': actions,
  }));
  File('${dir.path}${Platform.pathSeparator}cover.png').writeAsBytesSync(kTinyPng);
  final clips = complete ? actions : actions.sublist(0, actions.length - 1);
  for (final a in clips) {
    File('${dir.path}${Platform.pathSeparator}$a.mp4').writeAsBytesSync(utf8.encode('clip $id/$a'));
  }
  return dir;
}
```

- [ ] **Step 2: 写失败的测试**

`apps/aipet/test/services/app_paths_test.dart`：

```dart
import 'package:aipet/services/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app data lives under %APPDATA%\\com.aipet\\aipet', () {
    final root = appDataRoot({'APPDATA': 'C:\\Users\\u\\AppData\\Roaming'});
    expect(root.path, 'C:\\Users\\u\\AppData\\Roaming\\com.aipet\\aipet');
    expect(customPetsRoot(root).path, '${root.path}\\pets');
    expect(matteCacheRoot(root).path, '${root.path}\\matte-cache\\v1');
  });

  test('missing APPDATA is an error, not a relative path', () {
    expect(() => appDataRoot(const {}), throwsStateError);
  });

  test('built-in pets sit in the Flutter asset folder next to the exe', () {
    expect(builtinPetsRoot('C:\\Program Files\\aipet\\aipet.exe').path,
        'C:\\Program Files\\aipet\\data\\flutter_assets\\assets\\pets');
  });
}
```

`apps/aipet/test/services/pet_library_test.dart`：

```dart
import 'dart:io';

import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pet_fixtures.dart';

void main() {
  late Directory tmp, builtin, custom;
  late PetLibrary lib;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('library_');
    builtin = Directory('${tmp.path}\\builtin')..createSync();
    custom = Directory('${tmp.path}\\custom')..createSync();
    lib = PetLibrary(builtinRoot: builtin, customRoot: custom);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('built-ins first, then custom pets, each sorted by id', () {
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat');
    writePet(builtin, id: 'builtin-gold');
    writePet(custom, id: 'custom-lucky', origin: 'custom');
    expect(lib.scan().map((p) => p.id), ['builtin-gold', 'builtin-ragdoll', 'custom-lucky']);
  });

  test('a broken pet.json is skipped, the rest still load', () {
    writePet(builtin, id: 'builtin-gold');
    Directory('${builtin.path}\\broken').createSync();
    File('${builtin.path}\\broken\\pet.json').writeAsStringSync('{nope');
    Directory('${builtin.path}\\no-json').createSync();
    File('${builtin.path}\\stray.txt').writeAsStringSync('x');
    expect(lib.scan().map((p) => p.id), ['builtin-gold']);
  });

  test('a folder whose origin does not match its root is skipped', () {
    writePet(builtin, id: 'sneaky', origin: 'custom');
    writePet(custom, id: 'also-sneaky', origin: 'builtin');
    expect(lib.scan(), isEmpty);
  });

  test('duplicate ids: the built-in wins', () {
    writePet(builtin, id: 'twin', name: '系统');
    writePet(custom, id: 'twin', origin: 'custom', name: '定制');
    final pets = lib.scan();
    expect(pets.single.name, '系统');
    expect(pets.single.origin, PetOrigin.builtin);
  });

  test('missing roots are simply empty', () {
    final none = PetLibrary(builtinRoot: Directory('${tmp.path}\\x'), customRoot: Directory('${tmp.path}\\y'));
    expect(none.scan(), isEmpty);
  });

  test('incomplete folders are still listed (the card shows 素材缺失)', () {
    writePet(builtin, id: 'half', complete: false);
    final p = lib.scan().single;
    expect(p.isComplete, isFalse);
  });

  test('byId', () {
    writePet(builtin, id: 'builtin-gold');
    final pets = lib.scan();
    expect(PetLibrary.byId(pets, 'builtin-gold')?.id, 'builtin-gold');
    expect(PetLibrary.byId(pets, 'nope'), isNull);
  });
}
```

- [ ] **Step 3: 运行，确认失败**

```powershell
flutter test test/services/app_paths_test.dart test/services/pet_library_test.dart
```

- [ ] **Step 4: 实现 `lib/services/app_paths.dart`**

```dart
import 'dart:io';

final String _sep = Platform.pathSeparator;

/// %APPDATA%\com.aipet\aipet (parent spec 4.4).
Directory appDataRoot([Map<String, String>? env]) {
  final base = (env ?? Platform.environment)['APPDATA'];
  if (base == null || base.isEmpty) throw StateError('APPDATA is not set');
  return Directory('$base${_sep}com.aipet${_sep}aipet');
}

Directory customPetsRoot(Directory appData) => Directory('${appData.path}${_sep}pets');

Directory matteCacheRoot(Directory appData) => Directory('${appData.path}${_sep}matte-cache${_sep}v1');

/// Flutter assets are plain files on Windows, so pet_matte can decode the
/// built-in clips in place by path.
Directory builtinPetsRoot([String? executable]) => Directory(
    '${File(executable ?? Platform.resolvedExecutable).parent.path}${_sep}data${_sep}flutter_assets${_sep}assets${_sep}pets');
```

- [ ] **Step 5: 实现 `lib/services/pet_library.dart`**

```dart
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/pet.dart';

/// Every pet folder the app can see: read-only built-ins shipped with the app,
/// then custom pets downloaded into %APPDATA% (sub-project C). Both engines may
/// scan; neither writes here.
class PetLibrary {
  PetLibrary({required this.builtinRoot, required this.customRoot});

  final Directory builtinRoot;
  final Directory customRoot;

  List<Pet> scan() {
    final pets = <Pet>[];
    final seen = <String>{};
    for (final (root, origin) in [(builtinRoot, PetOrigin.builtin), (customRoot, PetOrigin.custom)]) {
      for (final pet in _scanRoot(root, origin)) {
        if (seen.add(pet.id)) pets.add(pet);
      }
    }
    return pets;
  }

  static Pet? byId(Iterable<Pet> pets, String id) {
    for (final p in pets) {
      if (p.id == id) return p;
    }
    return null;
  }

  // One bad folder (a broken download, a hand-edited pet.json) must not hide
  // every other pet, so failures are logged and skipped.
  List<Pet> _scanRoot(Directory root, PetOrigin origin) {
    if (!root.existsSync()) return const [];
    final dirs = root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    final out = <Pet>[];
    for (final dir in dirs) {
      final json = File('${dir.path}${Platform.pathSeparator}pet.json');
      if (!json.existsSync()) continue;
      try {
        final pet = parsePet(json.readAsStringSync(), dir);
        if (pet.origin != origin) throw FormatException('origin ${pet.origin.name} under the ${origin.name} root');
        out.add(pet);
      } catch (e) {
        developer.log('skipping ${dir.path}: $e', name: 'aipet.library');
      }
    }
    return out;
  }
}
```

- [ ] **Step 6: 运行，确认通过**

```powershell
flutter test test/services/app_paths_test.dart test/services/pet_library_test.dart
```

- [ ] **Step 7: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/services/app_paths.dart apps/aipet/lib/services/pet_library.dart apps/aipet/test/services apps/aipet/test/support
git commit -m "feat(aipet): app directories and pet library scan" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: 原生抠像任务队列 `native/prepare_queue`

spec 第 6 节：抠像移出平台线程。队列逻辑与 Windows 无关，放进 `native/` 用 ctest 测；插件只负责把「交回平台线程」接到消息窗口上（Task 9）。

**Files:**
- Create: `native/prepare_queue/CMakeLists.txt`、`native/prepare_queue/include/prepare_queue/prepare_queue.h`、`native/prepare_queue/src/prepare_queue.cpp`
- Test: `native/prepare_queue/tests/test_prepare_queue.cpp`
- Modify: `native/CMakeLists.txt`（`add_subdirectory(prepare_queue)`）

**Interfaces:**
- Produces（Task 9 使用）:

```cpp
namespace prepare_queue {
struct Outcome { int32_t code = 0; std::string error; };
inline constexpr int32_t kWorkThrew = -99;
inline constexpr int32_t kCancelled = -100;
class PrepareQueue {
 public:
  using Work = std::function<Outcome(const std::wstring& src, const std::wstring& dst, uint32_t edge)>;
  using Task = std::function<void()>;
  using Post = std::function<void(Task)>;
  using Done = std::function<void(const Outcome&)>;
  PrepareQueue(Work work, Post post);
  ~PrepareQueue();
  void Submit(const std::wstring& src, const std::wstring& dst, uint32_t edge, Done done);
};
}
```

- [ ] **Step 1: CMake 接线**

`native/prepare_queue/CMakeLists.txt`：

```cmake
add_library(prepare_queue STATIC src/prepare_queue.cpp)
target_include_directories(prepare_queue PUBLIC include)

add_executable(prepare_queue_tests tests/test_prepare_queue.cpp)
target_link_libraries(prepare_queue_tests PRIVATE prepare_queue GTest::gtest_main)
gtest_discover_tests(prepare_queue_tests)
```

`native/CMakeLists.txt` 末尾 `add_subdirectory(frame_source)` 之后加一行：

```cmake
add_subdirectory(prepare_queue)
```

- [ ] **Step 2: 写失败的测试**

`native/prepare_queue/tests/test_prepare_queue.cpp`：

```cpp
#include "prepare_queue/prepare_queue.h"

#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace prepare_queue;
using namespace std::chrono_literals;

namespace {

// Stands in for the platform thread: posted tasks pile up until Drain() runs
// them on the test thread.
class Inbox {
 public:
  PrepareQueue::Post poster() {
    return [this](PrepareQueue::Task t) {
      {
        std::lock_guard<std::mutex> lk(mu_);
        tasks_.push_back(std::move(t));
      }
      cv_.notify_all();
    };
  }
  bool WaitFor(size_t n) {
    std::unique_lock<std::mutex> lk(mu_);
    return cv_.wait_for(lk, 5s, [&] { return tasks_.size() >= n; });
  }
  size_t Drain() {
    std::vector<PrepareQueue::Task> ts;
    {
      std::lock_guard<std::mutex> lk(mu_);
      ts.swap(tasks_);
    }
    for (auto& t : ts) t();
    return ts.size();
  }

 private:
  std::mutex mu_;
  std::condition_variable cv_;
  std::vector<PrepareQueue::Task> tasks_;
};

// A work function that records which destinations started and blocks until Open().
class Gate {
 public:
  PrepareQueue::Work work(int32_t code = 0) {
    return [this, code](const std::wstring&, const std::wstring& dst, uint32_t) {
      std::unique_lock<std::mutex> lk(mu_);
      started_.push_back(dst);
      cv_.notify_all();
      cv_.wait(lk, [&] { return open_; });
      return Outcome{code, code != 0 ? "failed" : ""};
    };
  }
  void Open() {
    {
      std::lock_guard<std::mutex> lk(mu_);
      open_ = true;
    }
    cv_.notify_all();
  }
  bool WaitStarted(size_t n) {
    std::unique_lock<std::mutex> lk(mu_);
    return cv_.wait_for(lk, 5s, [&] { return started_.size() >= n; });
  }
  std::vector<std::wstring> started() {
    std::lock_guard<std::mutex> lk(mu_);
    return started_;
  }

 private:
  std::mutex mu_;
  std::condition_variable cv_;
  bool open_ = false;
  std::vector<std::wstring> started_;
};

}  // namespace

TEST(PrepareQueue, ResultArrivesOnlyThroughPost) {
  Inbox inbox;
  Gate gate;
  gate.Open();
  std::vector<Outcome> got;
  PrepareQueue q(gate.work(0), inbox.poster());
  q.Submit(L"a.mp4", L"a.aipmat", 720, [&](const Outcome& o) { got.push_back(o); });
  ASSERT_TRUE(inbox.WaitFor(1));
  EXPECT_TRUE(got.empty()) << "a result ran on the worker thread instead of being posted";
  EXPECT_EQ(inbox.Drain(), 1u);
  ASSERT_EQ(got.size(), 1u);
  EXPECT_EQ(got[0].code, 0);
}

TEST(PrepareQueue, SameDestinationWhileRunningIsMerged) {
  Inbox inbox;
  Gate gate;
  std::vector<int32_t> codes;
  PrepareQueue q(gate.work(0), inbox.poster());
  q.Submit(L"a.mp4", L"x", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  ASSERT_TRUE(gate.WaitStarted(1));
  q.Submit(L"a.mp4", L"x", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  gate.Open();
  ASSERT_TRUE(inbox.WaitFor(2));
  inbox.Drain();
  EXPECT_EQ(codes, (std::vector<int32_t>{0, 0}));
  EXPECT_EQ(gate.started().size(), 1u);
}

TEST(PrepareQueue, SameDestinationWhilePendingIsMerged) {
  Inbox inbox;
  Gate gate;
  int calls = 0;
  PrepareQueue q(gate.work(0), inbox.poster());
  q.Submit(L"y.mp4", L"y", 720, [&](const Outcome&) { ++calls; });  // occupies the worker
  ASSERT_TRUE(gate.WaitStarted(1));
  q.Submit(L"x.mp4", L"x", 720, [&](const Outcome&) { ++calls; });
  q.Submit(L"x.mp4", L"x", 720, [&](const Outcome&) { ++calls; });
  gate.Open();
  ASSERT_TRUE(inbox.WaitFor(3));
  inbox.Drain();
  EXPECT_EQ(calls, 3);
  EXPECT_EQ(gate.started(), (std::vector<std::wstring>{L"y", L"x"}));
}

TEST(PrepareQueue, JobsRunInSubmissionOrder) {
  Inbox inbox;
  Gate gate;
  gate.Open();
  PrepareQueue q(gate.work(0), inbox.poster());
  for (const wchar_t* d : {L"a", L"b", L"c"}) q.Submit(L"s", d, 720, [](const Outcome&) {});
  ASSERT_TRUE(inbox.WaitFor(3));
  inbox.Drain();
  EXPECT_EQ(gate.started(), (std::vector<std::wstring>{L"a", L"b", L"c"}));
}

TEST(PrepareQueue, FailureCodesAndExceptionsReachTheCaller) {
  Inbox inbox;
  std::vector<Outcome> got;
  {
    PrepareQueue q([](const std::wstring&, const std::wstring&, uint32_t) { return Outcome{-2, "decode failed"}; },
                   inbox.poster());
    q.Submit(L"s", L"d1", 720, [&](const Outcome& o) { got.push_back(o); });
    ASSERT_TRUE(inbox.WaitFor(1));
  }
  {
    PrepareQueue q([](const std::wstring&, const std::wstring&, uint32_t) -> Outcome {
                     throw std::runtime_error("boom");
                   },
                   inbox.poster());
    q.Submit(L"s", L"d2", 720, [&](const Outcome& o) { got.push_back(o); });
    ASSERT_TRUE(inbox.WaitFor(2));
  }
  inbox.Drain();
  ASSERT_EQ(got.size(), 2u);
  EXPECT_EQ(got[0].code, -2);
  EXPECT_EQ(got[0].error, "decode failed");
  EXPECT_EQ(got[1].code, kWorkThrew);
  EXPECT_EQ(got[1].error, "boom");
}

TEST(PrepareQueue, DestructorWaitsForTheRunningJobAndCancelsThePending) {
  Inbox inbox;
  Gate gate;
  std::vector<int32_t> codes;
  auto q = std::make_unique<PrepareQueue>(gate.work(0), inbox.poster());
  q->Submit(L"a", L"running", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  ASSERT_TRUE(gate.WaitStarted(1));
  q->Submit(L"b", L"pending", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  std::thread opener([&] {
    std::this_thread::sleep_for(100ms);
    gate.Open();
  });
  const auto t0 = std::chrono::steady_clock::now();
  q.reset();  // must block until the running job finishes
  const auto waited = std::chrono::steady_clock::now() - t0;
  opener.join();
  EXPECT_GE(waited, 80ms);
  inbox.Drain();
  EXPECT_EQ(codes, (std::vector<int32_t>{0, kCancelled}));
  EXPECT_EQ(gate.started().size(), 1u) << "the pending job must never start once teardown began";
}
```

- [ ] **Step 3: 构建，确认失败**

```powershell
$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
& $cmake --build C:\Users\Administrator\code\aipet\native\build --config Debug --target prepare_queue_tests
```

Expected：编译失败，找不到 `prepare_queue/prepare_queue.h`（或 `src/prepare_queue.cpp`）。

- [ ] **Step 4: 实现头文件 `include/prepare_queue/prepare_queue.h`**

```cpp
#pragma once

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace prepare_queue {

struct Outcome {
  int32_t code = 0;  // 0 ok; pet_matte_prepare's negative codes; kWorkThrew; kCancelled
  std::string error;
};

inline constexpr int32_t kWorkThrew = -99;
inline constexpr int32_t kCancelled = -100;

// Runs prepare jobs on exactly ONE worker thread -- pet_matte_last_error() is a
// process-wide string, so pet_matte_prepare must never run concurrently -- and
// hands every result back through `post`, never on the worker itself (the
// plugin's post lands on the platform thread, the only place a Flutter
// MethodResult may be answered). Jobs are keyed by destination: a Submit for a
// destination that is already queued or running only adds a waiter.
class PrepareQueue {
 public:
  using Work = std::function<Outcome(const std::wstring& src, const std::wstring& dst, uint32_t edge)>;
  using Task = std::function<void()>;
  using Post = std::function<void(Task)>;
  using Done = std::function<void(const Outcome&)>;

  PrepareQueue(Work work, Post post);
  // Lets the running job finish (joins the worker), then posts kCancelled to
  // every job that never started. `post` must still work while this runs.
  ~PrepareQueue();

  PrepareQueue(const PrepareQueue&) = delete;
  PrepareQueue& operator=(const PrepareQueue&) = delete;

  void Submit(const std::wstring& src, const std::wstring& dst, uint32_t edge, Done done);

 private:
  struct Job {
    std::wstring src;
    uint32_t edge = 0;
    std::vector<Done> waiters;
  };

  void Run();

  Work work_;
  Post post_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<std::wstring> order_;    // destinations in FIFO order
  std::map<std::wstring, Job> jobs_;  // queued + running, keyed by destination
  bool stopping_ = false;
  std::thread worker_;  // declared last: started once everything above exists
};

}  // namespace prepare_queue
```

- [ ] **Step 5: 实现 `src/prepare_queue.cpp`**

```cpp
#include "prepare_queue/prepare_queue.h"

#include <exception>
#include <utility>

namespace prepare_queue {

PrepareQueue::PrepareQueue(Work work, Post post) : work_(std::move(work)), post_(std::move(post)) {
  worker_ = std::thread([this] { Run(); });
}

PrepareQueue::~PrepareQueue() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stopping_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();
  // The worker is gone, so jobs_ now holds only jobs that never started.
  for (auto& [dst, job] : jobs_) {
    for (auto& done : job.waiters) {
      post_([done] { done(Outcome{kCancelled, "cancelled"}); });
    }
  }
  jobs_.clear();
}

void PrepareQueue::Submit(const std::wstring& src, const std::wstring& dst, uint32_t edge, Done done) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = jobs_.find(dst);
    if (it != jobs_.end()) {
      it->second.waiters.push_back(std::move(done));
      return;
    }
    Job job;
    job.src = src;
    job.edge = edge;
    job.waiters.push_back(std::move(done));
    jobs_.emplace(dst, std::move(job));
    order_.push_back(dst);
  }
  cv_.notify_one();
}

void PrepareQueue::Run() {
  std::unique_lock<std::mutex> lk(mu_);
  while (true) {
    // stopping_ is checked between jobs only: a running prepare always finishes.
    cv_.wait(lk, [this] { return stopping_ || !order_.empty(); });
    if (stopping_) return;
    const std::wstring dst = order_.front();
    order_.pop_front();
    const std::wstring src = jobs_.at(dst).src;
    const uint32_t edge = jobs_.at(dst).edge;
    lk.unlock();

    Outcome out;
    try {
      out = work_(src, dst, edge);
    } catch (const std::exception& e) {
      out = Outcome{kWorkThrew, e.what()};
    } catch (...) {
      out = Outcome{kWorkThrew, "unknown exception"};
    }

    lk.lock();
    // Waiters that arrived while the job ran were appended to this same entry.
    std::vector<Done> waiters = std::move(jobs_.at(dst).waiters);
    jobs_.erase(dst);
    lk.unlock();
    for (auto& done : waiters) {
      post_([done, out] { done(out); });
    }
    lk.lock();
  }
}

}  // namespace prepare_queue
```

- [ ] **Step 6: 构建并运行全部原生测试**

```powershell
$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
& $cmake --build C:\Users\Administrator\code\aipet\native\build --config Debug
& "$(Split-Path $cmake)\ctest.exe" --test-dir C:\Users\Administrator\code\aipet\native\build -C Debug --output-on-failure
```

Expected：原有 49 个 + 新增 6 个 `PrepareQueue.*` 全部通过。

- [ ] **Step 7: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add native/CMakeLists.txt native/prepare_queue
git commit -m "feat(native): single-worker prepare queue with destination merge and posted results" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: 插件接入队列（抠像不再阻塞平台线程）

**Files:**
- Modify: `native/testdata/make_fixtures.ps1`；Create: `native/testdata/green_box_long.mp4`
- Create: `packages/alpha_video/example/integration_test/prepare_async_test.dart`
- Modify: `packages/alpha_video/windows/CMakeLists.txt`、`alpha_video_plugin.h`、`alpha_video_plugin.cpp`

**Interfaces:**
- Consumes: Task 8 的 `prepare_queue::PrepareQueue`、`Outcome`。
- Produces: Dart 接口 `AlphaVideo.prepare(...)` **不变**；它返回的 `Future` 现在在原生侧异步完成，同目标并发调用合并，失败仍是 `PlatformException(code: 'prepare_failed')`。

- [ ] **Step 1: 慢夹具（让「阻塞」和「异步」可区分）**

在 `native/testdata/make_fixtures.ps1` 末尾追加（ASCII）：

```powershell
# A slow fixture for the async-prepare test: 1280x1280, 5 s, so a blocking
# prepare holds the platform thread long enough to measure.
$long = Join-Path $PSScriptRoot "green_box_long.mp4"
ffmpeg -y -f lavfi -i "color=c=0x00FF00:s=1280x1280:d=5:r=24" `
  -f lavfi -i "color=c=white:s=300x300:d=5:r=24" `
  -filter_complex "[0:v][1:v]overlay=x='100+n*6':y=200:shortest=1,gblur=sigma=1" `
  -c:v libx264 -pix_fmt yuv420p -an $long
Write-Host "wrote $long"
```

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Administrator\code\aipet\native\testdata\make_fixtures.ps1
(Get-Item C:\Users\Administrator\code\aipet\native\testdata\green_box_long.mp4).Length
```

Expected：文件存在，小于 1 MB（纯色加一个方块，压缩率极高）。

- [ ] **Step 2: 写失败的集成测试**

`packages/alpha_video/example/integration_test/prepare_async_test.dart`：

```dart
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final src = '${Directory.current.path}\\..\\..\\..\\native\\testdata\\green_box_long.mp4';
  String tmp(String name) =>
      '${Directory.systemTemp.path}\\${name}_${DateTime.now().microsecondsSinceEpoch}.aipmat';

  // Platform-thread method calls are answered in order. If prepare blocks that
  // thread, a cheap call issued right after it waits for the whole prepare.
  testWidgets('another method call is answered while prepare runs', (tester) async {
    final total = Stopwatch()..start();
    final prep = AlphaVideo.prepare(source: src, destination: tmp('async'), targetEdge: 720);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final ping = Stopwatch()..start();
    expect(await AlphaVideo.abiVersion(), 1);
    ping.stop();
    expect(await prep, 0);
    total.stop();
    expect(total.elapsedMilliseconds, greaterThan(400),
        reason: 'fixture too fast to tell blocking from async (${total.elapsedMilliseconds} ms)');
    expect(ping.elapsedMilliseconds, lessThan(total.elapsedMilliseconds ~/ 4),
        reason: 'abiVersion waited ${ping.elapsedMilliseconds} ms behind a ${total.elapsedMilliseconds} ms prepare');
  });

  testWidgets('two prepares of one destination both succeed', (tester) async {
    final dst = tmp('merge');
    final r = await Future.wait([
      AlphaVideo.prepare(source: src, destination: dst, targetEdge: 320),
      AlphaVideo.prepare(source: src, destination: dst, targetEdge: 320),
    ]);
    expect(r, [0, 0]);
    expect(File(dst).existsSync(), isTrue);
  });

  testWidgets('a missing source still fails with prepare_failed', (tester) async {
    await expectLater(
      AlphaVideo.prepare(source: 'C:\\nope\\missing.mp4', destination: tmp('missing')),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'prepare_failed')),
    );
  });
}
```

- [ ] **Step 3: 运行，确认第一个测试失败**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\packages\alpha_video\example
flutter test integration_test\prepare_async_test.dart -d windows
```

Expected：`another method call is answered while prepare runs` **失败**，原因是 `abiVersion waited ~N ms behind a ~N ms prepare`（两者接近）。另两个测试通过。**如果第一个测试此时就通过了，停下来**：说明测试测不出阻塞，要先把夹具加长，而不是继续改插件。

- [ ] **Step 4: 插件 CMake 链接队列**

`packages/alpha_video/windows/CMakeLists.txt`：把

```cmake
target_link_libraries(${PLUGIN_NAME} PRIVATE pet_matte frame_source)
```

改为

```cmake
target_link_libraries(${PLUGIN_NAME} PRIVATE pet_matte frame_source prepare_queue)
```

- [ ] **Step 5: 头文件 `alpha_video_plugin.h`**

在 `struct Clip;` 前加：

```cpp
namespace prepare_queue {
class PrepareQueue;
}  // namespace prepare_queue
```

在 `namespace alpha_video {` 之前（`#include <memory>` 之后）加一行前向声明（HWND 在 STRICT 下就是 `HWND__*`，这样头文件不必引入 `<windows.h>`）：

```cpp
struct HWND__;
```

在私有成员 `std::map<int64_t, std::shared_ptr<Clip>> clips_;` 之后加：

```cpp
  // Message-only window created on the platform thread. Worker-thread
  // prepare results are PostMessage'd here so that the MethodResult reply
  // runs on the platform thread, the only thread Flutter allows it on.
  HWND__* message_window_ = nullptr;

  // Single-worker queue running pet_matte_prepare off the platform thread
  // (spec 6). Null only if message_window_ could not be created, in which
  // case "prepare" falls back to the old blocking call.
  std::unique_ptr<prepare_queue::PrepareQueue> prepare_queue_;
```

- [ ] **Step 6: 实现 `alpha_video_plugin.cpp`**

(a) `#include "pet_matte/pet_matte.h"` 之后加：

```cpp
#include "prepare_queue/prepare_queue.h"

#include <objbase.h>
```

(b) 在第二个匿名命名空间（`StartTicker` 所在的那个）里，`StartTicker` 之后加：

```cpp
constexpr UINT kRunOnPlatformThread = WM_APP + 0x51;
constexpr wchar_t kMessageWindowClass[] = L"AipetAlphaVideoPlatformThread";

// Runs on the platform thread: the window is created there.
LRESULT CALLBACK PlatformThreadProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kRunOnPlatformThread) {
    std::unique_ptr<prepare_queue::PrepareQueue::Task> task(
        reinterpret_cast<prepare_queue::PrepareQueue::Task*>(lp));
    (*task)();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

HWND CreatePlatformThreadWindow() {
  static const bool registered = [] {
    WNDCLASSW wc{};
    wc.lpfnWndProc = PlatformThreadProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kMessageWindowClass;
    return RegisterClassW(&wc) != 0;
  }();
  (void)registered;  // a second engine reuses the class; CreateWindowExW reports real failures
  return CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                         GetModuleHandleW(nullptr), nullptr);
}

// Worker thread. Media Foundation gets a COM apartment of its own here; on
// the platform thread (blocking fallback) CoInitializeEx fails with
// RPC_E_CHANGED_MODE and nothing is uninitialized.
prepare_queue::Outcome RunPetMattePrepare(const std::wstring& src, const std::wstring& dst, uint32_t edge) {
  const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const int32_t code = pet_matte_prepare(src.c_str(), dst.c_str(), edge);
  prepare_queue::Outcome out{code, code != 0 ? pet_matte_last_error() : ""};
  if (SUCCEEDED(hr)) CoUninitialize();
  return out;
}
```

(c) 构造函数替换为：

```cpp
AlphaVideoPlugin::AlphaVideoPlugin(flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar), message_window_(CreatePlatformThreadWindow()) {
  if (!message_window_) return;
  HWND hwnd = message_window_;
  prepare_queue_ = std::make_unique<prepare_queue::PrepareQueue>(
      RunPetMattePrepare, [hwnd](prepare_queue::PrepareQueue::Task task) {
        auto* boxed = new prepare_queue::PrepareQueue::Task(std::move(task));
        if (!PostMessageW(hwnd, kRunOnPlatformThread, 0, reinterpret_cast<LPARAM>(boxed))) delete boxed;
      });
}
```

(d) 析构函数开头（在现有 `while (!clips_.empty())` 循环之前）插入：

```cpp
  // Stop the queue first: it joins the worker (a running prepare finishes)
  // and posts cancellations for jobs that never started. This engine is going
  // away and nobody awaits those replies, so drop every posted task without
  // running it, then destroy the window.
  prepare_queue_.reset();
  if (message_window_) {
    MSG msg;
    while (PeekMessageW(&msg, message_window_, kRunOnPlatformThread, kRunOnPlatformThread, PM_REMOVE)) {
      delete reinterpret_cast<prepare_queue::PrepareQueue::Task*>(msg.lParam);
    }
    DestroyWindow(message_window_);
    message_window_ = nullptr;
  }
```

(e) `"prepare"` 分支里，从 `// pet_matte_prepare 的负返回码携带的错误详情` 这段注释开始到该分支的 `return;`（原第 382–394 行）整段替换为：

```cpp
      if (!prepare_queue_) {  // no message window: keep the old blocking path
        const prepare_queue::Outcome o = RunPetMattePrepare(wsrc, wdst, static_cast<uint32_t>(edge));
        if (o.code != 0) {
          result->Error("prepare_failed", o.error, flutter::EncodableValue(o.code));
        } else {
          result->Success(flutter::EncodableValue(o.code));
        }
        return;
      }
      // Answered later on the platform thread (PlatformThreadProc runs the
      // posted Done). Failures still arrive as Error("prepare_failed", ...)
      // carrying pet_matte_last_error(), as before.
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> pending(std::move(result));
      prepare_queue_->Submit(wsrc, wdst, static_cast<uint32_t>(edge),
                             [pending](const prepare_queue::Outcome& o) {
                               if (o.code != 0) {
                                 pending->Error("prepare_failed", o.error, flutter::EncodableValue(o.code));
                               } else {
                                 pending->Success(flutter::EncodableValue(o.code));
                               }
                             });
      return;
```

(f) 文件末尾的 `catch` 改为（`result` 可能已经在上面被移走）：

```cpp
  } catch (const std::exception& e) {
    if (result) result->Error("bad_args", e.what());
  }
```

- [ ] **Step 7: 运行，确认全部通过**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\packages\alpha_video\example
flutter test integration_test -d windows
Set-Location C:\Users\Administrator\code\aipet\apps\pet_shell
flutter build windows --release
```

Expected：`prepare_async_test.dart` 三个全部通过，原有 `plugin_test`、`texture_test`、`playback_test` 仍通过；pet_shell 仍能编译（它用的也是这个插件）。

- [ ] **Step 8: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add native/testdata packages/alpha_video
git commit -m "fix(alpha_video): run prepare on a worker thread, reply on the platform thread (HANDOFF item 2)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: 抠像缓存 `MatteCache`

spec 4.2：键 = 源视频内容 sha256 前 32 位 + `-p1`；先写 `.staging\` 临时文件，成功后原子改名；同一内容并发只抠一次。

**Files:**
- Create: `apps/aipet/lib/services/matte_cache.dart`
- Test: `apps/aipet/test/services/matte_cache_test.dart`

**Interfaces:**
- Produces:
  - `const String kMattePipelineVersion = 'p1'`
  - `typedef PrepareFn = Future<void> Function({required String source, required String destination})`
  - `class MatteCache { MatteCache({required Directory root, required PrepareFn prepare}); static String keyFor(List<int> bytes); Future<File> ensure(File source); }`
  - 生产用的 `PrepareFn` 在 Task 13 接到 `AlphaVideo.prepare(..., targetEdge: 720)`；本文件不依赖插件，单元测试不需要原生代码。

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/matte_cache_test.dart`：

```dart
import 'dart:async';
import 'dart:io';

import 'package:aipet/services/matte_cache.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePrepare {
  int calls = 0;
  final destinations = <String>[];
  Completer<void>? gate;
  Object? error;

  Future<void> call({required String source, required String destination}) async {
    calls++;
    destinations.add(destination);
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    File(destination).writeAsStringSync('matted:${File(source).readAsStringSync()}');
  }
}

void main() {
  late Directory tmp, root;
  late FakePrepare prepare;
  late MatteCache cache;

  File clip(String name, String content) =>
      File('${tmp.path}\\$name')..writeAsStringSync(content);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('matte_');
    root = Directory('${tmp.path}\\matte-cache\\v1');
    prepare = FakePrepare();
    cache = MatteCache(root: root, prepare: prepare.call);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('key is 32 hex chars of sha256 plus the pipeline version', () {
    final k = MatteCache.keyFor('abc'.codeUnits);
    expect(k, matches(RegExp(r'^[0-9a-f]{32}-p1$')));
    expect(k, startsWith('ba7816bf8f01cfea414140de5dae2223')); // sha256("abc")
    expect(MatteCache.keyFor('abd'.codeUnits), isNot(k));
  });

  test('first use mattes into staging, then renames into the cache', () async {
    final f = await cache.ensure(clip('stand.mp4', 'A'));
    expect(prepare.calls, 1);
    expect(prepare.destinations.single, contains('\\.staging\\'));
    expect(f.path, '${root.path}\\${MatteCache.keyFor('A'.codeUnits)}.aipmat');
    expect(f.readAsStringSync(), 'matted:A');
    expect(Directory('${root.path}\\.staging').listSync(), isEmpty);
  });

  test('a cached clip is not matted again', () async {
    final src = clip('stand.mp4', 'A');
    await cache.ensure(src);
    await cache.ensure(src);
    expect(prepare.calls, 1);
  });

  test('keyed by content: the same clip under two paths is matted once', () async {
    final a = await cache.ensure(clip('a.mp4', 'same'));
    final b = await cache.ensure(clip('b.mp4', 'same'));
    expect(prepare.calls, 1);
    expect(b.path, a.path);
  });

  test('concurrent requests share one prepare', () async {
    prepare.gate = Completer<void>();
    final src = clip('walk.mp4', 'W');
    final f1 = cache.ensure(src);
    final f2 = cache.ensure(src);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    prepare.gate!.complete();
    final r = await Future.wait([f1, f2]);
    expect(prepare.calls, 1);
    expect(r[0].path, r[1].path);
  });

  test('a failed prepare leaves nothing behind and the next call retries', () async {
    prepare.error = Exception('decode failed');
    final src = clip('sleep.mp4', 'S');
    await expectLater(cache.ensure(src), throwsException);
    expect(root.listSync().whereType<File>(), isEmpty);
    expect(Directory('${root.path}\\.staging').listSync(), isEmpty);
    prepare.error = null;
    expect((await cache.ensure(src)).readAsStringSync(), 'matted:S');
    expect(prepare.calls, 2);
  });
}
```

- [ ] **Step 2: 运行，确认失败**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter test test/services/matte_cache_test.dart
```

- [ ] **Step 3: 实现 `lib/services/matte_cache.dart`**

```dart
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Bump when pet_matte's output changes, so old caches are not reused.
const String kMattePipelineVersion = 'p1';

typedef PrepareFn = Future<void> Function({required String source, required String destination});

/// Content-addressed .aipmat cache (spec 4.2). Keyed by what the clip IS, not
/// where it lives: the install folder can move, and an upgrade can ship a
/// different clip under the same name.
class MatteCache {
  MatteCache({required this.root, required PrepareFn prepare}) : _prepare = prepare;

  final Directory root;
  final PrepareFn _prepare;
  final Map<String, Future<File>> _inFlight = {};

  static String keyFor(List<int> bytes) =>
      '${sha256.convert(bytes).toString().substring(0, 32)}-$kMattePipelineVersion';

  /// The matted clip for [source], matting it first if it is not cached yet.
  Future<File> ensure(File source) async {
    final key = keyFor(await source.readAsBytes());
    final done = File('${root.path}${Platform.pathSeparator}$key.aipmat');
    if (done.existsSync()) return done;
    return _inFlight[key] ??= _build(source, key, done).whenComplete(() => _inFlight.remove(key));
  }

  Future<File> _build(File source, String key, File done) async {
    final staging = Directory('${root.path}${Platform.pathSeparator}.staging')..createSync(recursive: true);
    final tmp = File('${staging.path}${Platform.pathSeparator}$key.$pid.tmp');
    try {
      await _prepare(source: source.path, destination: tmp.path);
      return await tmp.rename(done.path); // same volume: atomic, never a half-written cache file
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }
}
```

- [ ] **Step 4: 运行，确认通过**

```powershell
flutter test test/services/matte_cache_test.dart
```

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/services/matte_cache.dart apps/aipet/test/services/matte_cache_test.dart
git commit -m "feat(aipet): content-addressed matte cache with staging and merged prepares" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: 窗口通道协议 `window_bridge`

spec 3.2。通道后面藏一个 `BridgeTransport` 接口：生产实现包 `WindowMethodChannel('aipet/pet')`，测试用内存里的一对假通道。**失败不靠跨引擎抛异常传递**（desktop_multi_window 是否转发异常未验证），`adopt` 的结果是返回值 `{ok, code, message}`。

**Files:**
- Create: `apps/aipet/lib/services/window_bridge.dart`、`apps/aipet/test/support/fake_transport.dart`
- Test: `apps/aipet/test/services/window_bridge_test.dart`

**Interfaces:**
- Consumes: Task 5 的 `LibraryState`。
- Produces:
  - `abstract final class BridgeMethods { getState, adopt, stateChanged, mainWindowClosing, quit }`（字符串常量）
  - `typedef BridgeHandler = Future<Object?> Function(String method, Object? args)`；`abstract class BridgeTransport { Future<Object?> invoke(String method, [Object? args]); void setHandler(BridgeHandler? handler); }`；`class WindowChannelTransport implements BridgeTransport`
  - `class AdoptError implements Exception { final String code; final String message; }`（code：`unknown_pet`、`missing_assets`、`busy`、`prepare_failed`）；`class BridgeTimeout implements Exception { final String stage; }`（stage：`getState`、`ack`、`adopt`）
  - 宠物窗端 `class PetWindowBridge { PetWindowBridge(BridgeTransport, {required LibraryState Function() state, required Future<void> Function(String petId) onAdopt, required Future<void> Function() onMainWindowClosing, required Future<void> Function() onQuit}); void start(); Future<void> pushState(LibraryState s); }`
  - 主窗口端 `class MainWindowBridge { MainWindowBridge(BridgeTransport, {Duration ackTimeout = 3s, Duration adoptTimeout = 60s}); void start(); Stream<LibraryState> get states; Future<LibraryState> getState(); Future<void> adopt(String petId); Future<void> notifyClosing(); void quit(); Future<void> dispose(); }`

- [ ] **Step 1: 测试辅助 `test/support/fake_transport.dart`**

```dart
import 'dart:async';

import 'package:aipet/services/window_bridge.dart';

/// Two in-memory ends of one channel. Values are copied the way the platform
/// channel copies them (maps arrive as Map<Object?, Object?>).
class FakeTransport implements BridgeTransport {
  FakeTransport._();

  late FakeTransport peer;
  BridgeHandler? _handler;

  /// When true, calls arriving at THIS end never get an answer (a hung window).
  bool silent = false;

  static (FakeTransport, FakeTransport) pair() {
    final a = FakeTransport._();
    final b = FakeTransport._();
    a.peer = b;
    b.peer = a;
    return (a, b);
  }

  @override
  Future<Object?> invoke(String method, [Object? args]) async {
    final h = peer._handler;
    if (h == null) throw StateError('nothing is listening on the other side');
    if (peer.silent) return Completer<Object?>().future;
    return _wire(await h(method, _wire(args)));
  }

  @override
  void setHandler(BridgeHandler? handler) => _handler = handler;
}

Object? _wire(Object? v) {
  if (v is Map) return <Object?, Object?>{for (final e in v.entries) e.key: _wire(e.value)};
  if (v is List) return <Object?>[for (final x in v) _wire(x)];
  return v;
}
```

- [ ] **Step 2: 写失败的测试**

`apps/aipet/test/services/window_bridge_test.dart`：

```dart
import 'dart:async';

import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

void main() {
  late FakeTransport petEnd, mainEnd;
  late LibraryState state;
  late PetWindowBridge pet;
  late MainWindowBridge main;
  late Future<void> Function(String) adoptImpl;
  var closing = 0, quits = 0;

  setUp(() {
    (petEnd, mainEnd) = FakeTransport.pair();
    state = const LibraryState(currentPetId: 'a', adoptedPetIds: ['a']);
    closing = 0;
    quits = 0;
    adoptImpl = (id) async {};
    pet = PetWindowBridge(petEnd,
        state: () => state,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async => closing++,
        onQuit: () async => quits++)
      ..start();
    main = MainWindowBridge(mainEnd,
        ackTimeout: const Duration(milliseconds: 50), adoptTimeout: const Duration(milliseconds: 500))
      ..start();
  });
  tearDown(() => main.dispose());

  test('getState returns what the pet window holds', () async {
    expect(await main.getState(), state);
  });

  test('adopt: ack via stateChanged, then success', () async {
    final seen = <LibraryState>[];
    main.states.listen(seen.add);
    adoptImpl = (id) async {
      state = state.preparing(id);
      await pet.pushState(state);
      await Future<void>.delayed(const Duration(milliseconds: 100)); // longer than ackTimeout
      state = state.adopted(id);
      await pet.pushState(state);
    };
    await main.adopt('b');
    expect(seen.map((s) => s.preparingPetId), ['b', null]);
    expect(seen.last.currentPetId, 'b');
  });

  test('adopt failure comes back as AdoptError with its code', () async {
    adoptImpl = (id) async {
      await pet.pushState(state.preparing(id));
      throw const AdoptError('missing_assets', 'sleep.mp4');
    };
    await expectLater(
        main.adopt('b'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'missing_assets')));
  });

  test('no ack within the timeout is a BridgeTimeout(ack)', () async {
    adoptImpl = (id) => Completer<void>().future; // never pushes, never finishes
    await expectLater(main.adopt('b'), throwsA(isA<BridgeTimeout>().having((e) => e.stage, 'stage', 'ack')));
  });

  test('a hung pet window makes getState time out', () async {
    petEnd.silent = true;
    await expectLater(main.getState(), throwsA(isA<BridgeTimeout>()));
  });

  test('pushing state with no main window open is harmless', () async {
    mainEnd.setHandler(null);
    await pet.pushState(state); // must not throw
  });

  test('closing and quit reach the pet window', () async {
    await main.notifyClosing();
    main.quit();
    await Future<void>.delayed(Duration.zero);
    expect(closing, 1);
    expect(quits, 1);
  });
}
```

- [ ] **Step 3: 运行，确认失败**

```powershell
flutter test test/services/window_bridge_test.dart
```

- [ ] **Step 4: 实现 `lib/services/window_bridge.dart`**

```dart
import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../domain/library_state.dart';

/// Spec 3.2. Small messages only; clips never cross the channel.
abstract final class BridgeMethods {
  static const getState = 'getState';
  static const adopt = 'adopt';
  static const stateChanged = 'stateChanged';
  static const mainWindowClosing = 'mainWindowClosing';
  static const quit = 'quit';
}

typedef BridgeHandler = Future<Object?> Function(String method, Object? args);

abstract class BridgeTransport {
  Future<Object?> invoke(String method, [Object? args]);
  void setHandler(BridgeHandler? handler);
}

class WindowChannelTransport implements BridgeTransport {
  WindowChannelTransport([this._channel = const WindowMethodChannel('aipet/pet')]);

  final WindowMethodChannel _channel;

  @override
  Future<Object?> invoke(String method, [Object? args]) => _channel.invokeMethod<Object?>(method, args);

  @override
  void setHandler(BridgeHandler? handler) {
    unawaited(_channel.setMethodCallHandler(
        handler == null ? null : (call) => handler(call.method, call.arguments)));
  }
}

class AdoptError implements Exception {
  const AdoptError(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'AdoptError($code: $message)';
}

class BridgeTimeout implements Exception {
  const BridgeTimeout(this.stage);
  final String stage;
  @override
  String toString() => 'BridgeTimeout($stage)';
}

/// Pet-window end. The pet window owns the state; the main window only asks.
class PetWindowBridge {
  PetWindowBridge(
    this._transport, {
    required this.state,
    required this.onAdopt,
    required this.onMainWindowClosing,
    required this.onQuit,
  });

  final BridgeTransport _transport;
  final LibraryState Function() state;

  /// Must push a preparing state right away, finish once the pet is on the
  /// desktop, and throw [AdoptError] on failure.
  final Future<void> Function(String petId) onAdopt;
  final Future<void> Function() onMainWindowClosing;
  final Future<void> Function() onQuit;

  void start() => _transport.setHandler(_handle);

  Future<Object?> _handle(String method, Object? args) async {
    switch (method) {
      case BridgeMethods.getState:
        return state().toJson();
      case BridgeMethods.adopt:
        final petId = (args! as Map<Object?, Object?>)['petId']! as String;
        try {
          await onAdopt(petId);
          return {'ok': true};
        } on AdoptError catch (e) {
          return {'ok': false, 'code': e.code, 'message': e.message};
        }
      case BridgeMethods.mainWindowClosing:
        await onMainWindowClosing();
        return null;
      case BridgeMethods.quit:
        unawaited(onQuit()); // answer before the process goes away
        return null;
      default:
        return null;
    }
  }

  /// Best effort: the main window may simply not be open.
  Future<void> pushState(LibraryState s) async {
    try {
      await _transport.invoke(BridgeMethods.stateChanged, s.toJson()).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}

/// Main-window end.
class MainWindowBridge {
  MainWindowBridge(
    this._transport, {
    this.ackTimeout = const Duration(seconds: 3),
    this.adoptTimeout = const Duration(seconds: 60),
  });

  final BridgeTransport _transport;
  final Duration ackTimeout;
  final Duration adoptTimeout;
  final _states = StreamController<LibraryState>.broadcast();

  Stream<LibraryState> get states => _states.stream;

  void start() => _transport.setHandler((method, args) async {
        if (method == BridgeMethods.stateChanged && !_states.isClosed) {
          _states.add(LibraryState.fromJson(args! as Map<Object?, Object?>));
        }
        return null;
      });

  Future<LibraryState> getState() async {
    try {
      final v = await _transport.invoke(BridgeMethods.getState).timeout(ackTimeout);
      return LibraryState.fromJson(v! as Map<Object?, Object?>);
    } on TimeoutException {
      throw const BridgeTimeout('getState');
    }
  }

  /// Two-step confirmation (spec 3.2): a stateChanged naming [petId] within
  /// [ackTimeout], then the call's own result within [adoptTimeout].
  Future<void> adopt(String petId) async {
    final ack = states.firstWhere((s) => s.preparingPetId == petId || s.currentPetId == petId).timeout(ackTimeout);
    final call = _transport.invoke(BridgeMethods.adopt, {'petId': petId}).timeout(adoptTimeout);
    try {
      await ack;
    } on TimeoutException {
      call.ignore();
      throw const BridgeTimeout('ack');
    }
    final Object? r;
    try {
      r = await call;
    } on TimeoutException {
      throw const BridgeTimeout('adopt');
    }
    final m = r! as Map<Object?, Object?>;
    if (m['ok'] != true) throw AdoptError(m['code']! as String, (m['message'] as String?) ?? '');
  }

  Future<void> notifyClosing() async {
    try {
      await _transport.invoke(BridgeMethods.mainWindowClosing).timeout(ackTimeout);
    } catch (_) {}
  }

  void quit() => _transport.invoke(BridgeMethods.quit).ignore();

  Future<void> dispose() => _states.close();
}
```

- [ ] **Step 5: 运行，确认通过**

```powershell
flutter test test/services/window_bridge_test.dart
```

- [ ] **Step 6: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/services/window_bridge.dart apps/aipet/test/services/window_bridge_test.dart apps/aipet/test/support/fake_transport.dart
git commit -m "feat(aipet): window channel protocol with two-step adopt confirmation" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 12: 宠物窗控制逻辑 `PetWindowController`

宠物窗的全部决策（启动时显示谁、领养、切动作、一次性动作回待机、出错提示）集中在一个不依赖插件和窗口的类里，用假播放器测试。移植 pet_shell `main.dart` 的切换逻辑。

**Files:**
- Create: `apps/aipet/lib/app/pet_window/pet_window_controller.dart`
- Test: `apps/aipet/test/app/pet_window_controller_test.dart`

**Interfaces:**
- Consumes: Task 4 `Pet`、`isLooping`、`kIdleAction`、`labelFor`；Task 5 `LibraryState`；Task 6 `SettingsStore`；Task 7 `PetLibrary`；Task 11 `AdoptError`。
- Produces（Task 15 使用）:
  - `abstract class ClipPlayer { Future<void> play(File aipmat, {required bool loop, VoidCallback? onFinished}); Future<void> dispose(); }`
  - `typedef EnsureFn = Future<File> Function(File source)`（生产用 `MatteCache.ensure`）
  - `class PetWindowController extends ChangeNotifier { PetWindowController({required PetLibrary library, required SettingsStore settings, required EnsureFn ensure, required ClipPlayer player, required Future<void> Function(LibraryState) push}); List<Pet> get pets; LibraryState get state; Pet? get currentPet; String? get currentAction; String? get error; Future<void> boot(); Future<void> adopt(String petId); Future<void> playAction(String key); }`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/pet_window_controller_test.dart`：

```dart
import 'dart:async';
import 'dart:io';

import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pet_fixtures.dart';

class FakePlayer implements ClipPlayer {
  final plays = <String>[]; // "<petId>/<clip file name>|loop" or "|once"
  VoidCallback? lastOnFinished;
  Completer<void>? gate;

  @override
  Future<void> play(File aipmat, {required bool loop, VoidCallback? onFinished}) async {
    if (gate != null) await gate!.future;
    final parts = aipmat.path.split('\\');
    plays.add('${parts[parts.length - 2]}/${parts.last}|${loop ? 'loop' : 'once'}');
    lastOnFinished = onFinished;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory tmp, builtin, appData;
  late SettingsStore settings;
  late FakePlayer player;
  late List<LibraryState> pushed;
  late Future<File> Function(File) ensure;
  late PetWindowController c;

  PetWindowController make() => PetWindowController(
        library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
        settings: settings,
        ensure: (f) => ensure(f),
        player: player,
        push: (s) async => pushed.add(s),
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('petwin_');
    builtin = Directory('${tmp.path}\\builtin')..createSync();
    appData = Directory('${tmp.path}\\appdata');
    writePet(builtin, id: 'builtin-gold');
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat');
    writePet(builtin, id: 'builtin-broken', complete: false);
    settings = SettingsStore(appData);
    player = FakePlayer();
    pushed = [];
    ensure = (f) async => f; // "matting" returns the clip itself, so plays name the action
    c = make();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('boot', () {
    test('first run: nobody on the desktop', () async {
      await c.boot();
      expect(c.currentPet, isNull);
      expect(player.plays, isEmpty);
      expect(pushed.single, LibraryState.empty);
      expect(c.pets.map((p) => p.id), ['builtin-broken', 'builtin-gold', 'builtin-ragdoll']);
    });

    test('shows the saved pet idling', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      expect(c.currentPet?.id, 'builtin-gold');
      expect(c.currentAction, 'stand');
      expect(player.plays, ['builtin-gold/stand.mp4|loop']);
    });

    test('a saved pet whose files went missing falls back to another adopted pet', () async {
      settings.save(const LibraryState(
          currentPetId: 'builtin-broken', adoptedPetIds: ['builtin-broken', 'builtin-ragdoll']));
      await c.boot();
      expect(c.currentPet?.id, 'builtin-ragdoll');
      expect(settings.load().currentPetId, 'builtin-ragdoll');
    });

    test('...and with nobody usable left it behaves like a first run', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-broken', adoptedPetIds: ['builtin-broken']));
      await c.boot();
      expect(c.currentPet, isNull);
      expect(settings.load(), const LibraryState(adoptedPetIds: ['builtin-broken']));
    });
  });

  group('adopt', () {
    test('pushes preparing, shows the pet, saves, pushes the result', () async {
      await c.boot();
      pushed.clear();
      await c.adopt('builtin-gold');
      expect(pushed.map((s) => (s.preparingPetId, s.currentPetId)), [
        ('builtin-gold', null),
        (null, 'builtin-gold'),
      ]);
      expect(player.plays, ['builtin-gold/stand.mp4|loop']);
      expect(settings.load(), const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
    });

    test('adopting the current pet again just re-announces the state', () async {
      await c.boot();
      await c.adopt('builtin-gold');
      pushed.clear();
      await c.adopt('builtin-gold');
      expect(pushed.single.currentPetId, 'builtin-gold');
      expect(player.plays, hasLength(1));
    });

    test('unknown and incomplete pets are refused', () async {
      await c.boot();
      await expectLater(c.adopt('nope'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'unknown_pet')));
      await expectLater(
          c.adopt('builtin-broken'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'missing_assets')));
    });

    test('a second adopt while one is preparing is busy', () async {
      await c.boot();
      player.gate = Completer<void>();
      final first = c.adopt('builtin-gold');
      await Future<void>.delayed(Duration.zero);
      await expectLater(c.adopt('builtin-ragdoll'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'busy')));
      player.gate!.complete();
      await first;
    });

    test('a failed prepare keeps the old pet and clears preparing', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      pushed.clear();
      ensure = (f) async => throw Exception('decode failed');
      await expectLater(
          c.adopt('builtin-ragdoll'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'prepare_failed')));
      expect(c.state, const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      expect(pushed.map((s) => s.preparingPetId), ['builtin-ragdoll', null]);
      expect(player.plays, ['builtin-gold/stand.mp4|loop']);
    });
  });

  group('actions', () {
    setUp(() => settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold'])));

    test('a one-shot plays once and hands back to stand', () async {
      await c.boot();
      await c.playAction('lick_paw');
      expect(player.plays.last, 'builtin-gold/lick_paw.mp4|once');
      expect(c.currentAction, 'lick_paw');
      player.lastOnFinished!();
      await Future<void>.delayed(Duration.zero);
      expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
      expect(c.currentAction, 'stand');
    });

    test('choosing the looping action already on screen does nothing', () async {
      await c.boot();
      await c.playAction('stand');
      expect(player.plays, hasLength(1));
    });

    test('a failed action keeps the current one and shows a short message', () async {
      await c.boot();
      ensure = (f) async => throw Exception('decode failed');
      await c.playAction('sleep');
      expect(c.currentAction, 'stand');
      expect(c.error, contains('睡觉'));
    });

    test('actions the pet does not have are ignored', () async {
      await c.boot();
      await c.playAction('backflip');
      expect(player.plays, hasLength(1));
    });
  });
}
```

- [ ] **Step 2: 运行，确认失败**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter test test/app/pet_window_controller_test.dart
```

- [ ] **Step 3: 实现 `lib/app/pet_window/pet_window_controller.dart`**

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import '../../services/pet_library.dart';
import '../../services/settings_store.dart';
import '../../services/window_bridge.dart';

/// Playback as the controller sees it; AlphaClipPlayer (Task 15) is the real one.
abstract class ClipPlayer {
  /// Puts [aipmat] on screen and starts it. The previous clip stays visible
  /// until this returns. For a one-shot ([loop] false), [onFinished] runs once
  /// when its last frame is shown.
  Future<void> play(File aipmat, {required bool loop, VoidCallback? onFinished});

  Future<void> dispose();
}

/// The matted .aipmat for a clip: MatteCache.ensure in production.
typedef EnsureFn = Future<File> Function(File source);

/// Everything the pet window decides. The only writer of settings.json.
class PetWindowController extends ChangeNotifier {
  PetWindowController({
    required PetLibrary library,
    required SettingsStore settings,
    required EnsureFn ensure,
    required ClipPlayer player,
    required Future<void> Function(LibraryState state) push,
  })  : _library = library,
        _settings = settings,
        _ensure = ensure,
        _player = player,
        _push = push;

  final PetLibrary _library;
  final SettingsStore _settings;
  final EnsureFn _ensure;
  final ClipPlayer _player;
  final Future<void> Function(LibraryState) _push;

  List<Pet> _pets = const [];
  LibraryState _state = LibraryState.empty;
  String? _currentAction;
  String? _error;
  bool _switching = false;

  List<Pet> get pets => _pets;
  LibraryState get state => _state;
  String? get currentAction => _currentAction;
  String? get error => _error;
  Pet? get currentPet => _state.currentPetId == null ? null : PetLibrary.byId(_pets, _state.currentPetId!);

  /// Spec 3.3 / 7: the saved pet if its folder is still complete, otherwise
  /// another adopted one, otherwise nobody (first-run behaviour).
  Future<void> boot() async {
    _pets = _library.scan();
    final saved = _settings.load();
    bool usable(String id) => PetLibrary.byId(_pets, id)?.isComplete ?? false;
    var s = saved;
    if (saved.currentPetId != null && !usable(saved.currentPetId!)) {
      s = LibraryState(
          currentPetId: saved.adoptedPetIds.where(usable).firstOrNull, adoptedPetIds: saved.adoptedPetIds);
      _settings.save(s);
    }
    _state = s;
    notifyListeners();
    if (currentPet != null) await _show(kIdleAction);
    await _push(_state);
  }

  /// Throws [AdoptError]. The old pet keeps playing until the new one's idle
  /// clip is matted and on screen (spec 6).
  Future<void> adopt(String petId) async {
    final pet = PetLibrary.byId(_pets, petId);
    if (pet == null) throw const AdoptError('unknown_pet');
    if (!pet.isComplete) throw const AdoptError('missing_assets');
    if (_state.currentPetId == petId && _state.preparingPetId == null) {
      await _push(_state); // the main window waits for a state naming this pet
      return;
    }
    if (_switching || _state.preparingPetId != null) throw const AdoptError('busy');

    _state = _state.preparing(petId);
    notifyListeners();
    await _push(_state);
    _switching = true;
    try {
      final clip = await _ensure(pet.actionFile(kIdleAction));
      await _player.play(clip, loop: true);
    } catch (e) {
      _state = _state.preparing(null);
      notifyListeners();
      await _push(_state);
      throw AdoptError('prepare_failed', '$e');
    } finally {
      _switching = false;
    }
    _state = _state.adopted(petId);
    _currentAction = kIdleAction;
    _error = null;
    _settings.save(_state);
    notifyListeners();
    await _push(_state);
  }

  Future<void> playAction(String key) async {
    final pet = currentPet;
    if (pet == null || !pet.actions.contains(key)) return;
    if (_switching || _state.preparingPetId != null) return;
    if (key == _currentAction && isLooping(key)) return;
    await _show(key);
  }

  Future<void> _show(String key) async {
    final pet = currentPet!;
    _switching = true;
    try {
      final clip = await _ensure(pet.actionFile(key));
      final loop = isLooping(key);
      await _player.play(clip, loop: loop, onFinished: loop ? null : () => playAction(kIdleAction));
      _currentAction = key;
      _error = null;
    } catch (e) {
      _error = '「${labelFor(key)}」准备失败';
    } finally {
      _switching = false;
      notifyListeners();
    }
  }
}
```

- [ ] **Step 4: 运行，确认通过**

```powershell
flutter test test/app/pet_window_controller_test.dart
```

- [ ] **Step 5: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/app/pet_window/pet_window_controller.dart apps/aipet/test/app/pet_window_controller_test.dart
git commit -m "feat(aipet): pet window controller (boot fallback, adopt, one-shot return)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 13: 主窗口主题与宠物卡片

**Files:**
- Create: `apps/aipet/lib/app/main_window/theme.dart`、`apps/aipet/lib/app/main_window/pet_card.dart`
- Test: `apps/aipet/test/app/pet_card_test.dart`

**Interfaces:**
- Consumes: Task 4 `Pet`；Task 5 `CardStatus`。
- Produces（Task 14 使用）:
  - `abstract final class AppColors { page, card, accent, accentSoft, text, textMuted }`；`ThemeData buildAppTheme()`
  - `class PetCard extends StatelessWidget { const PetCard({required Pet pet, required CardStatus status, required VoidCallback onAdopt}); }`——只有 `adoptable`、`switchable` 两种状态会调用 `onAdopt`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/pet_card_test.dart`：

```dart
import 'dart:io';

import 'package:aipet/app/main_window/pet_card.dart';
import 'package:aipet/app/main_window/theme.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _pet = Pet(
  id: 'builtin-gold',
  name: '金毛',
  species: Species.dog,
  origin: PetOrigin.builtin,
  blurb: '温柔的大暖男，走到哪跟到哪',
  dir: Directory('C:\\nowhere'),
  cover: 'cover.png',
  actions: const ['stand'],
);

void main() {
  Future<List<int>> pump(WidgetTester tester, CardStatus status) async {
    final taps = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 200, height: 300, child: PetCard(pet: _pet, status: status, onAdopt: () => taps.add(1))),
        ),
      ),
    ));
    return taps;
  }

  const cases = {
    CardStatus.adoptable: ('带它回家', true),
    CardStatus.switchable: ('换它陪我', true),
    CardStatus.companion: ('陪伴中', false),
    CardStatus.preparing: ('正在准备…', false),
    CardStatus.missing: ('素材缺失', false),
  };

  for (final MapEntry(key: status, value: (label, enabled)) in cases.entries) {
    testWidgets('$status shows "$label" and is ${enabled ? 'tappable' : 'disabled'}', (tester) async {
      final taps = await pump(tester, status);
      expect(find.text('金毛'), findsOneWidget);
      expect(find.text('温柔的大暖男，走到哪跟到哪'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed != null, enabled);
      await tester.tap(find.text(label));
      expect(taps.length, enabled ? 1 : 0);
    });
  }

  testWidgets('preparing shows a spinner', (tester) async {
    await pump(tester, CardStatus.preparing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  test('palette matches the spec', () {
    expect(AppColors.page, const Color(0xFFFFF8F0));
    expect(AppColors.card, const Color(0xFFFFFFFF));
    expect(AppColors.accent, const Color(0xFFF08A3C));
    expect(AppColors.accentSoft, const Color(0xFFFDEBD9));
    expect(AppColors.text, const Color(0xFF3D2B1F));
    expect(AppColors.textMuted, const Color(0xFF8A6E5A));
    expect(buildAppTheme().scaffoldBackgroundColor, AppColors.page);
  });
}
```

- [ ] **Step 2: 运行，确认失败**

```powershell
flutter test test/app/pet_card_test.dart
```

- [ ] **Step 3: 实现 `lib/app/main_window/theme.dart`**

```dart
import 'package:flutter/material.dart';

/// Our own warm palette (spec 5) -- deliberately not the competitor's pink.
abstract final class AppColors {
  static const page = Color(0xFFFFF8F0);
  static const card = Color(0xFFFFFFFF);
  static const accent = Color(0xFFF08A3C);
  static const accentSoft = Color(0xFFFDEBD9);
  static const text = Color(0xFF3D2B1F);
  static const textMuted = Color(0xFF8A6E5A);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.accent, surface: AppColors.page);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.page,
    textTheme: ThemeData.light().textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.card,
      indicatorColor: AppColors.accentSoft,
    ),
  );
}
```

- [ ] **Step 4: 实现 `lib/app/main_window/pet_card.dart`**

```dart
import 'package:flutter/material.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import 'theme.dart';

/// One pet in the plaza / 我的 grid, in one of the five states of spec 5.
class PetCard extends StatelessWidget {
  const PetCard({super.key, required this.pet, required this.status, required this.onAdopt});

  final Pet pet;
  final CardStatus status;
  final VoidCallback onAdopt;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(14)),
                child: Opacity(
                  opacity: status == CardStatus.missing ? 0.35 : 1,
                  child: Image.file(
                    pet.coverFile,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.pets, size: 48, color: AppColors.textMuted),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(pet.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text)),
            Text(pet.blurb,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: _button()),
          ],
        ),
      ),
    );
  }

  Widget _button() => switch (status) {
        CardStatus.adoptable => FilledButton(onPressed: onAdopt, child: const Text('带它回家')),
        CardStatus.switchable => FilledButton.tonal(onPressed: onAdopt, child: const Text('换它陪我')),
        CardStatus.companion => const FilledButton.tonal(onPressed: null, child: Text('陪伴中')),
        CardStatus.preparing => const FilledButton.tonal(
            onPressed: null,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('正在准备…'),
            ]),
          ),
        CardStatus.missing => const FilledButton.tonal(onPressed: null, child: Text('素材缺失')),
      };
}
```

- [ ] **Step 5: 运行，确认通过**

```powershell
flutter test test/app/pet_card_test.dart
```

- [ ] **Step 6: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/app/main_window/theme.dart apps/aipet/lib/app/main_window/pet_card.dart apps/aipet/test/app/pet_card_test.dart
git commit -m "feat(aipet): warm theme and five-state pet card" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 14: 主窗口模型与页面（广场 / 我的）

主窗口只读宠物文件夹（扫描），状态一律从宠物窗要（spec 4.3）。测试用真 `MainWindowBridge` + Task 11 的内存假通道 + 一个测试里的宠物窗端。

**Files:**
- Create: `apps/aipet/lib/app/main_window/main_window_model.dart`、`apps/aipet/lib/app/main_window/main_window_app.dart`
- Test: `apps/aipet/test/app/main_window_test.dart`

**Interfaces:**
- Consumes: Task 5 `LibraryState`、`CardStatus`、`Category`、`cardStatusFor`、`filterPets`、`adoptedPets`；Task 7 `PetLibrary`；Task 11 `MainWindowBridge`、`AdoptError`、`BridgeTimeout`；Task 13 `PetCard`、`buildAppTheme`、`AppColors`。
- Produces（Task 15 使用）:
  - `class MainWindowModel extends ChangeNotifier { MainWindowModel({required PetLibrary library, required MainWindowBridge bridge}); Future<void> start(); List<Pet> get plazaPets; List<Pet> get minePets; Category get category; void setCategory(Category c); int get tab; void setTab(int i); CardStatus statusOf(Pet p); Future<void> adopt(String petId); String? takeMessage(); void quit(); Future<void> closing(); }`
  - `class MainWindowApp extends StatefulWidget { const MainWindowApp({required MainWindowModel model}); }`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/main_window_test.dart`：

```dart
import 'dart:async';
import 'dart:io';

import 'package:aipet/app/main_window/main_window_app.dart';
import 'package:aipet/app/main_window/main_window_model.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';
import '../support/pet_fixtures.dart';

void main() {
  late Directory tmp;
  late LibraryState petState;
  late Future<void> Function(String) adoptImpl;
  late PetWindowBridge petSide;
  late MainWindowModel model;
  var quits = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mainwin_');
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold', name: '金毛');
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat', name: '布偶猫');
    final (petEnd, mainEnd) = FakeTransport.pair();
    petState = LibraryState.empty;
    quits = 0;
    adoptImpl = (id) async {};
    petSide = PetWindowBridge(petEnd,
        state: () => petState,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async {},
        onQuit: () async => quits++)
      ..start();
    model = MainWindowModel(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      // Both timeouts short: a pending 60 s Timer fails a widget test at teardown.
      bridge: MainWindowBridge(mainEnd,
          ackTimeout: const Duration(milliseconds: 50), adoptTimeout: const Duration(milliseconds: 200)),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester) async {
    await model.start();
    await tester.pumpWidget(MainWindowApp(model: model));
    await tester.pump();
  }

  // The pet-window side of a successful adopt, optionally held at "preparing".
  Future<void> Function(String) adoptingSucceeds([Completer<void>? hold]) => (id) async {
        petState = petState.preparing(id);
        await petSide.pushState(petState);
        if (hold != null) await hold.future;
        petState = petState.adopted(id);
        await petSide.pushState(petState);
      };

  testWidgets('plaza: banner, categories and one adoptable card per pet', (tester) async {
    await open(tester);
    expect(find.text('定制专属宠物'), findsOneWidget);
    expect(find.text('上传您的爱宠照片，生成桌面伙伴'), findsOneWidget);
    for (final label in ['全部', '狗狗', '猫猫', '其他小宠', '宠物广场', '我的']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('金毛'), findsOneWidget);
    expect(find.text('布偶猫'), findsOneWidget);
    expect(find.text('带它回家'), findsNWidgets(2));
  });

  testWidgets('category chips filter the grid', (tester) async {
    await open(tester);
    await tester.tap(find.text('猫猫'));
    await tester.pump();
    expect(find.text('布偶猫'), findsOneWidget);
    expect(find.text('金毛'), findsNothing);
    await tester.tap(find.text('其他小宠'));
    await tester.pump();
    expect(find.text('这里还没有小伙伴'), findsOneWidget);
  });

  testWidgets('adopting shows 正在准备… and then 陪伴中', (tester) async {
    final hold = Completer<void>();
    adoptImpl = adoptingSucceeds(hold);
    await open(tester);
    await tester.tap(find.text('带它回家').first);
    await tester.pump();
    expect(find.text('正在准备…'), findsOneWidget);
    hold.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('陪伴中'), findsOneWidget);
    expect(find.text('带它回家'), findsOneWidget);
  });

  testWidgets('no answer within 3 s (50 ms here) says 切换失败，请重试', (tester) async {
    adoptImpl = (id) => Completer<void>().future;
    await open(tester);
    await tester.tap(find.text('带它回家').first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('切换失败，请重试'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300)); // let the ignored adopt timeout fire
  });

  testWidgets('a failed prepare also says 切换失败，请重试', (tester) async {
    adoptImpl = (id) async {
      await petSide.pushState(petState.preparing(id));
      throw const AdoptError('prepare_failed', 'decode failed');
    };
    await open(tester);
    await tester.tap(find.text('带它回家').first);
    await tester.pump();
    await tester.pump();
    expect(find.text('切换失败，请重试'), findsOneWidget);
  });

  testWidgets('立即定制 is not open yet', (tester) async {
    await open(tester);
    await tester.tap(find.text('立即定制'));
    await tester.pumpAndSettle();
    expect(find.text('即将开放，敬请期待'), findsOneWidget);
  });

  testWidgets('我的: empty state, adopted pets, and 退出程序', (tester) async {
    await open(tester);
    await tester.tap(find.text('我的'));
    await tester.pump();
    expect(find.text('还没有领养小伙伴，去广场看看吧'), findsOneWidget);

    petState = const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']);
    await petSide.pushState(petState);
    await tester.pump();
    expect(find.text('金毛'), findsOneWidget);
    expect(find.text('陪伴中'), findsOneWidget);
    expect(find.text('布偶猫'), findsNothing);

    await tester.tap(find.text('退出程序'));
    await tester.pump();
    expect(quits, 1);
  });
}
```

- [ ] **Step 2: 运行，确认失败**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter test test/app/main_window_test.dart
```

- [ ] **Step 3: 实现 `lib/app/main_window/main_window_model.dart`**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import '../../services/pet_library.dart';
import '../../services/window_bridge.dart';

/// Main-window state. Reads pet folders itself (read-only); everything about
/// who is adopted or on the desktop comes from the pet window (spec 4.3).
class MainWindowModel extends ChangeNotifier {
  MainWindowModel({required PetLibrary library, required MainWindowBridge bridge})
      : _library = library,
        _bridge = bridge;

  final PetLibrary _library;
  final MainWindowBridge _bridge;
  StreamSubscription<LibraryState>? _sub;

  List<Pet> _pets = const [];
  LibraryState _state = LibraryState.empty;
  Category _category = Category.all;
  int _tab = 0;
  String? _message;

  Category get category => _category;
  int get tab => _tab;
  List<Pet> get plazaPets => filterPets(_pets, _category);
  List<Pet> get minePets => adoptedPets(_pets, _state);

  CardStatus statusOf(Pet p) => cardStatusFor(petId: p.id, complete: p.isComplete, state: _state);

  Future<void> start() async {
    _pets = _library.scan();
    _bridge.start();
    _sub = _bridge.states.listen((s) {
      _state = s;
      notifyListeners();
    });
    try {
      _state = await _bridge.getState();
    } on BridgeTimeout {
      // The pet window pushes stateChanged whenever something happens; the
      // cards simply start from "nobody adopted" until it does.
    }
    notifyListeners();
  }

  void setCategory(Category c) {
    _category = c;
    notifyListeners();
  }

  void setTab(int i) {
    _tab = i;
    notifyListeners();
  }

  Future<void> adopt(String petId) async {
    try {
      await _bridge.adopt(petId);
    } on AdoptError catch (e) {
      _say(e.code == 'missing_assets' ? '素材缺失' : '切换失败，请重试');
    } on BridgeTimeout {
      _say('切换失败，请重试');
    }
  }

  /// A one-shot message for a SnackBar; reading it clears it.
  String? takeMessage() {
    final m = _message;
    _message = null;
    return m;
  }

  void quit() => _bridge.quit();

  Future<void> closing() => _bridge.notifyClosing();

  void _say(String m) {
    _message = m;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _bridge.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 4: 实现 `lib/app/main_window/main_window_app.dart`**

```dart
import 'package:flutter/material.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import 'main_window_model.dart';
import 'pet_card.dart';
import 'theme.dart';

class MainWindowApp extends StatefulWidget {
  const MainWindowApp({super.key, required this.model});

  final MainWindowModel model;

  @override
  State<MainWindowApp> createState() => _MainWindowAppState();
}

class _MainWindowAppState extends State<MainWindowApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_showMessage);
  }

  @override
  void dispose() {
    widget.model.removeListener(_showMessage);
    super.dispose();
  }

  void _showMessage() {
    final m = widget.model.takeMessage();
    if (m != null) _messenger.currentState?.showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'aipet',
      theme: buildAppTheme(),
      scaffoldMessengerKey: _messenger,
      home: ListenableBuilder(
        listenable: model,
        builder: (context, _) => Scaffold(
          body: SafeArea(child: model.tab == 0 ? _PlazaPage(model: model) : _MinePage(model: model)),
          bottomNavigationBar: NavigationBar(
            selectedIndex: model.tab,
            onDestinationSelected: model.setTab,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: '宠物广场'),
              NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: '我的'),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetGrid extends StatelessWidget {
  const _PetGrid({required this.model, required this.pets});

  final MainWindowModel model;
  final List<Pet> pets;

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverGrid.count(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.68,
          children: [
            for (final p in pets) PetCard(pet: p, status: model.statusOf(p), onAdopt: () => model.adopt(p.id)),
          ],
        ),
      );
}

class _PlazaPage extends StatelessWidget {
  const _PlazaPage({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final pets = model.plazaPets;
    return CustomScrollView(slivers: [
      const SliverPadding(padding: EdgeInsets.fromLTRB(16, 16, 16, 8), sliver: SliverToBoxAdapter(child: _Banner())),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            for (final c in Category.values)
              ChoiceChip(
                label: Text(c.label),
                selected: model.category == c,
                selectedColor: AppColors.accentSoft,
                onSelected: (_) => model.setCategory(c),
              ),
          ]),
        ),
      ),
      if (pets.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('这里还没有小伙伴', style: TextStyle(color: AppColors.textMuted))),
        )
      else
        _PetGrid(model: model, pets: pets),
    ]);
  }
}

class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(24)),
        child: Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('定制专属宠物', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text)),
              SizedBox(height: 4),
              Text('上传您的爱宠照片，生成桌面伙伴', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ]),
          ),
          FilledButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                content: const Text('即将开放，敬请期待'),
                actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了'))],
              ),
            ),
            child: const Text('立即定制'),
          ),
        ]),
      );
}

class _MinePage extends StatelessWidget {
  const _MinePage({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final pets = model.minePets;
    return Column(children: [
      Expanded(
        child: pets.isEmpty
            ? const Center(child: Text('还没有领养小伙伴，去广场看看吧', style: TextStyle(color: AppColors.textMuted)))
            : CustomScrollView(slivers: [_PetGrid(model: model, pets: pets)]),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(onPressed: model.quit, child: const Text('退出程序')),
        ),
      ),
    ]);
  }
}
```

- [ ] **Step 5: 运行，确认通过**

```powershell
flutter test test/app/main_window_test.dart
```

- [ ] **Step 6: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib/app/main_window apps/aipet/test/app/main_window_test.dart
git commit -m "feat(aipet): main window plaza and mine pages" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 15: 宠物窗界面、托盘、主窗口启动与整体接线

把前面的部件接成能跑的应用，替换 Task 1 的原型 `main.dart`。**本任务按 Task 1 结果文件里 C6、C7 的结论选分支**（下面 Step 4 写了两条路）。

**Files:**
- Create: `apps/aipet/lib/app/pet_window/clip_player.dart`、`apps/aipet/lib/app/pet_window/library_launcher.dart`、`apps/aipet/lib/app/pet_window/pet_window_app.dart`、`apps/aipet/lib/app/main_window/main_window_entry.dart`、`tools/dev/windows.ps1`
- Modify: `apps/aipet/lib/main.dart`（整体替换）

**Interfaces:**
- Consumes: Task 6、7、10、11、12、14 的全部公开接口；插件 `AlphaVideo`、`AlphaVideoController`、`AlphaVideoView`。
- Produces: 可运行的 `aipet.exe`；`tools/dev/windows.ps1`（Task 16 复用）。宠物窗标题固定为 `aipet pet`（无边框，用户看不到，只给脚本识别），主窗口标题 `aipet`。

- [ ] **Step 1: `lib/app/pet_window/clip_player.dart`**

```dart
import 'dart:async';
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'pet_window_controller.dart';

/// ClipPlayer on alpha_video. Ported from pet_shell's switching code.
class AlphaClipPlayer implements ClipPlayer {
  final ValueNotifier<AlphaVideoController?> controller = ValueNotifier(null);
  Timer? _watch;

  @override
  Future<void> play(File aipmat, {required bool loop, VoidCallback? onFinished}) async {
    _watch?.cancel();
    final next = await AlphaVideoController.open(aipmat.path);
    final prev = controller.value;
    // Hold the new controller before play(): teardown must always be able to
    // find whatever open() created, even if play() throws.
    controller.value = next;
    // Let the frame that swaps the Texture land before the old texture is
    // unregistered. Bounded: a hidden window may not produce frames.
    await SchedulerBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 500), onTimeout: () {});
    await prev?.dispose();
    await next.play(loop: loop);
    if (!loop && onFinished != null) _watchEnd(next, onFinished);
  }

  // The plugin has no finished event and cannot replay (HANDOFF item 3): poll
  // the frame counter; a replay reopens the cache, which starts at frame 0.
  void _watchEnd(AlphaVideoController c, VoidCallback onFinished) {
    _watch = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      if (!identical(controller.value, c)) {
        t.cancel();
        return;
      }
      final int frame;
      try {
        frame = await c.currentFrame();
      } catch (_) {
        t.cancel();
        return;
      }
      if (t.isActive && frame >= c.frameCount - 1 && identical(controller.value, c)) {
        t.cancel();
        onFinished();
      }
    });
  }

  @override
  Future<void> dispose() async {
    _watch?.cancel();
    final c = controller.value;
    controller.value = null;
    await c?.dispose();
  }
}
```

- [ ] **Step 2: `lib/app/pet_window/library_launcher.dart`**

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';

/// Arguments string that makes an engine the main window (Global Constraints).
const kMainWindowArgs = 'main_window';

/// Opens the main window, re-creating it if the user's × destroyed it --
/// whichever of hide/destroy Task 1 (C7) observed, this handles both.
class LibraryLauncher {
  WindowController? _main;

  Future<bool> isOpen() async =>
      _main != null && (await WindowController.getAll()).any((w) => w.windowId == _main!.windowId);

  Future<void> open() async {
    if (!await isOpen()) {
      _main = await WindowController.create(WindowConfiguration(arguments: kMainWindowArgs, hiddenAtLaunch: false));
    }
    await _main!.show();
  }
}
```

- [ ] **Step 3: `lib/app/pet_window/pet_window_app.dart`**

```dart
import 'dart:async';

import 'package:alpha_video/alpha_video.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/pet.dart';
import '../../services/app_paths.dart';
import '../../services/matte_cache.dart';
import '../../services/pet_library.dart';
import '../../services/settings_store.dart';
import '../../services/window_bridge.dart';
import 'clip_player.dart';
import 'library_launcher.dart';
import 'pet_window_controller.dart';

/// Primary engine: builds the services, boots, and opens the library on a
/// first run (spec 3.3).
Future<void> runPetWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(360, 360),
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'aipet pet',
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(false);
      // WM_CLOSE -> onWindowClose -> quit, so clips are torn down before the
      // engine (pet_shell's I-7 lesson). Shown only once there is a pet.
      await windowManager.setPreventClose(true);
    },
  );

  final appData = appDataRoot();
  final cache = MatteCache(
    root: matteCacheRoot(appData),
    prepare: ({required source, required destination}) =>
        AlphaVideo.prepare(source: source, destination: destination, targetEdge: 720),
  );
  final player = AlphaClipPlayer();
  final launcher = LibraryLauncher();
  late final PetWindowBridge bridge;
  final controller = PetWindowController(
    library: PetLibrary(builtinRoot: builtinPetsRoot(), customRoot: customPetsRoot(appData)),
    settings: SettingsStore(appData),
    ensure: cache.ensure,
    player: player,
    push: (s) => bridge.pushState(s),
  );

  var quitting = false;
  Future<void> quit() async {
    if (quitting) return;
    quitting = true;
    try {
      await player.dispose();
      await trayManager.destroy();
    } finally {
      await windowManager.destroy(); // ends the process, sub-window engine included
    }
  }

  bridge = PetWindowBridge(
    WindowChannelTransport(),
    state: () => controller.state,
    onAdopt: controller.adopt,
    // Spec 3.3: closing the library with nobody on the desktop ends the app.
    onMainWindowClosing: () async {
      if (controller.currentPet == null) await quit();
    },
    onQuit: quit,
  )..start();

  runApp(PetWindowApp(controller: controller, player: player, launcher: launcher, onQuit: quit));
  await controller.boot();
  if (controller.currentPet == null) await launcher.open();
}

class PetWindowApp extends StatefulWidget {
  const PetWindowApp({
    super.key,
    required this.controller,
    required this.player,
    required this.launcher,
    required this.onQuit,
  });

  final PetWindowController controller;
  final AlphaClipPlayer player;
  final LibraryLauncher launcher;
  final Future<void> Function() onQuit;

  @override
  State<PetWindowApp> createState() => _PetWindowAppState();
}

class _PetWindowAppState extends State<PetWindowApp> with TrayListener, WindowListener {
  bool? _visible;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    widget.controller.addListener(_syncVisibility);
    unawaited(_setUpTray());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncVisibility);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _setUpTray() async {
    await trayManager.setIcon('assets/tray.ico');
    await trayManager.setToolTip('aipet');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: '打开宠物库'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
  }

  void _syncVisibility() {
    final want = widget.controller.currentPet != null;
    if (want == _visible) return;
    _visible = want;
    unawaited(want ? windowManager.show() : windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() => widget.launcher.open();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') widget.launcher.open();
    if (menuItem.key == 'quit') widget.onQuit();
  }

  @override
  void onWindowClose() => widget.onQuit();

  Future<void> _showMenu(BuildContext ctx, Offset at) async {
    final c = widget.controller;
    final pet = c.currentPet;
    final overlay = Overlay.of(ctx).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        if (pet != null) ...[
          for (final a in pet.actions)
            CheckedPopupMenuItem<String>(
                value: 'action:$a', checked: a == c.currentAction, height: 36, child: Text(labelFor(a))),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem<String>(value: 'open', height: 36, child: Text('打开宠物库')),
        const PopupMenuItem<String>(value: 'quit', height: 36, child: Text('退出')),
      ],
    );
    if (choice == null) return;
    if (choice == 'open') return widget.launcher.open();
    if (choice == 'quit') return widget.onQuit();
    await c.playAction(choice.substring('action:'.length));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          // Builder: showMenu needs a context below MaterialApp (Navigator, Overlay).
          body: Builder(
            builder: (ctx) => GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              onSecondaryTapUp: (d) => _showMenu(ctx, d.globalPosition),
              child: Stack(alignment: Alignment.center, children: [
                ValueListenableBuilder<AlphaVideoController?>(
                  valueListenable: widget.player.controller,
                  builder: (_, vc, __) => vc == null ? const SizedBox.shrink() : AlphaVideoView(controller: vc),
                ),
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (_, __) {
                    final e = widget.controller.error;
                    if (e == null) return const SizedBox.shrink();
                    return Positioned(
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: const Color(0xCC3D2B1F), borderRadius: BorderRadius.circular(10)),
                        child: Text(e, style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    );
                  },
                ),
              ]),
            ),
          ),
        ),
      );
}
```

- [ ] **Step 4: `lib/app/main_window/main_window_entry.dart`（按 Task 1 的 C6 结论二选一）**

**C6 通过（子窗口里 `window_manager` 可用、标题生效）**——用这一版：

```dart
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/app_paths.dart';
import '../../services/pet_library.dart';
import '../../services/window_bridge.dart';
import 'main_window_app.dart';
import 'main_window_model.dart';

Future<void> runMainWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: Size(420, 740), minimumSize: Size(420, 600), center: true, title: 'aipet'),
    () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    },
  );
  final model = MainWindowModel(
    library: PetLibrary(builtinRoot: builtinPetsRoot(), customRoot: customPetsRoot(appDataRoot())),
    bridge: MainWindowBridge(WindowChannelTransport()),
  );
  windowManager.addListener(_CloseToHide(model));
  runApp(MainWindowApp(model: model));
  await model.start();
}

/// × hides the library instead of destroying it; the pet window first gets
/// the chance to end the app when nobody is on the desktop (spec 3.3).
class _CloseToHide with WindowListener {
  _CloseToHide(this.model);

  final MainWindowModel model;

  @override
  void onWindowClose() async {
    await model.closing();
    await windowManager.hide();
  }
}
```

**C6 不通过**——`runMainWindow` 不调用 `windowManager`（窗口尺寸与标题用 desktop_multi_window 的默认值，在结果文件记为已知差异），并在 `runPetWindow()` 末尾追加轮询兜底，替代 `mainWindowClosing` 通知：

```dart
  // Fallback for C6 = fail: the main window cannot announce its own close, so
  // watch for it disappearing while nobody is on the desktop.
  Timer.periodic(const Duration(seconds: 1), (t) async {
    if (controller.currentPet != null) return;
    if (!await launcher.isOpen()) {
      t.cancel();
      await quit();
    }
  });
```

（C6 不通过时，`runMainWindow` 就是上面那版去掉 `ensureInitialized`、`waitUntilReadyToShow`、`addListener(_CloseToHide(...))` 三处，以及 `_CloseToHide` 类。）

- [ ] **Step 5: `lib/main.dart`（整体替换原型）**

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';

import 'app/main_window/main_window_entry.dart';
import 'app/pet_window/library_launcher.dart';
import 'app/pet_window/pet_window_app.dart';

/// One process, two engines (spec 3.1): the primary engine is the pet window;
/// an engine created with kMainWindowArgs is the main window.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await WindowController.fromCurrentEngine();
  if (self.arguments == kMainWindowArgs) {
    await runMainWindow();
  } else {
    await runPetWindow();
  }
}
```

- [ ] **Step 6: 窗口工具 `tools/dev/windows.ps1`（ASCII）**

```powershell
# List the top-level windows of a process, optionally post WM_CLOSE to one by
# exact title (same effect as clicking its X). ASCII only (PowerShell 5.1).
# DPI-aware: W/H are physical pixels, the same space as shot.ps1 / click.ps1.
# Usage: windows.ps1 [-Name aipet] [-CloseTitle "aipet"]
param([string]$Name = 'aipet', [string]$CloseTitle)

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class TopWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][TopWin]::SetProcessDPIAware()

$procIds = @(Get-Process $Name -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
if ($procIds.Count -eq 0) { "no $Name process"; exit 0 }
$script:rows = @()
[void][TopWin]::EnumWindows({ param($h, $l)
  $p = [uint32]0
  [void][TopWin]::GetWindowThreadProcessId($h, [ref]$p)
  if ($procIds -contains $p) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][TopWin]::GetWindowText($h, $sb, 256)
    $r = New-Object TopWin+RECT
    [void][TopWin]::GetWindowRect($h, [ref]$r)
    $script:rows += [pscustomobject]@{ Handle = $h; Title = $sb.ToString(); Visible = [TopWin]::IsWindowVisible($h); W = $r.R - $r.L; H = $r.B - $r.T }
  }
  return $true }, [IntPtr]::Zero)
$script:rows | Where-Object { $_.Title -ne '' } | ForEach-Object {
  $r = New-Object TopWin+RECT; [void][TopWin]::GetWindowRect($_.Handle, [ref]$r)
  $_ | Add-Member -NotePropertyName Rect -NotePropertyValue "$($r.L),$($r.T),$($r.R),$($r.B)" -PassThru
} | Format-Table Title, Visible, W, H, Rect -AutoSize | Out-String
if ($CloseTitle) {
  $t = $script:rows | Where-Object { $_.Title -eq $CloseTitle } | Select-Object -First 1
  if ($t) { [void][TopWin]::PostMessage($t.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); "posted WM_CLOSE to '$CloseTitle'" }
  else { "no window titled '$CloseTitle'" }
}
```

- [ ] **Step 7: 静态检查与全部测试**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
flutter analyze
flutter test
flutter build windows --release
```

Expected：`No issues found!`；所有测试通过；构建成功。

- [ ] **Step 8: 烟测（不动鼠标）**

首次启动——空的 APPDATA，应只出现主窗口；关掉主窗口后程序应退出：

```powershell
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
$fresh = Join-Path $env:TEMP "aipet-smoke-$(Get-Random)"; New-Item -ItemType Directory $fresh | Out-Null
$env:APPDATA = $fresh
Start-Process .\build\windows\x64\runner\Release\aipet.exe
Start-Sleep -Seconds 5
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1 -CloseTitle aipet
Start-Sleep -Seconds 3
Get-Process aipet -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count
```

Expected：第一次列表里 `aipet` 可见（物理像素约 420×740 乘以屏幕缩放比例），`aipet pet` 不可见；关闭后进程数为 0。

已有宠物——预置设置，应只出现宠物：

```powershell
$seeded = Join-Path $env:TEMP "aipet-smoke-$(Get-Random)"
New-Item -ItemType Directory "$seeded\com.aipet\aipet" -Force | Out-Null
'{"schema":1,"currentPetId":"builtin-gold","adoptedPetIds":["builtin-gold"]}' | Set-Content -Encoding ascii "$seeded\com.aipet\aipet\settings.json"
$env:APPDATA = $seeded
Start-Process .\build\windows\x64\runner\Release\aipet.exe
Start-Sleep -Seconds 8
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1
Get-ChildItem "$seeded\com.aipet\aipet\matte-cache\v1" -Filter *.aipmat | Select-Object Name, Length
powershell -ExecutionPolicy Bypass -File ..\..\tools\dev\windows.ps1 -CloseTitle "aipet pet"
Start-Sleep -Seconds 3
Get-Process aipet -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count
Remove-Item Env:APPDATA   # the session's real APPDATA comes back in a new shell; do not reuse this one for other work
```

Expected：`aipet pet` 可见、没有 `aipet` 主窗口；缓存目录里有 1 个 `.aipmat`（金毛 stand）；向宠物窗发 `WM_CLOSE` 后进程数为 0。把两次输出贴进结果文件的「Task 15 烟测」一节。

- [ ] **Step 9: 提交**

```powershell
Set-Location C:\Users\Administrator\code\aipet
git add apps/aipet/lib tools/dev/windows.ps1 docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md
git commit -m "feat(aipet): wire pet window, tray, main window launcher and routing" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 16: 端到端验收、文档与收尾

对照 spec 第 1 节的 5 条验收标准在真机上走一遍，更新 HANDOFF，全量回归。

**Files:**
- Create: `tools/dev/shot.ps1`、`tools/dev/click.ps1`
- Modify: `HANDOFF.md`、`docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`

**Interfaces:**
- Consumes: Task 15 的 `aipet.exe`、`tools/dev/windows.ps1`。

- [ ] **Step 1: DPI 感知的截图与点击工具（ASCII）**

屏幕缩放 150% 时，未声明 DPI 感知的进程里 `SetCursorPos` 用逻辑坐标，而截图是物理像素——spike 里因此误点过用户的浏览器。两个脚本都先 `SetProcessDPIAware()`，全程用物理像素；点击前校验落点像素。

`tools/dev/shot.ps1`：

```powershell
# Capture the whole virtual desktop in physical pixels. Usage: shot.ps1 -Out <png>
param([Parameter(Mandatory)][string]$Out)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System.Runtime.InteropServices;
public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][Dpi]::SetProcessDPIAware()
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"saved $Out ($($b.Width)x$($b.Height))"
```

`tools/dev/click.ps1`：

```powershell
# DPI-safe click in physical pixels (the same space as shot.ps1).
# -Expect "r,g,b": the pixel AT the click point must match (+-6) or no click is sent.
# Usage: click.ps1 -X <px> -Y <px> [-Button left|right] [-Expect "r,g,b"]
param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y,
      [ValidateSet('left', 'right')][string]$Button = 'left', [string]$Expect)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Mouse {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
}
"@
[void][Mouse]::SetProcessDPIAware()
if ($Expect) {
  $want = $Expect.Split(',') | ForEach-Object { [int]$_ }
  $bmp = New-Object System.Drawing.Bitmap 1, 1
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
  $c = $bmp.GetPixel(0, 0); $g.Dispose(); $bmp.Dispose()
  if ([math]::Abs($c.R - $want[0]) -gt 6 -or [math]::Abs($c.G - $want[1]) -gt 6 -or [math]::Abs($c.B - $want[2]) -gt 6) {
    "GUARD FAILED at ($X,$Y): saw $($c.R),$($c.G),$($c.B), expected $Expect -- no click sent"; exit 1
  }
}
[void][Mouse]::SetCursorPos($X, $Y)
Start-Sleep -Milliseconds 80
if ($Button -eq 'right') { $down = 0x0008; $up = 0x0010 } else { $down = 0x0002; $up = 0x0004 }
[Mouse]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 40
[Mouse]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
"$Button click at physical ($X,$Y)"
```

- [ ] **Step 2: 征得用户同意**

真机验收要移动用户的鼠标约 3 分钟。**先问用户**（Global Constraints）。用户不同意或正在用电脑：把 Step 3 的清单原样交给用户手动走，逐条记录用户的答复；不要自行点击。

- [ ] **Step 3: 验收清单**

构建 release，用全新 APPDATA 启动（同 Task 15 Step 8 的写法）。每步：`shot.ps1` 截图 → 看图找到目标控件的物理坐标 → 取控件背景一点的颜色作为 `-Expect` → `click.ps1`。截图和结论逐条写进结果文件。

| # | 对应 spec 验收 | 操作 | 通过条件 |
|---|---|---|---|
| A1 | 1 | 全新启动 | 只有主窗口 `aipet`，没有宠物 |
| A2 | 1、4 | 在金毛卡片点「带它回家」 | 卡片立即变「正在准备…」，其间两张相隔 300 ms 的截图里转圈区域不同（主窗口没卡）；随后宠物出现在桌面、卡片变「陪伴中」、主窗口仍开着 |
| A3 | 3 | 点「猫猫」，再点「其他小宠」 | 只剩布偶猫；然后显示「这里还没有小伙伴」 |
| A4 | 3、4 | 回「全部」，布偶猫点「带它回家」，再对金毛点「换它陪我」 | 每次切换期间旧宠物一直在桌面、不闪空白；两只都进「我的」 |
| A5 | — | 在宠物上右键，依次选 5 个动作 | 菜单列出 待机/走路/睡觉/舔爪子/卖萌 并勾选当前项；每个都播放；舔爪子、卖萌播完自动回待机 |
| A6 | 5 | 每只宠物各截一张桌面图 | 宠物窗矩形（`windows.ps1` 的 Rect 列，物理像素）内强偏绿像素（G > R+40 且 G > B+40）为 0（用下面的脚本） |
| A7 | 2 | 关主窗口 → 退出 → 重新启动 | 直接出现上次的宠物，主窗口不打开 |
| A8 | 2 | 单击托盘图标；再在宠物右键选「打开宠物库」 | 两种方式都打开主窗口（关掉后再开也行） |
| A9 | — | 分别用宠物右键「退出」、托盘「退出」、我的「退出程序」各退一次 | 每次 3 秒内 `Get-Process aipet` 为空 |
| A10 | — | 稳态放置 60 秒 | 记录 CPU 与内存（对照 HANDOFF 里 Plan A 的 164 MB） |

A6 的像素统计（`<png>` 为截图，`x0 y0 x1 y1` 为宠物窗在截图里的物理像素矩形）：

```powershell
C:\Users\Administrator\code\aipet\tools\petgen\.venv\Scripts\python -c "import sys,numpy as np; from PIL import Image; a=np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(int); x0,y0,x1,y1=map(int,sys.argv[2:6]); r=a[y0:y1,x0:x1]; g=(r[...,1]>r[...,0]+40)&(r[...,1]>r[...,2]+40); print('strong-green', int(g.sum()), 'of', r.shape[0]*r.shape[1])" <png> <x0> <y0> <x1> <y1>
```

任何一条不通过：记录现象和截图，交给用户，不在本任务里临时改代码——修复走新的任务。

- [ ] **Step 4: 全量回归**

```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
Set-Location C:\Users\Administrator\code\aipet\apps\aipet;  flutter analyze; flutter test
Set-Location C:\Users\Administrator\code\aipet\apps\pet_shell; flutter test
Set-Location C:\Users\Administrator\code\aipet\packages\alpha_video\example; flutter test integration_test -d windows
$cmake = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
& $cmake --build C:\Users\Administrator\code\aipet\native\build --config Debug
& "$(Split-Path $cmake)\ctest.exe" --test-dir C:\Users\Administrator\code\aipet\native\build -C Debug
Set-Location C:\Users\Administrator\code\aipet\tools\petgen; .\.venv\Scripts\python -m pytest -q
```

Expected：全部通过。把每组的通过数写进结果文件。

- [ ] **Step 5: 合入 spike 文档并更新 HANDOFF**

M2 spike 的 HANDOFF 更新在分支 `docs/m2-kling-spike`（只改了 `HANDOFF.md`），先合进来再改，避免之后冲突：

```powershell
Set-Location C:\Users\Administrator\code\aipet
git merge --no-ff docs/m2-kling-spike -m "merge: M2 Kling spike findings (docs/m2-kling-spike)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

然后在 `HANDOFF.md`：
- 第 1 节加「子项目 A（主窗口 + 宠物库）」：做了什么、怎么启动 `apps/aipet`（release 构建 + `aipet.exe`）、A1–A10 结论摘要。
- 第 5 节待办：待办 2（prepare 阻塞平台线程）标为已解决并指向 Task 8、9 的提交；新增本计划执行中发现、但未在本计划内修的问题。
- 第 4 节：B（生成服务）、C（定制流程）、D（账号支付）是下一批子项目，`tools/petgen` 是 B 的雏形；列出发布前必做的「确认可灵生成内容商用条款」。

```powershell
git add HANDOFF.md docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md tools/dev
git commit -m "docs: sub-project A acceptance results and handoff update" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: 收尾**

使用 superpowers:finishing-a-development-branch 决定 `feat/aipet-main-window` 如何合入（合 master / 开 PR / 保留分支），由用户选择。
