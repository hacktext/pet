# aipet 定制宠物自动下发（客户端）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 后台交付后，用户任一台已登录的电脑自动把定制宠物下载进宠物库、主窗口提示「你的「<名字>」做好了」并能一键「换它陪我」；「我的定制」显示新的生成状态，定制页只开放猫、狗。

**Architecture:** 宠物窗口（`pets/` 唯一写者）新增 `CustomDownloader`：同一时间只跑一轮，按「启动后 / 每次同步后（含登录后那次）/ 主窗口请求」触发；`GET custom/deliveries` → 本机缺的 → `GET …/assets` → 经可替换的 `DownloadTransport` 流式下载到 `pets/.downloading/<pet_id>/`，逐个 sha256 校验、已校验的跳过（续传）→ 整目录改名进 `pets/<pet_id>/` → 宠物窗口重扫 → 经窗口通道推「新宠物」给主窗口（主窗口没开时留着，等它启动来取）。主窗口收到后重扫并显示横幅；「我的定制」改用新状态与进度文字，生成中且页面可见时每 30 秒刷新，发现已交付但本机没有的单就请宠物窗口补下载。

**Tech Stack:** Flutter 3.47 / Dart 3.13（Windows），`dart:io` `HttpClient`（流式下载），`package:crypto`（已有依赖，sha256），`desktop_multi_window` 窗口通道。无新依赖。

**Spec:** `docs/superpowers/specs/2026-10-10-aipet-custom-generation-design.md`（本计划只覆盖第 6 节客户端与第 9 节在客户端的状态改名）；前置计划 `docs/superpowers/plans/2026-10-02-aipet-custom-order.md`（客户端 Task 7–12 必须已完成，本计划在它们产出的文件上改）。

## Global Constraints

- 仓库 `C:\Users\Administrator\code\aipet`，当前分支 `feat/human-character`，工作区有大量用户未提交的改动：**在现有工作区上直接做，不切分支、不 `git stash`、不 `git reset`、不 `git checkout -- <file>`**。每个 commit 只用显式路径 `git add <本任务列出的文件>`，绝不 `git add -A` / `git add .`。若本任务必须提交的文件里还混着别的会话未提交的改动，先停下问用户。
- Flutter 不在 PATH：一律用全路径 `C:\Users\Administrator\code\envs\flutter\bin\flutter`，在 `C:\Users\Administrator\code\aipet\apps\aipet` 下运行（例：`C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/custom_downloader_test.dart`）。
- 写文件用 Write/Edit 工具，**不要用 bash heredoc 写含反斜杠的内容**（会吃掉 `\`）。
- commit message 以 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` 结尾（用第二个 `-m` 给出）。
- 接口（与服务端计划逐字一致）：信封 `{code, message, data}`；`GET api/aipet/custom/deliveries` → `[{id, pet_id, name, delivered_at}]`；`GET api/aipet/custom/requests/:id/assets` → `{pet_id, files: [{path, bytes, sha256, url}]}`（url 是 30 分钟限时 GET，可能过期 → 下一次触发重新要 assets）；`GET api/aipet/custom/requests` 每项多 `pet_id`、`stage`、`stage_done`、`stage_total`、`fail_reason`。
- 定制单状态：`draft, pending_payment, paid, generating, review, delivered, failed, refunded`（`making`、`done` 不再存在）。客户端文字：draft / pending_payment 待支付、paid 待生成、generating 生成中（参考图、动作两步带进度：「生成中（参考图 n/m）」「生成中（动作 n/m）」，其它步骤只显示「生成中」）、review 审核中、delivered 已完成、failed「生成失败（我们会联系你处理或退款）」、refunded 已退款。
- `pet_id` 形如 `custom-123`，必须匹配 `^[a-z0-9-]+$`（长度 ≤ 64）；交付的 `pet.json` 的 `origin` 为 `custom`、`id` 等于 `pet_id`。
- 目录：成品 `pets/<pet_id>/`；下载中 `pets/.downloading/<pet_id>/<path>`；单个文件先写 `<path>.part`，校验通过再改名；替换旧目录时旧的先改名为 `pets/.old-<pet_id>/` 再删。`PetLibrary` 跳过所有以 `.` 开头的目录。
- 下载器只在宠物窗口构建（`pets/` 的唯一写者）；主窗口只读、只「请求刷新」。
- 失败（网络、sha256 / 大小不符、URL 过期、改名失败）一律：保留已校验的文件、`developer.log(name: 'aipet.custom')`、下次触发再试，**不弹任何错误**。下载器所有公开方法不抛异常。
- UI isolate 跑在平台线程上（HANDOFF 坑 / 记忆）：下载与校验**只用异步、分块的 IO**（`openWrite` / `openRead` 流、`sha256.bind`），不得对视频文件用 `readAsBytesSync` / `sha256.convert(整文件)`。
- 写 JSON 仍走 `writeJsonAtomic`；store 不抛；`testWidgets` 里有定时器的用例用 try/finally 收尾（HANDOFF 坑 11）。
- 「我的定制」生成中刷新间隔 30 秒，仅在「我的」页且主窗口可见时。

## Review Focus

1. **下载到一半退出程序再启动**：只补下缺的和半截的文件（`.part`），已校验的不重下，最后完整安装。（Task 4「quit mid-download」测试）
2. **某一个文件 sha256 不符**：整只宠物不安装、不弹错；其余已通过的文件留在 `.downloading`，下一次只重下那一个。（Task 4「one file failing its sha256」测试）
3. **本机 `pets/<pet_id>/` 存在但不完整（旧的半截）或被用户删掉**：前者整体替换（旧目录经 `.old-` 删掉），后者下一次触发重新下载。（Task 4「an incomplete folder … the user deleting it」测试）
4. **签名 URL 在拿到 assets 和下载之间过期**：这一轮静默失败，下一轮重新 `GET …/assets` 拿新地址后成功。（Task 4「a signed URL that expired」测试）
5. **两个时机同时到（登录 + 登录后的同步，或主窗口刷新 + 定时同步）**：同一时间只跑一轮，期间来的触发合并成最多一轮补跑，每个文件只下一次。（Task 4「two triggers at once」测试）

另两条也由 Task 4 测试钉住：已交付且本机完整的不再请求 assets；未登录时一个请求都不发。

---

## 文件结构

客户端（相对 `apps/aipet/`）：

| 文件 | 职责 |
|---|---|
| `lib/domain/custom_order.dart`（改，前置计划 Task 7 创建） | 状态改名；`CustomRequestInfo` 加进度字段与 `statusText`；新增 `CustomDelivery`、`CustomAsset`、`CustomAssets`、`isCustomPetId`、`isSafeAssetPath` |
| `lib/services/api_client.dart`（改） | `customDeliveries()`、`customAssets(int)` |
| `lib/services/pet_library.dart`（改） | 扫描跳过 `.` 开头的目录 |
| `lib/services/file_download.dart`（新） | `DownloadTransport` 接口、`DownloadFailed`、`IoDownloadTransport`（流式写盘） |
| `lib/services/custom_downloader.dart`（新） | 单飞的下载、校验、续传、原子安装 |
| `lib/services/window_bridge.dart`（改） | `ReadyPet`；`petsReady` / `takeReady` / `refreshCustom` 三条消息 |
| `lib/app/pet_window/pet_window_controller.dart`（改） | `rescan()` |
| `lib/app/pet_window/account_keeper.dart`（改） | `onSynced` 回调 |
| `lib/app/pet_window/pet_window_app.dart`（改） | 构建下载器并接上四个触发 |
| `lib/app/main_window/main_window_model.dart`（改） | 新宠物横幅、换它陪我、30 秒刷新、请求补下载、窗口可见性 |
| `lib/app/main_window/main_window_app.dart`（改） | `_ReadyBanner`；`_CustomList` 用新状态文字 |
| `lib/app/main_window/main_window_entry.dart`（改） | 窗口可见性 → model |
| `lib/app/main_window/custom_flow/custom_form_model.dart` `custom_form_page.dart`（改） | 只开放猫、狗，其余显示「即将开放」 |
| `test/support/fake_downloads.dart`（新） | 假下载传输 |
| 测试：`test/domain/custom_order_test.dart` `test/services/api_client_test.dart` `test/services/pet_library_test.dart` `test/services/file_download_test.dart` `test/services/custom_downloader_test.dart` `test/services/window_bridge_test.dart` `test/app/pet_window_controller_test.dart` `test/app/account_keeper_test.dart` `test/app/main_window_test.dart` `test/app/custom_form_test.dart` | |

> **开工前检查：** 在 `apps/aipet` 下确认前置计划客户端已落地：`lib/domain/custom_order.dart`、`lib/services/custom_service.dart`、`lib/app/main_window/custom_flow/custom_form_model.dart`、`custom_form_page.dart` 都存在，`main_window_model.dart` 里有 `loadCustoms()`、`customs`、`custom`，`main_window_app.dart` 里有 `_CustomList` 与 `openPlans`。任何一项不存在 → 停下告诉用户「前置计划 2026-10-02 客户端 Task 7–12 尚未完成」，不要自己补。再跑一次 `C:\Users\Administrator\code\envs\flutter\bin\flutter test`，记下基线（应全绿；不绿先报告）。

---

### Task 1: 状态改名、进度字段、交付类型与两个接口方法

**Files:**
- Modify: `apps/aipet/lib/domain/custom_order.dart`（替换 `CustomStatus` 与 `CustomRequestInfo`；文件末尾追加交付类型）
- Modify: `apps/aipet/lib/services/api_client.dart`（`customRequests()` 之后加两个方法）
- Modify: `apps/aipet/test/domain/custom_order_test.dart`（替换状态用例，追加三个用例）
- Modify: `apps/aipet/test/services/api_client_test.dart`（追加一个用例）
- Modify: `apps/aipet/test/app/main_window_test.dart`（前置计划的「我的定制」用例里 `making` → `generating`）

