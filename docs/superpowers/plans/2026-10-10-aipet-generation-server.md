# aipet 定制宠物自动生成 · 服务端 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 付款成功的定制单自动进入生成队列，生成程序（petgen worker）经内部接口领单、报进度、传成品；后台逐个动作预览、重做、改朝向、交付；客户端能列出并下载已交付的宠物。

**Architecture:** 在下单计划（`2026-10-02-aipet-custom-order.md`）已实现的 pixpickweb-tp 上：一个幂等迁移给 `aipet_custom_requests` 加生成列、新建 `aipet_custom_assets`；`GenerationService` 负责生成程序一侧的全部状态变化（领单 / 进度 / 签名 PUT / 完成 / 失败 / 状态上报 / 卡单回收），`ReviewService` 负责后台审核操作（重做 / 重新生成 / 标记失败 / 朝向 / 交付并重写 `pet.json`）；内部接口 `/internal/aipet/*` 由 `WorkerAuth` 中间件认密钥，控制器以 aipet 产品身份执行；`CustomOrderService` 在付款时建任务、追加客户端的 `deliveries` / `assets` 接口。

**Tech Stack:** PHP 8 / ThinkPHP 6.1 / MySQL 5.7+（JSON 列）/ 阿里云 OSS V1 签名（PUT 签名 URL、HEAD、GET）。

**Spec:** `docs/superpowers/specs/2026-10-10-aipet-custom-generation-design.md`（本计划只做服务端：§3、§4.1–4.7、§9，以及 README 服务器验收清单）。前置计划：`docs/superpowers/plans/2026-10-02-aipet-custom-order.md` 的服务端 Task 1–6 必须已实现并提交。

## Global Constraints

- 服务端仓库 `C:\Users\Administrator\code\pixpick\pixpickweb-tp`。开工前确认下单计划服务端 Task 1–6 已提交（`git log --oneline | grep 定制` 能看到「套餐 / 上传凭证 / 定制单表」「OSS 直传签名」「建单、下单、付款履约」「六个客户端接口」「定制订单与定制套餐」「服务器验收清单」）；然后从当前 `master` 建分支：`git checkout -b feat/aipet-generation`。没有 remote：**只 commit，不 push**。
- **按 pixpick CLAUDE.md「只写代码，不写测试」：服务端不写自动化测试。** 验证 = `php -l` + `php think run --port 8089` + curl（产品路由带 `-H 'Host: aipet.localhost'`；`/internal/aipet/*` 不需要 Host）+ 模板编译检查（Task 9 的 `runtime/tplcheck.php`）。本机 PHP 没有 pdo_mysql，**凡是要连库才能看到的行为都写进 README 服务器验收清单（Task 10）**，在服务器上逐条过。
- commit message 用中文写清**为什么**，结尾单独一段 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`（用第二个 `-m` 传）。每个 commit 只 `git add` 本任务列出的文件。
- 写文件一律用 Write / Edit 工具，**不要用 bash heredoc 写含反斜杠的内容**（会吃掉 `\`，PHP 命名空间和 `"\n"` 全坏）。
- HANDOFF.md §3 的坑照做：新路由组带 `:id` 一律 `completeMatch()`（#15）；业务模型继承 `ProductScoped`、不用 `Db::table()/Db::name()`、不写顶层 `whereOr`（#16/#17）；高频接口不挂 `Throttle`（#38，内部接口每 15 秒调一次）；新路由组注册在文件末尾 `:page` 兜底之前（#26）；后台 POST 表单带 `<input type="hidden" name="__token__" value="{:csrf_token()}">`；视图名带 `.html`（#3）。
- 状态（spec §3）：`draft → pending_payment → paid → generating → review → delivered`；`generating → failed`；`review / failed →（重做 / 重新生成）→ paid`；`paid / generating / review / failed / delivered → refunded`（后台订单退款）。`making`、`done` 删除（spec §9）。
- `pet_id = "custom-<id>"`。`plan_actions`：`standard → [stand, walk, feed, play, sleep]`，`pro → [stand, walk, feed, play, sleep, lick_paw, act_cute]`；未知套餐 code（如 0.01 元测试套餐）按 standard。
- 成品 object key：`aipet/custom/<userId>/<requestId>/<path>`（前缀取 `config('aipet.custom.key_prefix')`）。签名 PUT 有效 30 分钟（1800 秒）；客户端下载 GET 30 分钟；后台预览 GET 600 秒；领单时照片 GET 3600 秒。
- 预算默认 8000 分（`custom.budget_cents`）。卡单回收：`generating` 且 `heartbeat_at` 早于 20 分钟（1200 秒）→ 回 `paid`；`attempts ≥ 3` → `failed`（`fail_reason = 生成程序多次中断`）。
- 只有 `dog`、`cat` 能建单（`POST /api/aipet/custom/requests` 校验，5010 field=species）。
- `.env [AIPET] WORKER_KEY`（`hash_equals` 比对 `X-Worker-Key`）、`WORKER_IPS`（逗号分隔，空 = 不限）。`.example.env` 只写键名，真实值不进代码、日志、对话。
- 内部接口契约**逐字**按下面「内部接口契约」一节实现：Python 生成程序的计划是按同一份 spec 并行写的，路径、字段名、返回形状改一个字都会对不上。

## Review Focus

1. **两个生成程序同时领单**：两次 `claim` 并发，必须拿到两张不同的单（或一张 + `null`），绝不能同一单被领两次、`attempts` 加两次。（Task 3：`claim` 在事务里 `lock(true)` 后复查 `status === paid`；README 清单第 3 条用两个并发 curl 验证。）
2. **后台已标记失败 / 已退款，生成程序还在跑**：之后的 `progress` 返回 `{"abort": true}`（花费仍然记上），`upload-urls` / `finish` / `fail` 返回 409 + `abort: true`，单子不会被改回 `review`，`aipet_custom_assets` 不写。（Task 3 代码；清单第 9 条。）
3. **「交付」点两次（双击 / 两个标签页）**：第二次提示「这一单已经交付过了」，`pet.json` 只重写一次，`delivered_at` 不变。（Task 8：`deliver` 在事务里锁行、先判 `delivered`；清单第 12 条。）
4. **生成中（或开着旧页面）点「重做」/「整单重新生成」**：拒绝并提示当前状态，`redo` 不被改写、不会把正在生成的单打回 `paid`。（Task 8 锁行判状态；清单第 13 条。）
5. **退款后的单 / 未交付的单 / 别人的单请求 `assets`**：一律 404；已交付单退款后从 `deliveries` 消失、`assets` 404（客户端已下载的文件不收回）。（Task 7；清单第 15、16 条。）

---

## 内部接口契约（与生成程序计划共用，逐字实现）

所有请求：`POST`，`Content-Type: application/json`，头 `X-Worker-Key: <WORKER_KEY>`。**不用** `{code, message, data}` 信封：成功直接返回下表的 JSON（HTTP 200）；出错用 HTTP 状态码 + `{"error": "<原因>"}`，单子已不在 `generating` 时额外带 `"abort": true`。

| 状态码 | 含义 |
|---|---|
| 401 `{"error":"unauthorized"}` | 没带 / 带错 `X-Worker-Key`，或服务端没配 `WORKER_KEY` |
| 403 `{"error":"forbidden"}` | 配了 `WORKER_IPS` 且来源 IP 不在里面 |
| 404 `{"error":"job not found"}` | 没有这个 id |
| 409 `{"error":"job is <status>","abort":true}` | 单子已不在 `generating`（被后台改了 / 被回收了）→ 生成程序应停下这一单 |
| 422 `{"error":"..."}` | 请求体不合法（路径、类型、大小、缺文件……），原因写在 error 里 |
| 500 `{"error":"server error"}` / 503 `{"error":"storage unconfigured"}` | 服务端异常 / OSS 没配 |

| 接口 | 请求体 | 成功返回 |
|---|---|---|
| `/internal/aipet/jobs/claim` | `{}` | `{"job": {"id": 12, "pet_id": "custom-12", "name": "豆豆", "species": "dog", "actions": ["stand","walk","feed","play","sleep"], "redo": null, "budget_cents": 8000, "spent_cents": 0, "photos": [{"url": "https://…"}]}}`；没有单 `{"job": null}`；最近一次 `worker/status` 报了 `paused: true` 时 `{"job": null, "paused_reason": "生成额度不足"}` |
| `/internal/aipet/jobs/:id/progress` | `{"stage": "video", "done": 2, "total": 5, "message": "play", "cost": {"image_units": 0, "video_units": 4, "cents": 400}}` | `{"abort": false}` / `{"abort": true}` |
| `/internal/aipet/jobs/:id/upload-urls` | `{"files": [{"path": "stand.mp4", "bytes": 5242880, "content_type": "video/mp4"}]}` | `[{"path": "stand.mp4", "url": "https://…"}]`（顶层数组，顺序同请求） |
| `/internal/aipet/jobs/:id/finish` | `{"walk_facing": "right", "files": [{"path": "stand.mp4", "bytes": 5242880, "sha256": "<64 位小写十六进制>", "qa": {"score": 0.93}, "deliverable": true}]}` | `{"ok": true}` |
| `/internal/aipet/jobs/:id/fail` | `{"stage": "video", "reason": "超出单笔预算"}` | `{"ok": true}` |
| `/internal/aipet/worker/status` | `{"paused": true, "reason": "生成额度不足", "balance": {"image": 20, "video": 8}}` | `{"ok": true}` |

细则：
- `redo`：`null`，或 `{"actions": ["play"], "refs": false, "hint": "尾巴摆慢一点"}`，或 `{"all": true}`。`finish` 成功后服务端清空。
- `photos[].url` 是 3600 秒的限时 GET。重新领取（卡单回收后）会拿到新地址。
- `progress.cost` 是**这次调用新增**的花费（增量），服务端累加；单子不在 `generating` 时也照样累加（钱已经花了），只是返回 `abort: true`。每次 `progress` 刷新 `heartbeat_at`（20 分钟没有就会被回收）。
- `path` 必须匹配 `^(refs/)?[a-z0-9][a-z0-9_-]{0,47}\.(mp4|png|jpg|json)$`；`content_type` 必须与扩展名对应：`mp4 → video/mp4`、`png → image/png`、`jpg → image/jpeg`、`json → application/json`；`bytes` 1 ~ 104857600。
- 上传：对返回的 `url` 发 `PUT`，请求头 `Content-Type` **必须与申请时的 `content_type` 完全一致**（它参与签名），不要加其它 `x-oss-*` 头；成功 HTTP 200。URL 1800 秒内有效。
- `finish`：服务端逐个 HEAD 核对对象存在且大小 = `bytes`；`refs/*` 一律按不下发处理；本次 + 已有文件合起来必须有 `pet.json`、`cover.png` 和每个动作的 `<action>.mp4` 且都 `deliverable`，否则 422。重做时只传变了的文件即可（同 path 覆盖）。`walk_facing` 只能 `left` / `right`。
- `fail_reason` 存为 `"<stage>：<reason>"`（截到 255 字）。
- 暂停：报了 `paused: true` 之后，服务端的 `claim` 一直返回 `job: null` + `paused_reason`，**直到生成程序再报一次 `paused: false`**。
- 生成程序每次调用任一内部接口都算一次「心跳」，后台概览据此显示在线（2 分钟内）/ 离线。

---

## 文件结构

（相对 `pixpickweb-tp/`）

| 文件 | 职责 |
|---|---|
| `database/migrations/2026-10-10_aipet_generation.sql` | 定制单加生成列、新表 `aipet_custom_assets`、旧状态迁移、Pro 套餐功能列表修订 |
| `app/model/AipetCustomRequest.php`（改） | 新状态常量、标签、`GENERATABLE_SPECIES`、新列类型 |
| `app/model/AipetCustomAsset.php` | 成品文件模型 |
| `config/aipet.php`（改） `.example.env`（改） | `worker.key/ips`、`custom.plan_actions/budget_cents/...` |
| `app/service/aipet/OssClient.php`（改） `app/command/AipetOssCheck.php`（改） | 签名 PUT URL、HEAD 取大小、GET 读小文件；自检加这三项 |
| `app/service/aipet/GenerationError.php` `GenerationService.php` | 生成程序一侧：建任务字段、领单、进度、上传地址、完成、失败、状态上报、在线状态、卡单回收 |
| `app/middleware/WorkerAuth.php` `app/controller/internal/AipetWorker.php` `route/app.php`（改） | 内部接口 |
| `app/command/AipetReap.php` `config/console.php`（改） | `php think aipet:reap` |
| `app/service/aipet/CustomOrderService.php`（改） `app/service/payment/Fulfillment.php`（改） `app/controller/admin/Orders.php`（改） `app/lang/zh-cn.php` `app/lang/en-us.php`（改） | 付款建任务、只开放狗猫、客户端 `deliveries` / `assets` / 列表新字段 |
| `app/controller/api/aipet/Custom.php`（改） | 两个新客户端接口 |
| `app/service/aipet/ReviewService.php` | 后台审核操作与面板数据 |
| `app/controller/admin/AipetCustom.php`（改） `app/view/admin/aipet/custom_show.html`（重写） `app/view/admin/aipet/custom.html`（改） `app/view/admin/layout.html`（改） `app/common.php`（改） `app/controller/admin/Aipet.php`（改） `app/view/admin/aipet/index.html`（改） | 后台生成面板、待审核角标、概览生成程序状态 |
| `README.md`（改） | 内部接口说明、上线步骤、服务器验收清单 |

---

### Task 1: 迁移、模型、配置（并去掉手动推进状态）

**Files:**
- Create: `database/migrations/2026-10-10_aipet_generation.sql`
- Create: `app/model/AipetCustomAsset.php`
- Modify: `app/model/AipetCustomRequest.php`（整文件替换）
- Modify: `config/aipet.php`, `.example.env`
- Modify: `app/controller/admin/AipetCustom.php`, `app/view/admin/aipet/custom_show.html`, `route/app.php`（删掉 `paid → making → done` 手动推进，spec §9）

**Interfaces:**
- Consumes: 下单计划的 `aipet_custom_requests`、`aipet_plans` 表，`config('aipet.custom.*')`。
- Produces:
  - 列：`pet_id, actions, stage, stage_done, stage_total, stage_message, claimed_at, heartbeat_at, review_at, delivered_at, delivered_by, redo, walk_facing, cost_image_units, cost_video_units, cost_cents, budget_cents, fail_reason, attempts`；表 `aipet_custom_assets(product_id, request_id, path, object_key, bytes, sha256, qa, deliverable)`。
  - `AipetCustomRequest::STATUS_{DRAFT,PENDING_PAYMENT,PAID,GENERATING,REVIEW,DELIVERED,FAILED,REFUNDED}`、`PAID_STATES`、`STATUS_LABELS`、`SPECIES`、`GENERATABLE_SPECIES = ['dog','cat']`、`isPaid()`。
  - `AipetCustomAsset` 模型。
  - `config('aipet.worker.key')`、`config('aipet.worker.ips')`、`config('aipet.custom.plan_actions|budget_cents|heartbeat_timeout|max_attempts|photo_url_ttl|upload_url_ttl|asset_url_ttl|asset_max_bytes')`。

- [ ] **Step 1: 写迁移**

`database/migrations/2026-10-10_aipet_generation.sql`：

```sql
-- ---------------------------------------------------------------------------
-- AI 桌宠（aipet）：定制宠物自动生成 + 审核 + 下发 · 2026-10-10
-- 设计：aipet/docs/superpowers/specs/2026-10-10-aipet-custom-generation-design.md
--
-- 服务器手工执行（先备份！），须在 2026-10-02_aipet_custom.sql 之后：
--   mysqldump -u<user> -p <db> aipet_custom_requests aipet_plans > backup_before_aipet_generation.sql
--   mysql -u<user> -p <db> < database/migrations/2026-10-10_aipet_generation.sql
--
-- 1. aipet_custom_requests 加生成相关列 + 领单索引
-- 2. aipet_custom_assets：成品文件，一个文件一行，(product_id, request_id, path) 唯一，重做覆盖同一行
-- 3. 旧状态迁移：making → paid（交给生成程序），done → failed（旧流程没有成品文件，人工处理）；
--    已付款的旧单补 pet_id / actions / budget_cents；非狗猫的待生成单直接 failed
-- 4. Pro 套餐功能列表：转圈 · 摸摸头 · 后空翻 · 鼠标跟随 标「后续追加」，补上「卖萌」（act_cute）
-- 全部幂等，可重复执行。动作列表、预算与 config/aipet.php 的 custom.plan_actions / budget_cents 保持一致。
-- ---------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS ag_add_column;
DROP PROCEDURE IF EXISTS ag_add_index;

DELIMITER $$

CREATE PROCEDURE ag_add_column(IN tbl VARCHAR(64), IN col VARCHAR(64), IN ddl TEXT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = tbl AND COLUMN_NAME = col) THEN
    SET @s = CONCAT('ALTER TABLE `', tbl, '` ADD COLUMN ', ddl);
    PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
  END IF;
END$$

CREATE PROCEDURE ag_add_index(IN tbl VARCHAR(64), IN idx VARCHAR(64), IN ddl TEXT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = tbl AND INDEX_NAME = idx) THEN
    SET @s = CONCAT('ALTER TABLE `', tbl, '` ADD ', ddl);
    PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
  END IF;
END$$

DELIMITER ;

-- 1) 定制单加列 ------------------------------------------------------------------
CALL ag_add_column('aipet_custom_requests', 'pet_id',           '`pet_id` VARCHAR(64) NULL COMMENT ''custom-<id>，付款时写入''');
CALL ag_add_column('aipet_custom_requests', 'actions',          '`actions` JSON NULL COMMENT ''按套餐确定的动作列表''');
CALL ag_add_column('aipet_custom_requests', 'stage',            '`stage` VARCHAR(32) NULL');
CALL ag_add_column('aipet_custom_requests', 'stage_done',       '`stage_done` INT UNSIGNED NOT NULL DEFAULT 0');
CALL ag_add_column('aipet_custom_requests', 'stage_total',      '`stage_total` INT UNSIGNED NOT NULL DEFAULT 0');
CALL ag_add_column('aipet_custom_requests', 'stage_message',    '`stage_message` VARCHAR(255) NULL');
CALL ag_add_column('aipet_custom_requests', 'claimed_at',       '`claimed_at` DATETIME NULL');
CALL ag_add_column('aipet_custom_requests', 'heartbeat_at',     '`heartbeat_at` DATETIME NULL');
CALL ag_add_column('aipet_custom_requests', 'review_at',        '`review_at` DATETIME NULL');
CALL ag_add_column('aipet_custom_requests', 'delivered_at',     '`delivered_at` DATETIME NULL');
CALL ag_add_column('aipet_custom_requests', 'delivered_by',     '`delivered_by` VARCHAR(64) NULL');
CALL ag_add_column('aipet_custom_requests', 'redo',             '`redo` JSON NULL COMMENT ''待重做；领取时下发，完成后清空''');
CALL ag_add_column('aipet_custom_requests', 'walk_facing',      '`walk_facing` VARCHAR(8) NULL');
CALL ag_add_column('aipet_custom_requests', 'cost_image_units', '`cost_image_units` INT UNSIGNED NOT NULL DEFAULT 0');
CALL ag_add_column('aipet_custom_requests', 'cost_video_units', '`cost_video_units` INT UNSIGNED NOT NULL DEFAULT 0');
CALL ag_add_column('aipet_custom_requests', 'cost_cents',       '`cost_cents` INT UNSIGNED NOT NULL DEFAULT 0');
CALL ag_add_column('aipet_custom_requests', 'budget_cents',     '`budget_cents` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''累计花费上限；重做时 = 已花 + 单笔预算''');
CALL ag_add_column('aipet_custom_requests', 'fail_reason',      '`fail_reason` VARCHAR(255) NULL');
CALL ag_add_column('aipet_custom_requests', 'attempts',         '`attempts` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''本轮领取次数（卡单回收计数）''');
CALL ag_add_index('aipet_custom_requests', 'idx_aipet_custom_requests_queue',
                  'KEY `idx_aipet_custom_requests_queue` (`product_id`, `status`, `paid_at`)');

DROP PROCEDURE ag_add_column;
DROP PROCEDURE ag_add_index;

-- 2) 成品文件 --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `aipet_custom_assets` (
  `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `product_id`  BIGINT UNSIGNED NOT NULL,
  `request_id`  BIGINT UNSIGNED NOT NULL,
  `path`        VARCHAR(64)     NOT NULL COMMENT '相对宠物目录：stand.mp4 / cover.png / pet.json / refs/front.png',
  `object_key`  VARCHAR(255)    NOT NULL,
  `bytes`       BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `sha256`      CHAR(64)        NOT NULL,
  `qa`          JSON            NULL COMMENT '质检分数',
  `deliverable` TINYINT(1)      NOT NULL DEFAULT 1 COMMENT '是否下发给客户端（refs/* 为 0）',
  `created_at`  DATETIME        NULL,
  `updated_at`  DATETIME        NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_aipet_custom_assets_path` (`product_id`, `request_id`, `path`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='AI 桌宠定制成品文件';

-- 3) 旧状态迁移与补字段 ------------------------------------------------------------
UPDATE `aipet_custom_requests` SET `status` = 'paid' WHERE `status` = 'making';
UPDATE `aipet_custom_requests`
   SET `status` = 'failed', `fail_reason` = '旧流程（人工制作）的单，没有成品文件，请人工处理'
 WHERE `status` = 'done';

UPDATE `aipet_custom_requests` SET `pet_id` = CONCAT('custom-', `id`)
 WHERE `pet_id` IS NULL AND `status` NOT IN ('draft', 'pending_payment');
UPDATE `aipet_custom_requests`
   SET `actions` = JSON_ARRAY('stand', 'walk', 'feed', 'play', 'sleep', 'lick_paw', 'act_cute')
 WHERE `actions` IS NULL AND `plan_code` = 'pro' AND `status` NOT IN ('draft', 'pending_payment');
UPDATE `aipet_custom_requests`
   SET `actions` = JSON_ARRAY('stand', 'walk', 'feed', 'play', 'sleep')
 WHERE `actions` IS NULL AND `status` NOT IN ('draft', 'pending_payment');
UPDATE `aipet_custom_requests` SET `budget_cents` = 8000
 WHERE `budget_cents` = 0 AND `status` NOT IN ('draft', 'pending_payment');
UPDATE `aipet_custom_requests`
   SET `status` = 'failed', `fail_reason` = '该类别暂不支持自动生成，请人工处理或退款'
 WHERE `status` = 'paid' AND `species` NOT IN ('dog', 'cat');

-- 4) Pro 套餐功能列表（只改还没改过的：仍含不带标注的「后空翻」）----------------------------
UPDATE `aipet_plans`
   SET `features` = JSON_ARRAY('站立', '行走', '喂食', '玩耍', '休眠', '舔爪', '卖萌',
                               '转圈（后续追加）', '摸摸头（后续追加）', '后空翻（后续追加）', '鼠标跟随（后续追加）',
                               '放大放小', '互动面板', '饱食度等数值统计'),
       `feature_count` = 14,
       `updated_at` = NOW()
 WHERE `code` = 'pro' AND JSON_CONTAINS(`features`, JSON_QUOTE('后空翻'));
```

- [ ] **Step 2: 改 `AipetCustomRequest` 模型（整文件替换）**

`app/model/AipetCustomRequest.php`：

```php
<?php
declare(strict_types=1);

namespace app\model;

/**
 * AI 桌宠定制单：名字、类别、照片（OSS key）、套餐快照、状态，以及自动生成的进度 / 花费 / 审核信息。
 * 状态流见设计 2026-10-10-aipet-custom-generation-design.md §3（取代下单设计里的 making / done）。
 */
