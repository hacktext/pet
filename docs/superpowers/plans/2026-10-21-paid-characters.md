# 付费人物（单个买断）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 5 个新人物做成桌宠素材，作为付费人物上架：宠物库显示价格 → 微信扫码买断 → 点「下载」→ 像免费人物一样使用；素材只在后端私有 OSS。

**Architecture:** 后端新增「付费人物目录 + 已解锁记录」，下单 / 支付回调 / 退款接在现有 `orders` + `Fulfillment` 上。客户端宠物库从后端拉目录（本地缓存），卡片按「未购 / 已购未装 / 下载中 / 已装」四态显示；下载与安装由桌宠窗口做（复用 `CustomDownloader` 的校验与原子安装，抽成 `PetInstaller`）。素材由 petgen 生成后用新的 `publish` 命令经内部接口上传。

**Tech Stack:** Flutter 3.47 / Dart 3.13（客户端，`flutter test`）；ThinkPHP + MySQL + 阿里云 OSS（后端，无自动化测试）；Python 3.14 petgen（`pytest`）。

**Spec:** `docs/superpowers/specs/2026-10-21-paid-characters-design.md`

## Global Constraints

- 两个仓库：客户端 `C:\Users\Administrator\code\aipet`；后端 `C:\Users\Administrator\code\pixpick\pixpickweb-tp`。各自提交，**不推送**（推送须用户点头）。
- 付费人物桌宠 id `paid-<code>`，`pet.json` 的 `origin` 为 `paid`，装在 `pets/paid-<code>/`（与定制宠物同目录）。
- 订单 `plan_code='aipet_character'`、`period='once'`，金额取下单时 `aipet_characters.price_cents`。
- 新 ApiCodes：`CHARACTER_UNAVAILABLE = 5015`（不存在 / 下架时下单），`CHARACTER_OWNED = 5016`（已购再下单）。
- 后端所有 aipet 接口先过 `AipetProduct::guard()`；业务表模型继承 `ProductScoped`，不用 `Db::table()`；模型内读 `name` 用 `getData('name')`。
- 后端响应信封 `{code, message, data}`（`ApiResponse::ok/fail`）；内部 worker 接口无信封（`json($result)`）。
- 迁移为手写可重复执行的 SQL：`database/migrations/2026-10-21_aipet_characters.sql`，`CREATE TABLE IF NOT EXISTS`，`product_id` 无默认值、种子行从 `products WHERE code='aipet'` 取。
- 种子 5 行：`suwan 苏晚 girl`、`guchen 顾沉 boy`、`luyu 陆屿 boy`、`xiaxia 夏夏 girl`、`zhiyi 林知意 girl`，`price_cents=1990`，**`enabled=0`**。
- 客户端不跑 `dart format`（仓库是旧排版风格，格式化会重排整个文件）；改动要贴合周围代码。
- 已购人物**不自动下载**；离线 / 登录过期**沿用缓存的已购**，只有明确登出或新目录说未拥有才锁。
- 视频额度：先做 5 段 stand，用户看过再做其余 15 段；余额不够就停下问，不降级。不启动 aipet.exe、不动鼠标，除非用户同意。
- 中文文案：角标「付费」/「已购」；按钮「¥19.9 解锁」（`yuan(priceCents)` + 「 解锁」）/「下载」/「下载中 42%」；提示「登录后即可解锁」「解锁成功，点下载即可使用」「下载失败，请重试」。

## Review Focus

1. **同一用户重复回调 / 后台重复「标记已支付」**：不能写出两行解锁、不能报错 → B2 `markPaid` 幂等测试（冒烟步骤里连发两次）。
2. **下载中途退出 / 断网**：再点「下载」应从已校验的文件续上，不重下全部，也不装出半个人物 → C3 `PetInstaller` 续传测试。
3. **已登出（或退款）时付费人物正在桌面上**：要换回免费宠物，且领养被拒 → C4 测试 `a paid pet that is no longer owned leaves the desktop`。
4. **目录接口失败 / 从没拉到过**：宠物库照常显示免费人物，付费区不出现、不报错；有缓存就用缓存 → C5 测试。
5. **下单时未登录或登录过期（1003）**：走登录页，不弹出空的支付页 → C6 测试。