**Interfaces:**
- Consumes: 前置计划 Task 7 的 `CustomStatus`、`CustomRequestInfo`、`PayStatus`、`ApiClient._call`、`Species`
- Produces:
  - `enum CustomStatus { draft, pendingPayment, paid, generating, review, delivered, failed, refunded }`，`wire`、`label`、`fromWire(Object?) → CustomStatus?`、`awaitingPayment`
  - `CustomRequestInfo` 新增 `String? petId, stage, failReason; int? stageDone, stageTotal; String get statusText`
  - `bool isCustomPetId(String)`、`bool isSafeAssetPath(String)`
  - `class CustomDelivery { int id; String petId; String name; static CustomDelivery? fromJson(Object?); static List<CustomDelivery> listFrom(Object?) }`
  - `class CustomAsset { String path; int bytes; String sha256 /* 小写 hex */; String url; static CustomAsset? fromJson(Object?) }`
  - `class CustomAssets { String petId; List<CustomAsset> files; static CustomAssets? fromJson(Object?) }`（任何一个文件不合格、重名（不分大小写）、或缺 `pet.json` → null）
  - `ApiClient.customDeliveries() → Future<ApiResult>`、`ApiClient.customAssets(int requestId) → Future<ApiResult>`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/domain/custom_order_test.dart`：删除前置计划里的 `test('status labels follow the spec, draft reads as 待支付', …)` 整个用例，在 `main()` 末尾加：

```dart
  test('statuses follow the generation flow (generation spec 3 / 9)', () {
    const want = {
      'draft': '待支付',
      'pending_payment': '待支付',
      'paid': '待生成',
      'generating': '生成中',
      'review': '审核中',
      'delivered': '已完成',
      'failed': '生成失败',
      'refunded': '已退款',
    };
    want.forEach((wire, label) => expect(CustomStatus.fromWire(wire)?.label, label, reason: wire));
    expect(CustomStatus.fromWire('making'), isNull);
    expect(CustomStatus.fromWire('done'), isNull);
    expect(CustomStatus.fromWire('nope'), isNull);
    expect(PayStatus.fromWire('paid'), PayStatus.paid);
    expect(PayStatus.fromWire('weird'), PayStatus.pending);
  });

  test('我的定制 status text: progress while generating, the promise of help when it failed', () {
    CustomRequestInfo r(Map<String, Object?> extra) =>
        CustomRequestInfo.fromJson({'id': 1, 'name': '豆豆', 'species': 'cat', ...extra})!;
    expect(r({'status': 'generating', 'stage': 'video', 'stage_done': 3, 'stage_total': 7}).statusText, '生成中（动作 3/7）');
    expect(r({'status': 'generating', 'stage': 'refs', 'stage_done': 1, 'stage_total': 3}).statusText, '生成中（参考图 1/3）');
    expect(r({'status': 'generating', 'stage': 'upload', 'stage_done': 2, 'stage_total': 9}).statusText, '生成中');
    expect(r({'status': 'generating'}).statusText, '生成中');
    expect(r({'status': 'generating', 'stage': 'video', 'stage_done': 9, 'stage_total': 7}).statusText, '生成中（动作 7/7）');
    final failed = r({'status': 'failed', 'fail_reason': 'refs: gate failed twice'});
    expect(failed.statusText, '生成失败（我们会联系你处理或退款）');
    expect(failed.failReason, 'refs: gate failed twice');
    expect(r({'status': 'review'}).statusText, '审核中');
    expect(r({'status': 'paid'}).statusText, '待生成');
    final done = r({'status': 'delivered', 'pet_id': 'custom-1'});
    expect((done.statusText, done.petId), ('已完成', 'custom-1'));
    expect(r({'status': 'delivered', 'pet_id': '../x'}).petId, isNull);
  });

  test('deliveries: the usable ones only', () {
    final ds = CustomDelivery.listFrom([
      {'id': 7, 'pet_id': 'custom-7', 'name': '豆豆', 'delivered_at': '2026-10-10 12:00:00'},
      {'id': 8, 'pet_id': 'Custom 8', 'name': 'x'},
      {'id': '9', 'pet_id': 'custom-9', 'name': 'y'},
      'junk',
    ]);
    expect([for (final d in ds) (d.id, d.petId, d.name)], [(7, 'custom-7', '豆豆')]);
    expect(CustomDelivery.listFrom(null), isEmpty);
    expect(isCustomPetId('custom-123'), isTrue);
    expect(isCustomPetId('.downloading'), isFalse);
  });

  test('assets: every file safe and checkable, pet.json among them, or nothing at all', () {
    final hash = 'ab' * 32;
    Map<String, Object?> file(String path) =>
        {'path': path, 'bytes': 10, 'sha256': hash.toUpperCase(), 'url': 'https://oss.test/$path?sig=1'};
    final a = CustomAssets.fromJson({
      'pet_id': 'custom-7',
      'files': [file('pet.json'), file('stand.mp4'), file('voices/a/stand-1.wav')],
    })!;
    expect(a.petId, 'custom-7');
    expect(a.files.map((f) => f.path), ['pet.json', 'stand.mp4', 'voices/a/stand-1.wav']);
    expect(a.files.first.sha256, hash);
    expect(a.files.first.bytes, 10);
    for (final bad in ['../evil.exe', '/abs.mp4', r'a\b.mp4', 'C:/x.mp4', '.hidden', 'a//b', '']) {
      expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [file('pet.json'), file(bad)]}), isNull,
          reason: bad);
    }
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [file('stand.mp4')]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [file('pet.json'), file('PET.json')]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [{...file('pet.json'), 'sha256': 'xyz'}]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [{...file('pet.json'), 'url': 'ftp://x/y'}]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [{...file('pet.json'), 'bytes': -1}]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': '../x', 'files': [file('pet.json')]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': []}), isNull);
  });
```

`apps/aipet/test/services/api_client_test.dart`：`main()` 末尾加：

```dart
  test('custom deliveries and assets: GET, with the token', () async {
    token = '1|t';
    await api.customDeliveries();
    await api.customAssets(7);
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'],
        ['GET /api/aipet/custom/deliveries', 'GET /api/aipet/custom/requests/7/assets']);
    expect(http.sent.last.headers['Authorization'], 'Bearer 1|t');
    expect(http.sent.last.body, isNull);
  });
```

`apps/aipet/test/app/main_window_test.dart`：前置计划 Task 12 加的 `testWidgets('我的定制 lists requests with their status; 待支付 offers 去支付', …)` 里，把 `'status': 'making'` 改成 `'status': 'generating'`，把 `expect(find.text('制作中'), findsOneWidget);` 改成 `expect(find.text('生成中'), findsOneWidget);`（Task 8 会整体替换这个用例；这里只让它跟着状态改名继续通过）。

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/domain/custom_order_test.dart test/services/api_client_test.dart`
Expected: 编译失败——`statusText`、`CustomDelivery`、`CustomAssets`、`isCustomPetId`、`customDeliveries` 未定义。

- [ ] **Step 3: 实现**

`apps/aipet/lib/domain/custom_order.dart`：把整个 `enum CustomStatus { … }` 替换为：

```dart
/// A custom pet's progress (generation spec 3, revising custom order spec 2):
/// draft and pending_payment both read as 待支付.
enum CustomStatus {
  draft('draft', '待支付'),
  pendingPayment('pending_payment', '待支付'),
  paid('paid', '待生成'),
  generating('generating', '生成中'),
  review('review', '审核中'),
  delivered('delivered', '已完成'),
  failed('failed', '生成失败'),
  refunded('refunded', '已退款');

  const CustomStatus(this.wire, this.label);
  final String wire;
  final String label;

  static CustomStatus? fromWire(Object? s) => {for (final v in values) v.wire: v}[s];

  bool get awaitingPayment => this == draft || this == pendingPayment;
}
```

把整个 `class CustomRequestInfo { … }` 替换为：

```dart
class CustomRequestInfo {
  const CustomRequestInfo({
    required this.id,
    required this.name,
    required this.species,
    required this.status,
    this.planCode,
    this.planName,
    this.priceCents,
    this.orderNo,
    this.coverUrl,
    this.petId,
    this.stage,
    this.stageDone,
    this.stageTotal,
    this.failReason,
  });

  final int id;
  final String name;
  final Species species;
  final CustomStatus status;
  final String? planCode, planName, orderNo, coverUrl;
  final int? priceCents;

  /// `custom-<id>`: the folder under pets/ it is delivered into; null until
  /// the server set up its generation.
  final String? petId;

  /// The latest progress while generating: which step, and n of m.
  final String? stage;
  final int? stageDone, stageTotal;

  /// Failed only. For support; the list does not show it.
  final String? failReason;

  /// What 我的定制 says (generation spec 6.2). The worker counts within a
  /// step (refs 1/3, then video 1/7), so the count is shown with the step's
  /// name -- a bare n/m would seem to go backwards when the step changes.
  String get statusText {
    final total = stageTotal ?? 0;
    final done = (stageDone ?? 0).clamp(0, total);
    return switch (status) {
      CustomStatus.generating when total > 0 && stage == 'refs' => '生成中（参考图 $done/$total）',
      CustomStatus.generating when total > 0 && stage == 'video' => '生成中（动作 $done/$total）',
      CustomStatus.failed => '生成失败（我们会联系你处理或退款）',
      _ => status.label,
    };
  }

  static CustomRequestInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    final species = Species.values.asNameMap()[j['species']];
    final status = CustomStatus.fromWire(j['status']);
    if (id is! int || name is! String || species == null || status == null) return null;
    String? s(String k) => j[k] is String ? j[k] as String : null;
    int? n(String k) => j[k] is int ? j[k] as int : null;
    final petId = s('pet_id');
    return CustomRequestInfo(
      id: id,
      name: name,
      species: species,
      status: status,
      planCode: s('plan_code'),
      planName: s('plan_name'),
      priceCents: n('price_cents'),
      orderNo: s('order_no'),
      coverUrl: s('cover_url'),
      petId: petId != null && isCustomPetId(petId) ? petId : null,
      stage: s('stage'),
      stageDone: n('stage_done'),
      stageTotal: n('stage_total'),
      failReason: s('fail_reason'),
    );
  }
}
```

文件末尾追加：

```dart
final _petIdPattern = RegExp(r'^[a-z0-9-]{1,64}$');

/// A path segment of a delivered file: no leading dot (so no `.`, `..` or
/// hidden files), no slashes, colons or other characters Windows minds.
final _segmentPattern = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// A folder name under pets/ that a delivered pet may use (the same rule as
/// pet.json ids), never a dot-folder.
bool isCustomPetId(String id) => _petIdPattern.hasMatch(id);

/// `stand.mp4`, `voices/a/stand-1.wav`: relative, forward slashes, and nothing
/// that could step outside the pet folder.
bool isSafeAssetPath(String path) {
  if (path.isEmpty || path.length > 200) return false;
  return path.split('/').every(_segmentPattern.hasMatch);
}

/// One delivered custom pet (`GET custom/deliveries`; delivered_at is not used).
class CustomDelivery {
  const CustomDelivery({required this.id, required this.petId, required this.name});

  final int id;
  final String petId;
  final String name;

  static CustomDelivery? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], petId = j['pet_id'], name = j['name'];
    if (id is! int || petId is! String || !isCustomPetId(petId) || name is! String) return null;
    return CustomDelivery(id: id, petId: petId, name: name);
  }

  static List<CustomDelivery> listFrom(Object? data) =>
      [for (final j in (data is List ? data : const [])) ?CustomDelivery.fromJson(j)];
}

/// One file of a delivered pet: where it goes inside the pet folder, and how
/// to tell it arrived whole.
class CustomAsset {
  const CustomAsset({required this.path, required this.bytes, required this.sha256, required this.url});

  final String path;
  final int bytes;

  /// Lower-case hex.
  final String sha256;

  /// A signed GET, good for 30 minutes.
  final String url;

  static CustomAsset? fromJson(Object? j) {
    if (j is! Map) return null;
    final path = j['path'], bytes = j['bytes'], hash = j['sha256'], url = j['url'];
    if (path is! String || !isSafeAssetPath(path)) return null;
    if (bytes is! int || bytes < 0 || hash is! String || url is! String) return null;
    final h = hash.toLowerCase();
    if (!_sha256Pattern.hasMatch(h)) return null;
    final u = Uri.tryParse(url);
    if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty) return null;
    return CustomAsset(path: path, bytes: bytes, sha256: h, url: url);
  }
}

/// `GET custom/requests/:id/assets`. All or nothing: a manifest with one
/// unusable file, two files that are the same file on Windows, or no
/// pet.json would install a broken pet.
class CustomAssets {
  const CustomAssets({required this.petId, required this.files});

  final String petId;
  final List<CustomAsset> files;

  static CustomAssets? fromJson(Object? j) {
    if (j is! Map) return null;
    final petId = j['pet_id'], raw = j['files'];
    if (petId is! String || !isCustomPetId(petId) || raw is! List || raw.isEmpty) return null;
    final files = <CustomAsset>[];
    for (final r in raw) {
      final f = CustomAsset.fromJson(r);
      if (f == null) return null;
      files.add(f);
    }
    final paths = {for (final f in files) f.path.toLowerCase()};
    if (paths.length != files.length || !paths.contains('pet.json')) return null;
    return CustomAssets(petId: petId, files: List.unmodifiable(files));
  }
}
```