class AipetCustomRequest extends ProductScoped
{
    public const STATUS_DRAFT           = 'draft';
    public const STATUS_PENDING_PAYMENT = 'pending_payment';
    public const STATUS_PAID            = 'paid';        // 待生成：生成程序只领这个状态
    public const STATUS_GENERATING      = 'generating';  // 已被领取
    public const STATUS_REVIEW          = 'review';      // 成品已上传，待人工审核
    public const STATUS_DELIVERED       = 'delivered';   // 已交付，客户端可下载
    public const STATUS_FAILED          = 'failed';      // 自动重试后仍失败 / 超预算 / 后台标记
    public const STATUS_REFUNDED        = 'refunded';

    /** 已付款及之后：不能再下单。 */
    public const PAID_STATES = [
        self::STATUS_PAID, self::STATUS_GENERATING, self::STATUS_REVIEW,
        self::STATUS_DELIVERED, self::STATUS_FAILED, self::STATUS_REFUNDED,
    ];

    public const STATUS_LABELS = [
        self::STATUS_DRAFT           => '待支付',
        self::STATUS_PENDING_PAYMENT => '待支付',
        self::STATUS_PAID            => '待生成',
        self::STATUS_GENERATING      => '生成中',
        self::STATUS_REVIEW          => '待审核',
        self::STATUS_DELIVERED       => '已交付',
        self::STATUS_FAILED          => '生成失败',
        self::STATUS_REFUNDED        => '已退款',
    ];

    /** 与客户端 Species 一致。 */
    public const SPECIES = ['dog' => '狗狗', 'cat' => '猫猫', 'other' => '其他宠物', 'girl' => '女生', 'boy' => '男生', 'anime' => '动漫角色'];

    /** 自动生成只支持这两类（设计 2026-10-10 §2）；建单只收这两类。 */
    public const GENERATABLE_SPECIES = ['dog', 'cat'];

    protected $table = 'aipet_custom_requests';

    protected $autoWriteTimestamp = 'datetime';
    protected $createTime = 'created_at';
    protected $updateTime = 'updated_at';

    protected $jsonAssoc = true;
    protected $type = [
        'photo_keys'       => 'json',
        'actions'          => 'json',
        'redo'             => 'json',
        'price_cents'      => 'integer',
        'stage_done'       => 'integer',
        'stage_total'      => 'integer',
        'cost_image_units' => 'integer',
        'cost_video_units' => 'integer',
        'cost_cents'       => 'integer',
        'budget_cents'     => 'integer',
        'attempts'         => 'integer',
    ];

    public function isPaid(): bool
    {
        return in_array($this->status, self::PAID_STATES, true);
    }
}
```

- [ ] **Step 3: 新模型 `AipetCustomAsset`**

`app/model/AipetCustomAsset.php`：

```php
<?php
declare(strict_types=1);

namespace app\model;

/**
 * 定制宠物的成品文件（一个文件一行，(request_id, path) 唯一；重做覆盖同一行）。
 * path 相对宠物目录：stand.mp4、cover.png、pet.json；refs/* 是参考图，deliverable = 0 不下发。
 */
class AipetCustomAsset extends ProductScoped
{
    protected $table = 'aipet_custom_assets';

    protected $autoWriteTimestamp = 'datetime';
    protected $createTime = 'created_at';
    protected $updateTime = 'updated_at';