---

## 后端（pixpickweb-tp）

### Task B1: 表、模型、种子

**Files:**
- Create: `database/migrations/2026-10-21_aipet_characters.sql`
- Create: `app/model/AipetCharacter.php`, `app/model/AipetCharacterAsset.php`, `app/model/AipetCharacterUnlock.php`, `app/model/AipetCharacterOrder.php`

**Interfaces:**
- Produces: 表 `aipet_characters`（id, product_id, code VARCHAR(32) 唯一于 (product_id, code), name, species VARCHAR(16), blurb VARCHAR(255), tags JSON, voices JSON `[{id,name}]`, actions JSON, price_cents INT UNSIGNED, sort INT, enabled TINYINT(1) DEFAULT 0, created_at, updated_at）；`aipet_character_assets`（id, product_id, character_code, path VARCHAR(255), bytes BIGINT, sha256 CHAR(64), content_type VARCHAR(64), oss_key VARCHAR(255), kind ENUM('card','file')，唯一 (product_id, character_code, path)）；`aipet_character_unlocks`（id, product_id, user_id, character_code, order_no, unlocked_at, revoked_at NULL，唯一 (product_id, user_id, character_code)）；`aipet_character_orders`（id, product_id, order_no 唯一, character_code, user_id, created_at）。
- Produces: `AipetCharacter::toApi(): array` → `{code, name, species, blurb, tags, voices, actions, price_cents, sort}`。

- [ ] **Step 1:** 按 `2026-10-02_aipet_custom.sql` 的风格写迁移（4 张表 + 5 行种子，`ON DUPLICATE KEY UPDATE code=code`）。种子的 `voices`/`actions`/`tags`/`blurb` 取 `tools/petgen/work/chars/spike.py` 里 5 个 paid 人物的值（voices 见 Task P2 的 `VOICES`）。
- [ ] **Step 2:** 四个模型继承 `ProductScoped`，`$type` 声明 JSON / 整数列，`AipetCharacter::toApi()` 内用 `getData('name')`。
- [ ] **Step 3:** `php -l` 每个新文件 → `No syntax errors detected`。
- [ ] **Step 4:** 在测试库执行迁移两遍（第二遍不报错、不重复插行）：`SELECT code, enabled, price_cents FROM aipet_characters` → 5 行、全部 `enabled=0`、1990。
- [ ] **Step 5:** Commit `feat(aipet): paid character tables and models`。

### Task B2: 目录 / 下单 / 状态 / 素材接口，接上支付与退款

**Files:**
- Create: `app/service/aipet/CharacterService.php`, `app/controller/api/aipet/Character.php`
- Modify: `app/support/ApiCodes.php`（5015、5016）, `route/app.php`, `app/service/payment/Fulfillment.php`, `app/controller/admin/Orders.php`, `lang/zh-cn/*`（与 `aipet.custom_*` 同处）

**Interfaces:**
- Consumes: B1 模型；`OrderService::generateOrderNo()`；`PaymentManager->driver($channel)->createCharge($order)`；`OssClient::fromConfig()->signedGetUrl($key, $ttl)`；`CustomOrderError`（复用为错误类型）。
- Produces（`CharacterService`, `PLAN_CODE = 'aipet_character'`）：
  - `catalog(): array` — enabled 的人物按 sort, id，每项 `toApi() + ['card_url' => signedGetUrl(card 的 oss_key, config('aipet.characters.card_url_ttl', 86400))]`（无 card 资产则 `card_url=null`）。
  - `owned(User $u): array` — 未撤销解锁的 `character_code` 列表。
  - `startOrder(User $u, string $code): array` — `{order_no, amount_cents, code_url, expired_at, expires_in}`；下架/不存在 → 5015；已解锁 → 5016；同人物未过期的 pending 订单复用；写 `aipet_character_orders` 关联行；结构照 `CustomOrderService::startOrder`。
  - `orderStatus(User $u, string $orderNo): string` — 只认本人的 `aipet_character` 订单；过期返回 `expired`。
  - `markPaid(Order $o): string` — `'paid'` 或 `'already'`；在事务里按 order_no 找关联行，插入（或把已撤销的那行重置 `revoked_at=NULL`）解锁行。
  - `markRefunded(Order $o): void` — 该订单对应的解锁行写 `revoked_at`。
  - `assets(User $u, string $code): array` — 已解锁（无论是否上架）才返回 `{pet_id: 'paid-'.$code, files: [{path, bytes, sha256, url}]}`（`kind='file'` 的行，url 用 `config('aipet.custom.asset_url_ttl', 1800)`），否则 `CustomOrderError(403, …)` → 控制器回 403。