`apps/aipet/lib/services/api_client.dart`：在 `customRequests()` 方法之后加：

```dart

  // Delivered custom pets (generation spec 4.6): the pet window's downloader.

  Future<ApiResult> customDeliveries() => _call('GET', '/api/aipet/custom/deliveries');

  Future<ApiResult> customAssets(int requestId) => _call('GET', '/api/aipet/custom/requests/$requestId/assets');
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/domain/custom_order_test.dart test/services/api_client_test.dart test/services/custom_service_test.dart test/app/main_window_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/domain/custom_order.dart apps/aipet/lib/services/api_client.dart apps/aipet/test/domain/custom_order_test.dart apps/aipet/test/services/api_client_test.dart apps/aipet/test/app/main_window_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): generation statuses, progress and the delivery types" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 宠物库跳过点目录

**Files:**
- Modify: `apps/aipet/lib/services/pet_library.dart`（`_scanRoot` 与类注释）
- Test: `apps/aipet/test/services/pet_library_test.dart`（追加一个用例）

**Interfaces:**
- Consumes: 无
- Produces: `PetLibrary.scan()` 不再列出任何以 `.` 开头的目录（`.downloading`、`.old-<pet_id>`）

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/pet_library_test.dart` 的 `main()` 末尾加：

```dart
  test('dot folders (a download in progress, a pet being replaced) are not pets', () {
    writePet(custom, id: 'custom-7', origin: 'custom');
    writePet(Directory('${custom.path}\\.downloading'), id: 'custom-8', origin: 'custom');
    // A complete, valid pet folder moved aside while its replacement goes in.
    writePet(custom, id: 'custom-9', origin: 'custom').renameSync('${custom.path}\\.old-custom-9');
    expect(lib.scan().map((p) => p.id), ['custom-7']);
  });
```

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/pet_library_test.dart`
Expected: FAIL，实际为 `['custom-7', 'custom-9']`（`.old-custom-9` 里的 pet.json 被当成宠物）。

- [ ] **Step 3: 实现**

`apps/aipet/lib/services/pet_library.dart`：

类注释改为：

```dart
/// Every pet folder the app can see: read-only built-ins shipped with the app,
/// then custom pets downloaded into %APPDATA% (generation spec 6.1). Both
/// engines may scan; only the pet window's CustomDownloader writes customRoot,
/// and its work in progress lives in dot-folders this skips.
```

`_scanRoot` 里列目录那一行：

```dart
      dirs = root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
```

改为：

```dart
      dirs = root.listSync().whereType<Directory>().where((d) => !_isDotFolder(d)).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
```

并在类里加：

```dart
  /// `.downloading`, `.old-<id>`: a download in progress or a folder on its way out.
  static bool _isDotFolder(Directory d) {
    final p = d.path;
    return p.substring(p.lastIndexOf(Platform.pathSeparator) + 1).startsWith('.');
  }
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/pet_library_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/services/pet_library.dart apps/aipet/test/services/pet_library_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): the pet library skips dot-folders (downloads in progress)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 流式下载传输

**Files:**
- Create: `apps/aipet/lib/services/file_download.dart`
- Create: `apps/aipet/test/support/fake_downloads.dart`
- Test: `apps/aipet/test/services/file_download_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class DownloadFailed implements Exception { const DownloadFailed(String reason); final String reason; }`
  - `abstract class DownloadTransport { Future<void> download(Uri url, File into); }`——创建或截断 `into`；除非 200 且整个 body 写完，否则抛 `DownloadFailed`
  - `class IoDownloadTransport implements DownloadTransport { IoDownloadTransport({Duration connectTimeout = 15 s, Duration idleTimeout = 30 s}); void close(); }`
  - 测试用 `class FakeDownloads implements DownloadTransport { List<String> requested; List<int>? Function(Uri) serve; Completer<void>? gate; }`（`serve` 返回 null = 403）

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/file_download_test.dart`：

```dart
import 'dart:async';
import 'dart:io';