    protected $jsonAssoc = true;
    protected $type = [
        'bytes'       => 'integer',
        'deliverable' => 'integer',
        'qa'          => 'json',
    ];
}
```

- [ ] **Step 4: 配置与 `.example.env`**

`config/aipet.php`：在 `'custom' => [` 数组里 `'name_max'                 => 8,` 这一行之后加：

```php

        // ---- 自动生成（设计 2026-10-10-aipet-custom-generation-design.md）----
        // 套餐 code → 生成的动作；不在表里的套餐（如 0.01 元测试套餐）按 standard
        'plan_actions' => [
            'standard' => ['stand', 'walk', 'feed', 'play', 'sleep'],
            'pro'      => ['stand', 'walk', 'feed', 'play', 'sleep', 'lick_paw', 'act_cute'],
        ],
        'budget_cents'      => 8000,               // 单笔预算（分）；重做 / 重新生成时再给一份
        'heartbeat_timeout' => 1200,               // generating 超过这么多秒没心跳 → aipet:reap 回收
        'max_attempts'      => 3,                  // 本轮领取次数达到它还卡住 → failed
        'photo_url_ttl'     => 3600,               // 领单时下发的照片限时 GET 秒数
        'upload_url_ttl'    => 1800,               // 成品签名 PUT 秒数
        'asset_url_ttl'     => 1800,               // 客户端下载成品的限时 GET 秒数
        'asset_max_bytes'   => 100 * 1024 * 1024,  // 单个成品文件上限
```

同文件在 `    // 阿里云 OSS（定制照片）：私有 bucket，密钥只在服务端 .env [OSS]` 这一行之前加：

```php
    // 生成程序（petgen worker）调 /internal/aipet/* 的密钥与可选 IP 白名单（逗号分隔，空 = 不限）
    'worker' => [
        'key' => env('aipet.worker_key', ''),
        'ips' => env('aipet.worker_ips', ''),
    ],

```

`.example.env` 末尾加：

```
[AIPET]
# 生成程序（petgen worker）调 /internal/aipet/* 用的密钥（openssl rand -hex 32），与生成程序 secrets/worker.env 的 AIPET_WORKER_KEY 相同；空 = 内部接口全部 401
WORKER_KEY =
# 可选：只允许这些 IP 调内部接口，逗号分隔；空 = 不限
WORKER_IPS =
```

- [ ] **Step 5: 去掉后台手动推进状态（spec §9）**

`app/controller/admin/AipetCustom.php`（下单计划 Task 5 写的）：

1. 删掉整个常量：

```php
    private const NEXT = [
        AipetCustomRequest::STATUS_PAID   => AipetCustomRequest::STATUS_MAKING,
        AipetCustomRequest::STATUS_MAKING => AipetCustomRequest::STATUS_DONE,
    ];
```

2. 删掉整个 `public function status(Request $request, $id): Response { ... }` 方法。
3. `show()` 的 `view(...)` 参数里删掉这两行：

```php
            'next'         => self::NEXT[$r->status] ?? '',
            'next_label'   => isset(self::NEXT[$r->status]) ? AipetCustomRequest::STATUS_LABELS[self::NEXT[$r->status]] : '',
```

4. 类注释第一段改为：

```php
/**
 * AI 桌宠「定制订单」「定制套餐」。定制单状态由生成流程推进（设计 2026-10-10 §3），后台只做审核操作；
 * 退款走订单管理（退款后定制单自动变「已退款」）。套餐不删除，只上下架。
 */
```

`app/view/admin/aipet/custom_show.html` 里把这一段：

```html
        {if $next}
        <form method="post" action="/admin/aipet/custom/{$r.id}/status" class="inline">
            <input type="hidden" name="__token__" value="{:csrf_token()}">
            <input type="hidden" name="to" value="{$next}">
            <button class="btn btn-pri" type="submit">改为「{$next_label}」</button>
        </form>
        {else /}<span class="muted">当前状态没有下一步。退款请到订单管理里操作该订单。</span>{/if}
```

换成：

```html
        <span class="muted">退款请到订单管理里操作该订单。</span>
```

`route/app.php` 删掉这一行：

```php
        Route::post('aipet/custom/:id/status', 'admin.AipetCustom/status')->pattern(['id' => '\d+']);
```

（若实现下单计划时这几处写法略有出入，按「删掉手动推进的常量、方法、路由、按钮」的语义改。）

- [ ] **Step 6: 检查**

Run（pixpickweb-tp 目录）：`for f in app/model/AipetCustomRequest.php app/model/AipetCustomAsset.php config/aipet.php app/controller/admin/AipetCustom.php route/app.php; do php -l $f; done`
Expected: 每个都是 `No syntax errors detected`

Run：`grep -rn "STATUS_MAKING\|STATUS_DONE\|'making'\|'done'" app/ route/`
Expected: 没有输出（若 `CustomOrderService` / 视图里还有引用，按新状态改掉再跑）。

- [ ] **Step 7: Commit**

```bash
git add database/migrations/2026-10-10_aipet_generation.sql app/model/AipetCustomRequest.php app/model/AipetCustomAsset.php config/aipet.php .example.env app/controller/admin/AipetCustom.php app/view/admin/aipet/custom_show.html route/app.php
git commit -m "AI 桌宠定制生成：定制单加生成列与成品表，状态改为 待生成→生成中→待审核→已交付——付款后要自动做，不再靠后台手动推进" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: OSS 签名 PUT、HEAD 取大小、GET 读小文件

**Files:**
- Modify: `app/service/aipet/OssClient.php`
- Modify: `app/command/AipetOssCheck.php`（整文件替换）

**Interfaces:**
- Consumes: 下单计划的 `OssClient`（`fromConfig`、`host`、`signedGetUrl`、`put`、`delete`、私有 `request/sign/resource/encodeKey`）。
- Produces（新增，签名与已有方法同属 `OssClient`）：
  - `signedPutUrl(string $key, int $ttl, string $contentType): string` —— V1 URL 签名，`Content-Type` 参与签名
  - `objectSize(string $key): ?int` —— HEAD；不存在返回 `null`
  - `get(string $key): ?string` —— 读小文件（`pet.json`）；非 200 返回 `null`
  - 私有 `request()` 改为返回 `array{0: int, 1: string, 2: int}`（第三项为 Content-Length，未知为 -1），已有调用 `[$status] = ...` 不受影响

- [ ] **Step 1: `OssClient` 加三个方法**

在 `signedGetUrl()` 方法之后加：

```php
    /**
     * 生成程序上传成品用的限时 PUT 地址（V1 URL 签名）。Content-Type 参与签名：
     * 上传时请求头 Content-Type 必须与这里一致，否则 OSS 返回 403 SignatureDoesNotMatch。
     */
    public function signedPutUrl(string $key, int $ttl, string $contentType): string
    {
        $expires   = time() + $ttl;
        $signature = $this->sign("PUT\n\n{$contentType}\n{$expires}\n" . $this->resource($key));

        return $this->host() . '/' . $this->encodeKey($key)
            . '?OSSAccessKeyId=' . rawurlencode($this->accessKeyId)
            . '&Expires=' . $expires
            . '&Signature=' . rawurlencode($signature);
    }

    /** HEAD 取对象大小（字节）；不存在或拿不到返回 null。finish 时核对生成程序报的 bytes。 */
    public function objectSize(string $key): ?int
    {
        [$status, , $length] = $this->request('HEAD', $key);
        return ($status === 200 && $length >= 0) ? $length : null;
    }

    /** 读小文件（交付时重写 pet.json 用）；不存在或失败返回 null。 */
    public function get(string $key): ?string
    {
        [$status, $body] = $this->request('GET', $key);
        return $status === 200 ? $body : null;
    }
```

把私有 `request()` 整个方法替换为（只多返回 Content-Length）：

```php
    /** @return array{0: int, 1: string, 2: int} 状态码、响应体、Content-Length（未知为 -1） */
    private function request(string $method, string $key, string $body = '', string $contentType = ''): array
    {
        $date = gmdate('D, d M Y H:i:s \G\M\T');
        $md5  = '';
        $sign = $this->sign("{$method}\n{$md5}\n{$contentType}\n{$date}\n" . $this->resource($key));

        $headers = ['Date: ' . $date, 'Authorization: OSS ' . $this->accessKeyId . ':' . $sign];
        if ($contentType !== '') {
            $headers[] = 'Content-Type: ' . $contentType;
        }

        $ch = curl_init();
        curl_setopt_array($ch, [
            CURLOPT_URL            => $this->host() . '/' . $this->encodeKey($key),
            CURLOPT_CUSTOMREQUEST  => $method,
            CURLOPT_HTTPHEADER     => $headers,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT        => 15,
            CURLOPT_NOBODY         => $method === 'HEAD',
        ]);
        if ($method === 'PUT') {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        }
        $raw = curl_exec($ch);
        if ($raw === false) {
            $err = curl_error($ch);
            curl_close($ch);
            throw new \RuntimeException('请求 OSS 失败：' . $err);
        }
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $length = (int) curl_getinfo($ch, CURLINFO_CONTENT_LENGTH_DOWNLOAD);
        curl_close($ch);

        return [$status, (string) $raw, $length];
    }
```

类注释的列表里加三行：

```php
 * - signedPutUrl：生成程序上传成品的限时 PUT 地址（30 分钟，Content-Type 参与签名）。
 * - objectSize：finish 时核对成品已上传且大小一致。
 * - get：交付时读 pet.json 改朝向后用 put 写回。
```

- [ ] **Step 2: 自检命令加签名 PUT（整文件替换）**

`app/command/AipetOssCheck.php`：

```php
<?php
declare(strict_types=1);

namespace app\command;

use think\console\Command;
use think\console\Input;
use think\console\Output;
use app\service\aipet\OssClient;

/**
 * php think aipet:oss-check —— 用 .env [OSS] 的真实 bucket 走一遍定制会用到的全部签名，不碰数据库：
 * 1. PostObject 表单直传（和客户端传照片一样）→ HEAD → 限时 GET → DELETE
 * 2. 签名 PUT 地址上传（和生成程序传成品一样）→ HEAD 取大小 → GET 读回 → DELETE
 */
class AipetOssCheck extends Command
{
    protected function configure(): void
    {
        $this->setName('aipet:oss-check')->setDescription('AI 桌宠：检查 OSS 配置与签名');
    }

    protected function execute(Input $input, Output $output): int
    {
        $oss = OssClient::fromConfig();
        if ($oss === null) {
            $output->writeln('<error>.env 的 [OSS] 没配全（ENDPOINT / BUCKET / ACCESS_KEY_ID / ACCESS_KEY_SECRET）</error>');
            return 1;
        }
        $prefix = rtrim((string) config('aipet.custom.key_prefix'), '/') . '/_check/';

        // 1) 客户端传照片的路子
        $key  = $prefix . bin2hex(random_bytes(8)) . '.jpg';
        $body = 'aipet oss check ' . date('c');

        $form = $oss->postPolicy($key, 1024 * 1024, 300);
        $ch   = curl_init($form['url']);
        $post = $form['fields'];
        $post['file'] = new \CURLStringFile($body, 'check.jpg', 'image/jpeg');
        curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => $post, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15]);
        $resp   = (string) curl_exec($ch);
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        $output->writeln("PostObject 直传：HTTP {$status}" . ($status === 204 ? ' ✓' : " ✗ {$resp}"));
        if ($status !== 204) {
            return 1;
        }

        $exists = $oss->exists($key);
        $output->writeln('HEAD：' . ($exists ? '存在 ✓' : '不存在 ✗'));

        $url = $oss->signedGetUrl($key, 60);
        $got = (string) @file_get_contents($url);
        $output->writeln('限时 GET：' . ($got === $body ? '内容一致 ✓' : '不一致 ✗'));

        $output->writeln('DELETE：' . ($oss->delete($key) ? '已删除 ✓' : '失败 ✗'));

        // 2) 生成程序传成品的路子
        $putKey  = $prefix . bin2hex(random_bytes(8)) . '.json';
        $putBody = '{"check":"' . date('c') . '"}';
        $ch      = curl_init($oss->signedPutUrl($putKey, 300, 'application/json'));
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST  => 'PUT',
            CURLOPT_POSTFIELDS     => $putBody,
            CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 15,
        ]);
        $resp      = (string) curl_exec($ch);
        $putStatus = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        $output->writeln("签名 PUT：HTTP {$putStatus}" . ($putStatus === 200 ? ' ✓' : " ✗ {$resp}"));

        $size = $oss->objectSize($putKey);
        $sizeOk = $size === strlen($putBody);
        $output->writeln('HEAD 大小：' . ($sizeOk ? "{$size} 字节 ✓" : '不一致 ✗（' . var_export($size, true) . '）'));

        $back   = $oss->get($putKey);
        $backOk = $back === $putBody;
        $output->writeln('GET 读回：' . ($backOk ? '一致 ✓' : '不一致 ✗'));

        $output->writeln('DELETE：' . ($oss->delete($putKey) ? '已删除 ✓' : '失败 ✗'));

        return ($exists && $got === $body && $putStatus === 200 && $sizeOk && $backOk) ? 0 : 1;
    }
}
```

- [ ] **Step 3: 语法检查**

Run: `php -l app/service/aipet/OssClient.php && php -l app/command/AipetOssCheck.php`
Expected: 两个 `No syntax errors detected`

- [ ] **Step 4: 未配置时的行为**

Run: `php think aipet:oss-check`（本地 `.env` 没有 `[OSS]` 时）
Expected: 输出「.env 的 [OSS] 没配全…」，退出码 1

- [ ] **Step 5: 真实 bucket 自检（需要用户已在本机 `.env` 填 `[OSS]`，不要让用户把值发过来）**

先问用户本机 `pixpickweb-tp/.env` 是否已填 `[OSS]`；填了：
Run: `php think aipet:oss-check`
Expected: 八行都是 ✓，退出码 0。签名 PUT 403：核对 RAM 子账号有 `oss:PutObject`、上传时 Content-Type 与签名一致。没填就跳过，在最终报告写「OSS 签名 PUT 未实测」。

- [ ] **Step 6: Commit**

```bash
git add app/service/aipet/OssClient.php app/command/AipetOssCheck.php
git commit -m "AI 桌宠定制生成：OSS 签名 PUT、取大小、读文件——生成程序拿限时地址直传成品，服务端核对大小、交付时改 pet.json" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `GenerationService`（生成程序一侧的全部状态变化）

**Files:**
- Create: `app/service/aipet/GenerationError.php`
- Create: `app/service/aipet/GenerationService.php`

**Interfaces:**
- Consumes: Task 1 模型与配置；Task 2 `OssClient::signedGetUrl / signedPutUrl / objectSize`；`app\model\Setting`（`fetchValue`）。
- Produces：
  - `GenerationError(int $status, string $message, bool $abort = false)`：`public readonly int $status`、`public readonly bool $abort`
  - `GenerationService::__construct(?OssClient $oss = null)`（null 时取 `OssClient::fromConfig()`）
  - `static planActions(?string $planCode): array`
  - `static requiredPaths(array $actions): array` —— `['pet.json', 'cover.png', '<action>.mp4'...]`
  - `static prepareOnPaid(AipetCustomRequest $r): void` —— 付款时写 `pet_id/actions/budget_cents/attempts/redo`，非狗猫置 `failed`；不 save
  - `claim(): array`、`progress(int $id, array $body): array`、`uploadUrls(int $id, $files): array`、`finish(int $id, string $walkFacing, $files): array`、`fail(int $id, string $stage, string $reason): array`、`reportStatus(array $body): array` —— 返回值即内部接口响应体
  - `touchSeen(): void`、`workerStatus(): array`（键：`state, badge, seen_at, balance_image, balance_video, reported_at, queue, generating, review, failed`）
  - `reap(): array` → `[int $requeued, int $failed]`
  - 都必须在 aipet 产品上下文里调用（`CurrentProduct::runAs`）。

- [ ] **Step 1: 错误类**

`app/service/aipet/GenerationError.php`：

```php
<?php
declare(strict_types=1);

namespace app\service\aipet;

/**
 * 生成 / 审核流程里的「不行」。status 是 HTTP 状态码（内部接口直接用；后台把 message 当提示），
 * abort = true 表示单子已不在 generating，生成程序应停下这一单。
 */
final class GenerationError extends \RuntimeException
{
    public function __construct(
        public readonly int $status,
        string $message,
        public readonly bool $abort = false,
    ) {
        parent::__construct($message);
    }
}
```

- [ ] **Step 2: 服务**

`app/service/aipet/GenerationService.php`：