- Routes（与 custom 路由同组同写法，`->completeMatch()`，长路径在前）：
  - 公开：`GET aipet/characters` → `Character/catalog`
  - 需 token：`GET aipet/characters/owned` → `owned`；`POST aipet/characters/:code/order` → `order`；`GET aipet/characters/orders/:orderNo` → `orderStatus`；`GET aipet/characters/:code/assets` → `assets`（`:code` pattern `[a-z0-9_]+`，`owned` 与 `orders` 路由放在 `:code` 之前）。

- [ ] **Step 1:** `ApiCodes` 加两个常量；lang 加 `aipet.character_unavailable`「这个人物暂未上架」、`aipet.character_owned`「你已经解锁过这个人物」。
- [ ] **Step 2:** 实现 `CharacterService`（上面的签名）与控制器 `Character`（`run()` 照 `Custom::run`，403 → `response('Forbidden', 403)`，404 同 Custom）。
- [ ] **Step 3:** `Fulfillment::fulfill`：`plan_code === CharacterService::PLAN_CODE` → `(new CharacterService())->markPaid($order); return null;`。`admin/Orders.php` 的 `markPaid` 与 `refund` 各加同样的 `aipet_character` 分支（refund 调 `markRefunded`），flash 文案「已标记为已支付，用户已解锁该人物」/「已退款，该人物已重新锁定」。
- [ ] **Step 4:** `php -l` 所有改动文件 → 无语法错误。
- [ ] **Step 5（冒烟，测试环境，支付通道 `fake`）：** 把一行人物临时 `enabled=1`，用测试账号 token：
  - `GET /api/aipet/characters` → code 0，含该人物，`price_cents` 1990。
  - `POST …/:code/order` → 拿到 `order_no`；再发一次 → 同一个 `order_no`（复用）。
  - 后台「标记已支付」该订单 → `GET …/owned` 含该 code；对同一订单再标记一次 → 不报错、`aipet_character_unlocks` 仍 1 行（Review Focus 1）。
  - `POST …/order` 再下单 → code 5016。
  - `GET …/:code/assets`：未上传素材时 `files: []`；另一账号 → 403。
  - 后台退款 → `owned` 不再含该 code，`assets` → 403。
  - 冒烟后恢复 `enabled=0`。
- [ ] **Step 6:** Commit `feat(aipet): paid characters -- catalog, order, unlock on payment, refund, assets`。

### Task B3: 内部上传接口（开发机 → OSS）

**Files:**
- Modify: `app/controller/internal/AipetWorker.php`, `route/app.php`（`internal/aipet` 组内）, `app/service/aipet/CharacterService.php`

**Interfaces:**
- Produces（无信封，WorkerAuth）：
  - `POST internal/aipet/characters/:code/upload-urls` body `{files:[{path, bytes, content_type}]}` → `[{path, url}]`（`signedPutUrl("aipet/characters/{code}/{path}", 1800, content_type)`）。校验：code 存在（不论上架）、1–60 个文件、path 只含 `[A-Za-z0-9_./-]` 且不含 `..`、content_type 与扩展名一致（复用 `GenerationService::contentType` 的映射，补 `.jpg`）。
  - `POST internal/aipet/characters/:code/finish` body `{files:[{path, bytes, sha256, content_type}]}` → `{ok: true, files: n}`：用 `OssClient::objectSize` 核对每个对象已上传且大小一致，否则 422；然后**替换**该人物全部资产行（`card.jpg` 为 `kind='card'`，其余 `file`）。