import 'package:aipet/services/file_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory tmp;
  late IoDownloadTransport t;
  final body = List<int>.generate(300000, (i) => i % 251);

  setUp(() async {
    // flutter_test's binding, once initialized, fakes every HttpClient with
    // 400s; these tests talk to a real loopback server.
    HttpOverrides.global = null;
    tmp = Directory.systemTemp.createTempSync('download_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        switch (req.uri.path) {
          case '/ok':
            req.response.contentLength = body.length;
            req.response.add(body);
          case '/stall':
            req.response.add([1, 2, 3]);
            await req.response.flush();
            await Future<void>.delayed(const Duration(seconds: 2));
          default:
            req.response.statusCode = HttpStatus.forbidden;
            req.response.write('<Error>AccessDenied</Error>');
        }
        await req.response.close();
      } catch (_) {
        // The client gave up first; nothing to do.
      }
    });
    t = IoDownloadTransport(idleTimeout: const Duration(milliseconds: 300));
  });

  tearDown(() async {
    t.close();
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  test('a 200 is streamed into the file, replacing what was there', () async {
    final f = File('${tmp.path}\\a.bin')..writeAsStringSync('old and longer than nothing');
    await t.download(at('/ok'), f);
    expect(f.readAsBytesSync(), body);
  });

  test('anything but 200 (an expired signed URL is a 403) is DownloadFailed', () async {
    await expectLater(t.download(at('/expired'), File('${tmp.path}\\b.bin')),
        throwsA(isA<DownloadFailed>().having((e) => e.reason, 'reason', 'HTTP 403')));
  });

  test('a server that stops sending is DownloadFailed, not a hang, and the file is not left open', () async {
    final f = File('${tmp.path}\\c.bin');
    await expectLater(t.download(at('/stall'), f), throwsA(isA<DownloadFailed>()));
    f.deleteSync(); // fails on Windows if the sink were still open
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('nobody listening is DownloadFailed', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(t.download(Uri.parse('http://127.0.0.1:$port/x'), File('${tmp.path}\\d.bin')),
        throwsA(isA<DownloadFailed>()));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/file_download_test.dart`
Expected: 编译失败，`file_download.dart` 不存在。

- [ ] **Step 3: 实现**

`apps/aipet/lib/services/file_download.dart`：

```dart
import 'dart:async';
import 'dart:io';

/// Why a download did not produce the whole file: a status other than 200
/// (an expired signed URL is a 403), a connection that failed or went quiet.
class DownloadFailed implements Exception {
  const DownloadFailed(this.reason);

  final String reason;

  @override
  String toString() => 'DownloadFailed($reason)';
}

/// Fetches one URL into one file (generation spec 6.1). Tests pass a fake.
abstract class DownloadTransport {
  /// Creates or truncates [into]; throws [DownloadFailed] unless the whole
  /// body of a 200 was written.
  Future<void> download(Uri url, File into);
}

/// dart:io, streamed straight to disk: the body is never held in memory, and
/// nothing here blocks the UI isolate (it runs on the platform thread).
class IoDownloadTransport implements DownloadTransport {
  IoDownloadTransport({
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : _client = HttpClient()..connectionTimeout = connectTimeout;

  final Duration connectTimeout;

  /// The longest wait for the headers or for the next piece of the body; a
  /// clip can take minutes on a slow line, so there is no overall limit.
  final Duration idleTimeout;
  final HttpClient _client;

  @override
  Future<void> download(Uri url, File into) async {
    IOSink? sink;
    try {
      final req = await _client.getUrl(url);
      final res = await req.close().timeout(idleTimeout);
      if (res.statusCode != HttpStatus.ok) {
        try {
          await res.drain<void>().timeout(idleTimeout);
        } catch (_) {}
        throw DownloadFailed('HTTP ${res.statusCode}');
      }
      final out = into.openWrite();
      sink = out;
      await out.addStream(res.timeout(idleTimeout));
      sink = null;
      await out.close();
      final expected = res.contentLength; // -1 when chunked or decompressed
      if (expected >= 0 && await into.length() != expected) throw const DownloadFailed('short body');
    } on DownloadFailed {
      rethrow;
    } catch (e) {
      throw DownloadFailed('$e');
    } finally {
      // An open sink would keep the file locked on Windows.
      try {
        await sink?.close();
      } catch (_) {}
    }
  }

  void close() => _client.close(force: true);
}
```

`apps/aipet/test/support/fake_downloads.dart`：

```dart
import 'dart:async';
import 'dart:io';

import 'package:aipet/services/file_download.dart';

/// OSS, scripted: [serve] gives the bytes at a URL, or null for a refusal
/// (an expired or unknown signed URL: 403). [requested] records every call.
class FakeDownloads implements DownloadTransport {
  final requested = <String>[];
  List<int>? Function(Uri url) serve = (_) => null;

  /// While set and not completed, every download waits for it (a slow line).
  Completer<void>? gate;

  @override
  Future<void> download(Uri url, File into) async {
    requested.add(url.toString());
    final g = gate;
    if (g != null) await g.future;
    final bytes = serve(url);
    if (bytes == null) throw const DownloadFailed('HTTP 403');
    await into.writeAsBytes(bytes, flush: true);
  }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/file_download_test.dart`
Expected: All tests passed（「nobody listening」在 Windows 上可能要约 2 秒才报连接被拒，属正常）。

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/services/file_download.dart apps/aipet/test/support/fake_downloads.dart apps/aipet/test/services/file_download_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): streamed file downloads that fail cleanly on 403, stalls and refusals" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: CustomDownloader

**Files:**
- Create: `apps/aipet/lib/services/custom_downloader.dart`
- Test: `apps/aipet/test/services/custom_downloader_test.dart`

**Interfaces:**
- Consumes: `ApiClient.customDeliveries()` / `customAssets(int)`、`ApiOk`、`CustomDelivery`、`CustomAssets`、`CustomAsset`（Task 1）；`DownloadTransport`、`DownloadFailed`、`FakeDownloads`（Task 3）；`parsePet`、`PetOrigin`、`Pet.isComplete`（已有）；`PetLibrary` 跳点目录（Task 2）
- Produces:
  - `class CustomDownloader { CustomDownloader({required ApiClient api, required DownloadTransport transport, required Directory petsRoot, required bool Function() signedIn, required Future<void> Function(List<CustomDelivery> installed) onInstalled}); Future<void> run(); bool get running; Directory get stagingRoot; }`
  - `run()` 永不抛；正在跑时再调用返回同一个 Future，并在本轮结束后最多补跑一轮；本轮装好的宠物（至少一只时）一次性交给 `onInstalled`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/custom_downloader_test.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_downloader.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_downloads.dart';
import '../support/fake_http.dart';

/// A delivered pet as OSS holds it: path -> bytes.
Map<String, List<int>> _package(String petId, String name) => {
      'pet.json': utf8.encode(jsonEncode({
        'schema': 1,
        'id': petId,
        'name': name,
        'species': 'cat',
        'origin': 'custom',
        'cover': 'cover.png',
        'actions': ['stand', 'walk'],
      })),
      'cover.png': utf8.encode('png $petId'),
      'stand.mp4': utf8.encode('stand clip of $petId'),
      'walk.mp4': utf8.encode('walk clip of $petId'),
    };

void main() {
  late Directory tmp, pets;
  late FakeHttp http;
  late FakeDownloads files;
  late List<int>? Function(Uri) serveOk;
  late bool signedIn;
  late List<List<String>> installed;
  late CustomDownloader dl;
  late Map<String, Map<String, List<int>>> server; // petId -> package
  late List<Map<String, Object?>> deliveries;
  late int assetVersion; // the signed URLs the assets endpoint hands out
  late int liveVersion; // the signed URLs OSS still accepts

  void deliver(int id, String petId, {String name = '豆豆'}) {
    server[petId] = _package(petId, name);
    deliveries.add({'id': id, 'pet_id': petId, 'name': name, 'delivered_at': '2026-10-10 12:00:00'});
  }

  File staged(String petId, String path) => File('${pets.path}\\.downloading\\$petId\\$path');
  File installedFile(String petId, String path) => File('${pets.path}\\$petId\\$path');
  List<String> downloaded() => [for (final u in files.requested) Uri.parse(u).pathSegments.last];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('custom_dl_');
    pets = Directory('${tmp.path}\\pets');
    http = FakeHttp();
    files = FakeDownloads();
    signedIn = true;
    installed = [];
    server = {};
    deliveries = [];
    assetVersion = 1;
    liveVersion = 1;
    final assetsPath = RegExp(r'^/api/aipet/custom/requests/(\d+)/assets$');
    http.reply = (r) {
      if (r.url.path == '/api/aipet/custom/deliveries') return FakeHttp.ok(deliveries);
      final m = assetsPath.firstMatch(r.url.path);
      if (m == null) return FakeHttp.fail(404, 'not found', null, 404);
      final d = deliveries.firstWhere((d) => '${d['id']}' == m.group(1));
      final petId = d['pet_id']! as String;
      return FakeHttp.ok({
        'pet_id': petId,
        'files': [
          for (final MapEntry(key: path, value: bytes) in server[petId]!.entries)
            {
              'path': path,
              'bytes': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
              'url': 'https://oss.test/v$assetVersion/$petId/$path?sig=x',
            },
        ],
      });
    };
    serveOk = (u) {
      final s = u.pathSegments; // [v1, custom-7, stand.mp4]
      if (s.first != 'v$liveVersion') return null;
      return server[s[1]]?[s.sublist(2).join('/')];
    };
    files.serve = serveOk;
    dl = CustomDownloader(
      api: ApiClient(http, baseUrl: 'https://x.test', token: () => 't'),
      transport: files,
      petsRoot: pets,
      signedIn: () => signedIn,
      onInstalled: (ds) async => installed.add([for (final d in ds) d.petId]),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a delivered pet is downloaded, verified, installed and announced', () async {
    deliver(7, 'custom-7');
    await dl.run();
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'],
        ['GET /api/aipet/custom/deliveries', 'GET /api/aipet/custom/requests/7/assets']);
    expect(http.sent.first.headers['Authorization'], 'Bearer t');
    expect(installed, [['custom-7']]);
    final pet = PetLibrary(builtinRoot: Directory('${tmp.path}\\none'), customRoot: pets).scan().single;
    expect((pet.id, pet.name, pet.isComplete), ('custom-7', '豆豆', true));
    expect(Directory('${pets.path}\\.downloading\\custom-7').existsSync(), isFalse);
  });

  test('a delivered pet already here and complete is not asked about again', () async {
    deliver(7, 'custom-7');
    await dl.run();
    http.sent.clear();
    files.requested.clear();
    await dl.run();
    expect([for (final r in http.sent) r.url.path], ['/api/aipet/custom/deliveries']);
    expect(files.requested, isEmpty);
    expect(installed, hasLength(1));
  });

  test('quit mid-download: the next run fetches only what is missing or half-written', () async {
    deliver(7, 'custom-7');
    final pkg = server['custom-7']!;
    staged('custom-7', 'pet.json')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(pkg['pet.json']!);
    staged('custom-7', 'cover.png').writeAsBytesSync(pkg['cover.png']!);
    File('${staged('custom-7', 'stand.mp4').path}.part').writeAsBytesSync(pkg['stand.mp4']!.sublist(0, 3));
    staged('custom-7', 'walk.mp4').writeAsBytesSync([1, 2, 3]); // wrong bytes from an older attempt
    await dl.run();
    expect(downloaded()..sort(), ['stand.mp4', 'walk.mp4']);
    expect(installed, [['custom-7']]);
    expect(installedFile('custom-7', 'walk.mp4').readAsBytesSync(), pkg['walk.mp4']);
    expect(File('${installedFile('custom-7', 'stand.mp4').path}.part').existsSync(), isFalse);
  });

  test('one file failing its sha256: nothing installed, the good files kept, the next run fetches only that one',
      () async {
    deliver(7, 'custom-7');
    files.serve = (u) => u.path.endsWith('/walk.mp4') ? utf8.encode('corrupted') : serveOk(u);
    await dl.run();
    expect(installed, isEmpty);
    expect(installedFile('custom-7', 'pet.json').existsSync(), isFalse);
    expect(staged('custom-7', 'stand.mp4').existsSync(), isTrue);
    expect(staged('custom-7', 'walk.mp4').existsSync(), isFalse);
    expect(File('${staged('custom-7', 'walk.mp4').path}.part').existsSync(), isFalse);
    files
      ..serve = serveOk
      ..requested.clear();
    await dl.run();
    expect(downloaded(), ['walk.mp4']);
    expect(installed, [['custom-7']]);
  });

  test('an incomplete folder already there is replaced whole; the user deleting it brings it back', () async {
    deliver(7, 'custom-7');
    final half = Directory('${pets.path}\\custom-7')..createSync(recursive: true);
    File('${half.path}\\pet.json').writeAsBytesSync(server['custom-7']!['pet.json']!);
    File('${half.path}\\stale.txt').writeAsStringSync('from an old, broken copy');
    await dl.run();
    expect(installed, [['custom-7']]);
    expect(File('${half.path}\\stale.txt').existsSync(), isFalse);
    expect(installedFile('custom-7', 'walk.mp4').existsSync(), isTrue);
    expect(Directory('${pets.path}\\.old-custom-7').existsSync(), isFalse);

    half.deleteSync(recursive: true);
    await dl.run();
    expect(installed, [['custom-7'], ['custom-7']]);
    expect(installedFile('custom-7', 'walk.mp4').existsSync(), isTrue);
  });

  test('a signed URL that expired: quiet now, and the next run asks for fresh URLs', () async {
    deliver(7, 'custom-7');
    liveVersion = 2; // what the assets endpoint hands out (v1) no longer works
    await dl.run();
    expect(installed, isEmpty);
    assetVersion = 2;
    await dl.run();
    expect(http.to('/api/aipet/custom/requests/7/assets'), hasLength(2));
    expect(installed, [['custom-7']]);
  });

  test('two triggers at once share one pass; those arriving mid-pass make one more pass after it', () async {
    deliver(7, 'custom-7');
    files.gate = Completer<void>();
    final a = dl.run();
    while (files.requested.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(dl.running, isTrue);
    final b = dl.run(); // login ...
    final c = dl.run(); // ... and its sync
    expect(identical(a, b) && identical(a, c), isTrue);
    files.gate!.complete();
    await a;
    expect(dl.running, isFalse);
    expect(http.to('/api/aipet/custom/deliveries'), hasLength(2));
    expect(downloaded()..sort(), ['cover.png', 'pet.json', 'stand.mp4', 'walk.mp4']);
    expect(installed, [['custom-7']]);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('signed out: not a single request', () async {
    signedIn = false;
    deliver(7, 'custom-7');
    await dl.run();
    expect(http.sent, isEmpty);
    expect(files.requested, isEmpty);
  });

  test('files that do not add up to a whole pet are not installed', () async {
    deliver(7, 'custom-7');
    server['custom-7']!.remove('walk.mp4'); // pet.json still lists walk
    await dl.run();
    expect(installed, isEmpty);
    expect(Directory('${pets.path}\\custom-7').existsSync(), isFalse);
  });

  test('a bad manifest or a server error skips that pet quietly; the others still come', () async {
    deliver(7, 'custom-7');
    deliver(8, 'custom-8', name: '旺财');
    final normal = http.reply;
    http.reply = (r) => r.url.path.endsWith('/7/assets')
        ? FakeHttp.ok({
            'pet_id': 'custom-7',
            'files': [
              {'path': '../evil.exe', 'bytes': 1, 'sha256': 'a' * 64, 'url': 'https://oss.test/v1/evil'},
            ],
          })
        : normal(r);
    await dl.run();
    expect(installed, [['custom-8']]);
    expect(File('${tmp.path}\\evil.exe').existsSync(), isFalse);
    expect(File('${pets.path}\\.downloading\\evil.exe').existsSync(), isFalse);

    http.reply = (_) => throw Exception('offline');
    await expectLater(dl.run(), completes);
    http.reply = (_) => FakeHttp.fail(1003, 'x', null, 401);
    await expectLater(dl.run(), completes);
  });
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/custom_downloader_test.dart`
Expected: 编译失败，`custom_downloader.dart` 不存在。

- [ ] **Step 3: 实现**

`apps/aipet/lib/services/custom_downloader.dart`：

```dart
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/custom_order.dart';
import '../domain/pet.dart';
import 'api_client.dart';
import 'file_download.dart';

final String _sep = Platform.pathSeparator;
const _log = 'aipet.custom';

/// Brings delivered custom pets down into `pets/<pet_id>/` (generation spec
/// 6.1). Built in the pet window, the only writer of the pets folder.
///
/// Files go to `pets/.downloading/<pet_id>/<path>` -- each through a `.part`
/// and checked against its size and sha256 -- and a file already there and
/// matching is not fetched again, so a quit mid-download resumes. Only a
/// complete pet is moved into place, in one directory rename. Anything that
/// fails is logged and left for the next trigger, keeping what was verified;
/// nothing here throws or shows an error.
class CustomDownloader {
  CustomDownloader({
    required ApiClient api,
    required DownloadTransport transport,
    required this.petsRoot,
    required bool Function() signedIn,
    required Future<void> Function(List<CustomDelivery> installed) onInstalled,
  })  : _api = api,
        _transport = transport,
        _signedIn = signedIn,
        _onInstalled = onInstalled;

  final Directory petsRoot;
  final ApiClient _api;
  final DownloadTransport _transport;
  final bool Function() _signedIn;
  final Future<void> Function(List<CustomDelivery>) _onInstalled;

  Future<void>? _running;
  bool _again = false;

  Directory get stagingRoot => Directory('${petsRoot.path}$_sep.downloading');

  bool get running => _running != null;

  Directory _target(String petId) => Directory('${petsRoot.path}$_sep$petId');
  Directory _staging(String petId) => Directory('${stagingRoot.path}$_sep$petId');
  Directory _aside(String petId) => Directory('${petsRoot.path}$_sep.old-$petId');

  /// One pass at a time. A trigger that arrives during a pass (login and the
  /// sync it starts, say) gets the same future, and one more pass runs after
  /// this one -- a delivery may have appeared since it asked.
  Future<void> run() {
    final current = _running;
    if (current != null) {
      _again = true;
      return current;
    }
    // Block body on purpose: see MatteCache.ensure.
    final started = _loop().whenComplete(() {
      _running = null;
    });
    _running = started;
    return started;
  }

  Future<void> _loop() async {
    do {
      _again = false;
      try {
        await _pass();
      } catch (e, s) {
        developer.log('pass failed: $e', name: _log, error: e, stackTrace: s);
      }
    } while (_again);
  }

  Future<void> _pass() async {
    if (!_signedIn()) return;
    final r = await _api.customDeliveries();
    if (r is! ApiOk) {
      developer.log('deliveries: ${r.message}', name: _log);
      return;
    }
    final installed = <CustomDelivery>[];
    for (final d in CustomDelivery.listFrom(r.data)) {
      if (!_signedIn()) break;
      if (await _isComplete(_target(d.petId), d.petId)) continue;
      if (await _fetch(d)) installed.add(d);
    }
    if (installed.isNotEmpty) await _onInstalled(installed);
  }

  /// [dir] holds a pet.json naming [petId] as a custom pet, and every file it lists.
  static Future<bool> _isComplete(Directory dir, String petId) async {
    try {
      final json = File('${dir.path}${_sep}pet.json');
      if (!await json.exists()) return false;
      final pet = parsePet(await json.readAsString(), dir);
      return pet.id == petId && pet.origin == PetOrigin.custom && pet.isComplete;
    } catch (_) {
      return false;
    }
  }

  /// True once [d] is installed; false when something is still missing.
  Future<bool> _fetch(CustomDelivery d) async {
    final r = await _api.customAssets(d.id);
    if (r is! ApiOk) {
      developer.log('${d.petId} assets: ${r.message}', name: _log);
      return false;
    }
    final assets = CustomAssets.fromJson(r.data);
    if (assets == null || assets.petId != d.petId) {
      developer.log('${d.petId}: unusable assets reply', name: _log);
      return false;
    }
    final staging = _staging(d.petId);
    var all = true;
    // Keep going after a failure: every file verified now is one less next time.
    for (final f in assets.files) {
      if (!await _ensureFile(staging, f)) all = false;
    }
    if (!all) return false;
    if (!await _isComplete(staging, d.petId)) {
      developer.log('${d.petId}: the delivered files do not make a complete pet', name: _log);
      return false;
    }
    return _install(staging, d.petId);
  }

  Future<bool> _ensureFile(Directory staging, CustomAsset f) async {
    final target = File('${staging.path}$_sep${f.path.replaceAll('/', _sep)}');
    if (await _matches(target, f)) return true; // verified on an earlier run
    final part = File('${target.path}.part');
    try {
      await part.parent.create(recursive: true);
      await _transport.download(Uri.parse(f.url), part);
      if (!await _matches(part, f)) {
        developer.log('${f.path}: size or sha256 does not match; next time', name: _log);
        await part.delete();
        return false;
      }
      await part.rename(target.path);
      return true;
    } on DownloadFailed catch (e) {
      developer.log('${f.path}: ${e.reason}; next time', name: _log);
      return false;
    } catch (e) {
      developer.log('${f.path}: $e; next time', name: _log);
      return false;
    }
  }

  /// Streamed in chunks: a clip is never read into memory whole, and the UI
  /// isolate is never held for long.
  static Future<bool> _matches(File f, CustomAsset a) async {
    try {
      if (!await f.exists() || await f.length() != a.bytes) return false;
      return (await sha256.bind(f.openRead()).first).toString() == a.sha256;
    } catch (_) {
      return false;
    }
  }

  /// staging -> pets/<petId>, one rename. A folder already there (incomplete,
  /// or deleted and half re-created by hand) is moved aside to .old-<petId>
  /// first and deleted after; if the move in fails, it is put back.
  Future<bool> _install(Directory staging, String petId) async {
    final target = _target(petId);
    final aside = _aside(petId);
    try {
      if (await aside.exists()) await aside.delete(recursive: true);
      if (await target.exists()) await target.rename(aside.path);
      try {
        await staging.rename(target.path);
      } catch (_) {
        if (await aside.exists() && !await target.exists()) await aside.rename(target.path);
        rethrow;
      }
    } catch (e) {
      developer.log('$petId: install failed ($e); next time', name: _log);
      return false;
    }
    try {
      if (await aside.exists()) await aside.delete(recursive: true);
    } catch (e) {
      // A dot-folder: the library never lists it, and the next install clears it.
      developer.log('$petId: could not delete the old folder ($e)', name: _log);
    }
    developer.log('$petId installed', name: _log);
    return true;
  }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/custom_downloader_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/services/custom_downloader.dart apps/aipet/test/services/custom_downloader_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): download delivered custom pets - verified, resumable, installed in one rename" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 窗口通道上的「新宠物」与「刷新」，宠物窗口重扫

**Files:**
- Modify: `apps/aipet/lib/services/window_bridge.dart`
- Modify: `apps/aipet/lib/app/pet_window/pet_window_controller.dart`（加 `rescan()`）
- Test: `apps/aipet/test/services/window_bridge_test.dart`、`apps/aipet/test/app/pet_window_controller_test.dart`（各追加）

**Interfaces:**
- Consumes: 已有 `PetWindowBridge`、`MainWindowBridge`、`BridgeTransport`、`FakeTransport`
- Produces:
  - `BridgeMethods.petsReady = 'petsReady'`（宠物窗口 → 主窗口，`{pets: [{petId, name}]}`）、`BridgeMethods.takeReady = 'takeReady'`（主窗口 → 宠物窗口，答 `{pets: […]}` 并清空）、`BridgeMethods.refreshCustom = 'refreshCustom'`（主窗口 → 宠物窗口）
  - `class ReadyPet { const ReadyPet({required String petId, required String name}); toJson(); static ReadyPet? fromJson(Object?); static List<ReadyPet> listFrom(Object?); == / hashCode }`
  - `PetWindowBridge({…, Future<void> Function()? onRefreshCustom})`；`Future<void> pushReady(List<ReadyPet> pets)`——送达则清空，没人收（主窗口没开）就留着等 `takeReady`
  - `MainWindowBridge`：`Stream<List<ReadyPet>> get readyPets`、`Future<List<ReadyPet>> takeReady()`（失败返回空）、`void refreshCustom()`
  - `PetWindowController.rescan()`：重新扫描宠物库并 `notifyListeners()`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/window_bridge_test.dart` 的 `main()` 末尾加：

```dart
  test('a ready pet reaches an open library at once and is not kept', () async {
    final seen = <List<ReadyPet>>[];
    main.readyPets.listen(seen.add);
    await pet.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    expect(seen.single, [const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    expect(await main.takeReady(), isEmpty);
  });

  test('with no library listening, ready pets wait until it asks', () async {
    mainEnd.setHandler(null); // the library window is not running
    await pet.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    await pet.pushReady([const ReadyPet(petId: 'custom-8', name: '旺财')]);
    main.start();
    expect((await main.takeReady()).map((p) => p.petId), ['custom-7', 'custom-8']);
    expect(await main.takeReady(), isEmpty);
  });

  test('refreshCustom reaches the pet window', () async {
    var refreshes = 0;
    pet = PetWindowBridge(petEnd,
        state: () => state,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async {},
        onQuit: () async {},
        onRefreshCustom: () async => refreshes++)
      ..start();
    main.refreshCustom();
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 1);
  });

  test('a garbled ready list is just empty', () {
    expect(ReadyPet.listFrom(null), isEmpty);
    expect(ReadyPet.listFrom({'pets': ['x', {'petId': 1}]}), isEmpty);
  });
```

`apps/aipet/test/app/pet_window_controller_test.dart` 的 `main()` 末尾加：

```dart
  test('rescan picks up a pet folder that arrived after boot', () async {
    await c.boot();
    expect(c.pets.map((p) => p.id), isNot(contains('custom-7')));
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat');
    var notified = 0;
    c.addListener(() => notified++);
    c.rescan();
    expect(c.pets.map((p) => p.id), contains('custom-7'));
    expect(notified, 1);
  });
```

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/window_bridge_test.dart test/app/pet_window_controller_test.dart`
Expected: 编译失败——`ReadyPet`、`pushReady`、`readyPets`、`takeReady`、`refreshCustom`、`onRefreshCustom`、`rescan` 未定义。

- [ ] **Step 3: 实现**

`apps/aipet/lib/services/window_bridge.dart`：

`BridgeMethods` 末尾（`accountChanged` 之后）加：

```dart

  // Delivered custom pets (generation spec 6.1 / 6.2): the pet window tells
  // the library a pet arrived, the library may ask what arrived while it was
  // closed, and may ask the pet window to look for deliveries now.
  static const petsReady = 'petsReady';
  static const takeReady = 'takeReady';
  static const refreshCustom = 'refreshCustom';
```

在 `AccountHandler` 之前加：

```dart
/// A custom pet that has just been downloaded and installed.
class ReadyPet {
  const ReadyPet({required this.petId, required this.name});

  final String petId;
  final String name;

  Map<String, Object?> toJson() => {'petId': petId, 'name': name};

  static ReadyPet? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['petId'], name = j['name'];
    if (id is! String || name is! String) return null;
    return ReadyPet(petId: id, name: name);
  }

  /// `{pets: [...]}` as it crosses the channel.
  static List<ReadyPet> listFrom(Object? j) {
    final raw = j is Map ? j['pets'] : null;
    return [for (final v in (raw is List ? raw : const [])) ?ReadyPet.fromJson(v)];
  }

  @override
  bool operator ==(Object other) => other is ReadyPet && other.petId == petId && other.name == name;

  @override
  int get hashCode => Object.hash(petId, name);

  @override
  String toString() => 'ReadyPet($petId, $name)';
}
```

`PetWindowBridge`：构造函数参数表加 `this.onRefreshCustom,`（放在 `this.account,` 之后），字段加：

```dart
  /// The library asked to look for delivered custom pets now; null ignores it.
  final Future<void> Function()? onRefreshCustom;

  /// Ready pets the library has not received yet (it was not running).
  final _ready = <ReadyPet>[];
```

`_handle` 的 `switch` 里 `default:` 之前加：

```dart
      case BridgeMethods.takeReady:
        final out = [for (final p in _ready) p.toJson()];
        _ready.clear();
        return {'pets': out};
      case BridgeMethods.refreshCustom:
        final refresh = onRefreshCustom;
        if (refresh != null) unawaited(refresh());
        return null;
```

`pushState` 之后加：

```dart
  /// Tells the library [pets] arrived. If it is not there to hear it, they
  /// wait (in memory) for its takeReady when it next starts.
  Future<void> pushReady(List<ReadyPet> pets) async {
    for (final p in pets) {
      _ready
        ..removeWhere((x) => x.petId == p.petId)
        ..add(p);
    }
    try {
      await _transport
          .invoke(BridgeMethods.petsReady, {'pets': [for (final p in _ready) p.toJson()]})
          .timeout(const Duration(seconds: 3));
      _ready.clear();
    } catch (_) {}
  }
```

`MainWindowBridge`：字段 `_accounts` 之后加：

```dart
  final _readies = StreamController<List<ReadyPet>>.broadcast();
```

getter `accounts` 之后加：

```dart
  Stream<List<ReadyPet>> get readyPets => _readies.stream;
```

`start()` 的 handler 里 `accountChanged` 分支之后加：

```dart
        if (method == BridgeMethods.petsReady && !_readies.isClosed) {
          _readies.add(ReadyPet.listFrom(args));
        }
```

`getAccount()` 之前加：

```dart
  /// What arrived while this window was not running; empty when nothing did
  /// or the pet window does not answer.
  Future<List<ReadyPet>> takeReady() async {
    try {
      return ReadyPet.listFrom(await _transport.invoke(BridgeMethods.takeReady).timeout(ackTimeout));
    } catch (_) {
      return const [];
    }
  }

  /// Ask the pet window to look for delivered custom pets now. Fire and forget.
  void refreshCustom() => _transport.invoke(BridgeMethods.refreshCustom).ignore();
```

`dispose()` 里加 `await _readies.close();`。

`apps/aipet/lib/app/pet_window/pet_window_controller.dart`：`boot()` 之后加：

```dart
  /// New pet folders arrived (a custom pet finished downloading): list them.
  /// Who is adopted or on the desktop does not change.
  void rescan() {
    _pets = _library.scan();
    notifyListeners();
  }
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/services/window_bridge_test.dart test/app/pet_window_controller_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/services/window_bridge.dart apps/aipet/lib/app/pet_window/pet_window_controller.dart apps/aipet/test/services/window_bridge_test.dart apps/aipet/test/app/pet_window_controller_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): the window channel carries ready custom pets and refresh requests" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 宠物窗口接线（启动、登录、同步、主窗口刷新四个时机）

**Files:**
- Modify: `apps/aipet/lib/app/pet_window/account_keeper.dart`（`onSynced`）
- Modify: `apps/aipet/lib/app/pet_window/pet_window_app.dart`（构建下载器）
- Test: `apps/aipet/test/app/account_keeper_test.dart`（`make` 加参数，追加一个用例）

**Interfaces:**
- Consumes: `CustomDownloader`（Task 4）、`IoDownloadTransport`（Task 3）、`ReadyPet`、`PetWindowBridge.pushReady`、`onRefreshCustom`、`PetWindowController.rescan()`（Task 5）、`customPetsRoot`（已有）
- Produces: `AccountKeeper({…, void Function()? onSynced})`——每次 `syncNow()` 结束后（登录后的那次也算）、以及 `tick()` 真的同步过之后调用

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/account_keeper_test.dart`：把

```dart
  AccountKeeper make() {
```

改为

```dart
  AccountKeeper make({void Function()? onSynced}) {
```

并在 `AccountKeeper(` 的参数里 `push: (v) async => pushed.add(v),` 之后加一行 `onSynced: onSynced,`。`main()` 末尾加：

```dart
  test('every sync, the one after login included, is followed by onSynced', () async {
    var synced = 0;
    keeper = make(onSynced: () => synced++);
    await keeper.login('13800138000', '123456');
    await Future<void>.delayed(Duration.zero); // login starts its sync without waiting for it
    expect(synced, 1);
    await keeper.syncNow();
    expect(synced, 2);
  });
```

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/account_keeper_test.dart`
Expected: 编译失败，`onSynced` 不是 `AccountKeeper` 的参数。

- [ ] **Step 3: 实现**

`apps/aipet/lib/app/pet_window/account_keeper.dart`：

构造函数参数表 `required this._push,` 之后加 `this.onSynced,`；字段加：

```dart
  /// After every sync (generation spec 6.1: delivered custom pets are looked
  /// for then). The sync after login counts, so this covers signing in too.
  final void Function()? onSynced;
```

`tick()` 改为：

```dart
  Future<void> tick() async {
    final before = _sync.lastSyncAt;
    await _sync.maybeSync();
    if (_sync.lastSyncAt != before) {
      unawaited(_push(view));
      onSynced?.call();
    }
  }
```

`syncNow()` 里 `final r = await running;` 之后、`return` 之前改为：

```dart
    final r = await running;
    unawaited(_push(view));
    onSynced?.call();
    return AccountReply(ok: r is ApiOk, message: r.message);
```

`apps/aipet/lib/app/pet_window/pet_window_app.dart`：

1. import 加 `'../../services/custom_downloader.dart'`、`'../../services/file_download.dart'`。
2. 在 `final controller = PetWindowController(…);` 语句之后加：

```dart
  // Delivered custom pets (generation spec 6.1). This window is the only
  // writer of pets/; the library only asks it to look.
  final downloads = CustomDownloader(
    api: api,
    transport: IoDownloadTransport(),
    petsRoot: customPetsRoot(appData),
    signedIn: () => account.signedIn,
    onInstalled: (ready) async {
      controller.rescan();
      await bridge.pushReady([for (final d in ready) ReadyPet(petId: d.petId, name: d.name)]);
    },
  );
```

3. `account = AccountKeeper(…)` 的参数里 `push: (v) => bridge.pushAccount(v),` 之后加：

```dart
    onSynced: () => unawaited(downloads.run()),
```

4. `bridge = PetWindowBridge(…)` 的参数里 `account: account,` 之后加：

```dart
    onRefreshCustom: downloads.run,
```

5. 文件末尾 `runPetWindow` 里 `account.start();` 之后加：

```dart
  unawaited(downloads.run()); // after boot: a pet installed now is scanned on top of boot's list
```

（下载中途退出：进程直接结束，`.part` 与已校验的文件留在 `.downloading`，下次启动续上；不需要在 `AppExit` 里做任何事。）

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter analyze` 然后 `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/account_keeper_test.dart`
Expected: `No issues found!`；All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/app/pet_window/account_keeper.dart apps/aipet/lib/app/pet_window/pet_window_app.dart apps/aipet/test/app/account_keeper_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): the pet window fetches delivered pets at launch, after every sync and on request" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

（`pet_window_app.dart`、`account_keeper.dart` 若仍含别的会话未提交的改动，按 Global Constraints 先问用户。）

---

### Task 7: 主窗口「你的「<名字>」做好了」与「换它陪我」

**Files:**
- Modify: `apps/aipet/lib/app/main_window/main_window_model.dart`
- Modify: `apps/aipet/lib/app/main_window/main_window_app.dart`
- Test: `apps/aipet/test/app/main_window_test.dart`（追加两个用例）

**Interfaces:**
- Consumes: `ReadyPet`、`MainWindowBridge.readyPets` / `takeReady()`、`PetWindowBridge.pushReady`（Task 5）；`MainWindowModel.adopt`、`loadCustoms`（已有 / 前置计划）
- Produces: `MainWindowModel.readyPet → ReadyPet?`、`dismissReady()`、`Future<void> adoptReady()`；收到新宠物时主窗口重扫宠物库（新宠物立刻出现在广场对应类别里）

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/main_window_test.dart` 的 `main()` 末尾加：

```dart
  testWidgets('a custom pet finished downloading: 做好了, and 换它陪我 puts it on the desktop', (tester) async {
    adoptImpl = adoptingSucceeds();
    await open(tester);
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat', name: '豆豆');
    await petSide.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsOneWidget);
    expect(model.plazaPets.map((p) => p.id), contains('custom-7')); // rescanned: in the plaza like the others
    await tester.tap(find.text('换它陪我'));
    await tester.pump();
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsNothing);
    expect(model.statusOf(model.plazaPets.firstWhere((p) => p.id == 'custom-7')), CardStatus.companion);
  });

  testWidgets('pets that finished while the library was closed are announced when it opens', (tester) async {
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat', name: '豆豆');
    await petSide.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]); // nobody listening yet
    await open(tester);
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsOneWidget);
    await tester.tap(find.byTooltip('知道了'));
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsNothing);
  });
```

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/main_window_test.dart`
Expected: 两个新用例 FAIL（找不到「你的「豆豆」做好了」）。

- [ ] **Step 3: 实现**

`apps/aipet/lib/app/main_window/main_window_model.dart`：

字段区（`_accountSub` 旁）加：

```dart
  StreamSubscription<List<ReadyPet>>? _readySub;
  ReadyPet? _ready;
```

getter 区加：

```dart
  /// A custom pet that just arrived (generation spec 6.2): 你的「…」做好了.
  ReadyPet? get readyPet => _ready;
```

`start()` 的最后一行 `notifyListeners();` 之前加：

```dart
    _readySub = _bridge.readyPets.listen(_petsArrived);
    _petsArrived(await _bridge.takeReady());
```

新增方法（放在 `adopt` 之后）：

```dart
  void _petsArrived(List<ReadyPet> ready) {
    if (ready.isEmpty) return;
    _pets = _library.scan();
    _ready = ready.last;
    notifyListeners();
    unawaited(loadCustoms());
  }

  void dismissReady() {
    _ready = null;
    notifyListeners();
  }

  /// 换它陪我: the library's usual switch.
  Future<void> adoptReady() async {
    final r = _ready;
    if (r == null) return;
    _ready = null;
    notifyListeners();
    await adopt(r.petId);
  }
```

`dispose()` 里加 `_readySub?.cancel();`。

`apps/aipet/lib/app/main_window/main_window_app.dart`：

1. import 加 `'../../services/window_bridge.dart'`（若前置计划已加过则跳过）。
2. `Scaffold` 的 `body:` 由

```dart
          body: SafeArea(child: model.tab == 0 ? _PlazaPage(model: model) : _MinePage(model: model)),
```

改为

```dart
          body: SafeArea(
            child: Column(children: [
              if (model.readyPet case final ready?)
                _ReadyBanner(pet: ready, onAdopt: model.adoptReady, onDismiss: model.dismissReady),
              Expanded(child: model.tab == 0 ? _PlazaPage(model: model) : _MinePage(model: model)),
            ]),
          ),
```

3. 文件末尾加：

```dart
/// 你的「豆豆」做好了 [换它陪我] [×] (generation spec 6.2).
class _ReadyBanner extends StatelessWidget {
  const _ReadyBanner({required this.pet, required this.onAdopt, required this.onDismiss});

  final ReadyPet pet;
  final VoidCallback onAdopt;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(20)),
        child: Row(children: [
          const Icon(Icons.celebration, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('你的「${pet.name}」做好了',
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.text)),
          ),
          FilledButton(onPressed: onAdopt, child: const Text('换它陪我')),
          IconButton(tooltip: '知道了', onPressed: onDismiss, icon: const Icon(Icons.close)),
        ]),
      );
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/main_window_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/app/main_window/main_window_model.dart apps/aipet/lib/app/main_window/main_window_app.dart apps/aipet/test/app/main_window_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): the library announces a finished custom pet, with 换它陪我" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: 「我的定制」状态文字、生成中 30 秒刷新、请求补下载

**Files:**
- Modify: `apps/aipet/lib/app/main_window/main_window_model.dart`
- Modify: `apps/aipet/lib/app/main_window/main_window_app.dart`（替换 `_CustomList`）
- Modify: `apps/aipet/lib/app/main_window/main_window_entry.dart`（窗口可见性）
- Test: `apps/aipet/test/app/main_window_test.dart`（setUp 加计数；替换前置计划的「我的定制」用例；追加两个用例）

**Interfaces:**
- Consumes: `CustomStatus`、`CustomRequestInfo.statusText` / `petId`（Task 1）；`MainWindowBridge.refreshCustom()`、`PetWindowBridge(onRefreshCustom:)`（Task 5）；前置计划的 `loadCustoms()`、`customs`、`custom`、`openPlans`、`speciesLabel`
- Produces:
  - `const kCustomPollInterval = Duration(seconds: 30)`
  - `MainWindowModel({…, CustomDeps? custom, Duration customPollInterval = kCustomPollInterval})`
  - `void setVisible(bool visible)`（主窗口被 × 隐藏 / 最小化时 false）
  - `loadCustoms()` 发现「已完成但本机没有完整宠物」的单时调用 `_bridge.refreshCustom()`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/main_window_test.dart`：

1. `var quits = 0;` 之后加 `var refreshes = 0;`；`setUp` 里 `quits = 0;` 之后加 `refreshes = 0;`；`petSide = PetWindowBridge(…)` 的参数里 `onQuit: () async => quits++)` 改为 `onQuit: () async => quits++, onRefreshCustom: () async => refreshes++)`。
2. 删除前置计划 Task 12 的 `testWidgets('我的定制 lists requests with their status; 待支付 offers 去支付', …)`（Task 1 改过的那个），换成下面三个：

```dart
  testWidgets('我的定制: every stage in words; 待支付 offers 去支付', (tester) async {
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            {'id': 5, 'name': '豆豆', 'species': 'cat', 'plan_name': '标准版', 'status': 'generating',
              'stage': 'video', 'stage_done': 3, 'stage_total': 7},
            {'id': 4, 'name': '旺财', 'species': 'dog', 'status': 'review'},
            {'id': 3, 'name': '咪咪', 'species': 'cat', 'status': 'failed', 'fail_reason': 'refs: gate'},
            {'id': 2, 'name': '小黑', 'species': 'dog', 'status': 'paid'},
            {'id': 1, 'name': '小白', 'species': 'cat', 'status': 'pending_payment'},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    tester.view.physicalSize = const Size(420, 1600); // the whole list on screen
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await tester.pump();
    try {
      model.setTab(1);
      await tester.pumpAndSettle();
      expect(find.text('我的定制'), findsOneWidget);
      for (final t in ['生成中（动作 3/7）', '审核中', '生成失败（我们会联系你处理或退款）', '待生成', '待支付', '去支付']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('refs: gate'), findsNothing);
    } finally {
      model.setTab(0); // stops the 30 s refresh before the timer check
    }
  });

  testWidgets('while something is generating and 我的 is on screen, 我的定制 refreshes every 30 s', (tester) async {
    var status = 'generating';
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            {'id': 5, 'name': '豆豆', 'species': 'cat', 'status': status, 'stage': 'video', 'stage_done': 1, 'stage_total': 7},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await tester.pump();
    int asks() => api.to('/api/aipet/custom/requests').length;
    try {
      model.setTab(1);
      await tester.pump();
      var n = asks();
      await tester.pump(const Duration(seconds: 30));
      expect(asks(), ++n);
      expect(find.text('生成中（动作 1/7）'), findsOneWidget);

      model.setVisible(false); // × hid the library
      await tester.pump(const Duration(seconds: 60));
      expect(asks(), n);
      model.setVisible(true);
      await tester.pump(const Duration(seconds: 30));
      expect(asks(), ++n);

      model.setTab(0); // 广场: no refreshing
      await tester.pump(const Duration(seconds: 60));
      expect(asks(), n);
      model.setTab(1); // coming back loads once
      await tester.pump();
      expect(asks(), ++n);

      status = 'review';
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(asks(), ++n);
      expect(find.text('审核中'), findsOneWidget);
      await tester.pump(const Duration(seconds: 60));
      expect(asks(), n); // nothing generating any more
    } finally {
      model.setTab(0);
    }
  });

  testWidgets('a delivered pet this computer lacks asks the pet window to fetch it', (tester) async {
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            {'id': 9, 'name': '豆豆', 'species': 'cat', 'status': 'delivered', 'pet_id': 'custom-9'},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await tester.pump();
    await tester.pump();
    expect(refreshes, 1);
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-9', origin: 'custom', species: 'cat', name: '豆豆');
    await petSide.pushReady([const ReadyPet(petId: 'custom-9', name: '豆豆')]);
    await tester.pump();
    await tester.pump();
    expect(api.to('/api/aipet/custom/requests'), hasLength(2)); // reloaded when it arrived
    expect(refreshes, 1); // and nothing is missing now
  });
```

（`api`、`AccountView`、`FakeHttp` 已由前置计划 Task 12 引入本测试文件；若 import 缺 `account_view.dart` / `fake_http.dart`，补上。）

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/main_window_test.dart`
Expected: 编译失败（`setVisible` 未定义）；去掉那几行后应是文字与刷新次数的断言失败。

- [ ] **Step 3: 实现**

`apps/aipet/lib/app/main_window/main_window_model.dart`：

1. 顶层（类之前）加：

```dart
/// 我的定制 asks again this often while something is generating and the page
/// is on screen (generation spec 6.2).
const kCustomPollInterval = Duration(seconds: 30);
```

2. 构造函数参数表 `this.custom` 之后加 `this.customPollInterval = kCustomPollInterval`，字段加：

```dart
  final Duration customPollInterval;
  Timer? _customPoll;
  bool _visible = true;
```

3. 把前置计划的 `loadCustoms()` 整个替换为：

```dart
  Future<void> loadCustoms() async {
    final c = custom;
    if (c == null || !_account.signedIn) {
      _customs = const [];
      _updateCustomPoll();
      notifyListeners();
      return;
    }
    try {
      _customs = await c.service.list();
      // Delivered but not here (yet, or the user deleted it): the pet window
      // is the one that downloads.
      if (_customs.any(_deliveredButMissing)) _bridge.refreshCustom();
    } on CustomFailure {
      // Keep what was shown; the next visit to 我的 asks again.
    }
    _updateCustomPoll();
    notifyListeners();
  }

  bool _deliveredButMissing(CustomRequestInfo r) =>
      r.status == CustomStatus.delivered &&
      r.petId != null &&
      !(PetLibrary.byId(_pets, r.petId!)?.isComplete ?? false);

  /// The library window is on screen (false while × has hidden it or it is
  /// minimized): 我的定制 only refreshes when someone can see it.
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    _updateCustomPoll();
  }

  void _updateCustomPoll() {
    final want = _visible &&
        _tab == 1 &&
        _account.signedIn &&
        _customs.any((r) => r.status == CustomStatus.generating);
    if (want) {
      _customPoll ??= Timer.periodic(customPollInterval, (_) => unawaited(loadCustoms()));
    } else {
      _customPoll?.cancel();
      _customPoll = null;
    }
  }
```

4. `setTab` 改为：

```dart
  void setTab(int i) {
    _tab = i;
    _updateCustomPoll();
    notifyListeners();
    if (i == 1) unawaited(loadCustoms());
  }
```

5. `dispose()` 里加 `_customPoll?.cancel();`。

`apps/aipet/lib/app/main_window/main_window_app.dart`：把前置计划的整个 `class _CustomList` 替换为：

```dart
class _CustomList extends StatelessWidget {
  const _CustomList({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('我的定制', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final r in model.customs)
            Card(
              color: AppColors.card,
              child: ListTile(
                isThreeLine: true,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: r.coverUrl == null
                        ? const Icon(Icons.pets, color: AppColors.accent)
                        : Image.network(r.coverUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.pets, color: AppColors.accent)),
                  ),
                ),
                title: Text(r.name),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text([speciesLabel(r.species), ?r.planName].join(' · ')),
                  Text(
                    r.statusText,
                    style: TextStyle(
                      color: r.status == CustomStatus.failed ? Colors.redAccent : AppColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ]),
                trailing: r.status.awaitingPayment
                    ? FilledButton(onPressed: () => openPlans(context, model, r), child: const Text('去支付'))
                    : null,
              ),
            ),
        ]),
      );
}
```

`apps/aipet/lib/app/main_window/main_window_entry.dart`：`_CloseToHide` 改为：

```dart
/// × hides the library instead of destroying it; the pet window first gets
/// the chance to end the app when nobody is on the desktop (spec 3.3). Also
/// tells the model whether anyone can see it (我的定制 refreshes only then).
class _CloseToHide with WindowListener {
  _CloseToHide(this.model);

  final MainWindowModel model;

  @override
  void onWindowClose() async {
    model.setVisible(false);
    await model.closing();
    await windowManager.hide();
  }

  @override
  void onWindowFocus() => model.setVisible(true);

  @override
  void onWindowMinimize() => model.setVisible(false);

  @override
  void onWindowRestore() => model.setVisible(true);
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter analyze` 然后 `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/main_window_test.dart`
Expected: `No issues found!`；All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/app/main_window/main_window_model.dart apps/aipet/lib/app/main_window/main_window_app.dart apps/aipet/lib/app/main_window/main_window_entry.dart apps/aipet/test/app/main_window_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): 我的定制 shows generation progress, refreshes while generating, asks for missing pets" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: 定制页只开放猫、狗

**Files:**
- Modify: `apps/aipet/lib/app/main_window/custom_flow/custom_form_model.dart`
- Modify: `apps/aipet/lib/app/main_window/custom_flow/custom_form_page.dart`
- Test: `apps/aipet/test/app/custom_form_test.dart`（替换两个用例）

**Interfaces:**
- Consumes: 前置计划 Task 9 的 `CustomFormModel`、`CustomFormPage`；`Group`、`Category`
- Produces: `const kOpenCategories = {Category.cat, Category.dog}`、`bool isOpenForCustom(Category)`、`bool isGroupOpen(Group)`；`setGroup` / `setCategory` 对未开放的项不做任何事

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/custom_form_test.dart`：

删除 `test('switching group picks its first real sub-category', …)`，换成：

```dart
  test('only cats and dogs can be ordered for now (generation spec 2 / 9)', () {
    final m = model();
    expect(m.category, Category.cat);
    m.setGroup(Group.people);
    expect((m.group, m.category), (Group.pets, Category.cat));
    m.setCategory(Category.other);
    expect(m.category, Category.cat);
    m.setCategory(Category.girl);
    expect(m.category, Category.cat);
    m.setCategory(Category.dog);
    expect(m.category, Category.dog);
    expect(isGroupOpen(Group.pets), isTrue);
    expect(isGroupOpen(Group.people), isFalse);
    expect([for (final c in Category.values) if (isOpenForCustom(c)) c], [Category.cat, Category.dog]);
  });
```

把 `testWidgets('page: counter, chips, disabled button until ready, submitted callback', …)` 整个替换为：

```dart
  testWidgets('page: counter, chips (人物 and 其他宠物 coming soon), disabled button until ready, submitted callback',
      (tester) async {
    // Tall enough that the ListView builds 下一步 too.
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    CustomRequestInfo? done;
    picks = [const PickedFile('a.jpg', [1])];
    await tester.pumpWidget(MaterialApp(home: CustomFormPage(deps: deps, onSubmitted: (_, r) => done = r)));
    expect(find.text('定制你的专属宠物'), findsOneWidget);
    expect(find.text('0/8'), findsOneWidget);
    for (final t in ['宠物', '人物', '猫猫', '狗狗', '其他宠物', '点击上传照片']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('即将开放'), findsNWidgets(2)); // on 人物 and on 其他宠物
    FilledButton next() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '下一步'));
    expect(next().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '豆豆');
    await tester.tap(find.text('点击上传照片'));
    await tester.pumpAndSettle();
    expect(find.text('2/8'), findsOneWidget);
    expect(next().onPressed, isNotNull);
    await tester.tap(find.text('人物'));
    await tester.tap(find.text('其他宠物'));
    await tester.pump();
    expect(find.text('女生'), findsNothing); // still on 宠物
    await tester.tap(find.text('狗狗'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '下一步'));
    await tester.pumpAndSettle();
    expect(done!.species.name, 'dog');
  });
```

（若 `find.text('宠物')` 与 AppBar「定制宠物」冲突，照前置计划 Task 9 的说明改用 `find.widgetWithText(ChoiceChip, '宠物')`。）

- [ ] **Step 2: 运行，确认失败**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/custom_form_test.dart`
Expected: 编译失败，`isGroupOpen` / `isOpenForCustom` 未定义。

- [ ] **Step 3: 实现**

`apps/aipet/lib/app/main_window/custom_flow/custom_form_model.dart`：

`const kNameMax = 8;` 之后加：

```dart
/// What can be generated today (generation spec 2 / 9): cats and dogs. The
/// rest show 即将开放 and cannot be picked.
const kOpenCategories = {Category.cat, Category.dog};

bool isOpenForCustom(Category c) => kOpenCategories.contains(c);

bool isGroupOpen(Group g) => g.categories.any(isOpenForCustom);
```

`setGroup` 与 `setCategory` 替换为：

```dart
  void setGroup(Group g) {
    if (g == group || !isGroupOpen(g)) return;
    _category = g.categories.firstWhere(isOpenForCustom);
    notifyListeners();
  }

  void setCategory(Category c) {
    if (!isOpenForCustom(c)) return;
    _category = c;
    notifyListeners();
  }
```

`apps/aipet/lib/app/main_window/custom_flow/custom_form_page.dart`：

把类别的两个 `Wrap` 替换为：

```dart
              Wrap(spacing: 8, children: [
                for (final g in Group.values)
                  ChoiceChip(
                    label: _SoonLabel(g.label, open: isGroupOpen(g)),
                    selected: _m.group == g,
                    selectedColor: AppColors.accentSoft,
                    onSelected: _m.busy || !isGroupOpen(g) ? null : (_) => _m.setGroup(g),
                  ),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final c in _m.group.categories)
                  if (c.species != null)
                    ChoiceChip(
                      label: _SoonLabel(c.label, open: isOpenForCustom(c)),
                      selected: _m.category == c,
                      selectedColor: AppColors.accentSoft,
                      onSelected: _m.busy || !isOpenForCustom(c) ? null : (_) => _m.setCategory(c),
                    ),
              ]),
```

文件末尾加：

```dart
/// A chip's label, with 即将开放 after it when it cannot be picked yet.
class _SoonLabel extends StatelessWidget {
  const _SoonLabel(this.text, {required this.open});

  final String text;
  final bool open;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(text),
        if (!open) ...[
          const SizedBox(width: 4),
          const Text('即将开放', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ],
      ]);
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `C:\Users\Administrator\code\envs\flutter\bin\flutter test test/app/custom_form_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git -C C:/Users/Administrator/code/aipet add apps/aipet/lib/app/main_window/custom_flow/custom_form_model.dart apps/aipet/lib/app/main_window/custom_flow/custom_form_page.dart apps/aipet/test/app/custom_form_test.dart
git -C C:/Users/Administrator/code/aipet commit -m "feat(aipet): the custom form offers cats and dogs; 人物 and 其他宠物 are coming soon" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: 全量验证与真机验收

**Files:** 无代码改动（发现问题按 superpowers:systematic-debugging 修，修完补测试再提交）

- [ ] **Step 1: 全量**

Run（`apps/aipet` 下）：`C:\Users\Administrator\code\envs\flutter\bin\flutter analyze` 然后 `C:\Users\Administrator\code\envs\flutter\bin\flutter test`
Expected: `No issues found!`；All tests passed（与开工前基线相比只多不少）。

- [ ] **Step 2: release 构建并启动**

Run（PowerShell）：
```powershell
Set-Location C:\Users\Administrator\code\aipet\apps\aipet
Stop-Process -Name aipet -Force -Confirm:$false -ErrorAction SilentlyContinue
C:\Users\Administrator\code\envs\flutter\bin\flutter build windows --release
Start-Process build\windows\x64\runner\Release\aipet.exe
```
Expected: 构建成功；宠物照常出现；未登录时 `%APPDATA%\com.aipet\aipet\pets` 下不出现 `.downloading`。

- [ ] **Step 3: 点目录不进宠物库（不需要服务端）**

关掉程序，把任一内置宠物目录（`build\windows\x64\runner\Release\data\flutter_assets\assets\pets\<某个>`）复制到 `%APPDATA%\com.aipet\aipet\pets\.old-test\`，把其中 `pet.json` 的 `origin` 改成 `custom`；再启动、打开宠物库：广场里不能多出这只。验完删掉 `.old-test`。

- [ ] **Step 4: 对着线上走一遍（需要服务端计划与生成计划已部署，且有一张已交付的单）**

先问用户：服务端是否已部署 `custom/deliveries` 与 `…/assets`、是否有一张 `delivered` 的单（或能在后台交付一张）。有则用 `tools/dev` 的 `shot.ps1` / `click.ps1`（点击前 `-Expect` 校验像素；宠物在动画，点宠物不加 `-Expect`）：
1. 「我的」登录该账号 → 数秒内 `pets\custom-<id>\` 出现、宠物库顶部出现「你的「<名字>」做好了」→ 截图。
2. 点「换它陪我」→ 桌面换成定制宠物 → 截图。
3. 删掉 `pets\custom-<id>\`，在「我的」页切走再切回（触发 `refreshCustom`）→ 目录重新出现。
4. 中途退出：删掉该目录后立刻重启程序，在 `.downloading\custom-<id>\` 里出现部分文件时 `Stop-Process -Name aipet -Force`；再启动 → 只补缺的、最终安装成功（可对比文件修改时间）。
5. 「我的定制」：后台把另一张单置为 `generating`（带进度）→ 「我的」页 30 秒内显示「生成中（动作 n/m）」或「生成中（参考图 n/m）」；置 `failed` → 显示「生成失败（我们会联系你处理或退款）」。
6. 定制页：「人物」「其他宠物」显示「即将开放」且点不动。

用户在用电脑时（前台出现其他窗口）停止一切鼠标操作，把剩余步骤交给用户。

- [ ] **Step 5: 报告**

列出：每个 Task 的提交；本机验证过什么；**没验证什么**（没有服务端时 Step 4 全部未验；真实 OSS 签名 URL 过期只在单测里模拟过）。

---

## Self-Review 记录

- **Spec 覆盖**：6.1 时机（启动 / 登录 / 每次同步 / 主窗口刷新）→ Task 6、Task 8；单飞 → Task 4；deliveries → assets → `.downloading` → sha256 → 跳过已校验 → 原子改名（`.old`）→ 重扫 → 推主窗口 → Task 4、5、6；失败保留、不弹错 → Task 4；`PetLibrary` 跳点目录 → Task 2。6.2 定制页「即将开放」→ Task 9；「我的定制」状态文字与 30 秒可见时刷新 → Task 1、8；「做好了 / 换它陪我」→ Task 7；「已完成的定制宠物与内置宠物一样展示」→ Task 7（重扫后进广场对应类别，领养后进「我的」，与内置宠物同一套卡片）。第 9 节状态改名 → Task 1。
- **占位扫描**：无 TBD / TODO；每个代码步骤都给出完整代码；对前置计划文件的修改都写明替换哪段、换成什么。
- **类型一致**：`CustomDelivery{id, petId, name}`、`CustomAssets.fromJson`、`CustomDownloader.run()`、`ReadyPet{petId, name}`、`pushReady` / `takeReady` / `readyPets` / `refreshCustom` / `onRefreshCustom`、`rescan()`、`onSynced`、`readyPet` / `adoptReady` / `dismissReady`、`setVisible`、`kCustomPollInterval`、`isOpenForCustom` / `isGroupOpen` 在定义与使用处一致。
- **Review Focus**：五条各有 Task 4 的测试；「已完整不重下」「未登录不发请求」「主窗口没开时的通知」也各有测试（Task 4、Task 5、Task 7）。