```php
<?php
declare(strict_types=1);

namespace app\service\aipet;

use think\facade\Db;
use app\model\AipetCustomAsset;
use app\model\AipetCustomRequest;
use app\model\Setting;

/**
 * 定制宠物自动生成：生成程序（petgen worker）那一侧的全部状态变化
 * （设计 2026-10-10-aipet-custom-generation-design.md §3、§4.2–4.5）。
 * PHP 是唯一的数据源；生成程序只经 /internal/aipet/* 读写这里，返回值就是接口响应体。
 * 必须在 aipet 产品上下文里调用（内部接口控制器、aipet:reap 都用 CurrentProduct::runAs）。
 */
class GenerationService
{
    public const STATUS_KEY = 'aipet_worker_status';   // worker/status 上报的内容（JSON）
    public const SEEN_KEY   = 'aipet_worker_seen';     // 生成程序最后一次调内部接口的时间

    private const PATH_RE       = '#^(refs/)?[a-z0-9][a-z0-9_-]{0,47}\.(mp4|png|jpg|json)$#';
    private const CONTENT_TYPES = ['mp4' => 'video/mp4', 'png' => 'image/png', 'jpg' => 'image/jpeg', 'json' => 'application/json'];
    private const ONLINE_SECONDS = 120;

    private ?OssClient $oss;

    public function __construct(?OssClient $oss = null)
    {
        $this->oss = $oss ?? OssClient::fromConfig();
    }

    /** 套餐 code → 动作列表；不在 plan_actions 里的套餐按 standard。 */
    public static function planActions(?string $planCode): array
    {
        $map = (array) config('aipet.custom.plan_actions');
        return array_values((array) ($map[(string) $planCode] ?? $map['standard']));
    }

    /** 一单要交付必须有的文件。 */
    public static function requiredPaths(array $actions): array
    {
        $paths = ['pet.json', 'cover.png'];
        foreach ($actions as $a) {
            $paths[] = $a . '.mp4';
        }
        return $paths;
    }

    /**
     * 付款成功时建生成任务（CustomOrderService::markPaid 在 status 置 paid 之后、save 之前调）。
     * 不是狗猫的单（客户端与建单接口都拦了，正常不会有）直接 failed，免得永远排在队里。
     */
    public static function prepareOnPaid(AipetCustomRequest $r): void
    {
        $r->pet_id       = 'custom-' . $r->id;
        $r->actions      = self::planActions($r->plan_code);
        $r->budget_cents = (int) config('aipet.custom.budget_cents', 8000);
        $r->attempts     = 0;
        $r->redo         = null;
        if (! in_array((string) $r->species, AipetCustomRequest::GENERATABLE_SPECIES, true)) {
            $r->status      = AipetCustomRequest::STATUS_FAILED;
            $r->fail_reason = '该类别暂不支持自动生成，请人工处理或退款';
        }
    }

    // ---- 内部接口 ----

    /** POST jobs/claim */
    public function claim(): array
    {
        $status = $this->readStatus();
        if (! empty($status['paused'])) {
            return ['job' => null, 'paused_reason' => (string) ($status['reason'] ?? '')];
        }
        $oss = $this->requireOss();

        $r = Db::transaction(function () {
            $r = AipetCustomRequest::where('status', AipetCustomRequest::STATUS_PAID)
                ->whereIn('species', AipetCustomRequest::GENERATABLE_SPECIES)
                ->order('paid_at', 'asc')->order('id', 'asc')
                ->lock(true)->find();
            // 锁到之后再看一眼：并发领单时另一个已经把它改成 generating 了
            if (! $r || $r->status !== AipetCustomRequest::STATUS_PAID) {
                return null;
            }
            $now = date('Y-m-d H:i:s');
            if ((string) $r->pet_id === '') {
                $r->pet_id = 'custom-' . $r->id;
            }
            if (! $r->actions) {
                $r->actions = self::planActions($r->plan_code);
            }
            $r->status        = AipetCustomRequest::STATUS_GENERATING;
            $r->claimed_at    = $now;
            $r->heartbeat_at  = $now;
            $r->attempts      = (int) $r->attempts + 1;
            $r->stage         = 'claimed';
            $r->stage_done    = 0;
            $r->stage_total   = 0;
            $r->stage_message = '';
            $r->fail_reason   = null;
            $r->save();
            return $r;
        });
        if (! $r) {
            return ['job' => null];
        }

        $ttl = (int) config('aipet.custom.photo_url_ttl', 3600);

        return ['job' => [
            'id'           => (int) $r->id,
            'pet_id'       => (string) $r->pet_id,
            'name'         => (string) $r->name,
            'species'      => (string) $r->species,
            'actions'      => array_values((array) $r->actions),
            'redo'         => $r->redo ?: null,
            'budget_cents' => (int) $r->budget_cents,
            'spent_cents'  => (int) $r->cost_cents,
            'photos'       => array_map(
                fn ($k) => ['url' => $oss->signedGetUrl((string) $k, $ttl)],
                array_values((array) $r->photo_keys),
            ),
        ]];
    }

    /** POST jobs/:id/progress —— 花费是增量，不管状态都记上；不在 generating 就让生成程序停下。 */
    public function progress(int $id, array $body): array
    {
        $cost = is_array($body['cost'] ?? null) ? $body['cost'] : [];

        return Db::transaction(function () use ($id, $body, $cost) {
            $r = $this->job($id, true);
            $r->cost_image_units = (int) $r->cost_image_units + max(0, (int) ($cost['image_units'] ?? 0));
            $r->cost_video_units = (int) $r->cost_video_units + max(0, (int) ($cost['video_units'] ?? 0));
            $r->cost_cents       = (int) $r->cost_cents + max(0, (int) ($cost['cents'] ?? 0));

            if ($r->status !== AipetCustomRequest::STATUS_GENERATING) {
                $r->save();
                return ['abort' => true];
            }
            $r->stage         = mb_substr(trim((string) ($body['stage'] ?? '')), 0, 32);
            $r->stage_done    = max(0, (int) ($body['done'] ?? 0));
            $r->stage_total   = max(0, (int) ($body['total'] ?? 0));
            $r->stage_message = mb_substr((string) ($body['message'] ?? ''), 0, 255);
            $r->heartbeat_at  = date('Y-m-d H:i:s');
            $r->save();
            return ['abort' => false];
        });
    }

    /** POST jobs/:id/upload-urls → [{path, url}]（顶层数组） */
    public function uploadUrls(int $id, $files): array
    {
        $oss = $this->requireOss();
        $r   = $this->generatingJob($id);
        if (! is_array($files) || ! $files || count($files) > 50) {
            throw new GenerationError(422, 'files must be a non-empty list (max 50)');
        }
        $max = (int) config('aipet.custom.asset_max_bytes');
        $ttl = (int) config('aipet.custom.upload_url_ttl', 1800);

        $out = [];
        foreach ($files as $f) {
            $f     = is_array($f) ? $f : [];
            $path  = (string) ($f['path'] ?? '');
            $type  = (string) ($f['content_type'] ?? '');
            $bytes = (int) ($f['bytes'] ?? 0);
            $want  = $this->contentType($path);
            if ($type !== $want) {
                throw new GenerationError(422, "{$path}: content_type must be {$want}");
            }
            if ($bytes < 1 || $bytes > $max) {
                throw new GenerationError(422, "{$path}: bytes must be 1..{$max}");
            }
            $out[] = ['path' => $path, 'url' => $oss->signedPutUrl($this->objectKey($r, $path), $ttl, $type)];
        }
        return $out;
    }

    /** POST jobs/:id/finish */
    public function finish(int $id, string $walkFacing, $files): array
    {
        $oss = $this->requireOss();
        $r   = $this->generatingJob($id);
        if (! in_array($walkFacing, ['left', 'right'], true)) {
            throw new GenerationError(422, 'walk_facing must be left or right');
        }
        if (! is_array($files) || ! $files) {
            throw new GenerationError(422, 'files must be a non-empty list');
        }

        $rows = [];
        foreach ($files as $f) {
            $f     = is_array($f) ? $f : [];
            $path  = (string) ($f['path'] ?? '');
            $this->contentType($path);   // 校验路径
            if (isset($rows[$path])) {
                throw new GenerationError(422, "{$path}: duplicate path");
            }
            $bytes = (int) ($f['bytes'] ?? 0);
            $sha   = strtolower((string) ($f['sha256'] ?? ''));
            if ($bytes < 1) {
                throw new GenerationError(422, "{$path}: bytes must be > 0");
            }
            if (! preg_match('/^[0-9a-f]{64}$/', $sha)) {
                throw new GenerationError(422, "{$path}: sha256 must be 64 hex chars");
            }
            $key  = $this->objectKey($r, $path);
            $size = $oss->objectSize($key);
            if ($size === null) {
                throw new GenerationError(422, "{$path}: not uploaded");
            }
            if ($size !== $bytes) {
                throw new GenerationError(422, "{$path}: size mismatch (oss {$size}, reported {$bytes})");
            }
            $rows[$path] = [
                'path'        => $path,
                'object_key'  => $key,
                'bytes'       => $bytes,
                'sha256'      => $sha,
                'qa'          => is_array($f['qa'] ?? null) ? $f['qa'] : null,
                'deliverable' => (str_starts_with($path, 'refs/') || empty($f['deliverable'])) ? 0 : 1,
            ];
        }

        // 本次 + 已有（重做只传变了的文件）合起来必须齐，而且都下发
        $have = AipetCustomAsset::where('request_id', $r->id)->column('deliverable', 'path');
        foreach ($rows as $path => $row) {
            $have[$path] = $row['deliverable'];
        }
        $missing = [];
        foreach (self::requiredPaths((array) $r->actions) as $p) {
            if (empty($have[$p])) {
                $missing[] = $p;
            }
        }
        if ($missing) {
            throw new GenerationError(422, 'missing deliverable files: ' . implode(', ', $missing));
        }

        Db::transaction(function () use ($id, $rows, $walkFacing) {
            $r = $this->generatingJob($id, true);   // 锁住再判一次：后台可能刚改了状态
            foreach ($rows as $row) {
                $a = AipetCustomAsset::where('request_id', $r->id)->where('path', $row['path'])->find() ?: new AipetCustomAsset();
                $a->request_id  = (int) $r->id;
                $a->path        = $row['path'];
                $a->object_key  = $row['object_key'];
                $a->bytes       = $row['bytes'];
                $a->sha256      = $row['sha256'];
                $a->qa          = $row['qa'];
                $a->deliverable = $row['deliverable'];
                $a->save();
            }
            $now = date('Y-m-d H:i:s');
            $r->walk_facing   = $walkFacing;
            $r->status        = AipetCustomRequest::STATUS_REVIEW;
            $r->redo          = null;
            $r->review_at     = $now;
            $r->heartbeat_at  = $now;
            $r->stage         = 'review';
            $r->stage_message = '';
            $r->save();
        });

        return ['ok' => true];
    }

    /** POST jobs/:id/fail */
    public function fail(int $id, string $stage, string $reason): array
    {
        Db::transaction(function () use ($id, $stage, $reason) {
            $r = $this->generatingJob($id, true);
            $r->status      = AipetCustomRequest::STATUS_FAILED;
            $r->stage       = mb_substr(trim($stage), 0, 32);
            $r->fail_reason = mb_substr(trim($stage) . '：' . trim($reason), 0, 255);
            $r->save();
        });
        return ['ok' => true];
    }

    /** POST worker/status */
    public function reportStatus(array $body): array
    {
        $bal = is_array($body['balance'] ?? null) ? $body['balance'] : [];
        $this->writeSetting(self::STATUS_KEY, (string) json_encode([
            'paused'      => (bool) ($body['paused'] ?? false),
            'reason'      => mb_substr((string) ($body['reason'] ?? ''), 0, 255),
            'balance'     => [
                'image' => isset($bal['image']) ? (int) $bal['image'] : null,
                'video' => isset($bal['video']) ? (int) $bal['video'] : null,
            ],
            'reported_at' => date('Y-m-d H:i:s'),
        ], JSON_UNESCAPED_UNICODE));

        return ['ok' => true];
    }

    /** 每次内部接口调用都记一笔，后台概览据此判断在线。 */
    public function touchSeen(): void
    {
        $this->writeSetting(self::SEEN_KEY, date('Y-m-d H:i:s'));
    }

    // ---- 后台概览 ----

    public function workerStatus(): array
    {
        $s      = $this->readStatus();
        $seen   = (string) Setting::fetchValue(self::SEEN_KEY, '');
        $online = $seen !== '' && strtotime($seen) >= time() - self::ONLINE_SECONDS;
        [$state, $badge] = match (true) {
            $seen === ''          => ['从未连接', 'b-mut'],
            ! $online             => ['离线', 'b-bad'],
            ! empty($s['paused']) => ['已暂停：' . (string) ($s['reason'] ?? ''), 'b-warn'],
            default               => ['在线', 'b-ok'],
        };
        $bal   = is_array($s['balance'] ?? null) ? $s['balance'] : [];
        $count = fn (string $st): int => AipetCustomRequest::where('status', $st)->count();

        return [
            'state'         => $state,
            'badge'         => $badge,
            'seen_at'       => $seen !== '' ? $seen : '—',
            'balance_image' => isset($bal['image']) ? (string) $bal['image'] : '—',
            'balance_video' => isset($bal['video']) ? (string) $bal['video'] : '—',
            'reported_at'   => (string) ($s['reported_at'] ?? '—'),
            'queue'         => $count(AipetCustomRequest::STATUS_PAID),
            'generating'    => $count(AipetCustomRequest::STATUS_GENERATING),
            'review'        => $count(AipetCustomRequest::STATUS_REVIEW),
            'failed'        => $count(AipetCustomRequest::STATUS_FAILED),
        ];
    }

    // ---- 卡单回收（aipet:reap）----

    /** @return array{0: int, 1: int} [回到待生成的数量, 置为失败的数量] */
    public function reap(): array
    {
        $cutoff   = date('Y-m-d H:i:s', time() - (int) config('aipet.custom.heartbeat_timeout', 1200));
        $max      = (int) config('aipet.custom.max_attempts', 3);
        $requeued = 0;
        $failed   = 0;

        $ids = AipetCustomRequest::where('status', AipetCustomRequest::STATUS_GENERATING)
            ->where('heartbeat_at', '<', $cutoff)
            ->column('id');
        foreach ($ids as $id) {
            Db::transaction(function () use ($id, $cutoff, $max, &$requeued, &$failed) {
                $r = AipetCustomRequest::where('id', (int) $id)->lock(true)->find();
                // 锁到之后再判：这期间生成程序可能刚报过进度
                if (! $r || $r->status !== AipetCustomRequest::STATUS_GENERATING || (string) $r->heartbeat_at >= $cutoff) {
                    return;
                }
                if ((int) $r->attempts >= $max) {
                    $r->status      = AipetCustomRequest::STATUS_FAILED;
                    $r->fail_reason = '生成程序多次中断';
                    $failed++;
                } else {
                    $r->status        = AipetCustomRequest::STATUS_PAID;
                    $r->stage_message = '生成程序中断，等待重新领取';
                    $requeued++;
                }
                $r->save();
            });
        }

        return [$requeued, $failed];
    }

    // ---- 内部 ----

    private function requireOss(): OssClient
    {
        if ($this->oss === null) {
            throw new GenerationError(503, 'storage unconfigured');
        }
        return $this->oss;
    }

    private function job(int $id, bool $lock = false): AipetCustomRequest
    {
        $q = AipetCustomRequest::where('id', $id);
        $r = $lock ? $q->lock(true)->find() : $q->find();
        if (! $r) {
            throw new GenerationError(404, 'job not found');
        }
        return $r;
    }

    private function generatingJob(int $id, bool $lock = false): AipetCustomRequest
    {
        $r = $this->job($id, $lock);
        if ($r->status !== AipetCustomRequest::STATUS_GENERATING) {
            throw new GenerationError(409, 'job is ' . $r->status, true);
        }
        return $r;
    }

    /** 校验路径并返回它应有的 Content-Type。 */
    private function contentType(string $path): string
    {
        if (! preg_match(self::PATH_RE, $path, $m)) {
            throw new GenerationError(422, "bad path: {$path}");
        }
        return self::CONTENT_TYPES[$m[2]];
    }

    private function objectKey(AipetCustomRequest $r, string $path): string
    {
        return rtrim((string) config('aipet.custom.key_prefix'), '/') . '/' . (int) $r->user_id . '/' . (int) $r->id . '/' . $path;
    }

    private function readStatus(): array
    {
        $raw = Setting::fetchValue(self::STATUS_KEY, '');
        $s   = json_decode((string) $raw, true);
        return is_array($s) ? $s : [];
    }

    private function writeSetting(string $key, string $value): void
    {
        $row = Setting::where('key', $key)->find() ?: new Setting();
        $row->key   = $key;
        $row->value = $value;
        $row->save();
    }
}
```

- [ ] **Step 3: 语法与静态检查**

Run: `php -l app/service/aipet/GenerationError.php && php -l app/service/aipet/GenerationService.php`
Expected: 两个 `No syntax errors detected`

Run: `grep -n "Db::table\|Db::name\|whereOr" app/service/aipet/GenerationService.php`
Expected: 没有输出（坑 #16/#17）。

- [ ] **Step 4: Commit**

```bash
git add app/service/aipet/GenerationError.php app/service/aipet/GenerationService.php
git commit -m "AI 桌宠定制生成：领单、进度、上传地址、完成、失败、卡单回收的状态机——PHP 是唯一数据源，生成程序只按接口推进，并发领单与后台改状态都在行锁后判断" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 内部接口（`WorkerAuth` + 控制器 + 路由）

**Files:**
- Create: `app/middleware/WorkerAuth.php`
- Create: `app/controller/internal/AipetWorker.php`
- Modify: `route/app.php`

**Interfaces:**
- Consumes: Task 3 `GenerationService`、`GenerationError`；`config('aipet.worker.*')`；`app\model\Product`、`CurrentProduct::runAs`。
- Produces: 「内部接口契约」一节的 6 个接口：`POST /internal/aipet/jobs/claim`、`/jobs/:id/progress`、`/jobs/:id/upload-urls`、`/jobs/:id/finish`、`/jobs/:id/fail`、`/worker/status`。

- [ ] **Step 1: 中间件**

`app/middleware/WorkerAuth.php`：

```php
<?php
declare(strict_types=1);

namespace app\middleware;

use Closure;
use think\Request;
use think\Response;

/**
 * 内部接口（/internal/aipet/*）只认生成程序：X-Worker-Key 与 .env [AIPET] WORKER_KEY 用 hash_equals 比对；
 * 服务端没配密钥时一律 401（宁可不能用，也不能裸奔）。可选 WORKER_IPS（逗号分隔，空 = 不限）。
 * 来源 IP 用 $request->ip()：app\Request 只在本机反代转来时才信 X-Real-IP（见其注释）。
 */
class WorkerAuth
{
    public function handle(Request $request, Closure $next): Response
    {
        $key   = (string) config('aipet.worker.key', '');
        $given = (string) $request->header('x-worker-key', '');
        if ($key === '' || $given === '' || ! hash_equals($key, $given)) {
            return json(['error' => 'unauthorized'], 401);
        }

        $ips = array_values(array_filter(array_map('trim', explode(',', (string) config('aipet.worker.ips', '')))));
        if ($ips && ! in_array((string) $request->ip(), $ips, true)) {
            return json(['error' => 'forbidden'], 403);
        }

        return $next($request);
    }
}
```

- [ ] **Step 2: 控制器**

`app/controller/internal/AipetWorker.php`：

```php
<?php
declare(strict_types=1);