- CharacterService 新增 `uploadUrls(string $code, $files): array`、`finishUpload(string $code, $files): array`。

- [ ] **Step 1:** 实现两个方法与两个 worker 动作（`run()` 走现有 `CurrentProduct::runAs`）。
- [ ] **Step 2:** `php -l` → 无语法错误。
- [ ] **Step 3:** 冒烟留到 Task P1 Step 5（用真实 publish 命令打一遍）。
- [ ] **Step 4:** Commit `feat(aipet): internal upload endpoints for paid character assets`。

### Task B4: 后台「付费人物」页

**Files:**
- Create: `app/controller/admin/AipetCharacters.php`, `app/view/admin/aipet/characters.html`, `app/view/admin/aipet/character_edit.html`
- Modify: `route/app.php`（admin 组）, `app/view/admin/layout.html`（aipet 导航加「付费人物」, `active=='aipet_characters'`）

**Interfaces:**
- 路由：`GET aipet/characters`（列表）、`GET aipet/characters/:id`（编辑）、`POST aipet/characters/save`、`POST aipet/characters/:id/toggle`。
- 列表列：排序、编号、名字、类别、价格（元）、上架、素材文件数（file 行数）/ 有无卡片照、已购人数（未撤销解锁数）、操作（编辑 / 上架·下架）。
- 编辑可改：名字、简介、标签（逗号分隔）、价格（元，转分同 `AipetCustom::save`）、排序。编号、声音、动作只读（来自种子 / 上传）。**上架前校验**：有卡片照且至少 4 个 mp4，否则 flash 错误「素材未上传完整，不能上架」。

- [ ] **Step 1:** 照 `AipetCustom::plans/edit/save/toggle` 与 `plans.html`/`plan_edit.html` 的写法实现（CSRF token、flash、redirect）。
- [ ] **Step 2:** `php -l` → 无语法错误。
- [ ] **Step 3:** 浏览器打开后台：列表 5 行；改价 29.9 保存 → `GET /api/aipet/characters`（临时上架后）返回 2990；素材缺失时点上架 → 报错不上架。
- [ ] **Step 4:** Commit `feat(admin): 付费人物 page -- price, listing, buyers`。

## petgen（客户端仓库 tools/petgen）

### Task P1: `publish` 命令

**Files:**
- Modify: `tools/petgen/petgen/server.py`, `tools/petgen/petgen/__main__.py`
- Test: `tools/petgen/tests/test_server.py`, `tools/petgen/tests/test_cli_publish.py`（新）

**Interfaces:**
- `Server.character_upload_urls(code: str, files: list[dict]) -> dict[str, str]`（path → url）、`Server.character_finish(code: str, files: list[dict]) -> dict`；走 `_post_idempotent` 同现有重试规则。
- CLI：`python -m petgen publish <dir> --code <code> --server <url> [--config secrets/worker.env]`：遍历 `<dir>` 下所有文件（相对路径用 `/`），算 bytes/sha256/content_type（`.json` application/json、`.mp4` video/mp4、`.wav` audio/wav、`.png` image/png、`.jpg` image/jpeg），申请 URL → 逐个 `Server.put` → finish。目录须含 `pet.json`（`id == 'paid-'+code`、`origin == 'paid'`）和 `card.jpg`，否则退出码 1 不上传。

- [ ] **Step 1:** 写测试 `test_character_upload_urls_and_finish_bodies`（用 tests/fakes 的 opener 断言路径 `/internal/aipet/characters/suwan/upload-urls`、`…/finish` 与 body）与 `test_publish_refuses_a_folder_that_is_not_a_paid_pet`、`test_publish_uploads_every_file_then_finishes`（fake Server 记录调用顺序：upload_urls → put×n → finish，sha256 正确）。
- [ ] **Step 2:** `.venv/Scripts/python -m pytest tests/test_server.py tests/test_cli_publish.py -q` → FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 同命令 → PASS；全量 `pytest -q` 不回归。
- [ ] **Step 5（与 B3 联调）:** 用 Task P2 做出的任一人物目录（或拿 `builtin-linyang` 复制改成 `paid-test` 的目录）对测试环境 publish → 后台该人物素材数正确；`GET …/assets`（已购账号）返回的每个 url 能下载且 sha256 一致。
- [ ] **Step 6:** Commit `feat(petgen): publish a paid character's folder to the backend`。

### Task P2: 5 个人物的素材

**Files:**
- Modify: `tools/petgen/work/chars/spike.py`（git 忽略，一次性脚本；5 个 paid 条目已加）

- [ ] **Step 1:** 5 张参考图 `ref` → `gate`（贴边就按 2026-10-17 的做法补留白；深色衣服若被提灰则 `calibrate: False`）。看图确认像原图。
- [ ] **Step 2:** 5 段 `video <c> stand pro` → `finish` → `qa` 全过；拼联系表给用户看。**停：用户点头（及续购）后才做其余 15 段。**
- [ ] **Step 3:** 其余 `act_coy`/`dance`/`talk`（男生用男生版提示词）→ `finish` → `qa` 全过。
- [ ] **Step 4:** `VOICES`/`LINES` 加 5 人（男声：小天 `zh_male_taocheng_uranus_bigtts`、梓辛 `zh_male_shaonianzixin_uranus_bigtts`、刘飞 `zh_male_liufei_uranus_bigtts`、逸辰 `zh_male_ruyayichen_uranus_bigtts`；女声：小雅 / 学妹 / 桃子 / Vivi / 小何同 2026-10-17），每人 3 种声音、每个一次性动作 2–3 句，台词按人设写；`voices` 生成并核对男声音高 < 160 Hz。
- [ ] **Step 5:** 卡片特写照（`work/ui/gen.py` 加 5 项）→ 640px `card.jpg`。
- [ ] **Step 6:** `package` 改为：paid 人物写到 `work/chars/paid-out/paid-<code>/`，`pet.json` 含 `origin: "paid"`、`card: "card.jpg"`、`tags`、`voices`；**不写进** `apps/aipet/assets`。
- [ ] **Step 7:** 逐个 `publish` 到后端（P1）；后台核对素材数；由用户在后台定价上架。

## 客户端（apps/aipet）

### Task C1: 付费人物的领域类型与目录缓存

**Files:**
- Create: `lib/domain/paid_character.dart`, `lib/services/catalog_store.dart`
- Modify: `lib/domain/pet.dart`（`PetOrigin` 加 `paid`）, `lib/services/pet_library.dart`（customRoot 接受 `custom` 与 `paid`）
- Test: `test/domain/paid_character_test.dart`, `test/services/catalog_store_test.dart`, `test/services/pet_library_test.dart`

**Interfaces:**
- `class PaidCharacter { code, name, species (Species), blurb, tags, priceCents, cardUrl (String?), voices (List<PetVoice>), actions; String get petId => 'paid-$code'; static PaidCharacter? fromJson(Object?) }`；`List<PaidCharacter> paidCatalogFrom(Object? data)`（跳过坏项）。
- `class CatalogStore(Directory appData)`：`({List<PaidCharacter> items, Set<String> owned})? load()`；`void save(List<PaidCharacter> items)`；`void saveOwned(Set<String> owned)`；`File cardFile(String code)`（`catalog/cards/<code>.jpg`）；`Future<void> cacheCard(PaidCharacter c, DownloadTransport t)`（已有且非空不重下）。文件 `catalog/catalog.json`、`catalog/owned.json`，写法同 `VoiceStore`（tmp + rename，读坏了当空）。
- `PetLibrary._scanRoot(root, Set<PetOrigin> allowed)`；customRoot 传 `{custom, paid}`。

- [ ] **Step 1:** 测试：`fromJson` 解析完整项 / 缺字段跳过 / species 映射；`CatalogStore` 往返、坏文件为 null；`PetLibrary` 能扫到 customRoot 下 `origin: paid` 的 `paid-x`，且 builtin 根下的 `paid` 仍被跳过。
- [ ] **Step 2:** `flutter test test/domain/paid_character_test.dart test/services/catalog_store_test.dart test/services/pet_library_test.dart` → FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 同命令 → PASS。
- [ ] **Step 5:** Commit `feat(aipet): paid character model, catalog cache, paid origin`。