namespace app\controller\internal;

use think\Request;
use think\Response;
use think\facade\Log;
use app\model\Product;
use app\service\aipet\GenerationError;
use app\service\aipet\GenerationService;
use app\support\CurrentProduct;

/**
 * 生成程序（petgen worker）的内部接口（设计 2026-10-10 §4.3）。不走 ResolveProduct：
 * 这里自己找 aipet 产品，以它的身份执行（ProductScoped 照常生效）。
 * 不用 {code, message, data} 信封：成功直接回 GenerationService 的返回值，失败用 HTTP 状态码 + {error[, abort]}。
 */
class AipetWorker
{
    /** POST /internal/aipet/jobs/claim */
    public function claim(): Response
    {
        return $this->run(fn (GenerationService $g) => $g->claim());
    }

    /** POST /internal/aipet/jobs/:id/progress */
    public function progress(Request $request, $id): Response
    {
        return $this->run(fn (GenerationService $g) => $g->progress((int) $id, (array) $request->param()));
    }

    /** POST /internal/aipet/jobs/:id/upload-urls */
    public function uploadUrls(Request $request, $id): Response
    {
        return $this->run(fn (GenerationService $g) => $g->uploadUrls((int) $id, $request->param('files')));
    }

    /** POST /internal/aipet/jobs/:id/finish */
    public function finish(Request $request, $id): Response
    {
        return $this->run(fn (GenerationService $g) => $g->finish(
            (int) $id,
            (string) $request->param('walk_facing', ''),
            $request->param('files'),
        ));
    }

    /** POST /internal/aipet/jobs/:id/fail */
    public function fail(Request $request, $id): Response
    {
        return $this->run(fn (GenerationService $g) => $g->fail(
            (int) $id,
            (string) $request->param('stage', ''),
            (string) $request->param('reason', ''),
        ));
    }

    /** POST /internal/aipet/worker/status */
    public function status(Request $request): Response
    {
        return $this->run(fn (GenerationService $g) => $g->reportStatus((array) $request->param()));
    }

    private function run(callable $fn): Response
    {
        try {
            $product = Product::where('code', (string) config('aipet.product_code'))->find();
        } catch (\Throwable $e) {
            Log::error('[aipet-worker] 找 aipet 产品失败：' . $e->getMessage());
            return json(['error' => 'server error'], 500);
        }
        if (! $product) {
            return json(['error' => 'aipet product missing'], 500);
        }

        return CurrentProduct::runAs($product, function () use ($fn) {
            try {
                $g = new GenerationService();
                $g->touchSeen();
                return json($fn($g));
            } catch (GenerationError $e) {
                $body = ['error' => $e->getMessage()];
                if ($e->abort) {
                    $body['abort'] = true;
                }
                return json($body, $e->status);
            } catch (\Throwable $e) {
                Log::error('[aipet-worker] ' . $e->getMessage() . ' @ ' . $e->getFile() . ':' . $e->getLine());
                return json(['error' => 'server error'], 500);
            }
        });
    }
}
```

- [ ] **Step 3: 路由**

`route/app.php` 顶部 `use` 区（`use app\middleware\BlockSiteOnly;` 之后）加：

```php
use app\middleware\WorkerAuth;
```

在苹果服务器通知那组结束的这一行之后：

```php
})->middleware([ResolveProduct::class]);
```

插入（必须在 `$licenseRoutes` 和文件末尾 `:page` 兜底之前，坑 #26）：

```php

/*
 |--------------------------------------------------------------------------
 | 内部接口（AI 桌宠生成程序 petgen worker，设计 2026-10-10-aipet-custom-generation-design.md §4.3）
 |--------------------------------------------------------------------------
 | 不挂 session / CSRF / ResolveProduct / SetLocale；不挂 Throttle（全站按 IP 共享计数，
 | 生成程序每 15 秒领一次单，坑 #38）。WorkerAuth 认 X-Worker-Key（+ 可选 IP 白名单），
 | 控制器里以 aipet 产品身份执行。整组 completeMatch()（坑 #15）。
 */
Route::group('internal/aipet', function () {
    Route::post('jobs/claim',            'internal.AipetWorker/claim');
    Route::post('jobs/:id/progress',     'internal.AipetWorker/progress')->pattern(['id' => '\d+']);
    Route::post('jobs/:id/upload-urls',  'internal.AipetWorker/uploadUrls')->pattern(['id' => '\d+']);
    Route::post('jobs/:id/finish',       'internal.AipetWorker/finish')->pattern(['id' => '\d+']);
    Route::post('jobs/:id/fail',         'internal.AipetWorker/fail')->pattern(['id' => '\d+']);
    Route::post('worker/status',         'internal.AipetWorker/status');
})->completeMatch()->middleware([WorkerAuth::class]);
```

- [ ] **Step 4: 语法检查**

Run: `php -l app/middleware/WorkerAuth.php && php -l app/controller/internal/AipetWorker.php && php -l route/app.php`
Expected: 三个 `No syntax errors detected`

- [ ] **Step 5: 本地鉴权检查**

本机 `pixpickweb-tp/.env`（不入库）末尾加（用 Edit 工具）：

```
[AIPET]
WORKER_KEY = local-test-key
WORKER_IPS =
```

后台启动 `php think run --port 8089`，然后：

Run: `curl -s -w " %{http_code}\n" -X POST http://127.0.0.1:8089/internal/aipet/jobs/claim`
Expected: `{"error":"unauthorized"} 401`

Run: `curl -s -w " %{http_code}\n" -X POST -H "X-Worker-Key: wrong" http://127.0.0.1:8089/internal/aipet/jobs/claim`
Expected: `{"error":"unauthorized"} 401`

Run: `curl -s -w " %{http_code}\n" -X POST -H "X-Worker-Key: local-test-key" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:8089/internal/aipet/jobs/claim`
Expected: `{"error":"server error"} 500`（过了鉴权、进了控制器；本机没库，`runtime/log` 里有「[aipet-worker] 找 aipet 产品失败」）。若是 404 / HTML 页，说明路由没注册或被别的组吞了。

Run: `curl -s -w " %{http_code}\n" -X POST -H "X-Worker-Key: local-test-key" -d "{}" http://127.0.0.1:8089/internal/aipet/jobs/7/progress`
Expected: `{"error":"server error"} 500`（同上，说明 `:id` 路由匹配）。

把本机 `.env` 的 `WORKER_IPS` 改成 `10.9.9.9` 再跑第三条：
Expected: `{"error":"forbidden"} 403`。改回空。停掉 `php think run`。

- [ ] **Step 6: Commit**

```bash
git add app/middleware/WorkerAuth.php app/controller/internal/AipetWorker.php route/app.php
git commit -m "AI 桌宠定制生成：生成程序的内部接口——只认 WORKER_KEY（可加 IP 白名单），不走用户 token、不挂全站限流" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 卡单回收命令 `aipet:reap`

**Files:**
- Create: `app/command/AipetReap.php`
- Modify: `config/console.php`

**Interfaces:**
- Consumes: Task 3 `GenerationService::reap(): array{0:int,1:int}`。
- Produces: `php think aipet:reap`（crontab 每 5 分钟）。

- [ ] **Step 1: 命令**

`app/command/AipetReap.php`：

```php
<?php
declare(strict_types=1);

namespace app\command;

use app\model\Product;
use app\service\aipet\GenerationService;
use app\support\CurrentProduct;
use think\console\Command;
use think\console\Input;
use think\console\Output;

/**
 * AI 桌宠定制卡单回收（设计 2026-10-10 §4.4）：generating 且超过 20 分钟没心跳 → 回到待生成，
 * 本轮已领取 3 次仍卡住 → 生成失败（「生成程序多次中断」）。可重复执行。系统计划任务每 5 分钟跑一次：
 *   *\/5 * * * * cd /path/to/pixpickweb-tp && php think aipet:reap > /dev/null 2>&1
 */
class AipetReap extends Command
{
    protected function configure(): void
    {
        $this->setName('aipet:reap')->setDescription('AI 桌宠：回收卡住的定制生成任务');
    }

    protected function execute(Input $input, Output $output): int
    {
        $product = Product::where('code', (string) config('aipet.product_code'))->find();
        if (! $product) {
            $output->writeln('<error>找不到 aipet 产品（先跑 database/migrations/2026-10-02_aipet.sql）</error>');
            return 1;
        }

        // 命令行没有当前产品，以 aipet 身份执行，ProductScoped 照常生效
        [$requeued, $failed] = CurrentProduct::runAs($product, fn () => (new GenerationService())->reap());
        $output->writeln("Requeued {$requeued}, failed {$failed}.");

        return 0;
    }
}
```

（注释里 crontab 的 `*\/5` 是为了不提前结束 `/** */` 注释；README 里写成正常的 `*/5`。）

`config/console.php` 的 `'commands' => [...]` 里 `'aipet:rollup'` 那行之后加：

```php
        'aipet:reap'     => \app\command\AipetReap::class,
```

- [ ] **Step 2: 检查**

Run: `php -l app/command/AipetReap.php && php -l config/console.php`
Expected: 两个 `No syntax errors detected`

Run: `php think list | grep aipet`
Expected: 列出 `aipet:reap`（以及 `aipet:rollup`、`aipet:oss-check`）。本机没库，不要直接跑 `aipet:reap`（会报连库失败，属预期）。

- [ ] **Step 3: Commit**

```bash
git add app/command/AipetReap.php config/console.php
git commit -m "AI 桌宠定制生成：卡单回收命令——生成程序崩了或断网，单子不会永远卡在生成中，也不会无限重试" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 付款建任务、只开放狗猫

**Files:**
- Modify: `app/service/aipet/CustomOrderService.php`（`createRequest`、`markPaid`）
- Modify: `app/service/payment/Fulfillment.php`（注释）
- Modify: `app/controller/admin/Orders.php`（提示文字）
- Modify: `app/lang/zh-cn.php`, `app/lang/en-us.php`

**Interfaces:**
- Consumes: Task 1 `AipetCustomRequest::GENERATABLE_SPECIES`；Task 3 `GenerationService::prepareOnPaid(AipetCustomRequest $r): void`。
- Produces: 付款后定制单 `status = paid` 且 `pet_id/actions/budget_cents` 已写；`POST /api/aipet/custom/requests` 对 `species` 不是 dog/cat 返回 5010 `data.field = species`、message「该类别即将开放」。

- [ ] **Step 1: 文案**

`app/lang/zh-cn.php` 在 `'aipet.custom_bad_species'  => '请选择类别',` 之后加：

```php
    'aipet.custom_species_soon' => '该类别即将开放',
```

`app/lang/en-us.php` 在 `'aipet.custom_bad_species'  => 'Please choose a category',` 之后加：

```php
    'aipet.custom_species_soon' => 'This category is coming soon',
```

- [ ] **Step 2: 建单只收狗猫**

`app/service/aipet/CustomOrderService.php` 的 `createRequest()` 里，这段之后：

```php
        if (! array_key_exists($species, AipetCustomRequest::SPECIES)) {
            throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_bad_species'), 'species');
        }
```

加：

```php
        // 自动生成目前只支持狗、猫（设计 2026-10-10 §2、§9）；客户端也拦，这里兜底
        if (! in_array($species, AipetCustomRequest::GENERATABLE_SPECIES, true)) {
            throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_species_soon'), 'species');
        }
```

- [ ] **Step 3: 付款时建生成任务**

同文件 `markPaid()` 里，把：

```php
        $request->status      = AipetCustomRequest::STATUS_PAID;
        $request->paid_at     = date('Y-m-d H:i:s');
        $request->save();
```

换成：

```php
        $request->status      = AipetCustomRequest::STATUS_PAID;
        $request->paid_at     = date('Y-m-d H:i:s');
        // 建生成任务：pet_id、按套餐的动作、预算（设计 2026-10-10 §4.2）；生成程序只领 paid 的单
        GenerationService::prepareOnPaid($request);
        $request->save();
```

`markPaid()` 的注释改为：

```php
    /** 订单已付（Fulfillment 调，已在回调的事务与产品上下文里）：定制单进入待生成。幂等。 */
```

（`GenerationService` 与 `CustomOrderService` 同在 `app\service\aipet` 命名空间，不用加 `use`。`markPaid` 开头的 `$request->isPaid()` 判断现在包含 generating / review / delivered / failed，重复回调不会把已在生成的单打回 paid。）

- [ ] **Step 4: 履约注释与后台提示**

`app/service/payment/Fulfillment.php` 里下单计划加的注释：

```php
        // AI 桌宠定制：定制单置为已付，等后台人工制作（不开会员）
```

改为：

```php
        // AI 桌宠定制：定制单置为待生成，生成程序自动领取（不开会员）
```

`app/controller/admin/Orders.php` 里：

```php
            return $this->back($id, '已标记为已支付，对应的桌宠定制单已变为「待制作」。');
```

改为：

```php
            return $this->back($id, '已标记为已支付，对应的桌宠定制单已进入「待生成」，生成程序会自动领取。');
```

- [ ] **Step 5: 检查**

Run: `for f in app/service/aipet/CustomOrderService.php app/service/payment/Fulfillment.php app/controller/admin/Orders.php app/lang/zh-cn.php app/lang/en-us.php; do php -l $f; done`
Expected: 全部 `No syntax errors detected`

Run: `grep -n "待制作\|人工制作" app/ -r`
Expected: 只剩迁移里的说明（`app/` 下没有输出）。

- [ ] **Step 6: Commit**

```bash
git add app/service/aipet/CustomOrderService.php app/service/payment/Fulfillment.php app/controller/admin/Orders.php app/lang/zh-cn.php app/lang/en-us.php
git commit -m "AI 桌宠定制生成：付款即建生成任务，建单只收狗猫——人物和其他小宠还做不了，不能收了钱再说做不了" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: 客户端接口追加（列表新字段、`deliveries`、`assets`）

**Files:**
- Modify: `app/service/aipet/CustomOrderService.php`（`listRequests`，新增 `deliveries`、`assets`）
- Modify: `app/controller/api/aipet/Custom.php`
- Modify: `route/app.php`（受保护分组里的定制路由块）

**Interfaces:**
- Consumes: Task 1 `AipetCustomAsset`、`STATUS_DELIVERED`；下单计划的 `ownedRequest()`、`requireOss()`、`run()`。
- Produces（客户端下载器按这些调用，统一信封 `{code, message, data}`）：
  - `GET /api/aipet/custom/requests` 每单增加 `pet_id`（未付为 null）、`stage`（null 或字符串）、`stage_done`、`stage_total`（int）、`fail_reason`（仅 failed，否则 null）
  - `GET /api/aipet/custom/deliveries` → `[{id, pet_id, name, delivered_at}]`（本人所有 delivered，按 id 升序）
  - `GET /api/aipet/custom/requests/:id/assets` → `{pet_id, files: [{path, bytes, sha256, url}]}`，只含 `deliverable = 1`，url 为 1800 秒限时 GET；不是本人 / 不是 delivered → HTTP 404
  - `CustomOrderService::deliveries(User $user): array`、`assets(User $user, int $id): array`

- [ ] **Step 1: 列表加字段**

`CustomOrderService::listRequests()` 返回数组里，`'cover_url' => ...` 那一行之后加：

```php
                'pet_id'      => $r->pet_id ? (string) $r->pet_id : null,
                'stage'       => $r->stage ? (string) $r->stage : null,
                'stage_done'  => (int) $r->stage_done,
                'stage_total' => (int) $r->stage_total,
                'fail_reason' => $r->status === AipetCustomRequest::STATUS_FAILED ? (string) $r->fail_reason : null,