### Task C2: 接口层

**Files:**
- Modify: `lib/services/api_client.dart`
- Create: `lib/services/character_service.dart`
- Test: `test/services/api_client_test.dart`, `test/services/character_service_test.dart`

**Interfaces:**
- `ApiClient`：`characters()` GET `/api/aipet/characters`；`ownedCharacters()` GET `/api/aipet/characters/owned`；`characterOrder(String code)` POST `/api/aipet/characters/$code/order`；`characterOrderStatus(String orderNo)` GET `/api/aipet/characters/orders/$orderNo`；`characterAssets(String code)` GET `/api/aipet/characters/$code/assets`。
- `class CharacterService(ApiClient)`：`Future<List<PaidCharacter>> catalog()`；`Future<Set<String>> owned()`；`Future<PayOrder> order(String code)`；`Future<PayStatus> status(String orderNo)`；`Future<CustomAssets> assets(String code)`。失败抛 `CustomFailure`（同 `CustomService` 的映射，含 `code`）。常量 `kCharacterOwnedCode = 5016`、`kCharacterUnavailableCode = 5015`。

- [ ] **Step 1:** 测试：每个 ApiClient 方法的 method + path；`CharacterService.order` 在 5016 时抛 `CustomFailure(code: 5016)`；`assets` 解析 `{pet_id, files}`。
- [ ] **Step 2–4:** FAIL → 实现 → PASS（`flutter test test/services/api_client_test.dart test/services/character_service_test.dart`）。
- [ ] **Step 5:** Commit `feat(aipet): client for the paid character endpoints`。

### Task C3: 抽出 `PetInstaller`

**Files:**
- Create: `lib/services/pet_installer.dart`
- Modify: `lib/services/custom_downloader.dart`（改用 PetInstaller，行为不变）
- Test: `test/services/pet_installer_test.dart`；现有 `custom_downloader` 测试必须原样通过

**Interfaces:**
- `class PetInstaller({required Directory petsRoot, required DownloadTransport transport})`：`Future<bool> install(CustomAssets assets, {required PetOrigin origin, required bool Function() keepGoing, void Function(int done, int total)? onProgress})` — 即现在 `_fetch` 从「逐个文件」到「`_install`」的整段（暂存 `.downloading/<petId>`、`.part`、大小 + sha256、`_prune`、完整性检查要求 `origin` 匹配、一次改名、`.old-<id>` 旁置）。`onProgress` 在每个文件校验通过后调一次（已存在且匹配的也算）。`static Future<bool> isInstalled(Directory petsRoot, String petId, PetOrigin origin)`。

- [ ] **Step 1:** 测试 `resumes from the files already verified`（第一次下载第 2 个文件失败 → 第二次只请求第 2、3 个；Review Focus 2）、`reports progress per verified file`、`refuses a manifest whose pet.json origin does not match`。
- [ ] **Step 2–4:** FAIL → 实现并让 `CustomDownloader` 调它 → PASS，且 `flutter test test/services` 全过。
- [ ] **Step 5:** Commit `refactor(aipet): PetInstaller, shared by custom and paid downloads`。

### Task C4: 桌宠窗口——下载、拥有状态、锁定

**Files:**
- Create: `lib/app/pet_window/paid_keeper.dart`
- Modify: `lib/services/window_bridge.dart`, `lib/app/pet_window/pet_window_app.dart`, `lib/app/pet_window/pet_window_controller.dart`
- Test: `test/app/paid_keeper_test.dart`, `test/services/window_bridge_test.dart`, `test/app/pet_window_controller_test.dart`

**Interfaces:**
- `class PaidKeeper extends ChangeNotifier`（桌宠窗口）：构造 `(CharacterService, PetInstaller, CatalogStore, {bool Function() signedIn})`；`Set<String> get owned`（启动时取 `CatalogStore.load()?.owned`）；`Future<void> refresh()`（已登录：`owned()` 成功则替换并 `saveOwned`；失败保留缓存）；`void signedOut()`（owned 清空并保存）；`Future<bool> download(String code)`（未拥有 → false；`assets` + `PetInstaller.install(origin: paid)`；进度经 `onProgress(code, done, total)` 回调）；`bool allows(Pet p)` → `p.origin != PetOrigin.paid || owned.contains(p.id.substring(5))`。
- `PetWindowController`：新增可选 `bool Function(Pet)? allows`；`adopt` 遇不允许的 → `AdoptError('locked', '请先解锁')`；新增 `Future<void> evictLocked()`：当前宠物不被允许时换到第一个已领养且允许的宠物，没有则清空当前宠物（与没有宠物时同样的界面）。
- 通道（`BridgeMethods`）：`downloadCharacter {code}` → `{ok: bool}`；推送 `characterProgress {code, done, total}`；`getOwned` → `{owned: [codes]}`；`refreshOwned`（宠物库付款成功后请桌宠窗口重新问后端）；推送 `ownedChanged {owned: [...]}`。`PetWindowBridge` 新增可选 `PaidHandler? paid`（`Set<String> get owned`、`Future<bool> download(String code)`、`Future<void> refresh()`）；`MainWindowBridge` 新增 `Stream<({String code, int done, int total})> characterProgress`、`Stream<Set<String>> owned`、`Future<Set<String>?> getOwned()`、`Future<bool> downloadCharacter(String code)`（超时 `adoptTimeout` 的 10 倍——下载可能几分钟）、`void refreshOwned()`（发了就走）。
- 接线（`pet_window_app.dart`）：登录 / 每次同步后 `paid.refresh()`；登出 `paid.signedOut()`；owned 变化 → `controller.evictLocked()` + `bridge.pushOwned`；下载完成 → `controller.rescan()` + `bridge.pushState`。

- [ ] **Step 1:** 测试：`PaidKeeper` 离线 refresh 保留缓存 owned；signedOut 清空；未拥有 download 返回 false 且不请求 assets；`a paid pet that is no longer owned leaves the desktop`（controller：当前 `paid-a`，owned 变空 → `evictLocked` 后当前为已领养的 `builtin-gold`；`adopt('paid-a')` 抛 `AdoptError('locked')`）（Review Focus 3）；通道往返 getOwned / downloadCharacter / characterProgress。
- [ ] **Step 2–4:** FAIL → 实现 → PASS（`flutter test test/app test/services`）。
- [ ] **Step 5:** Commit `feat(aipet): the pet window downloads, keeps and enforces paid characters`。

### Task C5: 宠物库——目录与卡片四态

**Files:**
- Modify: `lib/app/main_window/main_window_model.dart`, `lib/app/main_window/main_window_app.dart`, `lib/app/main_window/pet_card.dart`, `lib/app/main_window/main_window_entry.dart`
- Test: `test/app/main_window_test.dart`, `test/app/pet_card_test.dart`

**Interfaces:**
- 模型：`List<PaidCharacter> get catalog`；`Set<String> get owned`；`Map<String, double> get downloading`（code → 0..1）；`PaidState paidStateOf(String code)`，`enum PaidState { locked, owned, downloading, installed }`；`plazaPets` 改为 `List<PlazaEntry>`（`sealed class PlazaEntry`：`InstalledEntry(Pet)` / `RemoteEntry(PaidCharacter)`；已安装的付费人物用 `InstalledEntry`，未安装的用 `RemoteEntry`；按 `filterPets` 同样的分类规则；付费人物排在免费人物之后、按 catalog 顺序）。`start()`：先用 `CatalogStore.load()` 填充，再后台 `CharacterService.catalog()`（成功 → `save` + 逐个 `cacheCard`）；owned 来自 `bridge.getOwned()` + `bridge.owned` 流。
- `PetCard` 新增可选 `PaidState? paid`、`int? priceCents`、`VoidCallback? onUnlock`、`VoidCallback? onDownload`、`double? progress`；角标在照片右上角：`locked` →「付费」（杏橙渐变底白字），其余 →「已购」（咖啡底白字）；按钮按 Spec 5.1 表。`RemoteEntry` 用 `CatalogStore.cardFile(code)` 作卡片照（不存在则占位图标）。
- 下载：`model.download(code)` → `bridge.downloadCharacter`；失败 → `_say('下载失败，请重试')`。