```

- [ ] **Step 2: 两个新方法**

同文件 `use` 区加 `use app\model\AipetCustomAsset;`，并在 `listRequests()` 之后加：

```php
    /** 本人所有已交付的定制宠物：客户端据此判断本机缺哪些（设计 2026-10-10 §4.6）。 */
    public function deliveries(User $user): array
    {
        $rows = AipetCustomRequest::where('user_id', $user->id)
            ->where('status', AipetCustomRequest::STATUS_DELIVERED)
            ->order('id', 'asc')->select();

        return array_map(fn (AipetCustomRequest $r) => [
            'id'           => (int) $r->id,
            'pet_id'       => (string) $r->pet_id,
            'name'         => (string) $r->name,
            'delivered_at' => (string) $r->delivered_at,
        ], $rows->all());
    }

    /** 已交付单的下发文件与限时下载地址；不是本人的、没交付的（含已退款）一律 404。 */
    public function assets(User $user, int $id): array
    {
        $oss = $this->requireOss();
        $r   = $this->ownedRequest($user, $id);
        if ($r->status !== AipetCustomRequest::STATUS_DELIVERED) {
            throw new CustomOrderError(404, 'not found');
        }
        $ttl   = (int) config('aipet.custom.asset_url_ttl', 1800);
        $files = AipetCustomAsset::where('request_id', $r->id)->where('deliverable', 1)->order('path', 'asc')->select();

        return [
            'pet_id' => (string) $r->pet_id,
            'files'  => array_map(fn (AipetCustomAsset $a) => [
                'path'   => (string) $a->path,
                'bytes'  => (int) $a->bytes,
                'sha256' => (string) $a->sha256,
                'url'    => $oss->signedGetUrl((string) $a->object_key, $ttl),
            ], $files->all()),
        ];
    }
```

- [ ] **Step 3: 控制器**

`app/controller/api/aipet/Custom.php` 在 `requests()` 方法之后加：

```php
    /** GET /api/aipet/custom/deliveries */
    public function deliveries(): Response
    {
        return $this->run(fn (CustomOrderService $s) => $s->deliveries(AuthHolder::user()));
    }

    /** GET /api/aipet/custom/requests/:id/assets */
    public function assets($id): Response
    {
        return $this->run(fn (CustomOrderService $s) => $s->assets(AuthHolder::user(), (int) $id));
    }
```

- [ ] **Step 4: 路由（顺便堵住前缀匹配）**

`api` 组**没有** `completeMatch()`：先注册的 `aipet/custom/requests` 会把 `/aipet/custom/requests/5/assets`（以及 POST 的 `/requests/5/order`）当成它自己（坑 #15）。把受保护分组里下单计划加的整块定制路由：

```php
        // AI 桌宠定制下单（设计 2026-10-02-aipet-custom-order-design.md）
        Route::get('aipet/custom/plans',              'api.aipet.Custom/plans');
        Route::post('aipet/custom/upload-tickets',    'api.aipet.Custom/tickets');
        Route::get('aipet/custom/requests',           'api.aipet.Custom/requests');
        Route::post('aipet/custom/requests',          'api.aipet.Custom/createRequest');
        Route::post('aipet/custom/requests/:id/order','api.aipet.Custom/order')->pattern(['id' => '\d+']);
        Route::get('aipet/custom/orders/:orderNo',    'api.aipet.Custom/orderStatus')->pattern(['orderNo' => '[A-Za-z0-9]+']);
```

替换为：

```php
        // AI 桌宠定制下单（2026-10-02-aipet-custom-order-design.md）+ 生成交付（2026-10-10-aipet-custom-generation-design.md）
        // api 组不是 completeMatch：短规则会吞掉长网址（坑 #15），所以长的写在前面、requests 两条单独 completeMatch
        Route::get('aipet/custom/plans',               'api.aipet.Custom/plans');
        Route::post('aipet/custom/upload-tickets',     'api.aipet.Custom/tickets');
        Route::get('aipet/custom/deliveries',          'api.aipet.Custom/deliveries');
        Route::get('aipet/custom/requests/:id/assets', 'api.aipet.Custom/assets')->pattern(['id' => '\d+']);
        Route::post('aipet/custom/requests/:id/order', 'api.aipet.Custom/order')->pattern(['id' => '\d+']);
        Route::get('aipet/custom/requests',            'api.aipet.Custom/requests')->completeMatch();
        Route::post('aipet/custom/requests',           'api.aipet.Custom/createRequest')->completeMatch();
        Route::get('aipet/custom/orders/:orderNo',     'api.aipet.Custom/orderStatus')->pattern(['orderNo' => '[A-Za-z0-9]+']);
```

- [ ] **Step 5: 检查**

Run: `php -l app/service/aipet/CustomOrderService.php && php -l app/controller/api/aipet/Custom.php && php -l route/app.php`
Expected: 全部 `No syntax errors detected`

`php think run --port 8089` 后：
Run: `for p in deliveries requests/5/assets requests; do curl -s -o /dev/null -w "$p %{http_code}\n" -H "Host: aipet.localhost" http://127.0.0.1:8089/api/aipet/custom/$p; done`
Expected: 三行都是 `401`（被 SanctumAuth 拦下，路由已注册；404 说明没进受保护分组）。真正的路由区分（assets 不被 requests 吞）在服务器清单第 14 条用 token 验证。停掉 `php think run`。

- [ ] **Step 6: Commit**

```bash
git add app/service/aipet/CustomOrderService.php app/controller/api/aipet/Custom.php route/app.php
git commit -m "AI 桌宠定制生成：客户端可查已交付清单与限时下载地址——只给本人已交付的单，退款后立即拿不到" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `ReviewService`（后台审核操作）

**Files:**
- Create: `app/service/aipet/ReviewService.php`

**Interfaces:**
- Consumes: Task 1 模型；Task 2 `OssClient::get / put / signedGetUrl`；Task 3 `GenerationError`、`GenerationService::requiredPaths()`。
- Produces（后台控制器 Task 9 调用；失败抛 `GenerationError`，message 直接作后台提示）：
  - `ReviewService::__construct(?OssClient $oss = null)`
  - `ACTION_LABELS`（动作 → 中文）
  - `panel(AipetCustomRequest $r): array` → `['gen' => array<string, string|bool>, 'actions' => list<{action,label,url,qa,size,updated_at}>, 'refs' => list<{path,url}>, 'cover' => string]`
  - `redo(int $id, array $actions, bool $refs, string $hint): void`（仅 review）
  - `regenerate(int $id): void`（review / failed）
  - `markFailed(int $id, string $reason): void`（paid / generating / review）
  - `setFacing(int $id, string $facing): void`（仅 review；`left` / `right`）
  - `deliver(int $id, string $admin): void`（仅 review；重写 `pet.json` 的 `walkFacing` 与 `id`，更新其 bytes / sha256）

- [ ] **Step 1: 服务**

`app/service/aipet/ReviewService.php`：

```php
<?php
declare(strict_types=1);

namespace app\service\aipet;

use think\facade\Db;
use app\model\AipetCustomAsset;
use app\model\AipetCustomRequest;

/**
 * 后台审核（设计 2026-10-10 §4.7）：看成品、单个动作重做、整单重新生成、标记失败、改朝向、交付。
 * 改状态的操作都在事务里锁行后再判断状态：双击「交付」、开着旧页面点「重做」，都只会得到一句提示。
 * 必须在 aipet 产品上下文里调用（后台 AdminAuth 已设好）。
 */
class ReviewService
{
    public const ACTION_LABELS = [
        'stand'    => '站立',
        'walk'     => '行走',
        'feed'     => '喂食',
        'play'     => '玩耍',
        'sleep'    => '休眠',
        'lick_paw' => '舔爪',
        'act_cute' => '卖萌',
    ];

    private ?OssClient $oss;

    public function __construct(?OssClient $oss = null)
    {
        $this->oss = $oss ?? OssClient::fromConfig();
    }

    /** 详情页「生成」面板的数据。值都是字符串 / 布尔，模板里不会碰到 null。 */
    public function panel(AipetCustomRequest $r): array
    {
        $ttl    = (int) config('aipet.custom.view_url_ttl', 600);
        $byPath = [];
        foreach (AipetCustomAsset::where('request_id', $r->id)->order('path', 'asc')->select()->all() as $a) {
            $byPath[(string) $a->path] = $a;
        }
        $url = fn (?AipetCustomAsset $a): string => ($a && $this->oss) ? $this->oss->signedGetUrl((string) $a->object_key, $ttl) : '';

        $actions = [];
        foreach ((array) $r->actions as $act) {
            $a = $byPath[$act . '.mp4'] ?? null;
            $actions[] = [
                'action'     => (string) $act,
                'label'      => self::ACTION_LABELS[$act] ?? (string) $act,
                'url'        => $url($a),
                'qa'         => ($a && $a->qa) ? (string) json_encode($a->qa, JSON_UNESCAPED_UNICODE) : '—',
                'size'       => $a ? round(((int) $a->bytes) / 1048576, 1) . ' MB' : '—',
                'updated_at' => $a ? (string) $a->updated_at : '—',
            ];
        }
        $refs = [];
        foreach ($byPath as $path => $a) {
            if (str_starts_with($path, 'refs/')) {
                $refs[] = ['path' => $path, 'url' => $url($a)];
            }
        }

        $s     = (string) $r->status;
        $start = $r->claimed_at ? (int) strtotime((string) $r->claimed_at) : 0;
        $end   = $s === AipetCustomRequest::STATUS_GENERATING ? time() : ($r->review_at ? (int) strtotime((string) $r->review_at) : 0);

        $progress = '—';
        if ((string) $r->stage !== '') {
            $progress = (string) $r->stage . ((int) $r->stage_total > 0 ? ' ' . (int) $r->stage_done . '/' . (int) $r->stage_total : '');
            if ((string) $r->stage_message !== '') {
                $progress .= ' · ' . $r->stage_message;
            }
        }

        return [
            'gen' => [
                'has_task'       => (string) $r->pet_id !== '',
                'pet_id'         => (string) $r->pet_id,
                'progress'       => $progress,
                'heartbeat_at'   => (string) ($r->heartbeat_at ?: '—'),
                'elapsed'        => ($start && $end >= $start) ? self::duration($end - $start) : '—',
                'cost'           => number_format(((int) $r->cost_cents) / 100, 2),
                'budget'         => number_format(((int) $r->budget_cents) / 100, 2),
                'image_units'    => (string) (int) $r->cost_image_units,
                'video_units'    => (string) (int) $r->cost_video_units,
                'attempts'       => (string) (int) $r->attempts,
                'fail_reason'    => (string) $r->fail_reason,
                'redo'           => $r->redo ? (string) json_encode($r->redo, JSON_UNESCAPED_UNICODE) : '—',
                'walk_facing'    => $r->walk_facing === 'left' ? 'left' : 'right',
                'delivered_at'   => (string) $r->delivered_at,
                'delivered_by'   => (string) $r->delivered_by,
                'can_deliver'    => $s === AipetCustomRequest::STATUS_REVIEW,
                'can_redo'       => $s === AipetCustomRequest::STATUS_REVIEW,
                'can_facing'     => $s === AipetCustomRequest::STATUS_REVIEW,
                'can_regenerate' => in_array($s, [AipetCustomRequest::STATUS_REVIEW, AipetCustomRequest::STATUS_FAILED], true),
                'can_fail'       => in_array($s, [AipetCustomRequest::STATUS_PAID, AipetCustomRequest::STATUS_GENERATING, AipetCustomRequest::STATUS_REVIEW], true),
            ],
            'actions' => $actions,
            'refs'    => $refs,
            'cover'   => $url($byPath['cover.png'] ?? null),
        ];
    }

    /** 审核时重做选中的动作（refs = true 时连参考图一起，依赖它的动作由生成程序一并重做）。 */
    public function redo(int $id, array $actions, bool $refs, string $hint): void
    {
        Db::transaction(function () use ($id, $actions, $refs, $hint) {
            $r = $this->locked($id);
            $this->expect($r, [AipetCustomRequest::STATUS_REVIEW], '只有「待审核」的单可以重做动作');
            $picked = array_values(array_intersect((array) $r->actions, array_map('strval', $actions)));
            if (! $picked && ! $refs) {
                throw new GenerationError(422, '请至少勾选一个动作，或勾选「参考图也重做」。');
            }
            $this->requeue($r, ['actions' => $picked, 'refs' => $refs, 'hint' => mb_substr(trim($hint), 0, 200)], '后台要求重做');
        });
    }

    /** 整单重新生成（review / failed）。 */
    public function regenerate(int $id): void
    {
        Db::transaction(function () use ($id) {
            $r = $this->locked($id);
            $this->expect($r, [AipetCustomRequest::STATUS_REVIEW, AipetCustomRequest::STATUS_FAILED], '只有「待审核」或「生成失败」的单可以整单重新生成');
            $this->requeue($r, ['all' => true], '后台要求整单重新生成');
        });
    }

    /** 标记失败（paid / generating / review）；生成中的单，生成程序下次报进度会收到 abort。 */
    public function markFailed(int $id, string $reason): void
    {
        Db::transaction(function () use ($id, $reason) {
            $r = $this->locked($id);
            $this->expect($r, [AipetCustomRequest::STATUS_PAID, AipetCustomRequest::STATUS_GENERATING, AipetCustomRequest::STATUS_REVIEW], '这一单当前不能标记失败');
            $reason         = trim($reason);
            $r->status      = AipetCustomRequest::STATUS_FAILED;
            $r->fail_reason = mb_substr('后台标记失败' . ($reason !== '' ? '：' . $reason : ''), 0, 255);
            $r->save();
        });
    }

    /** 审核时改行走朝向（交付时写进 pet.json）。 */
    public function setFacing(int $id, string $facing): void
    {
        if (! in_array($facing, ['left', 'right'], true)) {
            throw new GenerationError(422, '朝向只能是 left 或 right。');
        }
        Db::transaction(function () use ($id, $facing) {
            $r = $this->locked($id);
            $this->expect($r, [AipetCustomRequest::STATUS_REVIEW], '只有「待审核」的单可以改朝向');
            $r->walk_facing = $facing;
            $r->save();
        });
    }