- [ ] **Step 1:** 测试：目录接口失败、无缓存 → 只显示免费人物且无报错；有缓存 → 显示缓存的付费人物（Review Focus 4）；四态按钮文案 `¥19.9 解锁` / `下载` / `下载中 42%` / `带TA回家`；角标「付费」/「已购」；下载失败提示。
- [ ] **Step 2–4:** FAIL → 实现 → PASS（`flutter test test/app/main_window_test.dart test/app/pet_card_test.dart`）。
- [ ] **Step 5:** 截图核对（同 2026-10-19 的临时 golden 方法，不提交）：人物页 1200×800 含付费卡片。
- [ ] **Step 6:** Commit `feat(aipet): paid characters in the library -- price, owned, download`。

### Task C6: 解锁流程（复用支付页）

**Files:**
- Modify: `lib/app/main_window/custom_flow/pay_model.dart`, `lib/app/main_window/custom_flow/pay_page.dart`, `lib/app/main_window/main_window_app.dart`（`openCustomFlow` 改用新 PayPage 签名；新增 `openUnlock(context, model, character)`）
- Test: `test/app/pay_page_test.dart`, `test/app/main_window_test.dart`

**Interfaces:**
- `abstract interface class PayBackend { Future<PayStatus> status(String orderNo); Future<PayOrder> reorder(); }`；`PayModel({required PayBackend backend, required PayOrder order, Duration pollEvery})`；`refresh()` 调 `reorder()`，`CustomFailure` 的 5011 **或 5016** 视为已付。
- `PayPage({required String title, required PayOrder order, required PayBackend backend, required String hint, required void Function(BuildContext) onPaid})`；定制流程传 `'${request.name} · ${plan.name}'` 与原提示文案；解锁传 `'${character.name} · 永久解锁'` 与「支付完成后会自动跳转」。
- `openUnlock`：未登录 → `requireLogin()` + `openLogin(reason: '登录后即可解锁')`；已登录 → `CharacterService.order(code)`（5016 → 直接当已购：刷新 owned 并提示）→ `PayPage` → `onPaid`：pop、`bridge` 请桌宠窗口 `paid.refresh()`（新消息 `refreshOwned`，PetWindowBridge 调 `PaidHandler.refresh`），`_say('解锁成功，点下载即可使用')`。1003 → 走 `loginExpired`（Review Focus 5）。

- [ ] **Step 1:** 测试：现有 pay_page 测试改用新签名后全过；`5016 on reorder counts as paid`；`unlock while signed out opens the sign-in page, not a QR`；`unlock → paid → the card says 下载`（FakeHttp 依次答 order、status paid、owned 含该 code）。
- [ ] **Step 2–4:** FAIL → 实现 → PASS（`flutter test`）。
- [ ] **Step 5:** `flutter analyze` → No issues；`flutter test` 全过；release 构建（先跑 `tools/dev/unlock_release.ps1`）成功。
- [ ] **Step 6:** Commit `feat(aipet): unlock a paid character by WeChat QR`。

### Task C7: 端到端验收（需用户同意或用户自己做）

- [ ] **Step 1:** 测试环境：一个人物 publish 完、后台上架。客户端 `AIPET_API_BASE` 指向测试环境。
- [ ] **Step 2:** 未登录看到「付费」卡片与价格 → 解锁 → 登录 → 扫码（fake 通道或后台「标记已支付」）→ 卡片「下载」→ 下载 → 「带TA回家」→ 桌面上动作、声音正常。
- [ ] **Step 3:** 登出 → 该人物离开桌面、卡片回到「¥ 解锁」；再登录 → 「带TA回家」（文件仍在，不重下）。另一台电脑（或清空 `%APPDATA%\com.aipet\aipet\pets\paid-*`）登录 → 「下载」。
- [ ] **Step 4:** 后台退款 → 客户端下次刷新后锁定。
- [ ] **Step 5:** 记录结果到 `docs/superpowers/plans/2026-10-21-paid-characters-results.md`。