    /** 交付：重写 pet.json（审核后的 walkFacing），更新其 sha256，置 delivered。 */
    public function deliver(int $id, string $admin): void
    {
        if ($this->oss === null) {
            throw new GenerationError(503, 'OSS 未配置，不能交付。');
        }
        $oss = $this->oss;

        Db::transaction(function () use ($id, $admin, $oss) {
            $r = $this->locked($id);
            if ($r->status === AipetCustomRequest::STATUS_DELIVERED) {
                throw new GenerationError(409, '这一单已经交付过了。');
            }
            $this->expect($r, [AipetCustomRequest::STATUS_REVIEW], '只有「待审核」的单可以交付');

            $have    = AipetCustomAsset::where('request_id', $r->id)->where('deliverable', 1)->column('path');
            $missing = array_values(array_diff(GenerationService::requiredPaths((array) $r->actions), $have));
            if ($missing) {
                throw new GenerationError(409, '成品不全，不能交付：缺 ' . implode('、', $missing));
            }

            $pj  = AipetCustomAsset::where('request_id', $r->id)->where('path', 'pet.json')->find();
            $raw = $oss->get((string) $pj->object_key);
            $doc = $raw !== null ? json_decode($raw, true) : null;
            if (! is_array($doc)) {
                throw new GenerationError(500, '读不到 OSS 上的 pet.json（或不是合法 JSON），未交付。');
            }
            $doc['id']         = (string) $r->pet_id;
            $doc['walkFacing'] = $r->walk_facing === 'left' ? 'left' : 'right';
            $body = json_encode($doc, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n";
            if (! $oss->put((string) $pj->object_key, $body, 'application/json')) {
                throw new GenerationError(500, '写回 pet.json 失败，未交付。');
            }
            $pj->bytes  = strlen($body);
            $pj->sha256 = hash('sha256', $body);
            $pj->save();

            $r->status       = AipetCustomRequest::STATUS_DELIVERED;
            $r->delivered_at = date('Y-m-d H:i:s');
            $r->delivered_by = mb_substr($admin, 0, 64);
            $r->stage        = 'delivered';
            $r->save();
        });
    }

    // ---- 内部 ----

    private function locked(int $id): AipetCustomRequest
    {
        $r = AipetCustomRequest::where('id', $id)->lock(true)->find();
        if (! $r) {
            throw new GenerationError(404, '定制单不存在。');
        }
        return $r;
    }

    private function expect(AipetCustomRequest $r, array $states, string $message): void
    {
        if (! in_array($r->status, $states, true)) {
            $label = AipetCustomRequest::STATUS_LABELS[$r->status] ?? (string) $r->status;
            throw new GenerationError(409, $message . '（当前：' . $label . '）。');
        }
    }

    /** 回到待生成：带上重做内容，再给一份预算（已花 + 单笔预算），本轮领取次数清零。 */
    private function requeue(AipetCustomRequest $r, array $redo, string $why): void
    {
        $r->redo          = $redo;
        $r->status        = AipetCustomRequest::STATUS_PAID;
        $r->attempts      = 0;
        $r->budget_cents  = (int) $r->cost_cents + (int) config('aipet.custom.budget_cents', 8000);
        $r->fail_reason   = null;
        $r->stage         = 'queued';
        $r->stage_done    = 0;
        $r->stage_total   = 0;
        $r->stage_message = $why;
        $r->save();
    }

    private static function duration(int $seconds): string
    {
        if ($seconds >= 3600) {
            return intdiv($seconds, 3600) . ' 小时 ' . intdiv($seconds % 3600, 60) . ' 分';
        }
        return intdiv($seconds, 60) . ' 分 ' . ($seconds % 60) . ' 秒';
    }
}
```

- [ ] **Step 2: 检查**

Run: `php -l app/service/aipet/ReviewService.php`
Expected: `No syntax errors detected`

Run: `grep -n "Db::table\|Db::name\|whereOr" app/service/aipet/ReviewService.php`
Expected: 没有输出。

- [ ] **Step 3: Commit**

```bash
git add app/service/aipet/ReviewService.php
git commit -m "AI 桌宠定制生成：后台审核操作——重做、重新生成、标记失败、改朝向、交付都锁行判状态，双击交付或对生成中的单点重做不会出错乱" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: 后台生成面板、待审核角标、概览生成程序状态

**Files:**
- Modify: `app/controller/admin/AipetCustom.php`（`index` 状态文字、`show` 重写、5 个新动作）
- Modify: `app/view/admin/aipet/custom_show.html`（整文件替换）
- Modify: `app/view/admin/aipet/custom.html`
- Modify: `route/app.php`（后台组）
- Modify: `app/common.php`, `app/view/admin/layout.html`
- Modify: `app/controller/admin/Aipet.php`, `app/view/admin/aipet/index.html`
- Create（不入库，`runtime/` 已被忽略）: `runtime/tplcheck.php`

**Interfaces:**
- Consumes: Task 8 `ReviewService`（`panel/redo/regenerate/markFailed/setFacing/deliver`）、`GenerationError`；Task 3 `GenerationService::workerStatus()`；`admin_user(): ?string`、`flash_set()`。
- Produces: 路由 `POST /admin/aipet/custom/:id/{deliver,redo,regenerate,fail,facing}`；全局函数 `aipet_custom_review_count(): int`。

- [ ] **Step 1: 控制器**

`app/controller/admin/AipetCustom.php`：

1. `use` 区加：

```php
use think\facade\Log;
use app\service\aipet\GenerationError;
use app\service\aipet\ReviewService;
```

2. `index()` 的 `$list = array_map(...)` 里把：

```php
            'status_label' => AipetCustomRequest::STATUS_LABELS[$r->status] ?? $r->status,
```

换成：

```php
            'status_label' => self::statusText($r),
```

3. 整个 `show()` 方法替换为：

```php
    public function show($id): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $r = AipetCustomRequest::find((int) $id);
        if (! $r) {
            return response('Not Found', 404);
        }
        $oss    = OssClient::fromConfig();
        $ttl    = (int) config('aipet.custom.view_url_ttl', 600);
        $photos = array_map(fn ($k) => ['key' => $k, 'url' => $oss ? $oss->signedGetUrl((string) $k, $ttl) : ''], (array) $r->photo_keys);
        $plan   = $r->plan_code ? AipetPlan::where('code', $r->plan_code)->find() : null;
        $user   = User::find((int) $r->user_id);
        $panel  = (new ReviewService($oss))->panel($r);

        // 提示（flash）由 layout 统一显示，这里不再取
        return view('admin/aipet/custom_show.html', [
            'title'        => '定制订单 #' . $r->id,
            'active'       => 'aipet_custom',
            'r'            => $r,
            'species'      => AipetCustomRequest::SPECIES[$r->species] ?? $r->species,
            'status_label' => self::statusText($r),
            'plan_name'    => $plan ? $plan->name : ($r->plan_code ?: '—'),
            'price'        => $r->price_cents !== null ? number_format($r->price_cents / 100, 2) : '—',
            'phone'        => $user ? AipetProduct::maskPhone($user->phone) : '—',
            'user_id'      => $r->user_id,
            'photos'       => $photos,
            'oss_ok'       => $oss !== null,
            'gen'          => $panel['gen'],
            'actions'      => $panel['actions'],
            'refs'         => $panel['refs'],
            'cover'        => $panel['cover'],
        ]);
    }
```

4. 在 `note()` 方法之后加：

```php
    // ---- 生成审核（设计 2026-10-10 §4.7）----

    public function deliver($id): Response
    {
        return $this->review($id, fn (ReviewService $s) => $s->deliver((int) $id, (string) admin_user()),
            '已交付，用户登录的客户端会自动下载。');
    }

    public function redo(Request $request, $id): Response
    {
        $actions = (array) $request->post('actions/a', []);
        return $this->review($id, fn (ReviewService $s) => $s->redo(
            (int) $id,
            $actions,
            (bool) $request->post('refs', ''),
            (string) $request->post('hint', ''),
        ), '已安排重做，生成程序会自动领取。');
    }

    public function regenerate($id): Response
    {
        return $this->review($id, fn (ReviewService $s) => $s->regenerate((int) $id),
            '已安排整单重新生成，生成程序会自动领取。');
    }

    public function fail(Request $request, $id): Response
    {
        return $this->review($id, fn (ReviewService $s) => $s->markFailed((int) $id, mb_substr((string) $request->post('reason', ''), 0, 100)),
            '已标记为生成失败。需要退款请到订单管理操作该订单。');
    }

    public function facing(Request $request, $id): Response
    {
        $facing = (string) $request->post('facing', '');
        return $this->review($id, fn (ReviewService $s) => $s->setFacing((int) $id, $facing),
            '行走朝向已改为' . ($facing === 'left' ? '朝左' : '朝右') . '，交付时写进 pet.json。');
    }

    /** 审核操作的公共外壳：成功 / 失败都 flash，回详情页。 */
    private function review($id, callable $fn, string $ok): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        try {
            $fn(new ReviewService());
            flash_set('status', $ok);
        } catch (GenerationError $e) {
            flash_set('admin_error', $e->getMessage());
        } catch (\Throwable $e) {
            Log::error('[aipet] 定制审核操作失败 #' . (int) $id . '：' . $e->getMessage());
            flash_set('admin_error', '操作失败：' . $e->getMessage());
        }
        return redirect('/admin/aipet/custom/' . (int) $id);
    }

    /** 列表 / 详情显示的状态：生成中带进度。 */
    private static function statusText(AipetCustomRequest $r): string
    {
        $label = AipetCustomRequest::STATUS_LABELS[$r->status] ?? (string) $r->status;
        if ($r->status === AipetCustomRequest::STATUS_GENERATING && (int) $r->stage_total > 0) {
            $label .= ' ' . (int) $r->stage_done . '/' . (int) $r->stage_total;
        }
        return $label;
    }
```

- [ ] **Step 2: 详情页（整文件替换）**

`app/view/admin/aipet/custom_show.html`：

```html
{extend name="admin/layout" /}
{block name="content"}
<div style="margin-bottom:14px"><a class="link" href="/admin/aipet/custom">← 返回定制订单</a></div>

<div class="panel">
    <h2>定制单 #{$r.id} · {$status_label}</h2>
    <div class="kv">
        <div class="k">名字</div><div>{$r.name}</div>
        <div class="k">类别</div><div>{$species}</div>
        <div class="k">套餐</div><div>{$plan_name}（{$price} 元）</div>
        <div class="k">订单号</div><div>{$r.order_no|default='—'}</div>
        <div class="k">用户</div><div><a class="link" href="/admin/users/{$user_id}">#{$user_id}</a> {$phone}</div>
        <div class="k">宠物 ID</div><div>{$gen.pet_id|default='—'}</div>
        <div class="k">付款时间</div><div class="muted">{$r.paid_at|default='—'}</div>
        <div class="k">创建时间</div><div class="muted">{$r.created_at}</div>
    </div>
</div>

<div class="panel">
    <h2>生成</h2>
    {if $gen.has_task}
    <div class="kv">
        <div class="k">进度</div><div>{$gen.progress}</div>
        <div class="k">最后心跳</div><div class="muted">{$gen.heartbeat_at}</div>
        <div class="k">耗时</div><div>{$gen.elapsed}</div>
        <div class="k">花费</div><div>{$gen.cost} 元 / 预算 {$gen.budget} 元 <span class="muted">（图片 {$gen.image_units} 单位 · 视频 {$gen.video_units} 单位）</span></div>
        <div class="k">本轮领取次数</div><div>{$gen.attempts}</div>
        <div class="k">待重做</div><div class="muted">{$gen.redo}</div>
        {if $gen.fail_reason}<div class="k">失败原因</div><div style="color:#fca5a5">{$gen.fail_reason}</div>{/if}
        {if $gen.delivered_at}<div class="k">交付</div><div>{$gen.delivered_at} · {$gen.delivered_by}</div>{/if}
    </div>
    {else /}
    <p class="muted">还没付款，没有生成任务。</p>
    {/if}
</div>

<div class="panel">
    <h2>用户照片 / 参考图 / 封面（链接 10 分钟内有效，过期刷新本页）</h2>
    {if !$oss_ok}<p class="muted">OSS 未配置，无法查看。</p>{/if}
    <div class="row" style="align-items:flex-start;gap:28px">
        <div>
            <label>用户照片</label>
            <div style="display:flex;gap:10px;flex-wrap:wrap">
            {volist name="photos" id="ph"}
                {if $ph.url}
                <a href="{$ph.url}" target="_blank" rel="noopener"><img src="{$ph.url}" style="width:180px;height:180px;object-fit:cover;border-radius:8px;border:1px solid #2a2f3a"></a>
                {else /}<code>{$ph.key}</code>{/if}
            {/volist}
            </div>
        </div>
        <div>
            <label>生成的参考图</label>
            <div style="display:flex;gap:10px;flex-wrap:wrap">
            {volist name="refs" id="rf"}
                <a href="{$rf.url}" target="_blank" rel="noopener" title="{$rf.path}"><img src="{$rf.url}" style="width:180px;height:180px;object-fit:contain;background:#fff;border-radius:8px"></a>
            {/volist}
            {empty name="refs"}<span class="muted">暂无</span>{/empty}
            </div>
        </div>
        <div>
            <label>封面</label>
            {if $cover}<img src="{$cover}" style="width:180px;height:180px;object-fit:contain;background:#fff;border-radius:8px">{else /}<span class="muted">暂无</span>{/if}
        </div>
    </div>
</div>

<div class="panel">
    <h2>动作</h2>
    <form method="post" action="/admin/aipet/custom/{$r.id}/redo">
        <input type="hidden" name="__token__" value="{:csrf_token()}">
        <div style="display:flex;gap:14px;flex-wrap:wrap">
        {volist name="actions" id="a"}
            <div style="width:240px;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:10px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
                    <strong>{$a.label}</strong><span class="muted">{$a.action}</span>
                </div>
                {if $a.url}
                <video src="{$a.url}" controls loop muted playsinline preload="metadata" style="width:100%;border-radius:6px;background:#0b0d12"></video>
                {else /}
                <div class="muted" style="height:120px;display:flex;align-items:center;justify-content:center">还没有成品</div>
                {/if}
                <div class="muted" style="font-size:12px;margin-top:6px;word-break:break-all">质检：{$a.qa}</div>
                <div class="muted" style="font-size:12px">{$a.size} · {$a.updated_at}</div>
                {if $gen.can_redo}<label style="margin-top:6px"><input type="checkbox" name="actions[]" value="{$a.action}"> 重做这个动作</label>{/if}
            </div>
        {/volist}
        {empty name="actions"}<span class="muted">还没有动作（未付款）。</span>{/empty}
        </div>
        {if $gen.can_redo}
        <div class="row" style="margin-top:14px">
            <div style="flex:1;min-width:260px">
                <label>补充提示（可空，交给生成程序）</label>
                <input name="hint" maxlength="200" style="width:100%" placeholder="如：尾巴摆慢一点">
            </div>
            <label style="margin-bottom:10px"><input type="checkbox" name="refs" value="1"> 参考图也重做（依赖它的动作都会重做）</label>
            <button class="btn" type="submit">重做勾选的</button>
        </div>
        {/if}
    </form>
</div>

<div class="panel">
    <h2>审核</h2>
    <div class="actions" style="align-items:center">
        <span class="muted">行走朝向（看「行走」视频里脸朝哪边）：</span>
        {if $gen.can_facing}
        <form method="post" action="/admin/aipet/custom/{$r.id}/facing" class="inline">
            <input type="hidden" name="__token__" value="{:csrf_token()}">
            <button class="btn {if $gen.walk_facing == 'left'}btn-pri{/if}" name="facing" value="left" type="submit">← 朝左</button>
            <button class="btn {if $gen.walk_facing == 'right'}btn-pri{/if}" name="facing" value="right" type="submit">朝右 →</button>
        </form>
        {else /}
        <span>{if $gen.walk_facing == 'left'}朝左{else /}朝右{/if}</span>
        {/if}
    </div>
    <div class="actions" style="margin-top:14px">
        {if $gen.can_deliver}
        <form method="post" action="/admin/aipet/custom/{$r.id}/deliver" class="inline" onsubmit="return confirm('确认交付？用户的客户端会自动下载。')">
            <input type="hidden" name="__token__" value="{:csrf_token()}">
            <button class="btn btn-pri" type="submit">交付</button>
        </form>
        {/if}
        {if $gen.can_regenerate}
        <form method="post" action="/admin/aipet/custom/{$r.id}/regenerate" class="inline" onsubmit="return confirm('整单重新生成会再花一份钱，确认？')">
            <input type="hidden" name="__token__" value="{:csrf_token()}">
            <button class="btn" type="submit">整单重新生成</button>
        </form>
        {/if}
        {if $gen.can_fail}
        <form method="post" action="/admin/aipet/custom/{$r.id}/fail" class="inline" onsubmit="return confirm('标记为生成失败？')">
            <input type="hidden" name="__token__" value="{:csrf_token()}">
            <input name="reason" maxlength="100" placeholder="失败原因（可空）">
            <button class="btn btn-bad" type="submit">标记失败</button>
        </form>
        {/if}
        {if $r.order_no}<a class="btn" href="/admin/orders?q={$r.order_no}">去订单管理（退款）</a>{/if}
    </div>
    <form method="post" action="/admin/aipet/custom/{$r.id}/note" style="margin-top:18px">
        <input type="hidden" name="__token__" value="{:csrf_token()}">
        <label>备注（仅后台可见）</label>
        <textarea name="admin_note" rows="4" style="width:100%">{$r.admin_note}</textarea>
        <button class="btn" type="submit" style="margin-top:8px">保存备注</button>
    </form>
</div>
{/block}
```

- [ ] **Step 3: 列表页**

`app/view/admin/aipet/custom.html` 里把：

```html
                <td>{$r.status_label}</td>
```

换成（待审核醒目一点）：

```html
                <td>{if $r.status == 'review'}<span class="badge b-warn">{$r.status_label}</span>{elseif $r.status == 'failed' /}<span class="badge b-bad">{$r.status_label}</span>{else /}{$r.status_label}{/if}</td>
```

- [ ] **Step 4: 后台路由**

`route/app.php` 后台分组里，`Route::post('aipet/custom/:id/note', ...)` 那行之后加：

```php
        Route::post('aipet/custom/:id/deliver',    'admin.AipetCustom/deliver')->pattern(['id' => '\d+']);
        Route::post('aipet/custom/:id/redo',       'admin.AipetCustom/redo')->pattern(['id' => '\d+']);
        Route::post('aipet/custom/:id/regenerate', 'admin.AipetCustom/regenerate')->pattern(['id' => '\d+']);
        Route::post('aipet/custom/:id/fail',       'admin.AipetCustom/fail')->pattern(['id' => '\d+']);
        Route::post('aipet/custom/:id/facing',     'admin.AipetCustom/facing')->pattern(['id' => '\d+']);
```

- [ ] **Step 5: 待审核角标**

`app/common.php` 在 `aipet_mode()` 那个 `if (! function_exists('aipet_mode')) { ... }` 块之后加：

```php

if (! function_exists('aipet_custom_review_count')) {
    /**
     * 当前产品待审核的定制单数（后台侧栏「定制订单」角标，布局每页调一次）。
     * 不是 aipet 产品、或表 / 列还没建（迁移未执行），一律 0，不让后台整体挂掉。
     */
    function aipet_custom_review_count(): int
    {
        try {
            return \app\support\AipetProduct::enabled()
                ? \app\model\AipetCustomRequest::where('status', \app\model\AipetCustomRequest::STATUS_REVIEW)->count()
                : 0;
        } catch (\Throwable) {
            return 0;
        }
    }
}
```

`app/view/admin/layout.html` 里下单计划加的：

```html
            <a href="/admin/aipet/custom" class="{if $active=='aipet_custom'}on{/if}">定制订单</a>
```

换成：

```html
            <a href="/admin/aipet/custom" class="{if $active=='aipet_custom'}on{/if}">
                <span>定制订单</span>
                {php}$__aipetReview = aipet_custom_review_count();{/php}
                {if $__aipetReview > 0}<span class="nav-dot">{$__aipetReview}</span>{/if}
            </a>
```

- [ ] **Step 6: 概览显示生成程序状态**

`app/controller/admin/Aipet.php`：`use` 区加 `use app\service\aipet\GenerationService;`；`index()` 的 `view('admin/aipet/index.html', [...])` 参数里 `'rolledUp' => ...` 那行之后加：

```php
            'worker'    => (new GenerationService())->workerStatus(),
```

`app/view/admin/aipet/index.html` 在第二行 `{block name="content"}` 之后插入：

```html
<div class="panel">
    <h2>定制生成程序</h2>
    <div class="kv">
        <div class="k">状态</div><div><span class="badge {$worker.badge}">{$worker.state}</span></div>
        <div class="k">最后心跳</div><div class="muted">{$worker.seen_at}</div>
        <div class="k">可灵余额</div><div>图片 {$worker.balance_image} · 视频 {$worker.balance_video} <span class="muted">（上报于 {$worker.reported_at}）</span></div>
        <div class="k">定制单</div>
        <div>排队 {$worker.queue} · 生成中 {$worker.generating} ·
            <a class="link" href="/admin/aipet/custom?status=review">待审核 {$worker.review}</a> ·
            <a class="link" href="/admin/aipet/custom?status=failed">失败 {$worker.failed}</a></div>
    </div>
</div>
```

- [ ] **Step 7: 模板编译检查脚本（不入库）**

`runtime/tplcheck.php`（`runtime/` 整个被 `.gitignore` 忽略）：

```php
<?php
// 只编译模板并对编译结果做语法检查，不真正渲染（本机没数据库，渲染会因缺变量 / 函数报错，那些忽略）。
// 用法：php runtime/tplcheck.php admin/aipet/custom_show admin/aipet/custom admin/aipet/index
require __DIR__ . '/../vendor/autoload.php';

$dir = __DIR__ . '/tplcheck/';
if (! is_dir($dir)) {
    mkdir($dir, 0777, true);
}
foreach (glob($dir . '*.php') ?: [] as $old) {
    unlink($old);
}

$tpl = new \think\Template([
    'view_path'   => dirname(__DIR__) . '/app/view/',
    'cache_path'  => $dir,
    'view_suffix' => 'html',
]);

$bad = 0;
foreach (array_slice($argv, 1) as $name) {
    $level = ob_get_level();
    $err   = null;
    ob_start();
    try {
        $tpl->fetch($name, []);
    } catch (\ParseError $e) {
        $err = $e;
    } catch (\Throwable $e) {
        // 缺变量、缺函数（csrf_token 等）——编译已完成，忽略
    }
    while (ob_get_level() > $level) {
        ob_end_clean();
    }
    if ($err) {
        $bad++;
        echo "✗ {$name}: " . $err->getMessage() . ' line ' . $err->getLine() . PHP_EOL;
    } else {
        echo "✓ {$name} 已编译" . PHP_EOL;
    }
}

foreach (glob($dir . '*.php') ?: [] as $f) {
    $out = [];
    exec('php -l ' . escapeshellarg($f), $out, $code);
    if ($code !== 0) {
        $bad++;
        echo implode(PHP_EOL, $out) . PHP_EOL;
    }
}
echo $bad ? "有 {$bad} 处问题" . PHP_EOL : '编译结果全部通过 php -l' . PHP_EOL;
exit($bad ? 1 : 0);
```

- [ ] **Step 8: 检查**

Run: `for f in app/controller/admin/AipetCustom.php app/controller/admin/Aipet.php app/common.php route/app.php; do php -l $f; done`
Expected: 全部 `No syntax errors detected`

Run: `php runtime/tplcheck.php admin/aipet/custom_show admin/aipet/custom admin/aipet/index`
Expected: 三行 `✓ … 已编译`，最后一行「编译结果全部通过 php -l」，退出码 0。

Run: `php think run --port 8089` 后
`curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Host: aipet.localhost" http://127.0.0.1:8089/admin/aipet/custom/1/deliver`
Expected: `419` 或 `302`（CSRF / 未登录拦下，路由存在；`404` 说明路由没注册）。停掉 `php think run`。

- [ ] **Step 9: Commit**

```bash
git add app/controller/admin/AipetCustom.php app/view/admin/aipet/custom_show.html app/view/admin/aipet/custom.html route/app.php app/common.php app/view/admin/layout.html app/controller/admin/Aipet.php app/view/admin/aipet/index.html
git commit -m "AI 桌宠后台：定制单生成面板（逐个动作预览、重做、改朝向、交付）、待审核角标、概览看生成程序在不在线——交付前必须有人看过" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: README（内部接口、上线步骤、服务器验收清单）

**Files:**
- Modify: `README.md`（在下单计划加的「### AI 桌宠 · 定制下单（服务器验收）」那一段之后）

- [ ] **Step 1: 写文档**

在「### AI 桌宠 · 定制下单（服务器验收）」整段（到它的第 12 条）之后加：

````markdown
### AI 桌宠 · 定制自动生成（内部接口、上线、服务器验收）

设计：`aipet/docs/superpowers/specs/2026-10-10-aipet-custom-generation-design.md`。状态：待生成 `paid` → 生成中 `generating` → 待审核 `review` → 已交付 `delivered`；失败 `failed`；重做 / 重新生成回到 `paid`；后台订单退款 → `refunded`。

内部接口（生成程序 petgen worker 用；头 `X-Worker-Key`；不走信封，出错为 HTTP 状态码 + `{"error"}`，单子已不在生成中时带 `"abort": true`）：

| 路径（POST） | 请求 | 返回 |
|---|---|---|
| /internal/aipet/jobs/claim | `{}` | `{job: {id, pet_id, name, species, actions, redo, budget_cents, spent_cents, photos: [{url}]}}` / `{job: null[, paused_reason]}` |
| /internal/aipet/jobs/:id/progress | `{stage, done, total, message, cost: {image_units, video_units, cents}}`（cost 为增量） | `{abort}` |
| /internal/aipet/jobs/:id/upload-urls | `{files: [{path, bytes, content_type}]}` | `[{path, url}]`（PUT，30 分钟，Content-Type 须一致） |
| /internal/aipet/jobs/:id/finish | `{walk_facing, files: [{path, bytes, sha256, qa, deliverable}]}` | `{ok: true}` |
| /internal/aipet/jobs/:id/fail | `{stage, reason}` | `{ok: true}` |
| /internal/aipet/worker/status | `{paused, reason, balance: {image, video}}` | `{ok: true}` |

客户端新增：`GET /api/aipet/custom/deliveries`、`GET /api/aipet/custom/requests/:id/assets`；`GET /api/aipet/custom/requests` 每单多 `pet_id, stage, stage_done, stage_total, fail_reason`。

**上线步骤**

1. 备份后执行 `database/migrations/2026-10-10_aipet_generation.sql`（幂等）。
2. `.env` 加 `[AIPET] WORKER_KEY`（`openssl rand -hex 32`），生成程序服务器固定 IP 的话填 `WORKER_IPS`。同一个密钥填进生成程序的 `secrets/worker.env`（`AIPET_WORKER_KEY`）。
3. `php think aipet:oss-check` 八行全 ✓（含签名 PUT）。
4. crontab 加 `*/5 * * * * cd /www/wwwroot/pixpickai.com && php think aipet:reap > /dev/null 2>&1`。

**服务器验收**（`K='-H X-Worker-Key:<密钥> -H Content-Type:application/json'`，`B=https://aipei.pixpickai.com/internal/aipet`；`TOKEN`、`H` 同上一段）

1. 迁移后 `SELECT status, COUNT(*) FROM aipet_custom_requests GROUP BY status` 没有 `making` / `done`；`DESCRIBE aipet_custom_requests` 有 `pet_id … attempts`、`budget_cents`；`aipet_custom_assets` 存在；`GET /api/aipet/custom/plans` 的 pro 功能里四项带「（后续追加）」、有「卖萌」。
2. 不带 / 带错 `X-Worker-Key` 调 `$B/jobs/claim` → 401；`.env` 临时填 `WORKER_IPS=1.1.1.1` → 403，改回。
3. `POST requests` 用 species=girl → 5010 field=species「该类别即将开放」。用 dog 建两张单，各用 0.01 元套餐付款（或后台「标记已支付」）→ 两单 `status=paid`、`pet_id=custom-<id>`、`actions` 5 个（测试套餐按 standard）、`budget_cents=8000`。**同时**发两个 claim：`curl -s -X POST $K $B/jobs/claim -d '{}' & curl -s -X POST $K $B/jobs/claim -d '{}' & wait` → 拿到两个**不同**的 id（或一个 id + `{"job":null}`），`attempts` 都是 1。
4. `photos[0].url` 浏览器能打开；再 claim → `{"job":null}`。
5. `progress` 发 `{"stage":"video","done":1,"total":5,"message":"stand","cost":{"image_units":32,"video_units":4,"cents":500}}` 两次 → `{"abort":false}`；库里 `cost_cents=1000`、`cost_image_units=64`、`heartbeat_at` 刷新；后台详情页进度显示 `video 1/5 · stand`，列表「生成中 1/5」。
6. `upload-urls` 用 `content_type: image/png` 申请 `stand.mp4` → 422；正确申请 `pet.json, cover.png, stand.mp4, walk.mp4, feed.mp4, play.mp4, sleep.mp4, refs/front.png` → 8 个 URL；按 `curl -X PUT -H 'Content-Type: <对应类型>' --data-binary @文件 '<url>'` 全部上传 → 200（pet.json 用 petgen 生成的样子，含 `"walkFacing": "right"`）。
7. `finish` 少传 `sleep.mp4` → 422 `missing deliverable files: sleep.mp4`；bytes 报错一个 → 422 `size mismatch`；`refs/front.png` 报 `deliverable: true` 的正确请求 → `{"ok":true}`，状态 `review`、`redo` 为空、`aipet_custom_assets` 8 行且 `refs/front.png` 的 `deliverable=0`。
8. 侧栏「定制订单」出现角标 1；概览「定制生成程序」显示在线、最后心跳是刚才。`worker/status` 发 `{"paused":true,"reason":"生成额度不足","balance":{"image":10,"video":2}}` → 概览显示「已暂停：生成额度不足」和余额；此时 claim → `{"job":null,"paused_reason":"生成额度不足"}`；再发 `paused:false` 恢复。
9. 第二单（generating）在后台点「标记失败」→ 之后它的 `progress` 返回 `{"abort":true}`（cost 仍累加）、`finish` / `upload-urls` / `fail` 返回 409 `{"error":"job is failed","abort":true}`，状态仍是 failed，`aipet_custom_assets` 没有它的行。
10. 卡单回收：对一张 generating 单手工 `UPDATE … SET heartbeat_at = NOW() - INTERVAL 30 MINUTE` → `php think aipet:reap` 输出 `Requeued 1` → 回到 paid；再改 `attempts=3`、状态 generating、心跳 30 分钟前 → reap 输出 `failed 1`，`fail_reason=生成程序多次中断`。
11. 详情页：照片、参考图、封面并排；每个动作 `<video>` 能播、显示质检；朝向点「朝左」→ 提示已改。
12. 点「交付」→ 已交付；OSS 上 `pet.json` 的 `walkFacing` 变成 `left`、`id` 为 `custom-<id>`，`aipet_custom_assets` 里 pet.json 的 `sha256` 与 `curl <url> | sha256sum` 一致。**两个标签页先后再点「交付」** → 提示「这一单已经交付过了」，`delivered_at` 不变。
13. 对一张 generating 单（在它变状态前打开的页面）点「整单重新生成」/「重做勾选的」→ 提示「…（当前：生成中）」，`redo` 不变。对 review 单勾 play、填提示「尾巴摆慢一点」重做 → 状态 paid、`redo={"actions":["play"],"refs":false,"hint":"尾巴摆慢一点"}`、`budget_cents = cost_cents + 8000`、`attempts=0`；claim 拿到的 `redo` 一致；finish 后 `redo` 清空。
14. 客户端接口：`GET /api/aipet/custom/deliveries` → 刚交付的 `{id, pet_id, name, delivered_at}`；`GET requests/<id>/assets` → 7 个文件（无 refs），url 能下载且 sha256 一致；`GET requests` 里该单 `pet_id`、`stage` 有值、`fail_reason` 为 null，失败单有 `fail_reason`。（确认 assets 返回的是 `{pet_id, files}` 而不是列表——是列表说明被 `requests` 路由吞了，见坑 #15。）
15. 别人的 / 未交付的单请求 `assets` → HTTP 404。
16. 后台订单管理对已交付单「标记退款」→ 定制单「已退款」；`deliveries` 不再有它，`assets` → 404。
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "AI 桌宠定制生成：内部接口说明与服务器验收清单——本机连不了库，领单并发、回收、交付这些只能在服务器上按清单过" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: 收尾**

Run: `git log --oneline master..feat/aipet-generation`
Expected: 10 个 commit，每个都带 `Co-Authored-By` 结尾。**不 push**（没有 remote）。最终报告里写明：哪些只做了 `php -l` / 路由 / 模板编译检查、README 清单哪些条目需要用户在服务器上过、OSS 签名 PUT 是否实测。
