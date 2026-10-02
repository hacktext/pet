# aipet 定制宠物下单 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 宠物库「立即定制」变成可用流程：填名字 / 类别 / 1–3 张照片 → 选后台可配置的套餐 → 客户端内微信扫码付款 → 后台看到资料人工制作。

**Architecture:** 服务端（pixpickweb-tp，ThinkPHP 6.1）新增套餐 / 上传凭证 / 定制单三张表、纯 PHP 的 OSS 客户端、`api/aipet/custom/*` 六个接口、复用 `orders` + 微信网关 + `Fulfillment`，以及两个后台页面。客户端（Flutter Windows）新增 `CustomService`（经已有 `ApiClient`）、`OssUploader`（multipart 直传 OSS）、`photo_prep`（压缩），宠物库窗口里四个页面和「我的定制」列表。

**Tech Stack:** PHP 8 / ThinkPHP 6.1 / MySQL / 阿里云 OSS PostObject V1 签名；Flutter 3.47 / Dart 3.13，新依赖 `file_selector`、`image`、`qr_flutter`。

**Spec:** `docs/superpowers/specs/2026-10-02-aipet-custom-order-design.md`

## Global Constraints

- 服务端仓库 `C:\Users\Administrator\code\pixpick\pixpickweb-tp`，分支 `feat/aipet`，没有 remote（只 commit，不 push）。**按 pixpick CLAUDE.md：服务端不写自动化测试**；验证 = `php -l` + `php think run` + curl；DB 相关写进 README 服务器验收清单。本机没有 pdo_mysql。commit message 用中文写清为什么。
- 客户端仓库 `C:\Users\Administrator\code\aipet`，`apps/aipet`；TDD。Flutter 不在 PATH：PowerShell 先 `$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"`。
- 写文件用 Write/Edit 工具，**不要用 bash heredoc 写含反斜杠的内容**（会吃掉 `\`）。
- 统一信封 `{code, message, data}`；新错误码：5010 `CUSTOM_INVALID`（data.field）、5011 `CUSTOM_ALREADY_PAID`、5012 `CUSTOM_TOO_FREQUENT`、5013 `CUSTOM_PLAN_UNAVAILABLE`、5014 `CUSTOM_STORAGE_UNCONFIGURED`。
- 限制：照片 1–3 张；单张 ≤ 10MB；客户端压到长边 ≤ 2048、JPEG 质量 88；凭证 15 分钟（900 秒）可上传、1 小时（3600 秒）内可用于建单；每用户每天凭证 30 张、定制单 10 张；后台照片限时 URL 600 秒；key 前缀 `aipet/custom/<userId>/`，文件名 `<uuid>.jpg`。
- 名字：去首尾空白后 1–8 个字（按 Unicode 码点计）。species 白名单 `dog, cat, other, girl, boy, anime`。
- 订单：`plan_code = 'aipet_custom'`、`period = 'once'`、金额只取 `aipet_plans.price_cents`；订单 15 分钟过期（沿用 `pixpick.order.expire_minutes`）。
- 定制单状态：`draft → pending_payment → paid → making → done`，`paid/making/done → refunded`。客户端文字：draft/pending_payment 待支付、paid 待制作、making 制作中、done 已完成、refunded 已退款。
- OSS AccessKey 只在服务端 `.env` 的 `[OSS]`；`.example.env` 只写键名。代码、日志、对话里不出现真实值。
- 主窗口只**读** token（不隔离坏文件、不写），account.json 的写者仍只有宠物窗口。
- 客户端轮询订单状态每 2 秒，用 `Timer`，页面销毁即停。

## Review Focus

1. **换套餐后扫了旧二维码付款**：同一定制单先下标准版单 A、再改 Pro 单 B，用户扫 A 付了款——必须仍然履约到这张定制单，并以 A 的套餐 / 金额为准。（由 Task 3 的 `aipet_custom_orders` 关联表保证，`markPaid` 不能依赖 `orders.payload`：微信回调的 `markPaid` 会用回调原文覆盖 payload。验收清单第 6 条。）
2. **名字只有空格 / 9 个字 / 带 emoji**：空格不算字、9 个字不能提交、一个 emoji 算一个字。（Task 9 测试）
3. **一次选了 5 张、或已有 3 张还点上传**：只收前几张到 3 张为止并提示「最多 3 张」。（Task 9 测试）
4. **第 2 张上传失败后重试**：只重传失败及之后的，已成功的不重复申请凭证。（Task 9 测试）
5. **支付页关掉 / 登录过期（401）**：关页面后不再轮询；401 时提示「登录已过期，请重新登录」，不崩溃。（Task 11、Task 9 测试）

---

## 文件结构

服务端（相对 `pixpickweb-tp/`）：

| 文件 | 职责 |
|---|---|
| `database/migrations/2026-10-02_aipet_custom.sql` | 新建 4 张表 + 初始套餐 |
| `app/model/AipetPlan.php` `AipetUploadTicket.php` `AipetCustomRequest.php` `AipetCustomOrder.php` | 模型 |
| `config/aipet.php`（改） `.example.env`（改） | OSS 与定制配置 |
| `app/support/ApiCodes.php`（改） `app/lang/zh-cn.php` `app/lang/en-us.php`（改） | 错误码与文案 |
| `app/service/aipet/OssClient.php` | PostObject 签名、HEAD、限时 GET、PUT / DELETE（自检用） |
| `app/command/AipetOssCheck.php`，`config/console.php`（改） | `php think aipet:oss-check` 真实 bucket 自检 |
| `app/service/aipet/CustomOrderError.php` `CustomOrderService.php` | 定制业务：套餐、凭证、建单、下单、状态、列表、付款履约、退款同步 |
| `app/service/payment/Fulfillment.php`（改） `app/controller/admin/Orders.php`（改） | 付款 → 定制单 paid；退款 → 定制单 refunded |
| `app/controller/api/aipet/Custom.php`，`route/app.php`（改） | 六个接口 |
| `app/controller/admin/AipetCustom.php`，`app/view/admin/aipet/{custom,custom_show,plans,plan_edit}.html`，`app/view/admin/layout.html`（改） | 后台两页 |
| `README.md`（改） | 服务器验收清单 |

客户端（相对 `apps/aipet/`）：

| 文件 | 职责 |
|---|---|
| `lib/domain/custom_order.dart` | 套餐、凭证、定制单、支付单、状态的类型与解析 |
| `lib/services/api_client.dart`（改） | 六个接口方法 |
| `lib/services/custom_service.dart` | 把 `ApiResult` 变成类型或 `CustomFailure` |
| `lib/services/oss_uploader.dart` | multipart 构造 + 直传 |
| `lib/services/photo_prep.dart` | 解码 / 转正 / 缩放 / 转 JPEG |
| `lib/services/account_store.dart`（改） | `readToken()` 只读 |
| `lib/app/main_window/custom_flow/custom_form_model.dart` + `custom_form_page.dart` | 定制页 |
| `lib/app/main_window/custom_flow/plan_model.dart` + `plan_page.dart` | 套餐页 |
| `lib/app/main_window/custom_flow/pay_model.dart` + `pay_page.dart` | 支付页 |
| `lib/app/main_window/custom_flow/submitted_page.dart` | 已提交页 |
| `lib/app/main_window/custom_flow/custom_deps.dart` | 页面需要的依赖打包 |
| `lib/app/main_window/main_window_app.dart` `main_window_model.dart` `main_window_entry.dart`（改） | 入口、「我的定制」 |
| `test/support/fake_oss.dart` | 假 multipart 传输 |

---

## 第一部分：服务端

### Task 1: 数据表、模型、配置、错误码

**Files:**
- Create: `database/migrations/2026-10-02_aipet_custom.sql`
- Create: `app/model/AipetPlan.php`, `app/model/AipetUploadTicket.php`, `app/model/AipetCustomRequest.php`, `app/model/AipetCustomOrder.php`
- Modify: `config/aipet.php`, `.example.env`, `app/support/ApiCodes.php`, `app/lang/zh-cn.php`, `app/lang/en-us.php`

**Interfaces:**
- Produces: 表 `aipet_plans`、`aipet_upload_tickets`、`aipet_custom_requests`、`aipet_custom_orders`；模型类同名；`config('aipet.oss.*')`、`config('aipet.custom.*')`；`ApiCodes::CUSTOM_INVALID` 等 5 个常量；`AipetCustomRequest::STATUS_*` 常量与 `SPECIES` 白名单。

- [ ] **Step 1: 写迁移**

`database/migrations/2026-10-02_aipet_custom.sql`：

```sql
-- ---------------------------------------------------------------------------
-- AI 桌宠（aipet）：定制宠物下单 · 2026-10-02
-- 设计：aipet/docs/superpowers/specs/2026-10-02-aipet-custom-order-design.md
--
-- 服务器手工执行（先备份！），须在 2026-10-02_aipet.sql 之后：
--   mysql -u<user> -p <db> < database/migrations/2026-10-02_aipet_custom.sql
--
-- 1. aipet_plans：定制套餐（后台可改）+ 初始两档
-- 2. aipet_upload_tickets：发出去的 OSS 上传凭证（建单时校验照片归属）
-- 3. aipet_custom_requests：定制单
-- 4. aipet_custom_orders：订单号 → 定制单（微信回调会覆盖 orders.payload，不能靠它找定制单）
-- 全部幂等，可重复执行。
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `aipet_plans` (
  `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `product_id`    BIGINT UNSIGNED NOT NULL,
  `code`          VARCHAR(32)     NOT NULL,
  `name`          VARCHAR(50)     NOT NULL,
  `subtitle`      VARCHAR(100)    NOT NULL DEFAULT '',
  `price_cents`   INT UNSIGNED    NOT NULL,
  `valid_days`    INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT '0 = 永久',
  `tags`          JSON            NULL,
  `features`      JSON            NULL,
  `feature_count` INT UNSIGNED    NOT NULL DEFAULT 0,
  `fidelity`      TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '还原度百分比',
  `revisions`     TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '修改机会次数',
  `badge`         VARCHAR(16)     NULL,
  `icon`          VARCHAR(16)     NOT NULL DEFAULT 'standard' COMMENT 'standard | pro，客户端内置图标',
  `sort`          INT             NOT NULL DEFAULT 0,
  `enabled`       TINYINT(1)      NOT NULL DEFAULT 1,
  `created_at`    DATETIME        NULL,
  `updated_at`    DATETIME        NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_aipet_plans_code` (`product_id`, `code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='AI 桌宠定制套餐';

CREATE TABLE IF NOT EXISTS `aipet_upload_tickets` (
  `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `product_id`  BIGINT UNSIGNED NOT NULL,
  `user_id`     BIGINT UNSIGNED NOT NULL,
  `object_key`  VARCHAR(191)    NOT NULL,
  `used_at`     DATETIME        NULL,
  `created_at`  DATETIME        NULL,
  `updated_at`  DATETIME        NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_aipet_upload_tickets_key` (`object_key`),
  KEY `idx_aipet_upload_tickets_user` (`product_id`, `user_id`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='AI 桌宠定制照片上传凭证';

CREATE TABLE IF NOT EXISTS `aipet_custom_requests` (
  `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `product_id`  BIGINT UNSIGNED NOT NULL,
  `user_id`     BIGINT UNSIGNED NOT NULL,
  `name`        VARCHAR(32)     NOT NULL,
  `species`     VARCHAR(16)     NOT NULL,
  `photo_keys`  JSON            NOT NULL,
  `plan_code`   VARCHAR(32)     NULL,
  `price_cents` INT UNSIGNED    NULL COMMENT '下单时的价格快照',
  `order_no`    VARCHAR(64)     NULL COMMENT '最近一次下单的订单号',
  `status`      VARCHAR(20)     NOT NULL DEFAULT 'draft',
  `admin_note`  TEXT            NULL,
  `paid_at`     DATETIME        NULL,
  `created_at`  DATETIME        NULL,
  `updated_at`  DATETIME        NULL,
  PRIMARY KEY (`id`),
  KEY `idx_aipet_custom_requests_user` (`product_id`, `user_id`, `created_at`),
  KEY `idx_aipet_custom_requests_status` (`product_id`, `status`, `id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='AI 桌宠定制单';

CREATE TABLE IF NOT EXISTS `aipet_custom_orders` (
  `id`                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `product_id`        BIGINT UNSIGNED NOT NULL,
  `order_no`          VARCHAR(64)     NOT NULL,
  `custom_request_id` BIGINT UNSIGNED NOT NULL,
  `plan_code`         VARCHAR(32)     NOT NULL,
  `created_at`        DATETIME        NULL,
  `updated_at`        DATETIME        NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_aipet_custom_orders_no` (`order_no`),
  KEY `idx_aipet_custom_orders_request` (`custom_request_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='订单号 → 定制单';

INSERT INTO `aipet_plans` (`product_id`, `code`, `name`, `subtitle`, `price_cents`, `valid_days`, `tags`, `features`,
                           `feature_count`, `fidelity`, `revisions`, `badge`, `icon`, `sort`, `enabled`, `created_at`, `updated_at`)
SELECT `id`, 'standard', '标准版', '还原你家爱宠的专属形象', 3900, 365,
       JSON_ARRAY('AI 定制形象'),
       JSON_ARRAY('站立', '行走', '喂食', '玩耍', '休眠', '放大放小', '互动面板', '饱食度等数值统计'),
       8, 85, 2, NULL, 'standard', 10, 1, NOW(), NOW()
FROM `products` WHERE `code` = 'aipet'
ON DUPLICATE KEY UPDATE `code` = `code`;

INSERT INTO `aipet_plans` (`product_id`, `code`, `name`, `subtitle`, `price_cents`, `valid_days`, `tags`, `features`,
                           `feature_count`, `fidelity`, `revisions`, `badge`, `icon`, `sort`, `enabled`, `created_at`, `updated_at`)
SELECT `id`, 'pro', '高级Pro版', '更丰富的动作与桌面互动', 5900, 0,
       JSON_ARRAY('AI 定制形象'),
       JSON_ARRAY('站立', '行走', '喂食', '玩耍', '休眠', '转圈', '舔爪', '摸摸头', '后空翻', '鼠标跟随', '放大放小', '互动面板', '饱食度等数值统计'),
       13, 98, 5, '推荐', 'pro', 20, 1, NOW(), NOW()
FROM `products` WHERE `code` = 'aipet'
ON DUPLICATE KEY UPDATE `code` = `code`;
```

- [ ] **Step 2: 写四个模型**

`app/model/AipetPlan.php`：

```php
<?php
declare(strict_types=1);

namespace app\model;

/** AI 桌宠定制套餐（后台可改；价格单位：分；valid_days 0 = 永久） */
class AipetPlan extends ProductScoped
{
    protected $table = 'aipet_plans';

    protected $autoWriteTimestamp = 'datetime';
    protected $createTime = 'created_at';
    protected $updateTime = 'updated_at';

    protected $jsonAssoc = true;
    protected $type = [
        'price_cents'   => 'integer',
        'valid_days'    => 'integer',
        'feature_count' => 'integer',
        'fidelity'      => 'integer',
        'revisions'     => 'integer',
        'sort'          => 'integer',
        'enabled'       => 'integer',
        'tags'          => 'json',
        'features'      => 'json',
    ];

    /** 客户端 / 接口看到的样子。 */
    public function toApi(): array
    {
        return [
            'code'          => (string) $this->code,
            'name'          => (string) $this->name,
            'subtitle'      => (string) $this->subtitle,
            'price_cents'   => (int) $this->price_cents,
            'valid_days'    => (int) $this->valid_days,
            'tags'          => array_values((array) ($this->tags ?? [])),
            'features'      => array_values((array) ($this->features ?? [])),
            'feature_count' => (int) $this->feature_count,
            'fidelity'      => (int) $this->fidelity,
            'revisions'     => (int) $this->revisions,
            'badge'         => $this->badge !== null && $this->badge !== '' ? (string) $this->badge : null,
            'icon'          => (string) $this->icon,
        ];
    }
}
```

`app/model/AipetUploadTicket.php`：

```php
<?php
declare(strict_types=1);

namespace app\model;

/** 发给客户端的 OSS 上传凭证：建单时据此确认照片是本人刚传的 */
class AipetUploadTicket extends ProductScoped
{
    protected $table = 'aipet_upload_tickets';

    protected $autoWriteTimestamp = 'datetime';
    protected $createTime = 'created_at';
    protected $updateTime = 'updated_at';
}
```

`app/model/AipetCustomRequest.php`：

```php
<?php
declare(strict_types=1);

namespace app\model;

/** AI 桌宠定制单：名字、类别、照片（OSS key）、套餐快照与状态 */
class AipetCustomRequest extends ProductScoped
{
    public const STATUS_DRAFT           = 'draft';
    public const STATUS_PENDING_PAYMENT = 'pending_payment';
    public const STATUS_PAID            = 'paid';
    public const STATUS_MAKING          = 'making';
    public const STATUS_DONE            = 'done';
    public const STATUS_REFUNDED        = 'refunded';

    /** 已付款及之后：不能再下单。 */
    public const PAID_STATES = [self::STATUS_PAID, self::STATUS_MAKING, self::STATUS_DONE, self::STATUS_REFUNDED];

    public const STATUS_LABELS = [
        self::STATUS_DRAFT           => '待支付',
        self::STATUS_PENDING_PAYMENT => '待支付',
        self::STATUS_PAID            => '待制作',
        self::STATUS_MAKING          => '制作中',
        self::STATUS_DONE            => '已完成',
        self::STATUS_REFUNDED        => '已退款',
    ];

    /** 与客户端 Species 一致。 */
    public const SPECIES = ['dog' => '狗狗', 'cat' => '猫猫', 'other' => '其他宠物', 'girl' => '女生', 'boy' => '男生', 'anime' => '动漫角色'];

    protected $table = 'aipet_custom_requests';

    protected $autoWriteTimestamp = 'datetime';
    protected $createTime = 'created_at';
    protected $updateTime = 'updated_at';

    protected $jsonAssoc = true;
    protected $type = [
        'photo_keys'  => 'json',
        'price_cents' => 'integer',
    ];

    public function isPaid(): bool
    {
        return in_array($this->status, self::PAID_STATES, true);
    }
}
```

`app/model/AipetCustomOrder.php`：

```php
<?php
declare(strict_types=1);

namespace app\model;

/**
 * 订单号 → 定制单。微信回调的 markPaid 会用回调原文覆盖 orders.payload，
 * 所以履约时靠这张表找定制单和当时选的套餐（换套餐后扫了旧码也能对上）。
 */
class AipetCustomOrder extends ProductScoped
{
    protected $table = 'aipet_custom_orders';

    protected $autoWriteTimestamp = 'datetime';
    protected $createTime = 'created_at';
    protected $updateTime = 'updated_at';
}
```

- [ ] **Step 3: 配置、错误码、文案**

`config/aipet.php` 在 `'events_keep_days' => 90,` 之后、`];` 之前加：

```php

    // 阿里云 OSS（定制照片）：私有 bucket，密钥只在服务端 .env [OSS]
    'oss' => [
        'endpoint'          => env('oss.endpoint', ''),   // 如 oss-cn-hangzhou.aliyuncs.com
        'bucket'            => env('oss.bucket', ''),
        'access_key_id'     => env('oss.access_key_id', ''),
        'access_key_secret' => env('oss.access_key_secret', ''),
    ],

    // 定制宠物下单（设计 2026-10-02-aipet-custom-order-design.md）
    'custom' => [
        'max_photos'               => 3,
        'photo_max_bytes'          => 10 * 1024 * 1024,
        'ticket_ttl'               => 900,    // 凭证可上传的秒数
        'ticket_valid_for_request' => 3600,   // 凭证可用于建单的秒数
        'daily_tickets'            => 30,
        'daily_requests'           => 10,
        'view_url_ttl'             => 600,    // 后台 / 列表看照片的限时 URL 秒数
        'key_prefix'               => 'aipet/custom/',
        'name_max'                 => 8,
    ],
```

`.example.env` 末尾加：

```
[OSS]
ENDPOINT =
BUCKET =
ACCESS_KEY_ID =
ACCESS_KEY_SECRET =
```

`app/support/ApiCodes.php` 在 `SYNC_TOO_LARGE` 之后加：

```php
    public const CUSTOM_INVALID              = 5010;  // 定制参数或照片无效，data.field 指出哪项
    public const CUSTOM_ALREADY_PAID         = 5011;  // 定制单已支付，不能再下单
    public const CUSTOM_TOO_FREQUENT         = 5012;  // 超过每日上限
    public const CUSTOM_PLAN_UNAVAILABLE     = 5013;  // 套餐不存在或已下架
    public const CUSTOM_STORAGE_UNCONFIGURED = 5014;  // OSS 未配置
```

`app/lang/zh-cn.php` 在 `'aipet.default_name' => ...,` 之后加：

```php
    'aipet.custom_bad_name'     => '名字需要 1–8 个字',
    'aipet.custom_bad_species'  => '请选择类别',
    'aipet.custom_bad_photos'   => '照片无效或已过期，请重新上传',
    'aipet.custom_bad_count'    => '最多上传 3 张照片',
    'aipet.custom_already_paid' => '这个定制已经支付过了',
    'aipet.custom_too_frequent' => '今天提交次数太多了，明天再来吧',
    'aipet.custom_plan_gone'    => '该套餐已下架',
    'aipet.custom_no_storage'   => '服务暂时不可用，请稍后再试',
    'aipet.custom_pay_failed'   => '创建支付失败，请稍后再试',
```

`app/lang/en-us.php` 同位置加：

```php
    'aipet.custom_bad_name'     => 'The name must be 1-8 characters',
    'aipet.custom_bad_species'  => 'Please choose a category',
    'aipet.custom_bad_photos'   => 'The photos are invalid or expired, please upload again',
    'aipet.custom_bad_count'    => 'Up to 3 photos',
    'aipet.custom_already_paid' => 'This order has already been paid',
    'aipet.custom_too_frequent' => 'Too many requests today, please try again tomorrow',
    'aipet.custom_plan_gone'    => 'This plan is no longer available',
    'aipet.custom_no_storage'   => 'Service unavailable, please try again later',
    'aipet.custom_pay_failed'   => 'Could not create the payment, please try again later',
```

- [ ] **Step 4: 语法检查**

Run（pixpickweb-tp 目录）：`for f in app/model/AipetPlan.php app/model/AipetUploadTicket.php app/model/AipetCustomRequest.php app/model/AipetCustomOrder.php config/aipet.php app/support/ApiCodes.php app/lang/zh-cn.php app/lang/en-us.php; do php -l $f; done`
Expected: 每个都是 `No syntax errors detected`

- [ ] **Step 5: Commit**

```bash
git add database/migrations/2026-10-02_aipet_custom.sql app/model/AipetPlan.php app/model/AipetUploadTicket.php app/model/AipetCustomRequest.php app/model/AipetCustomOrder.php config/aipet.php .example.env app/support/ApiCodes.php app/lang/zh-cn.php app/lang/en-us.php
git commit -m "AI 桌宠定制：套餐 / 上传凭证 / 定制单表与配置——套餐要后台可改，照片要能核对是本人刚传的"
```

---

### Task 2: OSS 客户端与自检命令

**Files:**
- Create: `app/service/aipet/OssClient.php`
- Create: `app/command/AipetOssCheck.php`
- Modify: `config/console.php`

**Interfaces:**
- Consumes: `config('aipet.oss.*')`
- Produces:
  - `OssClient::fromConfig(): ?OssClient`（任一项为空返回 null）
  - `postPolicy(string $key, int $maxBytes, int $ttl): array` → `['url' => string, 'fields' => array<string,string>]`
  - `exists(string $key): bool`
  - `signedGetUrl(string $key, int $ttl): string`
  - `put(string $key, string $body, string $contentType): bool`、`delete(string $key): bool`（自检用）

- [ ] **Step 1: 写 OssClient**

`app/service/aipet/OssClient.php`：

```php
<?php
declare(strict_types=1);

namespace app\service\aipet;

/**
 * 阿里云 OSS 的最小客户端（V1 签名，纯 PHP + curl，不引 SDK，同 AliyunSmsClient 的写法）。
 *
 * - postPolicy：给客户端直传用的 PostObject 表单字段。policy 锁死 key、大小、类型，15 分钟失效；
 *   客户端拿不到 AccessKey。
 * - exists：建单时 HEAD 确认照片真的传上去了。
 * - signedGetUrl：私有 bucket 的限时查看链接（后台、「我的定制」封面）。
 * - put / delete：只给 aipet:oss-check 自检用。
 */
final class OssClient
{
    public function __construct(
        private readonly string $endpoint,
        private readonly string $bucket,
        private readonly string $accessKeyId,
        private readonly string $accessKeySecret,
    ) {}

    /** 四项任一为空 → null（接口据此返回 5014）。 */
    public static function fromConfig(): ?self
    {
        $c = (array) config('aipet.oss');
        $endpoint = trim((string) ($c['endpoint'] ?? ''));
        $bucket   = trim((string) ($c['bucket'] ?? ''));
        $id       = trim((string) ($c['access_key_id'] ?? ''));
        $secret   = trim((string) ($c['access_key_secret'] ?? ''));
        if ($endpoint === '' || $bucket === '' || $id === '' || $secret === '') {
            return null;
        }
        $endpoint = preg_replace('#^https?://#', '', rtrim($endpoint, '/'));

        return new self($endpoint, $bucket, $id, $secret);
    }

    public function host(): string
    {
        return 'https://' . $this->bucket . '.' . $this->endpoint;
    }

    /** @return array{url: string, fields: array<string, string>} 表单字段按这个顺序发，文件放最后。 */
    public function postPolicy(string $key, int $maxBytes, int $ttl): array
    {
        $policy = base64_encode((string) json_encode([
            'expiration' => gmdate('Y-m-d\TH:i:s.000\Z', time() + $ttl),
            'conditions' => [
                ['bucket' => $this->bucket],
                ['eq', '$key', $key],
                ['content-length-range', 1, $maxBytes],
                ['eq', '$Content-Type', 'image/jpeg'],
                ['eq', '$success_action_status', '204'],
            ],
        ], JSON_UNESCAPED_SLASHES));

        return [
            'url'    => $this->host(),
            'fields' => [
                'key'                   => $key,
                'policy'                => $policy,
                'OSSAccessKeyId'        => $this->accessKeyId,
                'Signature'             => base64_encode(hash_hmac('sha1', $policy, $this->accessKeySecret, true)),
                'success_action_status' => '204',
                'Content-Type'          => 'image/jpeg',
            ],
        ];
    }

    public function exists(string $key): bool
    {
        [$status] = $this->request('HEAD', $key);
        return $status === 200;
    }

    public function signedGetUrl(string $key, int $ttl): string
    {
        $expires   = time() + $ttl;
        $signature = $this->sign("GET\n\n\n{$expires}\n" . $this->resource($key));

        return $this->host() . '/' . $this->encodeKey($key)
            . '?OSSAccessKeyId=' . rawurlencode($this->accessKeyId)
            . '&Expires=' . $expires
            . '&Signature=' . rawurlencode($signature);
    }

    public function put(string $key, string $body, string $contentType): bool
    {
        [$status] = $this->request('PUT', $key, $body, $contentType);
        return $status === 200;
    }

    public function delete(string $key): bool
    {
        [$status] = $this->request('DELETE', $key);
        return $status === 204;
    }

    // ---- 内部 ----

    /** @return array{0: int, 1: string} */
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
        curl_close($ch);

        return [$status, (string) $raw];
    }

    private function sign(string $stringToSign): string
    {
        return base64_encode(hash_hmac('sha1', $stringToSign, $this->accessKeySecret, true));
    }

    private function resource(string $key): string
    {
        return '/' . $this->bucket . '/' . $key;
    }

    private function encodeKey(string $key): string
    {
        return implode('/', array_map('rawurlencode', explode('/', $key)));
    }
}
```

- [ ] **Step 2: 写自检命令**

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
 * php think aipet:oss-check —— 用 .env [OSS] 的真实 bucket 走一遍定制照片会用到的全部签名：
 * PostObject 表单直传（和客户端一样）→ HEAD → 限时 GET → DELETE。不碰数据库。
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

        $key  = rtrim((string) config('aipet.custom.key_prefix'), '/') . '/_check/' . bin2hex(random_bytes(8)) . '.jpg';
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

        return ($exists && $got === $body) ? 0 : 1;
    }
}
```

`config/console.php` 的 `'commands' => [...]` 里照 `aipet:rollup` 那行加一行：

```php
        'aipet:oss-check' => \app\command\AipetOssCheck::class,
```

- [ ] **Step 3: 语法检查**

Run: `php -l app/service/aipet/OssClient.php && php -l app/command/AipetOssCheck.php && php -l config/console.php`
Expected: 三个 `No syntax errors detected`

- [ ] **Step 4: 未配置时的行为**

Run: `php think aipet:oss-check`（本地 `.env` 没有 `[OSS]` 时）
Expected: 输出「.env 的 [OSS] 没配全…」，退出码 1

- [ ] **Step 5: 真实 bucket 自检（需要用户在本机 `.env` 填 `[OSS]`，不要让用户把值发过来）**

先问用户是否已在本机 `pixpickweb-tp/.env` 填好 `[OSS]`；填好后：
Run: `php think aipet:oss-check`
Expected: 四行都是 ✓，退出码 0。若 PostObject 403：检查 bucket 地域与 ENDPOINT 是否一致、RAM 子账号是否有 `oss:PutObject/GetObject/DeleteObject` 权限。用户没填就跳过此步，在最终报告里写明「OSS 实传未验证」。

- [ ] **Step 6: Commit**

```bash
git add app/service/aipet/OssClient.php app/command/AipetOssCheck.php config/console.php
git commit -m "AI 桌宠定制：OSS 直传签名与自检命令——客户端只拿一次性凭证，密钥不出服务器"
```

---

### Task 3: 定制业务服务、付款履约、退款同步

**Files:**
- Create: `app/service/aipet/CustomOrderError.php`
- Create: `app/service/aipet/CustomOrderService.php`
- Modify: `app/service/payment/Fulfillment.php`
- Modify: `app/controller/admin/Orders.php`（`refund()`）

**Interfaces:**
- Consumes: Task 1 模型与配置；Task 2 `OssClient`；现有 `OrderService::generateOrderNo()`、`PaymentManager::driver()`、`Order`。
- Produces（`CustomOrderService`，构造参数 `?OssClient $oss = null` 时取 `OssClient::fromConfig()`）：
  - `plans(): array`（`toApi()` 列表）
  - `issueTickets(User $user, int $count): array`（`[{key, url, fields}]`）
  - `createRequest(User $user, string $name, string $species, array $photoKeys): AipetCustomRequest`
  - `startOrder(User $user, int $requestId, string $planCode): array`（`{order_no, amount_cents, code_url, expired_at, expires_in}`）
  - `orderStatus(User $user, string $orderNo): string`
  - `listRequests(User $user): array`
  - `markPaid(Order $order): void`（Fulfillment 调）
  - `markRefunded(Order $order): void`（后台退款调）
  - 失败一律抛 `CustomOrderError(int $apiCode, string $message, ?string $field = null)`；资源不是本人的抛 `CustomOrderError(404, 'not found')`。

- [ ] **Step 1: 错误类**

`app/service/aipet/CustomOrderError.php`：

```php
<?php
declare(strict_types=1);

namespace app\service\aipet;

/** 定制业务的「不行」：apiCode 是 ApiCodes 里的值（404 表示查无此单 / 不是本人的）。 */
final class CustomOrderError extends \RuntimeException
{
    public function __construct(
        public readonly int $apiCode,
        string $message,
        public readonly ?string $field = null,
    ) {
        parent::__construct($message);
    }
}
```

- [ ] **Step 2: 业务服务**

`app/service/aipet/CustomOrderService.php`：

```php
<?php
declare(strict_types=1);

namespace app\service\aipet;

use think\facade\Db;
use think\facade\Log;
use app\model\AipetCustomOrder;
use app\model\AipetCustomRequest;
use app\model\AipetPlan;
use app\model\AipetUploadTicket;
use app\model\Order;
use app\model\User;
use app\service\payment\OrderService;
use app\service\payment\PaymentManager;
use app\support\ApiCodes;

/**
 * AI 桌宠定制下单（设计 2026-10-02-aipet-custom-order-design.md 第 4 节）。
 * 照片 key 由这里生成并登记，建单时校验归属 / 时效 / 未用过 / OSS 上真有；金额只取套餐表。
 */
class CustomOrderService
{
    public const PLAN_CODE = 'aipet_custom';

    private ?OssClient $oss;

    public function __construct(?OssClient $oss = null, private readonly OrderService $orders = new OrderService())
    {
        $this->oss = $oss ?? OssClient::fromConfig();
    }

    public function plans(): array
    {
        return array_map(
            fn (AipetPlan $p) => $p->toApi(),
            AipetPlan::where('enabled', 1)->order('sort', 'asc')->order('id', 'asc')->select()->all(),
        );
    }

    public function issueTickets(User $user, int $count): array
    {
        $cfg = (array) config('aipet.custom');
        $oss = $this->requireOss();
        if ($count < 1 || $count > (int) $cfg['max_photos']) {
            throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_bad_count'), 'count');
        }
        $today = AipetUploadTicket::where('user_id', $user->id)->where('created_at', '>=', date('Y-m-d 00:00:00'))->count();
        if ($today + $count > (int) $cfg['daily_tickets']) {
            throw new CustomOrderError(ApiCodes::CUSTOM_TOO_FREQUENT, lang('aipet.custom_too_frequent'));
        }

        $out = [];
        for ($i = 0; $i < $count; $i++) {
            $key = rtrim((string) $cfg['key_prefix'], '/') . '/' . $user->id . '/' . $this->uuid() . '.jpg';
            $t = new AipetUploadTicket();
            $t->user_id    = $user->id;
            $t->object_key = $key;
            $t->save();
            $out[] = ['key' => $key] + $oss->postPolicy($key, (int) $cfg['photo_max_bytes'], (int) $cfg['ticket_ttl']);
        }

        return $out;
    }

    public function createRequest(User $user, string $name, string $species, array $photoKeys): AipetCustomRequest
    {
        $cfg  = (array) config('aipet.custom');
        $oss  = $this->requireOss();
        $name = trim($name);
        $len  = mb_strlen($name, 'UTF-8');
        if ($len < 1 || $len > (int) $cfg['name_max']) {
            throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_bad_name'), 'name');
        }
        if (! array_key_exists($species, AipetCustomRequest::SPECIES)) {
            throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_bad_species'), 'species');
        }
        $keys = array_values(array_filter($photoKeys, 'is_string'));
        if (count($keys) < 1 || count($keys) > (int) $cfg['max_photos'] || count($keys) !== count(array_unique($keys))
            || count($keys) !== count($photoKeys)) {
            throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_bad_photos'), 'photo_keys');
        }
        $today = AipetCustomRequest::where('user_id', $user->id)->where('created_at', '>=', date('Y-m-d 00:00:00'))->count();
        if ($today >= (int) $cfg['daily_requests']) {
            throw new CustomOrderError(ApiCodes::CUSTOM_TOO_FREQUENT, lang('aipet.custom_too_frequent'));
        }

        $since   = date('Y-m-d H:i:s', time() - (int) $cfg['ticket_valid_for_request']);
        $tickets = AipetUploadTicket::where('user_id', $user->id)
            ->whereIn('object_key', $keys)
            ->whereNull('used_at')
            ->where('created_at', '>=', $since)
            ->select();
        if (count($tickets) !== count($keys)) {
            throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_bad_photos'), 'photo_keys');
        }
        foreach ($keys as $key) {
            if (! $oss->exists($key)) {
                throw new CustomOrderError(ApiCodes::CUSTOM_INVALID, lang('aipet.custom_bad_photos'), 'photo_keys');
            }
        }

        return Db::transaction(function () use ($user, $name, $species, $keys, $tickets) {
            foreach ($tickets as $t) {
                $t->used_at = date('Y-m-d H:i:s');
                $t->save();
            }
            $r = new AipetCustomRequest();
            $r->user_id    = $user->id;
            $r->name       = $name;
            $r->species    = $species;
            $r->photo_keys = $keys;
            $r->status     = AipetCustomRequest::STATUS_DRAFT;
            $r->save();
            return $r;
        });
    }

    public function startOrder(User $user, int $requestId, string $planCode): array
    {
        $request = $this->ownedRequest($user, $requestId);
        if ($request->isPaid()) {
            throw new CustomOrderError(ApiCodes::CUSTOM_ALREADY_PAID, lang('aipet.custom_already_paid'));
        }
        $plan = AipetPlan::where('code', $planCode)->where('enabled', 1)->find();
        if (! $plan) {
            throw new CustomOrderError(ApiCodes::CUSTOM_PLAN_UNAVAILABLE, lang('aipet.custom_plan_gone'));
        }

        $order = $this->reusableOrder($request, $planCode);
        if (! $order) {
            $order = new Order();
            $order->order_no   = $this->orders->generateOrderNo();
            $order->user_id    = $user->id;
            $order->plan_code  = self::PLAN_CODE;
            $order->period     = 'once';
            $order->amount     = (int) $plan->price_cents;   // 金额只认套餐表
            $order->currency   = 'CNY';
            $order->channel    = (string) config('pixpick.payment.default', 'fake');
            $order->status     = Order::STATUS_PENDING;
            $order->payload    = ['custom_request_id' => (int) $request->id, 'aipet_plan' => $planCode];
            $order->expired_at = date('Y-m-d H:i:s', time() + (int) config('pixpick.order.expire_minutes', 15) * 60);
            $order->save();

            $link = new AipetCustomOrder();
            $link->order_no          = $order->order_no;
            $link->custom_request_id = (int) $request->id;
            $link->plan_code         = $planCode;
            $link->save();
        }

        try {
            $charge = (new PaymentManager())->driver((string) $order->channel)->createCharge($order);
        } catch (\Throwable $e) {
            Log::error('[aipet] 定制下单失败 order=' . $order->order_no . '：' . $e->getMessage());
            throw new CustomOrderError(ApiCodes::INVALID_PARAM, lang('aipet.custom_pay_failed'));
        }

        $request->plan_code   = $planCode;
        $request->price_cents = (int) $plan->price_cents;
        $request->order_no    = $order->order_no;
        $request->status      = AipetCustomRequest::STATUS_PENDING_PAYMENT;
        $request->save();

        $expiresAt = strtotime((string) $order->expired_at);

        return [
            'order_no'     => (string) $order->order_no,
            'amount_cents' => (int) $order->amount,
            'code_url'     => $charge->codeUrl,
            'expired_at'   => (string) $order->expired_at,
            'expires_in'   => max(0, $expiresAt - time()),
        ];
    }

    public function orderStatus(User $user, string $orderNo): string
    {
        $order = Order::where('order_no', $orderNo)->where('user_id', $user->id)->where('plan_code', self::PLAN_CODE)->find();
        if (! $order) {
            throw new CustomOrderError(404, 'not found');
        }
        return $order->isExpired() ? Order::STATUS_EXPIRED : (string) $order->status;
    }

    public function listRequests(User $user): array
    {
        $rows  = AipetCustomRequest::where('user_id', $user->id)->order('id', 'desc')->limit(50)->select();
        $codes = array_filter(array_unique(array_map(fn ($r) => (string) $r->plan_code, $rows->all())));
        $names = $codes ? AipetPlan::whereIn('code', $codes)->column('name', 'code') : [];
        $ttl   = (int) config('aipet.custom.view_url_ttl', 600);

        return array_map(function (AipetCustomRequest $r) use ($names, $ttl) {
            $keys = (array) $r->photo_keys;
            return [
                'id'          => (int) $r->id,
                'name'        => (string) $r->name,
                'species'     => (string) $r->species,
                'plan_code'   => $r->plan_code,
                'plan_name'   => $r->plan_code ? ($names[$r->plan_code] ?? $r->plan_code) : null,
                'price_cents' => $r->price_cents,
                'status'      => (string) $r->status,
                'order_no'    => $r->order_no,
                'created_at'  => (string) $r->created_at,
                'paid_at'     => $r->paid_at ? (string) $r->paid_at : null,
                'cover_url'   => ($this->oss && $keys) ? $this->oss->signedGetUrl((string) $keys[0], $ttl) : null,
            ];
        }, $rows->all());
    }

    /** 订单已付（Fulfillment 调，已在回调的事务与产品上下文里）。幂等。 */
    public function markPaid(Order $order): void
    {
        $link = AipetCustomOrder::where('order_no', $order->order_no)->find();
        if (! $link) {
            Log::error('[aipet] 定制订单找不到定制单 order=' . $order->order_no);
            return;
        }
        $request = AipetCustomRequest::where('id', $link->custom_request_id)->lock(true)->find();
        if (! $request || $request->isPaid()) {
            return;
        }
        // 以付款的这一单为准（换套餐后扫了旧码也对得上）
        $request->plan_code   = (string) $link->plan_code;
        $request->price_cents = (int) $order->amount;
        $request->order_no    = (string) $order->order_no;
        $request->status      = AipetCustomRequest::STATUS_PAID;
        $request->paid_at     = date('Y-m-d H:i:s');
        $request->save();
    }

    /** 后台把这一单标记退款后调。 */
    public function markRefunded(Order $order): void
    {
        $link = AipetCustomOrder::where('order_no', $order->order_no)->find();
        $request = $link ? AipetCustomRequest::find($link->custom_request_id) : null;
        if ($request && $request->isPaid() && $request->order_no === $order->order_no) {
            $request->status = AipetCustomRequest::STATUS_REFUNDED;
            $request->save();
        }
    }

    // ---- 内部 ----

    private function requireOss(): OssClient
    {
        if ($this->oss === null) {
            throw new CustomOrderError(ApiCodes::CUSTOM_STORAGE_UNCONFIGURED, lang('aipet.custom_no_storage'));
        }
        return $this->oss;
    }

    private function ownedRequest(User $user, int $id): AipetCustomRequest
    {
        $r = AipetCustomRequest::where('id', $id)->where('user_id', $user->id)->find();
        if (! $r) {
            throw new CustomOrderError(404, 'not found');
        }
        return $r;
    }

    /** 同一定制单、同一套餐、还没过期的待付单就复用。 */
    private function reusableOrder(AipetCustomRequest $request, string $planCode): ?Order
    {
        if (! $request->order_no || $request->plan_code !== $planCode) {
            return null;
        }
        $order = Order::where('order_no', $request->order_no)->find();
        return ($order && $order->status === Order::STATUS_PENDING && ! $order->isExpired()) ? $order : null;
    }

    private function uuid(): string
    {
        $b = random_bytes(16);
        $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
        $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
    }
}
```

- [ ] **Step 3: Fulfillment 分支**

`app/service/payment/Fulfillment.php`：`use` 区加 `use app\service\aipet\CustomOrderService;`；`fulfill()` 开头（`if (! $order->isLicense())` 之前）加：

```php
        // AI 桌宠定制：定制单置为已付，等后台人工制作（不开会员）
        if ($order->plan_code === CustomOrderService::PLAN_CODE) {
            (new CustomOrderService())->markPaid($order);
            return null;
        }
```

类注释第二句改为：「会员订单开会员（行为不变）；买断订单发授权码……；AI 桌宠定制单置为已付。」

- [ ] **Step 4: 后台标记已付 / 退款**

`app/controller/admin/Orders.php`：`use` 区加 `use app\service\aipet\CustomOrderService;`。

`markPaid()` 里 `$license = $this->fulfillment->fulfill($order);` 之后加（否则提示会说「已激活会员」）：

```php
        if ($order->plan_code === CustomOrderService::PLAN_CODE) {
            return $this->back($id, '已标记为已支付，对应的桌宠定制单已变为「待制作」。');
        }
```

`refund()` 里 `$order->save();` 之后、`return` 之前加：

```php
        if ($order->plan_code === CustomOrderService::PLAN_CODE) {
            (new CustomOrderService())->markRefunded($order);
            return $this->back($id, '订单已标记为退款，对应的桌宠定制单已同步为「已退款」。');
        }
```

- [ ] **Step 5: 语法检查**

Run: `php -l app/service/aipet/CustomOrderError.php && php -l app/service/aipet/CustomOrderService.php && php -l app/service/payment/Fulfillment.php && php -l app/controller/admin/Orders.php`
Expected: 全部 `No syntax errors detected`

- [ ] **Step 6: Commit**

```bash
git add app/service/aipet/CustomOrderError.php app/service/aipet/CustomOrderService.php app/service/payment/Fulfillment.php app/controller/admin/Orders.php
git commit -m "AI 桌宠定制：建单、下单、付款履约与退款同步——付款靠订单号关联表找定制单，回调覆盖 payload 也不丢"
```

---

### Task 4: 定制接口与路由

**Files:**
- Create: `app/controller/api/aipet/Custom.php`
- Modify: `route/app.php`（受保护分组里，`aipet/sync` 两行之后）

**Interfaces:**
- Consumes: Task 3 `CustomOrderService`、`CustomOrderError`
- Produces: 六个接口（客户端 Task 7 按这些路径调用）：
  - `GET  /api/aipet/custom/plans` → `[plan]`
  - `POST /api/aipet/custom/upload-tickets` `{count}` → `[{key, url, fields}]`
  - `POST /api/aipet/custom/requests` `{name, species, photo_keys}` → `{id, name, species, status, photo_count}`
  - `GET  /api/aipet/custom/requests` → `[request]`
  - `POST /api/aipet/custom/requests/:id/order` `{plan_code}` → `{order_no, amount_cents, code_url, expired_at, expires_in}`
  - `GET  /api/aipet/custom/orders/:orderNo` → `{status}`

- [ ] **Step 1: 控制器**

`app/controller/api/aipet/Custom.php`：

```php
<?php
declare(strict_types=1);

namespace app\controller\api\aipet;

use think\Request;
use think\Response;
use app\service\aipet\CustomOrderError;
use app\service\aipet\CustomOrderService;
use app\support\AipetProduct;
use app\support\ApiResponse;
use app\support\Auth as AuthHolder;

/**
 * AI 桌宠定制下单（需登录）。业务都在 CustomOrderService；这里只取参、转信封。
 * 不是本人的定制单 / 订单一律 404，不暴露存在与否。
 */
class Custom
{
    /** GET /api/aipet/custom/plans */
    public function plans(): Response
    {
        return $this->run(fn (CustomOrderService $s) => $s->plans());
    }

    /** POST /api/aipet/custom/upload-tickets {count} */
    public function tickets(Request $request): Response
    {
        return $this->run(fn (CustomOrderService $s) => $s->issueTickets(AuthHolder::user(), (int) $request->param('count', 0)));
    }

    /** POST /api/aipet/custom/requests {name, species, photo_keys} */
    public function createRequest(Request $request): Response
    {
        return $this->run(function (CustomOrderService $s) use ($request) {
            $keys = $request->param('photo_keys');
            $r = $s->createRequest(
                AuthHolder::user(),
                (string) $request->param('name', ''),
                (string) $request->param('species', ''),
                is_array($keys) ? $keys : [],
            );
            return ['id' => (int) $r->id, 'name' => (string) $r->name, 'species' => (string) $r->species,
                    'status' => (string) $r->status, 'photo_count' => count((array) $r->photo_keys)];
        });
    }

    /** GET /api/aipet/custom/requests */
    public function requests(): Response
    {
        return $this->run(fn (CustomOrderService $s) => $s->listRequests(AuthHolder::user()));
    }

    /** POST /api/aipet/custom/requests/:id/order {plan_code} */
    public function order(Request $request, int $id): Response
    {
        return $this->run(fn (CustomOrderService $s) => $s->startOrder(AuthHolder::user(), $id, (string) $request->param('plan_code', '')));
    }

    /** GET /api/aipet/custom/orders/:orderNo */
    public function orderStatus(string $orderNo): Response
    {
        return $this->run(fn (CustomOrderService $s) => ['status' => $s->orderStatus(AuthHolder::user(), $orderNo)]);
    }

    private function run(callable $fn): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        try {
            return ApiResponse::ok($fn(new CustomOrderService()));
        } catch (CustomOrderError $e) {
            if ($e->apiCode === 404) {
                return response('Not Found', 404);
            }
            return ApiResponse::fail($e->apiCode, $e->getMessage(), $e->field ? ['field' => $e->field] : null);
        }
    }
}
```

- [ ] **Step 2: 路由**

`route/app.php` 受保护分组里，`Route::put('aipet/sync', 'api.aipet.Sync/update');` 之后加：

```php

        // AI 桌宠定制下单（设计 2026-10-02-aipet-custom-order-design.md）
        Route::get('aipet/custom/plans',              'api.aipet.Custom/plans');
        Route::post('aipet/custom/upload-tickets',    'api.aipet.Custom/tickets');
        Route::get('aipet/custom/requests',           'api.aipet.Custom/requests');
        Route::post('aipet/custom/requests',          'api.aipet.Custom/createRequest');
        Route::post('aipet/custom/requests/:id/order','api.aipet.Custom/order')->pattern(['id' => '\d+']);
        Route::get('aipet/custom/orders/:orderNo',    'api.aipet.Custom/orderStatus')->pattern(['orderNo' => '[A-Za-z0-9]+']);
```

- [ ] **Step 3: 语法与路由检查**

Run: `php -l app/controller/api/aipet/Custom.php && php -l route/app.php`
Expected: `No syntax errors detected`

Run（后台启动）：`php think run --port 8089`，然后
`curl -s -o /dev/null -w "%{http_code}\n" -H "Host: aipet.localhost" http://127.0.0.1:8089/api/aipet/custom/plans`
Expected: `401`（无 token 被 SanctumAuth 拦下，说明路由已注册；若是 404 说明路由没进受保护分组或 dev_products 没配 aipet.localhost）。检查完停掉 `php think run`。

- [ ] **Step 4: Commit**

```bash
git add app/controller/api/aipet/Custom.php route/app.php
git commit -m "AI 桌宠定制：六个客户端接口——套餐、上传凭证、建单、下单、支付状态、我的定制"
```

---

### Task 5: 后台「定制订单」「定制套餐」

**Files:**
- Create: `app/controller/admin/AipetCustom.php`
- Create: `app/view/admin/aipet/custom.html`, `custom_show.html`, `plans.html`, `plan_edit.html`
- Modify: `route/app.php`（后台 `aipet/pets` 那行之后）, `app/view/admin/layout.html`（桌宠导航）

**Interfaces:**
- Consumes: Task 1 模型；Task 2 `OssClient`
- Produces: 路由 `/admin/aipet/custom`、`/admin/aipet/custom/:id`、`POST /admin/aipet/custom/:id/status`、`POST /admin/aipet/custom/:id/note`、`/admin/aipet/plans`、`/admin/aipet/plans/create`、`/admin/aipet/plans/:id`、`POST /admin/aipet/plans/save`、`POST /admin/aipet/plans/:id/toggle`

- [ ] **Step 1: 控制器**

`app/controller/admin/AipetCustom.php`：

```php
<?php
declare(strict_types=1);

namespace app\controller\admin;

use think\Request;
use think\Response;
use app\model\AipetCustomRequest;
use app\model\AipetPlan;
use app\model\User;
use app\service\aipet\OssClient;
use app\support\AipetProduct;

/**
 * AI 桌宠「定制订单」「定制套餐」。状态只能 待制作 → 制作中 → 已完成 往前推；
 * 退款走订单管理（退款后定制单自动变「已退款」）。套餐不删除，只上下架。
 */
class AipetCustom
{
    private const PER_PAGE = 20;
    private const NEXT = [
        AipetCustomRequest::STATUS_PAID   => AipetCustomRequest::STATUS_MAKING,
        AipetCustomRequest::STATUS_MAKING => AipetCustomRequest::STATUS_DONE,
    ];

    public function index(Request $request): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $status = (string) $request->get('status', '');
        $q      = trim((string) $request->get('q', ''));
        $page   = max(1, (int) $request->get('page', 1));

        $build = function () use ($status, $q) {
            $query = AipetCustomRequest::order('id', 'desc');
            if ($status !== '' && array_key_exists($status, AipetCustomRequest::STATUS_LABELS)) {
                $query->where('status', $status);
            }
            if ($q !== '') {
                $query->whereIn('user_id', User::where('phone', $q)->column('id') ?: [0]);
            }
            return $query;
        };
        $total = $build()->count();
        $rows  = $build()->page($page, self::PER_PAGE)->select();
        $users = $this->phones(array_map(fn ($r) => (int) $r->user_id, $rows->all()));
        $plans = AipetPlan::column('name', 'code');

        $list = array_map(fn (AipetCustomRequest $r) => [
            'id'           => $r->id,
            'name'         => $r->name,
            'species'      => AipetCustomRequest::SPECIES[$r->species] ?? $r->species,
            'plan'         => $r->plan_code ? ($plans[$r->plan_code] ?? $r->plan_code) : '—',
            'price'        => $r->price_cents !== null ? number_format($r->price_cents / 100, 2) : '—',
            'status'       => $r->status,
            'status_label' => AipetCustomRequest::STATUS_LABELS[$r->status] ?? $r->status,
            'phone'        => $users[(int) $r->user_id] ?? '—',
            'created_at'   => $r->created_at,
            'paid_at'      => $r->paid_at ?: '—',
        ], $rows->all());

        return view('admin/aipet/custom.html', [
            'title'    => '定制订单',
            'active'   => 'aipet_custom',
            'rows'     => $list,
            'total'    => $total,
            'status'   => $status,
            'q'        => $q,
            'statuses' => AipetCustomRequest::STATUS_LABELS,
            'page'     => $page,
            'pages'    => max(1, (int) ceil($total / self::PER_PAGE)),
            'prev'     => $page - 1,
            'next'     => $page + 1,
        ]);
    }

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

        return view('admin/aipet/custom_show.html', [
            'title'        => '定制订单 #' . $r->id,
            'active'       => 'aipet_custom',
            'r'            => $r,
            'species'      => AipetCustomRequest::SPECIES[$r->species] ?? $r->species,
            'status_label' => AipetCustomRequest::STATUS_LABELS[$r->status] ?? $r->status,
            'next'         => self::NEXT[$r->status] ?? '',
            'next_label'   => isset(self::NEXT[$r->status]) ? AipetCustomRequest::STATUS_LABELS[self::NEXT[$r->status]] : '',
            'plan_name'    => $plan ? $plan->name : ($r->plan_code ?: '—'),
            'price'        => $r->price_cents !== null ? number_format($r->price_cents / 100, 2) : '—',
            'phone'        => $user ? AipetProduct::maskPhone($user->phone) : '—',
            'user_id'      => $r->user_id,
            'photos'       => $photos,
            'oss_ok'       => $oss !== null,
            'status_msg'   => flash('status'),
            'error_msg'    => flash('admin_error'),
        ]);
    }

    public function status(Request $request, $id): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $r = AipetCustomRequest::find((int) $id);
        if (! $r) {
            return response('Not Found', 404);
        }
        $to = (string) $request->post('to', '');
        if ((self::NEXT[$r->status] ?? null) !== $to) {
            flash_set('admin_error', '状态只能按 待制作 → 制作中 → 已完成 往前推。');
        } else {
            $r->status = $to;
            $r->save();
            flash_set('status', '已改为「' . AipetCustomRequest::STATUS_LABELS[$to] . '」。');
        }
        return redirect('/admin/aipet/custom/' . $r->id);
    }

    public function note(Request $request, $id): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $r = AipetCustomRequest::find((int) $id);
        if (! $r) {
            return response('Not Found', 404);
        }
        $r->admin_note = mb_substr(trim((string) $request->post('admin_note', '')), 0, 2000);
        $r->save();
        flash_set('status', '备注已保存。');
        return redirect('/admin/aipet/custom/' . $r->id);
    }

    // ---- 套餐 ----

    public function plans(): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $rows = array_map(fn (AipetPlan $p) => $p->toApi() + [
            'id' => $p->id, 'enabled' => (int) $p->enabled, 'sort' => (int) $p->sort,
            'price' => number_format($p->price_cents / 100, 2),
        ], AipetPlan::order('sort', 'asc')->order('id', 'asc')->select()->all());

        return view('admin/aipet/plans.html', [
            'title' => '定制套餐', 'active' => 'aipet_plans', 'rows' => $rows,
            'status_msg' => flash('status'), 'error_msg' => flash('admin_error'),
        ]);
    }

    public function edit($id = null): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $p = $id ? AipetPlan::find((int) $id) : null;
        if ($id && ! $p) {
            return response('Not Found', 404);
        }
        return view('admin/aipet/plan_edit.html', [
            'title'  => $p ? '编辑套餐' : '新建套餐',
            'active' => 'aipet_plans',
            'p'      => $p ? $p->toApi() + ['id' => $p->id, 'sort' => $p->sort, 'enabled' => $p->enabled,
                                         'price_yuan' => number_format($p->price_cents / 100, 2, '.', '')]
                           : ['id' => 0, 'code' => '', 'name' => '', 'subtitle' => '', 'price_yuan' => '', 'valid_days' => 0,
                              'tags' => [], 'features' => [], 'feature_count' => 0, 'fidelity' => 0, 'revisions' => 0,
                              'badge' => '', 'icon' => 'standard', 'sort' => 0, 'enabled' => 1],
            'error_msg' => flash('admin_error'),
        ]);
    }

    public function save(Request $request): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $id    = (int) $request->post('id', 0);
        $p     = $id ? AipetPlan::find($id) : new AipetPlan();
        $back  = $id ? '/admin/aipet/plans/' . $id : '/admin/aipet/plans/create';
        if (! $p) {
            return response('Not Found', 404);
        }
        $lines = fn (string $f) => array_values(array_filter(array_map('trim', preg_split('/\r?\n/', (string) $request->post($f, ''))), 'strlen'));
        $code  = trim((string) $request->post('code', ''));
        $name  = trim((string) $request->post('name', ''));
        $price = (string) $request->post('price_yuan', '');

        if (! $id) {
            if (! preg_match('/^[a-z0-9_]{2,32}$/', $code)) {
                flash_set('admin_error', '套餐代码只能是 2–32 位小写字母、数字、下划线。');
                return redirect($back);
            }
            if (AipetPlan::where('code', $code)->find()) {
                flash_set('admin_error', '套餐代码已存在。');
                return redirect($back);
            }
            $p->code = $code;
        }
        if ($name === '' || ! preg_match('/^\d+(\.\d{1,2})?$/', $price) || (float) $price <= 0) {
            flash_set('admin_error', '名称不能为空，价格要是大于 0 的金额（最多两位小数）。');
            return redirect($back);
        }

        $p->name          = mb_substr($name, 0, 50);
        $p->subtitle      = mb_substr(trim((string) $request->post('subtitle', '')), 0, 100);
        $p->price_cents   = (int) round((float) $price * 100);
        $p->valid_days    = max(0, (int) $request->post('valid_days', 0));
        $p->tags          = $lines('tags');
        $p->features      = $lines('features');
        $p->feature_count = max(0, (int) $request->post('feature_count', 0));
        $p->fidelity      = min(100, max(0, (int) $request->post('fidelity', 0)));
        $p->revisions     = min(255, max(0, (int) $request->post('revisions', 0)));
        $badge            = trim((string) $request->post('badge', ''));
        $p->badge         = $badge === '' ? null : mb_substr($badge, 0, 16);
        $p->icon          = $request->post('icon') === 'pro' ? 'pro' : 'standard';
        $p->sort          = (int) $request->post('sort', 0);
        $p->enabled       = $request->post('enabled') ? 1 : 0;
        $p->save();

        flash_set('status', '套餐已保存。');
        return redirect('/admin/aipet/plans');
    }

    public function toggle($id): Response
    {
        if ($blocked = AipetProduct::guard()) {
            return $blocked;
        }
        $p = AipetPlan::find((int) $id);
        if (! $p) {
            return response('Not Found', 404);
        }
        $p->enabled = $p->enabled ? 0 : 1;
        $p->save();
        flash_set('status', '「' . $p->name . '」已' . ($p->enabled ? '上架' : '下架') . '。');
        return redirect('/admin/aipet/plans');
    }

    /** @return array<int, string> user_id → 脱敏手机号 */
    private function phones(array $ids): array
    {
        $ids = array_values(array_unique(array_filter($ids)));
        if (! $ids) {
            return [];
        }
        return array_map(fn ($p) => AipetProduct::maskPhone($p), User::whereIn('id', $ids)->column('phone', 'id'));
    }
}
```

- [ ] **Step 2: 视图**

`app/view/admin/aipet/custom.html`：

```html
{extend name="admin/layout" /}
{block name="content"}
<form class="toolbar" method="get" action="/admin/aipet/custom">
    <div>
        <label>状态</label>
        <select name="status">
            <option value="" {if $status == ''}selected{/if}>全部</option>
            {foreach $statuses as $k => $v}
            {if $k != 'draft'}<option value="{$k}" {if $status == $k}selected{/if}>{$v}</option>{/if}
            {/foreach}
        </select>
    </div>
    <div><label>手机号</label><input name="q" value="{$q}" placeholder="完整 11 位"></div>
    <button class="btn btn-pri" type="submit">筛选</button>
    <a class="btn" href="/admin/aipet/custom">重置</a>
</form>

<div class="panel">
    <h2>定制订单（共 {$total} 单）</h2>
    <table>
        <thead><tr><th>#</th><th>名字</th><th>类别</th><th>套餐</th><th class="num">金额</th><th>状态</th><th>手机号</th><th>付款时间</th><th>创建时间</th></tr></thead>
        <tbody>
        {volist name="rows" id="r"}
            <tr>
                <td><a class="link" href="/admin/aipet/custom/{$r.id}">{$r.id}</a></td>
                <td><a class="link" href="/admin/aipet/custom/{$r.id}">{$r.name}</a></td>
                <td>{$r.species}</td>
                <td>{$r.plan}</td>
                <td class="num">{$r.price}</td>
                <td>{$r.status_label}</td>
                <td>{$r.phone}</td>
                <td class="muted">{$r.paid_at}</td>
                <td class="muted">{$r.created_at}</td>
            </tr>
        {/volist}
        {empty name="rows"}<tr><td colspan="9" class="muted">暂无定制单</td></tr>{/empty}
        </tbody>
    </table>
    {if $pages > 1}
    <div class="actions" style="margin-top:12px">
        {if $page > 1}<a class="btn" href="/admin/aipet/custom?status={$status}&q={$q|urlencode}&page={$prev}">上一页</a>{/if}
        <span class="muted">第 {$page} / {$pages} 页</span>
        {if $page < $pages}<a class="btn" href="/admin/aipet/custom?status={$status}&q={$q|urlencode}&page={$next}">下一页</a>{/if}
    </div>
    {/if}
</div>
{/block}
```

`app/view/admin/aipet/custom_show.html`：

```html
{extend name="admin/layout" /}
{block name="content"}
<div style="margin-bottom:14px"><a class="link" href="/admin/aipet/custom">← 返回定制订单</a></div>
{if $status_msg}<div class="flash ok">{$status_msg}</div>{/if}
{if $error_msg}<div class="flash err">{$error_msg}</div>{/if}

<div class="panel">
    <h2>定制单 #{$r.id} · {$status_label}</h2>
    <div class="kv">
        <div class="k">名字</div><div>{$r.name}</div>
        <div class="k">类别</div><div>{$species}</div>
        <div class="k">套餐</div><div>{$plan_name}（{$price} 元）</div>
        <div class="k">订单号</div><div>{$r.order_no|default='—'}</div>
        <div class="k">用户</div><div><a class="link" href="/admin/users/{$user_id}">#{$user_id}</a> {$phone}</div>
        <div class="k">付款时间</div><div class="muted">{$r.paid_at|default='—'}</div>
        <div class="k">创建时间</div><div class="muted">{$r.created_at}</div>
    </div>
</div>

<div class="panel">
    <h2>照片（链接 10 分钟内有效，过期刷新本页）</h2>
    {if !$oss_ok}<p class="muted">OSS 未配置，无法查看照片。key：</p>{/if}
    <div style="display:flex;gap:12px;flex-wrap:wrap">
    {volist name="photos" id="ph"}
        {if $ph.url}
        <a href="{$ph.url}" target="_blank" rel="noopener"><img src="{$ph.url}" style="width:200px;height:200px;object-fit:cover;border-radius:8px;border:1px solid #ddd"></a>
        {else /}<code>{$ph.key}</code>{/if}
    {/volist}
    </div>
</div>

<div class="panel">
    <h2>操作</h2>
    <div class="actions">
        {if $next}
        <form method="post" action="/admin/aipet/custom/{$r.id}/status" class="inline">
            <input type="hidden" name="__token__" value="{:csrf_token()}">
            <input type="hidden" name="to" value="{$next}">
            <button class="btn btn-pri" type="submit">改为「{$next_label}」</button>
        </form>
        {else /}<span class="muted">当前状态没有下一步。退款请到订单管理里操作该订单。</span>{/if}
        {if $r.order_no}<a class="btn" href="/admin/orders?q={$r.order_no}">去订单管理</a>{/if}
    </div>
    <form method="post" action="/admin/aipet/custom/{$r.id}/note" style="margin-top:14px">
        <input type="hidden" name="__token__" value="{:csrf_token()}">
        <label>备注（仅后台可见）</label>
        <textarea name="admin_note" rows="4" style="width:100%">{$r.admin_note}</textarea>
        <button class="btn" type="submit" style="margin-top:8px">保存备注</button>
    </form>
</div>
{/block}
```

`app/view/admin/aipet/plans.html`：

```html
{extend name="admin/layout" /}
{block name="content"}
{if $status_msg}<div class="flash ok">{$status_msg}</div>{/if}
{if $error_msg}<div class="flash err">{$error_msg}</div>{/if}
<div class="panel">
    <h2>定制套餐 <a class="btn btn-pri" href="/admin/aipet/plans/create" style="float:right">新建套餐</a></h2>
    <table>
        <thead><tr><th>排序</th><th>代码</th><th>名称</th><th class="num">价格</th><th>有效期</th><th>还原度</th><th>修改次数</th><th>角标</th><th>状态</th><th></th></tr></thead>
        <tbody>
        {volist name="rows" id="p"}
            <tr>
                <td>{$p.sort}</td>
                <td>{$p.code}</td>
                <td>{$p.name}</td>
                <td class="num">{$p.price}</td>
                <td>{if $p.valid_days == 0}永久{else /}{$p.valid_days} 天{/if}</td>
                <td>{$p.fidelity}%</td>
                <td>{$p.revisions}</td>
                <td>{$p.badge|default='—'}</td>
                <td>{if $p.enabled}上架{else /}<span class="muted">下架</span>{/if}</td>
                <td>
                    <a class="link" href="/admin/aipet/plans/{$p.id}">编辑</a>
                    <form method="post" action="/admin/aipet/plans/{$p.id}/toggle" class="inline">
                        <input type="hidden" name="__token__" value="{:csrf_token()}">
                        <button class="btn" type="submit">{if $p.enabled}下架{else /}上架{/if}</button>
                    </form>
                </td>
            </tr>
        {/volist}
        {empty name="rows"}<tr><td colspan="10" class="muted">还没有套餐（先执行迁移 2026-10-02_aipet_custom.sql）</td></tr>{/empty}
        </tbody>
    </table>
</div>
{/block}
```

`app/view/admin/aipet/plan_edit.html`：

```html
{extend name="admin/layout" /}
{block name="content"}
<div style="margin-bottom:14px"><a class="link" href="/admin/aipet/plans">← 返回定制套餐</a></div>
{if $error_msg}<div class="flash err">{$error_msg}</div>{/if}
<div class="panel">
    <h2>{$title}</h2>
    <form method="post" action="/admin/aipet/plans/save" class="form">
        <input type="hidden" name="__token__" value="{:csrf_token()}">
        <input type="hidden" name="id" value="{$p.id}">
        <div><label>代码（创建后不可改）</label><input name="code" value="{$p.code}" {if $p.id}disabled{/if} placeholder="如 standard"></div>
        <div><label>名称</label><input name="name" value="{$p.name}"></div>
        <div><label>副标题</label><input name="subtitle" value="{$p.subtitle}"></div>
        <div><label>价格（元）</label><input name="price_yuan" value="{$p.price_yuan}"></div>
        <div><label>有效期（天，0 = 永久）</label><input name="valid_days" value="{$p.valid_days}"></div>
        <div><label>标签（每行一个）</label><textarea name="tags" rows="3">{:implode("\n", $p['tags'])}</textarea></div>
        <div><label>包含功能（每行一个）</label><textarea name="features" rows="8">{:implode("\n", $p['features'])}</textarea></div>
        <div><label>功能数（显示「N 项功能」）</label><input name="feature_count" value="{$p.feature_count}"></div>
        <div><label>还原度（%）</label><input name="fidelity" value="{$p.fidelity}"></div>
        <div><label>修改次数</label><input name="revisions" value="{$p.revisions}"></div>
        <div><label>角标（如「推荐」，留空不显示）</label><input name="badge" value="{$p.badge}"></div>
        <div>
            <label>图标</label>
            <select name="icon">
                <option value="standard" {if $p.icon == 'standard'}selected{/if}>标准（橙色爪印）</option>
                <option value="pro" {if $p.icon == 'pro'}selected{/if}>Pro（紫色勋章）</option>
            </select>
        </div>
        <div><label>排序（小的在前）</label><input name="sort" value="{$p.sort}"></div>
        <div><label><input type="checkbox" name="enabled" value="1" {if $p.enabled}checked{/if}> 上架</label></div>
        <button class="btn btn-pri" type="submit">保存</button>
    </form>
</div>
{/block}
```

执行时先打开一个现有后台页（如 `app/view/admin/aipet/devices.html`、`settings` 下的表单页）核对 `flash`、`form` 的 class 名；若现有页面用的是别的 class（例如 `alert`），照现有的改，不要新增 CSS。

- [ ] **Step 3: 路由与导航**

`route/app.php` 后台分组里，`Route::get('aipet/pets', 'admin.Aipet/pets');` 之后加（`create` 必须在 `:id` 之前，`:id` 限定数字）：

```php
        Route::get('aipet/custom',             'admin.AipetCustom/index');
        Route::get('aipet/custom/:id',         'admin.AipetCustom/show')->pattern(['id' => '\d+']);
        Route::post('aipet/custom/:id/status', 'admin.AipetCustom/status')->pattern(['id' => '\d+']);
        Route::post('aipet/custom/:id/note',   'admin.AipetCustom/note')->pattern(['id' => '\d+']);
        Route::get('aipet/plans',              'admin.AipetCustom/plans');
        Route::get('aipet/plans/create',       'admin.AipetCustom/edit');
        Route::post('aipet/plans/save',        'admin.AipetCustom/save');
        Route::get('aipet/plans/:id',          'admin.AipetCustom/edit')->pattern(['id' => '\d+']);
        Route::post('aipet/plans/:id/toggle',  'admin.AipetCustom/toggle')->pattern(['id' => '\d+']);
```

`app/view/admin/layout.html` 在「宠物与互动」那行之后加：

```html
            <a href="/admin/aipet/custom" class="{if $active=='aipet_custom'}on{/if}">定制订单</a>
            <a href="/admin/aipet/plans" class="{if $active=='aipet_plans'}on{/if}">定制套餐</a>
```

- [ ] **Step 4: 检查**

Run: `php -l app/controller/admin/AipetCustom.php && php -l route/app.php`
Expected: `No syntax errors detected`

Run: `php think run --port 8089` 后 `curl -s -o /dev/null -w "%{http_code}\n" -H "Host: aipet.localhost" http://127.0.0.1:8089/admin/aipet/plans`
Expected: `302`（未登录后台跳登录页，说明路由存在）。停掉 `php think run`。

- [ ] **Step 5: Commit**

```bash
git add app/controller/admin/AipetCustom.php app/view/admin/aipet/custom.html app/view/admin/aipet/custom_show.html app/view/admin/aipet/plans.html app/view/admin/aipet/plan_edit.html route/app.php app/view/admin/layout.html
git commit -m "AI 桌宠后台：定制订单（看照片、推进制作状态、备注）与定制套餐（改价、上下架）"
```

---

### Task 6: 服务器验收清单

**Files:**
- Modify: `README.md`（在现有 aipet 验收段之后加一段）

- [ ] **Step 1: 写清单**

在 `README.md` 现有「AI 桌宠」服务器验证段之后加：

```markdown
### AI 桌宠 · 定制下单（服务器验收）

前置：执行 `database/migrations/2026-10-02_aipet_custom.sql`；`.env` 填 `[OSS]`；OSS bucket 私有、CORS 允许 POST。
`TOKEN` 为手机号登录拿到的 token，`H='-H Host:aipei.pixpickai.com -H "Authorization: Bearer $TOKEN" -H Content-Type:application/json'`。

1. `php think aipet:oss-check` 四行全 ✓。
2. `GET /api/aipet/custom/plans` → 两档（standard 3900 / pro 5900），按 sort。
3. `POST upload-tickets {"count":4}` → 5010 field=count；`{"count":2}` → 两个 key 都以 `aipet/custom/<自己的 userId>/` 开头。
4. 用返回的 fields 直传两张 JPEG（`curl -F key=... -F policy=... ... -F file=@a.jpg`，file 放最后）→ 204。
5. `POST requests` 依次验证：名字 9 个字 → 5010 name；species=fish → 5010 species；用别人 / 编造的 key → 5010 photo_keys；
   没传上去的 key → 5010 photo_keys；正确参数 → draft；同一组 key 再建一次 → 5010（凭证已用）。
6. `POST requests/:id/order {"plan_code":"standard"}` 两次 → 同一个 order_no；改 `pro` → 新 order_no。
   **用 standard 那单的二维码付款**（或后台对 standard 单「标记已支付」）→ 定制单变 paid，plan_code=standard、price_cents=3900。
7. 再 `POST requests/:id/order` → 5011。`GET orders/<order_no>` → paid；别人的 order_no → 404。
8. 后台 `/admin/aipet/custom`：看到这单，照片能打开；推进 待制作 → 制作中 → 已完成；不能回退。
9. 后台订单管理对这单「标记退款」→ 定制单变已退款。
10. 后台下架 pro → `plans` 不再返回；对 pro 下单 → 5013。
11. 当天第 11 次建单 → 5012。
12. 真付：后台新建 0.01 元套餐 `test001`，客户端走完整流程用微信付款，确认自动跳「已提交」；验完下架。
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "AI 桌宠定制：服务器验收清单——本机连不了库，DB 相关在服务器按清单逐条过"
```

---

## 第二部分：客户端

> **开工前检查：** `git -C C:\Users\Administrator\code\aipet status --short apps/aipet` 里登录相关文件（`lib/domain/account_view.dart`、`lib/services/api_client.dart`、`lib/services/account_store.dart`、`main_window_*.dart` 的登录卡片）若仍未提交，先问用户由谁提交 / 是否可以一并提交，再开始 Task 7。不要把别的会话的改动混进本计划的 commit（每个 commit 只 `git add` 本任务列出的文件；若必须改到同一文件，在 commit 前向用户说明）。

### Task 7: 领域类型、接口方法、CustomService

**Files:**
- Create: `apps/aipet/lib/domain/custom_order.dart`
- Create: `apps/aipet/lib/services/custom_service.dart`
- Modify: `apps/aipet/lib/services/api_client.dart`（`putSync` 之后加六个方法）
- Test: `apps/aipet/test/domain/custom_order_test.dart`, `apps/aipet/test/services/custom_service_test.dart`

**Interfaces:**
- Consumes: `ApiClient`、`ApiResult`/`ApiOk`/`ApiError`/`ApiOffline`（已有）、`Species`、`Category`
- Produces:
  - `enum CustomStatus { draft, pendingPayment, paid, making, done, refunded }`，`CustomStatus.fromWire(String) → CustomStatus?`，`String get label`
  - `enum PayStatus { pending, paid, expired, failed, refunded }`，`PayStatus.fromWire(String) → PayStatus`（未知 → pending）
  - `class CustomPlan { code, name, subtitle, priceCents, validDays, tags, features, featureCount, fidelity, revisions, badge, icon; String get priceText; String get validText; static CustomPlan? fromJson(Object?) }`
  - `class UploadTicket { key, url, fields }`、`class CustomRequestInfo { id, name, species, planCode, planName, priceCents, status, orderNo, coverUrl }`、`class PayOrder { orderNo, amountCents, codeUrl, expiresIn }`
  - `String speciesLabel(Species)`、`String yuan(int cents)`
  - `class CustomFailure implements Exception { message, code, field }`
  - `class CustomService { Future<List<CustomPlan>> plans(); Future<List<UploadTicket>> tickets(int count); Future<CustomRequestInfo> create({name, species, photoKeys}); Future<PayOrder> order(int requestId, String planCode); Future<PayStatus> status(String orderNo); Future<List<CustomRequestInfo>> list(); }`
  - `ApiClient.customPlans() / uploadTickets(int) / createCustomRequest({name, species, photoKeys}) / customOrder(int, String) / customOrderStatus(String) / customRequests()`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/domain/custom_order_test.dart`：

```dart
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plans parse, with price and validity as the cards show them', () {
    final p = CustomPlan.fromJson({
      'code': 'pro', 'name': '高级Pro版', 'subtitle': '更丰富', 'price_cents': 5900, 'valid_days': 0,
      'tags': ['AI 定制形象'], 'features': ['站立', '行走'], 'feature_count': 13, 'fidelity': 98,
      'revisions': 5, 'badge': '推荐', 'icon': 'pro',
    })!;
    expect(p.priceText, '¥59');
    expect(p.validText, '永久解锁');
    expect(p.badge, '推荐');
    expect(p.features, ['站立', '行走']);
    final s = CustomPlan.fromJson({
      'code': 'standard', 'name': '标准版', 'subtitle': '', 'price_cents': 3950, 'valid_days': 365,
      'tags': [], 'features': [], 'feature_count': 8, 'fidelity': 85, 'revisions': 2, 'badge': null, 'icon': 'standard',
    })!;
    expect(s.priceText, '¥39.50');
    expect(s.validText, '解锁一年');
    expect(CustomPlan.fromJson({'code': 'x'}), isNull);
  });

  test('status labels follow the spec, draft reads as 待支付', () {
    expect(CustomStatus.fromWire('draft')!.label, '待支付');
    expect(CustomStatus.fromWire('pending_payment')!.label, '待支付');
    expect(CustomStatus.fromWire('paid')!.label, '待制作');
    expect(CustomStatus.fromWire('making')!.label, '制作中');
    expect(CustomStatus.fromWire('done')!.label, '已完成');
    expect(CustomStatus.fromWire('refunded')!.label, '已退款');
    expect(CustomStatus.fromWire('nope'), isNull);
    expect(PayStatus.fromWire('paid'), PayStatus.paid);
    expect(PayStatus.fromWire('weird'), PayStatus.pending);
  });

  test('requests, tickets and pay orders parse; species labels match the plaza', () {
    final r = CustomRequestInfo.fromJson({
      'id': 7, 'name': '豆豆', 'species': 'girl', 'plan_code': 'pro', 'plan_name': '高级Pro版',
      'price_cents': 5900, 'status': 'paid', 'order_no': 'PX1', 'cover_url': 'https://x/y.jpg',
    })!;
    expect(r.species, Species.girl);
    expect(r.status, CustomStatus.paid);
    expect(speciesLabel(Species.girl), '女生');
    expect(speciesLabel(Species.other), '其他宠物');
    final t = UploadTicket.fromJson({'key': 'k', 'url': 'https://b.oss', 'fields': {'key': 'k', 'policy': 'p'}})!;
    expect(t.fields, {'key': 'k', 'policy': 'p'});
    final o = PayOrder.fromJson({'order_no': 'PX2', 'amount_cents': 3900, 'code_url': 'weixin://x', 'expires_in': 900})!;
    expect(o.expiresIn, const Duration(seconds: 900));
    expect(yuan(3900), '¥39');
  });
}
```

`apps/aipet/test/services/custom_service_test.dart`：

```dart
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';

void main() {
  late FakeHttp http;
  late CustomService svc;

  setUp(() {
    http = FakeHttp();
    svc = CustomService(ApiClient(http, baseUrl: 'https://example.test', token: () => 't'));
  });

  test('every call: method, path and body as the server reads them', () async {
    http.reply = (r) => switch (r.url.path) {
          '/api/aipet/custom/plans' || '/api/aipet/custom/upload-tickets' => FakeHttp.ok([]),
          '/api/aipet/custom/requests' when r.method == 'GET' => FakeHttp.ok([]),
          '/api/aipet/custom/requests' => FakeHttp.ok({'id': 3, 'name': 'a', 'species': 'cat', 'status': 'draft'}),
          '/api/aipet/custom/requests/3/order' =>
            FakeHttp.ok({'order_no': 'PX9', 'amount_cents': 3900, 'code_url': 'weixin://x', 'expires_in': 900}),
          _ => FakeHttp.ok({'status': 'paid'}),
        };
    await svc.plans();
    await svc.tickets(2);
    await svc.create(name: '豆豆', species: 'cat', photoKeys: ['k1', 'k2']);
    await svc.order(3, 'pro');
    expect(await svc.status('PX9'), PayStatus.paid);
    await svc.list();
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'], [
      'GET /api/aipet/custom/plans',
      'POST /api/aipet/custom/upload-tickets',
      'POST /api/aipet/custom/requests',
      'POST /api/aipet/custom/requests/3/order',
      'GET /api/aipet/custom/orders/PX9',
      'GET /api/aipet/custom/requests',
    ]);
    expect(http.sent[1].json, {'count': 2});
    expect(http.sent[2].json, {'name': '豆豆', 'species': 'cat', 'photo_keys': ['k1', 'k2']});
    expect(http.sent[3].json, {'plan_code': 'pro'});
    expect(http.sent.first.headers['Authorization'], 'Bearer t');
  });

  test('server refusals become CustomFailure with code and field', () async {
    http.reply = (_) => FakeHttp.fail(5010, '名字需要 1–8 个字', {'field': 'name'});
    await expectLater(
      svc.create(name: '', species: 'cat', photoKeys: ['k']),
      throwsA(isA<CustomFailure>()
          .having((f) => f.code, 'code', 5010)
          .having((f) => f.field, 'field', 'name')
          .having((f) => f.message, 'message', '名字需要 1–8 个字')),
    );
  });

  test('offline and 401 become CustomFailure with the client words', () async {
    http.reply = (_) => throw Exception('down');
    await expectLater(svc.plans(), throwsA(isA<CustomFailure>().having((f) => f.message, 'm', '网络连接失败，请稍后再试')));
    http.reply = (_) => FakeHttp.fail(1003, 'x', null, 401);
    await expectLater(svc.plans(), throwsA(isA<CustomFailure>().having((f) => f.message, 'm', '登录已过期，请重新登录')));
  });

  test('a malformed reply is a failure, not a crash', () async {
    http.reply = (_) => FakeHttp.ok({'unexpected': true});
    await expectLater(svc.order(1, 'pro'), throwsA(isA<CustomFailure>()));
    http.reply = (_) => FakeHttp.ok([{'code': 'bad'}, {'code': 'ok', 'name': 'n', 'subtitle': '', 'price_cents': 1,
      'valid_days': 0, 'tags': [], 'features': [], 'feature_count': 0, 'fidelity': 0, 'revisions': 0, 'icon': 'standard'}]);
    expect((await svc.plans()).map((p) => p.code), ['ok']);
  });
}
```

- [ ] **Step 2: 运行，确认失败**

Run（PowerShell，`apps/aipet`）：`flutter test test/domain/custom_order_test.dart test/services/custom_service_test.dart`
Expected: 编译失败，`custom_order.dart` / `custom_service.dart` 不存在。

- [ ] **Step 3: 实现**

`apps/aipet/lib/domain/custom_order.dart`：

```dart
import 'library_state.dart';
import 'pet.dart';

/// A custom pet's progress (custom order spec 2): draft and pending_payment
/// both read as 待支付.
enum CustomStatus {
  draft('draft', '待支付'),
  pendingPayment('pending_payment', '待支付'),
  paid('paid', '待制作'),
  making('making', '制作中'),
  done('done', '已完成'),
  refunded('refunded', '已退款');

  const CustomStatus(this.wire, this.label);
  final String wire;
  final String label;

  static CustomStatus? fromWire(Object? s) => {for (final v in values) v.wire: v}[s];

  bool get awaitingPayment => this == draft || this == pendingPayment;
}

enum PayStatus {
  pending,
  paid,
  expired,
  failed,
  refunded;

  static PayStatus fromWire(Object? s) => values.asNameMap()[s] ?? pending;
}

/// ¥39 or ¥39.50.
String yuan(int cents) =>
    cents % 100 == 0 ? '¥${cents ~/ 100}' : '¥${(cents / 100).toStringAsFixed(2)}';

/// The plaza's sub-category name for [s].
String speciesLabel(Species s) => Category.values.firstWhere((c) => c.species == s).label;

List<String> _strings(Object? j) => [for (final v in (j is List ? j : const [])) if (v is String) v];

class CustomPlan {
  const CustomPlan({
    required this.code,
    required this.name,
    required this.subtitle,
    required this.priceCents,
    required this.validDays,
    required this.tags,
    required this.features,
    required this.featureCount,
    required this.fidelity,
    required this.revisions,
    required this.badge,
    required this.icon,
  });

  final String code, name, subtitle, icon;
  final int priceCents, validDays, featureCount, fidelity, revisions;
  final List<String> tags, features;
  final String? badge;

  String get priceText => yuan(priceCents);

  String get validText => switch (validDays) {
        0 => '永久解锁',
        365 => '解锁一年',
        final d => '解锁 $d 天',
      };

  static CustomPlan? fromJson(Object? j) {
    if (j is! Map) return null;
    final code = j['code'], name = j['name'], price = j['price_cents'];
    if (code is! String || name is! String || price is! int) return null;
    int n(String k) => j[k] is int ? j[k] as int : 0;
    final badge = j['badge'];
    return CustomPlan(
      code: code,
      name: name,
      subtitle: j['subtitle'] is String ? j['subtitle'] as String : '',
      priceCents: price,
      validDays: n('valid_days'),
      tags: _strings(j['tags']),
      features: _strings(j['features']),
      featureCount: n('feature_count'),
      fidelity: n('fidelity'),
      revisions: n('revisions'),
      badge: badge is String && badge.isNotEmpty ? badge : null,
      icon: j['icon'] == 'pro' ? 'pro' : 'standard',
    );
  }
}

/// Where and how one photo may be posted to OSS (never the key secret).
class UploadTicket {
  const UploadTicket({required this.key, required this.url, required this.fields});

  final String key;
  final String url;

  /// The form fields in the order they are to be sent; the file goes last.
  final Map<String, String> fields;

  static UploadTicket? fromJson(Object? j) {
    if (j is! Map) return null;
    final key = j['key'], url = j['url'], fields = j['fields'];
    if (key is! String || url is! String || fields is! Map) return null;
    return UploadTicket(key: key, url: url, fields: {for (final e in fields.entries) '${e.key}': '${e.value}'});
  }
}

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
  });

  final int id;
  final String name;
  final Species species;
  final CustomStatus status;
  final String? planCode, planName, orderNo, coverUrl;
  final int? priceCents;

  static CustomRequestInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    final species = Species.values.asNameMap()[j['species']];
    final status = CustomStatus.fromWire(j['status']);
    if (id is! int || name is! String || species == null || status == null) return null;
    String? s(String k) => j[k] is String ? j[k] as String : null;
    return CustomRequestInfo(
      id: id,
      name: name,
      species: species,
      status: status,
      planCode: s('plan_code'),
      planName: s('plan_name'),
      priceCents: j['price_cents'] is int ? j['price_cents'] as int : null,
      orderNo: s('order_no'),
      coverUrl: s('cover_url'),
    );
  }
}

class PayOrder {
  const PayOrder({required this.orderNo, required this.amountCents, required this.codeUrl, required this.expiresIn});

  final String orderNo;
  final int amountCents;
  final String codeUrl;

  /// From when the reply arrived; the client never compares server clocks.
  final Duration expiresIn;

  static PayOrder? fromJson(Object? j) {
    if (j is! Map) return null;
    final no = j['order_no'], amount = j['amount_cents'], url = j['code_url'], secs = j['expires_in'];
    if (no is! String || amount is! int || url is! String || secs is! int) return null;
    return PayOrder(orderNo: no, amountCents: amount, codeUrl: url, expiresIn: Duration(seconds: secs));
  }
}
```

`apps/aipet/lib/services/api_client.dart`：在 `putSync` 方法之后加：

```dart

  // Custom pets (custom order spec 4.4); all need a token.

  Future<ApiResult> customPlans() => _call('GET', '/api/aipet/custom/plans');

  Future<ApiResult> uploadTickets(int count) =>
      _call('POST', '/api/aipet/custom/upload-tickets', {'count': count});

  Future<ApiResult> createCustomRequest(
          {required String name, required String species, required List<String> photoKeys}) =>
      _call('POST', '/api/aipet/custom/requests', {'name': name, 'species': species, 'photo_keys': photoKeys});

  Future<ApiResult> customOrder(int requestId, String planCode) =>
      _call('POST', '/api/aipet/custom/requests/$requestId/order', {'plan_code': planCode});

  Future<ApiResult> customOrderStatus(String orderNo) =>
      _call('GET', '/api/aipet/custom/orders/${Uri.encodeComponent(orderNo)}');

  Future<ApiResult> customRequests() => _call('GET', '/api/aipet/custom/requests');
```

`apps/aipet/lib/services/custom_service.dart`：

```dart
import '../domain/custom_order.dart';
import 'api_client.dart';

/// Why a custom-pet call did not work, in words to show; [code] and [field]
/// when the server said no (5010 carries the offending field).
class CustomFailure implements Exception {
  const CustomFailure(this.message, {this.code, this.field});

  final String message;
  final int? code;
  final String? field;

  @override
  String toString() => 'CustomFailure($code, $field, $message)';
}

/// The custom-pet endpoints as typed calls; every failure is a [CustomFailure].
class CustomService {
  CustomService(this._api);

  final ApiClient _api;

  Future<List<CustomPlan>> plans() async =>
      [for (final j in _list(await _api.customPlans())) ?CustomPlan.fromJson(j)];

  Future<List<UploadTicket>> tickets(int count) async {
    final t = [for (final j in _list(await _api.uploadTickets(count))) ?UploadTicket.fromJson(j)];
    if (t.length != count) throw const CustomFailure('服务暂时不可用，请稍后再试');
    return t;
  }

  Future<CustomRequestInfo> create(
          {required String name, required String species, required List<String> photoKeys}) async =>
      CustomRequestInfo.fromJson(
              _data(await _api.createCustomRequest(name: name, species: species, photoKeys: photoKeys))) ??
          (throw const CustomFailure('服务暂时不可用，请稍后再试'));

  Future<PayOrder> order(int requestId, String planCode) async =>
      PayOrder.fromJson(_data(await _api.customOrder(requestId, planCode))) ??
      (throw const CustomFailure('服务暂时不可用，请稍后再试'));

  Future<PayStatus> status(String orderNo) async {
    final d = _data(await _api.customOrderStatus(orderNo));
    return PayStatus.fromWire(d is Map ? d['status'] : null);
  }

  Future<List<CustomRequestInfo>> list() async =>
      [for (final j in _list(await _api.customRequests())) ?CustomRequestInfo.fromJson(j)];

  Object? _data(ApiResult r) => switch (r) {
        ApiOk(:final data) => data,
        ApiError(:final code, :final message, :final data) => throw CustomFailure(message,
            code: code, field: data is Map && data['field'] is String ? data['field'] as String : null),
        ApiOffline() => throw CustomFailure(r.message),
      };

  List<Object?> _list(ApiResult r) {
    final d = _data(r);
    return d is List ? d : const [];
  }
}
```

（`?expr` 是 Dart 3.8+ 的空感知集合元素，项目 SDK `^3.13.2` 支持。）

- [ ] **Step 4: 运行，确认通过**

Run: `flutter test test/domain/custom_order_test.dart test/services/custom_service_test.dart test/services/api_client_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git add apps/aipet/lib/domain/custom_order.dart apps/aipet/lib/services/custom_service.dart apps/aipet/lib/services/api_client.dart apps/aipet/test/domain/custom_order_test.dart apps/aipet/test/services/custom_service_test.dart
git commit -m "feat(aipet): typed client for the custom-pet endpoints

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

（若 `api_client.dart` 仍是未提交的别人的文件，按第二部分开头的规则先问用户。）

---

### Task 8: OSS 直传与照片压缩

**Files:**
- Create: `apps/aipet/lib/services/oss_uploader.dart`
- Create: `apps/aipet/lib/services/photo_prep.dart`
- Create: `apps/aipet/test/support/fake_oss.dart`
- Modify: `apps/aipet/pubspec.yaml`（`image` 依赖）
- Test: `apps/aipet/test/services/oss_uploader_test.dart`, `apps/aipet/test/services/photo_prep_test.dart`

**Interfaces:**
- Consumes: `UploadTicket`（Task 7）
- Produces:
  - `List<int> buildMultipart(String boundary, Map<String, String> fields, {required String fileField, required String filename, required String contentType, required List<int> bytes})`
  - `abstract class MultipartTransport { Future<int> post(Uri url, Map<String, String> fields, {required String filename, required List<int> bytes}); }`（file 字段名固定 `file`、类型固定 `image/jpeg`，返回 HTTP 状态；网络错误抛异常）
  - `class IoMultipartTransport implements MultipartTransport`
  - `class OssUploader { OssUploader(MultipartTransport); Future<void> upload(UploadTicket t, List<int> jpeg); }`，失败抛 `OssUploadFailed(int status)`（网络错误 status = -1）
  - `class PhotoPrepError implements Exception`；`List<int> prepPhoto(List<int> bytes, {int maxSide = 2048, int quality = 88})`；`Future<List<int>> prepPhotoInBackground(List<int> bytes)`
  - `test/support/fake_oss.dart`：`class FakeOss implements MultipartTransport { final posts = <(Uri, Map<String,String>, int)>[]; FutureOr<int> Function(Uri url, Map<String, String> fields) reply = (_, _) => 204; }`

- [ ] **Step 1: 加依赖**

Run（PowerShell，`apps/aipet`）：`flutter pub add image`
Expected: `pubspec.yaml` 出现 `image: ^4.x`

- [ ] **Step 2: 写失败的测试**

`apps/aipet/test/support/fake_oss.dart`：

```dart
import 'dart:async';

import 'package:aipet/services/oss_uploader.dart';

/// OSS as the tests see it: records each post; [reply] gives the HTTP status
/// (throwing is a network failure).
class FakeOss implements MultipartTransport {
  final posts = <(Uri, Map<String, String>, int)>[];
  FutureOr<int> Function(Uri url, Map<String, String> fields) reply = (_, _) => 204;

  @override
  Future<int> post(Uri url, Map<String, String> fields, {required String filename, required List<int> bytes}) async {
    posts.add((url, Map.of(fields), bytes.length));
    return reply(url, fields);
  }
}
```

`apps/aipet/test/services/oss_uploader_test.dart`：

```dart
import 'dart:convert';

import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_oss.dart';

void main() {
  test('multipart: the fields in order, then the file last', () {
    final body = latin1.decode(buildMultipart('BB', {'key': 'k/1.jpg', 'policy': 'P'},
        fileField: 'file', filename: 'a.jpg', contentType: 'image/jpeg', bytes: [1, 2, 3]));
    expect(body.indexOf('name="key"'), lessThan(body.indexOf('name="policy"')));
    expect(body.indexOf('name="policy"'), lessThan(body.indexOf('name="file"')));
    expect(body, contains('--BB\r\nContent-Disposition: form-data; name="key"\r\n\r\nk/1.jpg\r\n'));
    expect(body, contains('name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n\x01\x02\x03\r\n'));
    expect(body, endsWith('--BB--\r\n'));
  });

  const ticket = UploadTicket(key: 'aipet/custom/1/u.jpg', url: 'https://b.oss-cn.aliyuncs.com', fields: {'key': 'aipet/custom/1/u.jpg', 'policy': 'P'});

  test('posts the ticket fields to the ticket url; 204 is success', () async {
    final oss = FakeOss();
    await OssUploader(oss).upload(ticket, [9, 9]);
    final (url, fields, size) = oss.posts.single;
    expect(url.toString(), 'https://b.oss-cn.aliyuncs.com');
    expect(fields, ticket.fields);
    expect(size, 2);
  });

  test('a refusal or a network failure is OssUploadFailed', () async {
    final oss = FakeOss()..reply = (_, _) => 403;
    await expectLater(OssUploader(oss).upload(ticket, [1]),
        throwsA(isA<OssUploadFailed>().having((e) => e.status, 'status', 403)));
    oss.reply = (_, _) => throw Exception('down');
    await expectLater(OssUploader(oss).upload(ticket, [1]),
        throwsA(isA<OssUploadFailed>().having((e) => e.status, 'status', -1)));
  });
}
```

`apps/aipet/test/services/photo_prep_test.dart`：

```dart
import 'package:aipet/services/photo_prep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('a big PNG comes back as a JPEG no longer than 2048 on its long side', () {
    final png = img.encodePng(img.Image(width: 3000, height: 1000));
    final out = img.decodeJpg(prepPhoto(png) as dynamic)!;
    expect(out.width, 2048);
    expect(out.height, 683);
  });

  test('a small photo keeps its size', () {
    final out = img.decodeJpg(prepPhoto(img.encodeJpg(img.Image(width: 800, height: 600))) as dynamic)!;
    expect((out.width, out.height), (800, 600));
  });

  test('bytes that are not an image are PhotoPrepError', () {
    expect(() => prepPhoto([1, 2, 3, 4]), throwsA(isA<PhotoPrepError>()));
  });
}
```

（`decodeJpg` 需要 `Uint8List`；`prepPhoto` 返回的就是 `Uint8List`，`as dynamic` 只为通过静态类型。实现返回 `Uint8List` 时改为 `prepPhoto(png) as Uint8List` 并 `import 'dart:typed_data';`。）

- [ ] **Step 3: 运行，确认失败**

Run: `flutter test test/services/oss_uploader_test.dart test/services/photo_prep_test.dart`
Expected: 编译失败，`oss_uploader.dart` / `photo_prep.dart` 不存在。

- [ ] **Step 4: 实现**

`apps/aipet/lib/services/oss_uploader.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/custom_order.dart';

/// A multipart/form-data body: [fields] in their order, then the file —
/// OSS PostObject ignores every field after the file.
List<int> buildMultipart(String boundary, Map<String, String> fields,
    {required String fileField, required String filename, required String contentType, required List<int> bytes}) {
  final out = BytesBuilder(copy: false);
  void line(String s) => out.add(utf8.encode('$s\r\n'));
  fields.forEach((k, v) {
    line('--$boundary');
    line('Content-Disposition: form-data; name="$k"');
    line('');
    line(v);
  });
  line('--$boundary');
  line('Content-Disposition: form-data; name="$fileField"; filename="$filename"');
  line('Content-Type: $contentType');
  line('');
  out.add(bytes);
  line('');
  line('--$boundary--');
  return out.takeBytes();
}

/// POSTs a form with one JPEG named `file`; the HTTP status comes back,
/// a failure to get one throws.
abstract class MultipartTransport {
  Future<int> post(Uri url, Map<String, String> fields, {required String filename, required List<int> bytes});
}

class IoMultipartTransport implements MultipartTransport {
  IoMultipartTransport({this.timeout = const Duration(seconds: 60)})
      : _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  final Duration timeout;
  final HttpClient _client;

  @override
  Future<int> post(Uri url, Map<String, String> fields, {required String filename, required List<int> bytes}) async {
    final boundary = 'aipet${Random().nextInt(1 << 32)}${DateTime.now().microsecondsSinceEpoch}';
    final body = buildMultipart(boundary, fields,
        fileField: 'file', filename: filename, contentType: 'image/jpeg', bytes: bytes);
    Future<int> run() async {
      final req = await _client.postUrl(url);
      req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    return run().timeout(timeout);
  }
}

class OssUploadFailed implements Exception {
  const OssUploadFailed(this.status);

  /// The HTTP status OSS answered with; -1 when there was no answer.
  final int status;

  @override
  String toString() => 'OssUploadFailed($status)';
}

/// Sends one prepared JPEG to OSS with the ticket the server signed.
class OssUploader {
  OssUploader(this._transport);

  final MultipartTransport _transport;

  Future<void> upload(UploadTicket ticket, List<int> jpeg) async {
    final int status;
    try {
      status = await _transport.post(Uri.parse(ticket.url), ticket.fields, filename: 'photo.jpg', bytes: jpeg);
    } catch (_) {
      throw const OssUploadFailed(-1);
    }
    if (status < 200 || status >= 300) throw OssUploadFailed(status);
  }
}
```

`apps/aipet/lib/services/photo_prep.dart`：

```dart
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class PhotoPrepError implements Exception {
  const PhotoPrepError();
}

/// Any JPEG/PNG the user picked, upright, no longer than [maxSide] on its
/// long side, as a JPEG (custom order spec 3).
Uint8List prepPhoto(List<int> bytes, {int maxSide = 2048, int quality = 88}) {
  final decoded = img.decodeImage(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  if (decoded == null) throw const PhotoPrepError();
  var image = img.bakeOrientation(decoded);
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
  }
  return img.encodeJpg(image, quality: quality);
}

/// [prepPhoto] off the UI isolate, which shares the platform thread (HANDOFF
/// pitfall 2): decoding a 12 MP photo takes long enough to freeze the window.
Future<Uint8List> prepPhotoInBackground(List<int> bytes) => Isolate.run(() => prepPhoto(bytes));
```

测试里把 `as dynamic` 改成 `as Uint8List`（`prepPhoto` 返回 `Uint8List`），并 `import 'dart:typed_data';`。

- [ ] **Step 5: 运行，确认通过**

Run: `flutter test test/services/oss_uploader_test.dart test/services/photo_prep_test.dart`
Expected: All tests passed（3000×1000 缩放后高度按 `copyResize` 取整为 683；若实际为 682/684，改断言为 `closeTo(683, 1)` 并说明原因）

- [ ] **Step 6: Commit**

```bash
git add apps/aipet/lib/services/oss_uploader.dart apps/aipet/lib/services/photo_prep.dart apps/aipet/test/support/fake_oss.dart apps/aipet/test/services/oss_uploader_test.dart apps/aipet/test/services/photo_prep_test.dart apps/aipet/pubspec.yaml apps/aipet/pubspec.lock
git commit -m "feat(aipet): upload custom-pet photos straight to OSS, shrunk off the UI isolate

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: 定制页（名字 / 类别 / 照片 / 上传建单）

**Files:**
- Create: `apps/aipet/lib/app/main_window/custom_flow/custom_deps.dart`
- Create: `apps/aipet/lib/app/main_window/custom_flow/custom_form_model.dart`
- Create: `apps/aipet/lib/app/main_window/custom_flow/custom_form_page.dart`
- Modify: `apps/aipet/pubspec.yaml`（`file_selector`）
- Test: `apps/aipet/test/app/custom_form_test.dart`

**Interfaces:**
- Consumes: `CustomService`、`CustomFailure`（Task 7）；`OssUploader`、`OssUploadFailed`、`prepPhotoInBackground`、`PhotoPrepError`（Task 8）；`Group`、`Category`
- Produces:
  - `class PickedFile { const PickedFile(this.name, this.bytes); final String name; final List<int> bytes; }`
  - `class CustomDeps { CustomDeps({required this.service, required this.uploader, required this.pick, Future<List<int>> Function(List<int>)? prep}); final CustomService service; final OssUploader uploader; final Future<List<PickedFile>> Function() pick; final Future<List<int>> Function(List<int>) prep; }`（`prep` 默认 `prepPhotoInBackground`）
  - `class CustomFormModel extends ChangeNotifier`：`name`、`setName(String)`、`nameLength`、`nameError`、`group`、`category`、`setGroup(Group)`、`setCategory(Category)`、`photos`（`List<FormPhoto>`）、`addPhotos()`、`removePhoto(int)`、`busy`、`progress`、`message`、`canSubmit`、`Future<CustomRequestInfo?> submit()`
  - `class FormPhoto { final String name; final List<int> jpeg; String? key; bool failed; }`
  - `class CustomFormPage extends StatefulWidget { const CustomFormPage({required this.deps, required this.onSubmitted}); final CustomDeps deps; final void Function(BuildContext, CustomRequestInfo) onSubmitted; }`
  - 常量 `kMaxPhotos = 3`、`kNameMax = 8`

- [ ] **Step 1: 加依赖**

Run: `flutter pub add file_selector`
Expected: `pubspec.yaml` 出现 `file_selector`

- [ ] **Step 2: 写失败的测试**

`apps/aipet/test/app/custom_form_test.dart`：

```dart
import 'package:aipet/app/main_window/custom_flow/custom_deps.dart';
import 'package:aipet/app/main_window/custom_flow/custom_form_model.dart';
import 'package:aipet/app/main_window/custom_flow/custom_form_page.dart';
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:aipet/services/photo_prep.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_oss.dart';

void main() {
  late FakeHttp http;
  late FakeOss oss;
  late List<PickedFile> picks;
  late CustomDeps deps;
  var ticketSeq = 0;

  setUp(() {
    http = FakeHttp();
    oss = FakeOss();
    picks = [];
    ticketSeq = 0;
    http.reply = (r) {
      if (r.url.path == '/api/aipet/custom/upload-tickets') {
        final n = r.json['count']! as int;
        return FakeHttp.ok([
          for (var i = 0; i < n; i++)
            {'key': 'k${++ticketSeq}', 'url': 'https://b.oss', 'fields': {'key': 'k$ticketSeq'}}
        ]);
      }
      if (r.url.path == '/api/aipet/custom/requests') {
        return FakeHttp.ok({'id': 5, 'name': r.json['name'], 'species': r.json['species'], 'status': 'draft'});
      }
      return FakeHttp.ok(null);
    };
    deps = CustomDeps(
      service: CustomService(ApiClient(http, baseUrl: 'https://x', token: () => 't')),
      uploader: OssUploader(oss),
      pick: () async => picks,
      prep: (b) async => b.first == 0 ? throw const PhotoPrepError() : b,
    );
  });

  CustomFormModel model() => CustomFormModel(deps);

  test('name: trimmed, 1–8 characters, an emoji counts as one', () {
    final m = model();
    m.setName('   ');
    expect(m.nameLength, 0);
    expect(m.canSubmit, isFalse);
    m.setName('一二三四五六七八九');
    expect(m.nameLength, 9);
    expect(m.nameError, '名字最多 8 个字');
    m.setName('豆豆🐶');
    expect(m.nameLength, 3);
    expect(m.nameError, isNull);
  });

  test('photos: at most 3 even from a bigger pick; unreadable ones are left out with a message', () async {
    final m = model();
    picks = [for (var i = 1; i <= 5; i++) PickedFile('p$i.jpg', [i])];
    await m.addPhotos();
    expect(m.photos.map((p) => p.name), ['p1.jpg', 'p2.jpg', 'p3.jpg']);
    expect(m.message, '最多 3 张照片');
    m.removePhoto(0);
    picks = [const PickedFile('bad.jpg', [0])];
    await m.addPhotos();
    expect(m.photos, hasLength(2));
    expect(m.message, '无法读取图片：bad.jpg');
  });

  test('switching group picks its first real sub-category', () {
    final m = model();
    expect(m.category, Category.cat);
    m.setGroup(Group.people);
    expect(m.category, Category.girl);
    m.setCategory(Category.anime);
    expect(m.category.species!.name, 'anime');
  });

  test('submit uploads every photo then creates the request', () async {
    final m = model()..setName(' 豆豆 ');
    picks = [const PickedFile('a.jpg', [1]), const PickedFile('b.jpg', [2])];
    await m.addPhotos();
    final r = await m.submit();
    expect(r!.id, 5);
    expect(oss.posts.map((p) => p.$2['key']), ['k1', 'k2']);
    expect(http.to('/api/aipet/custom/requests').single.json,
        {'name': '豆豆', 'species': 'cat', 'photo_keys': ['k1', 'k2']});
  });

  test('a failed upload is retried alone; photos already up are not sent again', () async {
    final m = model()..setName('豆豆');
    picks = [const PickedFile('a.jpg', [1]), const PickedFile('b.jpg', [2]), const PickedFile('c.jpg', [3])];
    await m.addPhotos();
    oss.reply = (_, f) => f['key'] == 'k2' ? 500 : 204;
    expect(await m.submit(), isNull);
    expect(m.message, '第 2 张上传失败，请重试');
    expect(m.photos[1].failed, isTrue);
    expect(m.busy, isFalse);
    oss.reply = (_, _) => 204;
    final r = await m.submit();
    expect(r, isNotNull);
    expect(http.to('/api/aipet/custom/upload-tickets').map((s) => s.json['count']), [3, 2]);
    expect(http.to('/api/aipet/custom/requests').single.json['photo_keys'], ['k1', 'k4', 'k5']);
  });

  test('server refusals land where they belong; 401 says to sign in again', () async {
    final m = model()..setName('豆豆');
    picks = [const PickedFile('a.jpg', [1])];
    await m.addPhotos();
    http.reply = (r) => r.url.path.endsWith('upload-tickets')
        ? FakeHttp.ok([{'key': 'k', 'url': 'https://b', 'fields': {'key': 'k'}}])
        : FakeHttp.fail(5010, '名字需要 1–8 个字', {'field': 'name'});
    expect(await m.submit(), isNull);
    expect(m.nameError, '名字需要 1–8 个字');
    http.reply = (_) => FakeHttp.fail(1003, 'x', null, 401);
    expect(await m.submit(), isNull);
    expect(m.message, '登录已过期，请重新登录');
  });

  testWidgets('page: counter, chips, disabled button until ready, submitted callback', (tester) async {
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
    FilledButton next() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '下一步'));
    expect(next().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '豆豆');
    await tester.tap(find.text('点击上传照片'));
    await tester.pumpAndSettle();
    expect(find.text('2/8'), findsOneWidget);
    expect(next().onPressed, isNotNull);
    await tester.tap(find.text('人物'));
    await tester.pump();
    expect(find.text('女生'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '下一步'));
    await tester.pumpAndSettle();
    expect(done!.species.name, 'girl');
  });
}
```

（页面上图片缩略图用 `Image.memory`；测试的假字节解码会失败——页面要给 `Image.memory` 加 `errorBuilder` 显示占位图标，不能让测试报异常。）

- [ ] **Step 3: 运行，确认失败**

Run: `flutter test test/app/custom_form_test.dart`
Expected: 编译失败，`custom_flow/` 下文件不存在。

- [ ] **Step 4: 实现**

`apps/aipet/lib/app/main_window/custom_flow/custom_deps.dart`：

```dart
import '../../../services/custom_service.dart';
import '../../../services/oss_uploader.dart';
import '../../../services/photo_prep.dart';

/// A file the user picked: its name (for messages) and its bytes.
class PickedFile {
  const PickedFile(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}

/// What the custom-pet pages need from outside; tests pass fakes.
class CustomDeps {
  CustomDeps({
    required this.service,
    required this.uploader,
    required this.pick,
    Future<List<int>> Function(List<int>)? prep,
  }) : prep = prep ?? prepPhotoInBackground;

  final CustomService service;
  final OssUploader uploader;
  final Future<List<PickedFile>> Function() pick;
  final Future<List<int>> Function(List<int>) prep;
}
```

`apps/aipet/lib/app/main_window/custom_flow/custom_form_model.dart`：

```dart
import 'package:flutter/foundation.dart' hide Category;

import '../../../domain/custom_order.dart';
import '../../../domain/library_state.dart';
import '../../../services/custom_service.dart';
import '../../../services/oss_uploader.dart';
import '../../../services/photo_prep.dart';
import 'custom_deps.dart';

const kMaxPhotos = 3;
const kNameMax = 8;

/// One chosen photo, already shrunk to the JPEG that gets uploaded; [key] once
/// OSS has it, so a retry sends only what is still missing.
class FormPhoto {
  FormPhoto(this.name, this.jpeg);

  final String name;
  final List<int> jpeg;
  String? key;
  bool failed = false;
}

/// 定制页 (custom order spec 3, step 2).
class CustomFormModel extends ChangeNotifier {
  CustomFormModel(this._deps);

  final CustomDeps _deps;

  String _name = '';
  String? _serverNameError;
  Category _category = Category.cat;
  final List<FormPhoto> _photos = [];
  bool _busy = false;
  String? _progress;
  String? _message;

  String get name => _name;
  int get nameLength => _name.trim().runes.length;
  String? get nameError => nameLength > kNameMax ? '名字最多 $kNameMax 个字' : _serverNameError;
  Group get group => _category.group;
  Category get category => _category;
  List<FormPhoto> get photos => List.unmodifiable(_photos);
  bool get busy => _busy;

  /// 正在上传 2/3 while uploading.
  String? get progress => _progress;

  /// The last thing to tell the user; null when there is nothing.
  String? get message => _message;

  bool get canSubmit => !_busy && nameLength >= 1 && nameLength <= kNameMax && _photos.isNotEmpty;

  void setName(String v) {
    _name = v;
    _serverNameError = null;
    notifyListeners();
  }

  void setGroup(Group g) {
    if (g == group) return;
    _category = g.categories.firstWhere((c) => c.species != null);
    notifyListeners();
  }

  void setCategory(Category c) {
    if (c.species == null) return;
    _category = c;
    notifyListeners();
  }

  Future<void> addPhotos() async {
    if (_busy) return;
    _message = null;
    final room = kMaxPhotos - _photos.length;
    if (room <= 0) {
      _message = '最多 $kMaxPhotos 张照片';
      notifyListeners();
      return;
    }
    final picked = await _deps.pick();
    if (picked.length > room) _message = '最多 $kMaxPhotos 张照片';
    for (final f in picked.take(room)) {
      try {
        _photos.add(FormPhoto(f.name, await _deps.prep(f.bytes)));
      } on PhotoPrepError {
        _message = '无法读取图片：${f.name}';
      } catch (_) {
        _message = '无法读取图片：${f.name}';
      }
      notifyListeners();
    }
    notifyListeners();
  }

  void removePhoto(int i) {
    if (_busy || i < 0 || i >= _photos.length) return;
    _photos.removeAt(i);
    notifyListeners();
  }

  /// Uploads what is not up yet, then creates the request; null (with
  /// [message] or [nameError] set) when something went wrong.
  Future<CustomRequestInfo?> submit() async {
    if (!canSubmit) return null;
    _busy = true;
    _message = null;
    _serverNameError = null;
    notifyListeners();
    try {
      final missing = [for (final p in _photos) if (p.key == null) p];
      if (missing.isNotEmpty) {
        final tickets = await _deps.service.tickets(missing.length);
        for (var i = 0; i < missing.length; i++) {
          final p = missing[i];
          final n = _photos.indexOf(p) + 1;
          _progress = '正在上传 $n/${_photos.length}';
          notifyListeners();
          try {
            await _deps.uploader.upload(tickets[i], p.jpeg);
            p
              ..key = tickets[i].key
              ..failed = false;
          } on OssUploadFailed {
            p.failed = true;
            _message = '第 $n 张上传失败，请重试';
            return null;
          }
        }
      }
      _progress = '正在提交…';
      notifyListeners();
      return await _deps.service.create(
        name: _name.trim(),
        species: _category.species!.name,
        photoKeys: [for (final p in _photos) p.key!],
      );
    } on CustomFailure catch (f) {
      if (f.field == 'name') {
        _serverNameError = f.message;
      } else {
        // A stale or rejected photo key: upload them again next time.
        if (f.field == 'photo_keys') {
          for (final p in _photos) {
            p.key = null;
          }
        }
        _message = f.message;
      }
      return null;
    } finally {
      _busy = false;
      _progress = null;
      notifyListeners();
    }
  }
}
```

`apps/aipet/lib/app/main_window/custom_flow/custom_form_page.dart`：

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Category;

import '../../../domain/custom_order.dart';
import '../../../domain/library_state.dart';
import '../theme.dart';
import 'custom_deps.dart';
import 'custom_form_model.dart';

/// 定制你的专属宠物: name, category, up to three photos, 下一步.
class CustomFormPage extends StatefulWidget {
  const CustomFormPage({super.key, required this.deps, required this.onSubmitted});

  final CustomDeps deps;
  final void Function(BuildContext context, CustomRequestInfo request) onSubmitted;

  @override
  State<CustomFormPage> createState() => _CustomFormPageState();
}

class _CustomFormPageState extends State<CustomFormPage> {
  late final CustomFormModel _m = CustomFormModel(widget.deps);
  final _name = TextEditingController();

  @override
  void dispose() {
    _m.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final r = await _m.submit();
    if (r != null && mounted) widget.onSubmitted(context, r);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('定制宠物'), centerTitle: true, backgroundColor: AppColors.page),
        body: ListenableBuilder(
          listenable: _m,
          builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
            const Text('定制你的专属宠物',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.text)),
            const SizedBox(height: 6),
            const Text('上传名字与清晰照片，约1小时即可完成定制，完成后可在「我的」查看。',
                style: TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            _Card(children: [
              const _Heading(Icons.pets, '名字'),
              TextField(
                controller: _name,
                enabled: !_m.busy,
                onChanged: _m.setName,
                decoration: InputDecoration(
                  hintText: '请输入名字（1–$kNameMax 个字）',
                  errorText: _m.nameError,
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Text('${_m.nameLength}/$kNameMax', style: const TextStyle(color: AppColors.textMuted)),
              ),
              const SizedBox(height: 12),
              const _Heading(Icons.category_outlined, '类别'),
              Wrap(spacing: 8, children: [
                for (final g in Group.values)
                  ChoiceChip(
                    label: Text(g.label),
                    selected: _m.group == g,
                    selectedColor: AppColors.accentSoft,
                    onSelected: _m.busy ? null : (_) => _m.setGroup(g),
                  ),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final c in _m.group.categories)
                  if (c.species != null)
                    ChoiceChip(
                      label: Text(c.label),
                      selected: _m.category == c,
                      selectedColor: AppColors.accentSoft,
                      onSelected: _m.busy ? null : (_) => _m.setCategory(c),
                    ),
              ]),
              const SizedBox(height: 12),
              const _Heading(Icons.add_a_photo_outlined, '上传正面全身照'),
              _Photos(model: _m),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(16)),
                child: const Row(children: [
                  Icon(Icons.lightbulb_outline, color: AppColors.accent),
                  SizedBox(width: 8),
                  Expanded(child: Text('拍照小贴士：请选择正脸和全身照片，越清晰效果越好！')),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(24)),
              child: const Row(children: [
                Icon(Icons.alarm, color: AppColors.accent, size: 32),
                SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('预计1小时左右定制完成', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    Text('定制完成后即可在「我的定制」查看', style: TextStyle(color: AppColors.textMuted)),
                  ]),
                ),
              ]),
            ),
            if (_m.message != null) ...[
              const SizedBox(height: 12),
              Text(_m.message!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: _m.canSubmit ? _submit : null,
                child: Text(_m.progress ?? '下一步', style: const TextStyle(fontSize: 18)),
              ),
            ),
          ]),
        ),
      );
}

class _Photos extends StatelessWidget {
  const _Photos({required this.model});

  final CustomFormModel model;

  @override
  Widget build(BuildContext context) {
    final photos = model.photos;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (var i = 0; i < photos.length; i++)
        Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                border: photos[i].failed ? Border.all(color: Colors.redAccent, width: 2) : null,
              ),
              child: Image.memory(
                Uint8List.fromList(photos[i].jpeg),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.image_outlined, size: 40, color: AppColors.textMuted),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.cancel, color: Colors.black54),
              onPressed: model.busy ? null : () => model.removePhoto(i),
            ),
          ),
        ]),
      if (photos.length < kMaxPhotos)
        InkWell(
          onTap: model.busy ? null : model.addPhotos,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: photos.isEmpty ? double.infinity : 100,
            height: photos.isEmpty ? 160 : 100,
            decoration: BoxDecoration(
              color: AppColors.page,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.textMuted.withValues(alpha: 0.4)),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.add_a_photo, size: 36, color: AppColors.accent),
              if (photos.isEmpty) ...[
                const SizedBox(height: 8),
                const Text('点击上传照片', style: TextStyle(fontWeight: FontWeight.w700)),
                const Text('最多 3 张正面清晰照片（JPG/PNG）', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              ],
            ]),
          ),
        ),
    ]);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(24)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(icon, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ]),
      );
}
```

（测试里点「点击上传照片」时只有 1 张照片的空态文字，之后文字消失；`find.text('宠物')` 在 AppBar 标题「定制宠物」之外唯一。若与「定制宠物」冲突导致 findsNWidgets(2)，把测试断言改用 `find.widgetWithText(ChoiceChip, '宠物')`。）

- [ ] **Step 5: 运行，确认通过**

Run: `flutter test test/app/custom_form_test.dart`
Expected: All tests passed

- [ ] **Step 6: Commit**

```bash
git add apps/aipet/lib/app/main_window/custom_flow/custom_deps.dart apps/aipet/lib/app/main_window/custom_flow/custom_form_model.dart apps/aipet/lib/app/main_window/custom_flow/custom_form_page.dart apps/aipet/test/app/custom_form_test.dart apps/aipet/pubspec.yaml apps/aipet/pubspec.lock
git commit -m "feat(aipet): the custom-pet form - name, category, up to three photos, retry what failed

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: 套餐页

**Files:**
- Create: `apps/aipet/lib/app/main_window/custom_flow/plan_model.dart`
- Create: `apps/aipet/lib/app/main_window/custom_flow/plan_page.dart`
- Test: `apps/aipet/test/app/plan_page_test.dart`

**Interfaces:**
- Consumes: `CustomService`、`CustomPlan`、`PayOrder`、`CustomRequestInfo`、`CustomFailure`、`CustomDeps`
- Produces:
  - `class PlanModel extends ChangeNotifier { PlanModel(CustomService, CustomRequestInfo); plans; selected (CustomPlan?); loading; busy; message; Future<void> load(); void select(String code); Future<PayOrder?> createOrder(); }`
  - `class PlanPage extends StatefulWidget { const PlanPage({required this.deps, required this.request, required this.onOrder}); final void Function(BuildContext, CustomPlan, PayOrder) onOrder; }`

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/app/plan_page_test.dart`：

```dart
import 'package:aipet/app/main_window/custom_flow/custom_deps.dart';
import 'package:aipet/app/main_window/custom_flow/plan_model.dart';
import 'package:aipet/app/main_window/custom_flow/plan_page.dart';
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_oss.dart';

Map<String, Object?> plan(String code, String name, int cents, {int days = 0, String? badge}) => {
      'code': code, 'name': name, 'subtitle': '$name副标题', 'price_cents': cents, 'valid_days': days,
      'tags': ['AI 定制形象'], 'features': ['站立', '行走'], 'feature_count': 8, 'fidelity': 85,
      'revisions': 2, 'badge': badge, 'icon': code == 'pro' ? 'pro' : 'standard',
    };

void main() {
  late FakeHttp http;
  late CustomService svc;
  const request = CustomRequestInfo(id: 5, name: '豆豆', species: Species.cat, status: CustomStatus.draft);

  setUp(() {
    http = FakeHttp();
    svc = CustomService(ApiClient(http, baseUrl: 'https://x', token: () => 't'));
    http.reply = (r) => r.url.path.endsWith('/plans')
        ? FakeHttp.ok([plan('standard', '标准版', 3900, days: 365), plan('pro', '高级Pro版', 5900, badge: '推荐')])
        : FakeHttp.ok({'order_no': 'PX1', 'amount_cents': 5900, 'code_url': 'weixin://x', 'expires_in': 900});
  });

  test('loads plans, selects the first, orders the chosen one', () async {
    final m = PlanModel(svc, request);
    await m.load();
    expect(m.selected!.code, 'standard');
    m.select('pro');
    final o = await m.createOrder();
    expect(o!.orderNo, 'PX1');
    expect(http.to('/api/aipet/custom/requests/5/order').single.json, {'plan_code': 'pro'});
  });

  test('a plan taken off sale reloads the list and says so; already paid says so', () async {
    final m = PlanModel(svc, request);
    await m.load();
    http.reply = (r) => r.url.path.endsWith('/plans')
        ? FakeHttp.ok([plan('pro', '高级Pro版', 5900)])
        : FakeHttp.fail(5013, '该套餐已下架');
    expect(await m.createOrder(), isNull);
    expect(m.message, '该套餐已下架');
    expect(m.plans.map((p) => p.code), ['pro']);
    expect(m.selected!.code, 'pro');
    http.reply = (_) => FakeHttp.fail(5011, '这个定制已经支付过了');
    expect(await m.createOrder(), isNull);
    expect(m.message, '这个定制已经支付过了');
  });

  testWidgets('page shows the cards as in the mock and hands back the order', (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    (CustomPlan, PayOrder)? got;
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    await tester.pumpWidget(MaterialApp(
        home: PlanPage(deps: deps, request: request, onOrder: (_, p, o) => got = (p, o))));
    await tester.pumpAndSettle();
    for (final t in ['选择宠物版本', '标准版', '¥39', '解锁一年', '高级Pro版', '¥59', '永久解锁', '推荐', '还原度85%', '2次修改机会',
      '微信支付', '支付宝（即将上线）']) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    expect(find.text('已选 标准版'), findsOneWidget);
    await tester.tap(find.text('高级Pro版'));
    await tester.pump();
    expect(find.text('已选 高级Pro版'), findsOneWidget);
    await tester.tap(find.text('创建宠物'));
    await tester.pumpAndSettle();
    expect(got!.$1.code, 'pro');
    expect(got!.$2.orderNo, 'PX1');
  });
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/app/plan_page_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`apps/aipet/lib/app/main_window/custom_flow/plan_model.dart`：

```dart
import 'package:flutter/foundation.dart';

import '../../../domain/custom_order.dart';
import '../../../services/custom_service.dart';

/// 选择宠物版本 (custom order spec 3, step 3).
class PlanModel extends ChangeNotifier {
  PlanModel(this._service, this.request);

  final CustomService _service;
  final CustomRequestInfo request;

  List<CustomPlan> _plans = const [];
  String? _selected;
  bool _loading = false;
  bool _busy = false;
  String? _message;

  List<CustomPlan> get plans => _plans;
  CustomPlan? get selected => _plans.where((p) => p.code == _selected).firstOrNull;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get message => _message;

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      _plans = await _service.plans();
      if (selected == null) _selected = _plans.firstOrNull?.code;
    } on CustomFailure catch (f) {
      _message = f.message;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void select(String code) {
    if (_busy) return;
    _selected = code;
    notifyListeners();
  }

  Future<PayOrder?> createOrder() async {
    final plan = selected;
    if (plan == null || _busy) return null;
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      return await _service.order(request.id, plan.code);
    } on CustomFailure catch (f) {
      _message = f.message;
      if (f.code == 5013) {
        _busy = false;
        await load();
      }
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
```

`apps/aipet/lib/app/main_window/custom_flow/plan_page.dart`：

```dart
import 'package:flutter/material.dart';

import '../../../domain/custom_order.dart';
import '../theme.dart';
import 'custom_deps.dart';
import 'plan_model.dart';

/// 选择宠物版本: plan cards, payment method, 创建宠物.
class PlanPage extends StatefulWidget {
  const PlanPage({super.key, required this.deps, required this.request, required this.onOrder});

  final CustomDeps deps;
  final CustomRequestInfo request;
  final void Function(BuildContext context, CustomPlan plan, PayOrder order) onOrder;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  late final PlanModel _m = PlanModel(widget.deps.service, widget.request)..load();

  @override
  void dispose() {
    _m.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final plan = _m.selected;
    final o = await _m.createOrder();
    if (o != null && plan != null && mounted) widget.onOrder(context, plan, o);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: AppColors.page),
        body: ListenableBuilder(
          listenable: _m,
          builder: (context, _) => Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                const Text('选择宠物版本', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const Text('选择合适的陪伴方式', style: TextStyle(color: AppColors.textMuted)),
                const SizedBox(height: 12),
                if (_m.loading && _m.plans.isEmpty) const Center(child: CircularProgressIndicator()),
                for (final p in _m.plans)
                  _PlanCard(plan: p, selected: _m.selected?.code == p.code, onTap: () => _m.select(p.code)),
              ]),
            ),
            _Footer(model: _m, onCreate: _create),
          ]),
        ),
      );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.selected, required this.onTap});

  final CustomPlan plan;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pro = plan.icon == 'pro';
    final tint = pro ? const Color(0xFF5B5BD6) : AppColors.accent;
    Widget chip(String t, {bool strong = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: strong ? const Color(0xFFFBE3C8) : AppColors.accentSoft,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(t, style: TextStyle(fontSize: 12, fontWeight: strong ? FontWeight.w700 : FontWeight.w500)),
        );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.accent : Colors.black12, width: selected ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
              child: Icon(pro ? Icons.workspace_premium : Icons.pets, color: tint, size: 36),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(plan.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                  if (plan.badge != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(6)),
                      child: Text(plan.badge!, style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ],
                ]),
                Text(plan.subtitle, style: const TextStyle(color: AppColors.textMuted)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final t in plan.tags) chip(t),
                  chip('${plan.featureCount} 项功能'),
                  chip('还原度${plan.fidelity}%', strong: true),
                  chip('${plan.revisions}次修改机会'),
                ]),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(plan.priceText, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: tint)),
              Text(plan.validText, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(height: 8),
              Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? AppColors.accent : Colors.black26, size: 28),
            ]),
          ]),
          if (plan.features.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12)),
              child: Text('包含功能：${plan.features.join(' · ')}', style: const TextStyle(fontSize: 13)),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.model, required this.onCreate});

  final PlanModel model;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final p = model.selected;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      color: AppColors.card,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (p != null)
          Row(children: [
            const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
            const SizedBox(width: 6),
            Text('已选 ${p.name}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(p.priceText, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.accent)),
          ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.chat_bubble, color: Color(0xFF07C160)),
              label: const Text('微信支付'),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.accent, width: 2)),
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: OutlinedButton(onPressed: null, child: Text('支付宝（即将上线）')),
          ),
        ]),
        if (model.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(model.message!, style: const TextStyle(color: Colors.redAccent)),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: p == null || model.busy ? null : onCreate,
            child: Text(model.busy ? '正在创建订单…' : '创建宠物', style: const TextStyle(fontSize: 18)),
          ),
        ),
      ]),
    );
  }
}
```

- [ ] **Step 4: 运行，确认通过**

Run: `flutter test test/app/plan_page_test.dart`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git add apps/aipet/lib/app/main_window/custom_flow/plan_model.dart apps/aipet/lib/app/main_window/custom_flow/plan_page.dart apps/aipet/test/app/plan_page_test.dart
git commit -m "feat(aipet): choose a custom-pet plan, prices and features from the server

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: 支付页与已提交页

**Files:**
- Create: `apps/aipet/lib/app/main_window/custom_flow/pay_model.dart`
- Create: `apps/aipet/lib/app/main_window/custom_flow/pay_page.dart`
- Create: `apps/aipet/lib/app/main_window/custom_flow/submitted_page.dart`
- Modify: `apps/aipet/pubspec.yaml`（`qr_flutter`）
- Test: `apps/aipet/test/app/pay_page_test.dart`

**Interfaces:**
- Consumes: `CustomService`、`PayOrder`、`PayStatus`、`CustomPlan`、`CustomRequestInfo`、`CustomDeps`
- Produces:
  - `class PayModel extends ChangeNotifier { PayModel({required CustomService service, required int requestId, required String planCode, required PayOrder order, Duration pollEvery = const Duration(seconds: 2)}); PayOrder get order; bool get paid; bool get expired; Duration get left; String? get message; void start(); Future<void> refresh(); }`（`dispose` 取消计时器）
  - `class PayPage extends StatefulWidget { const PayPage({required this.deps, required this.request, required this.plan, required this.order, required this.onPaid}); final void Function(BuildContext) onPaid; }`
  - `class SubmittedPage extends StatelessWidget { const SubmittedPage({required this.onDone}); final void Function(BuildContext) onDone; }`

- [ ] **Step 1: 加依赖**

Run: `flutter pub add qr_flutter`

- [ ] **Step 2: 写失败的测试**

`apps/aipet/test/app/pay_page_test.dart`：

```dart
import 'package:aipet/app/main_window/custom_flow/custom_deps.dart';
import 'package:aipet/app/main_window/custom_flow/pay_model.dart';
import 'package:aipet/app/main_window/custom_flow/pay_page.dart';
import 'package:aipet/app/main_window/custom_flow/submitted_page.dart';
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_oss.dart';

void main() {
  late FakeHttp http;
  late CustomService svc;
  var status = 'pending';
  const order = PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'weixin://wxpay/x', expiresIn: Duration(minutes: 15));
  const request = CustomRequestInfo(id: 5, name: '豆豆', species: Species.cat, status: CustomStatus.pendingPayment);
  const plan = CustomPlan(code: 'standard', name: '标准版', subtitle: '', priceCents: 3900, validDays: 365, tags: [],
      features: [], featureCount: 8, fidelity: 85, revisions: 2, badge: null, icon: 'standard');

  setUp(() {
    status = 'pending';
    http = FakeHttp()
      ..reply = (r) => r.url.path.endsWith('/order')
          ? FakeHttp.ok({'order_no': 'PX2', 'amount_cents': 3900, 'code_url': 'weixin://wxpay/y', 'expires_in': 900})
          : FakeHttp.ok({'status': status});
    svc = CustomService(ApiClient(http, baseUrl: 'https://x', token: () => 't'));
  });

  testWidgets('polls every 2 s and reports paid', (tester) async {
    var paid = 0;
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    await tester.pumpWidget(MaterialApp(
        home: PayPage(deps: deps, request: request, plan: plan, order: order, onPaid: (_) => paid++)));
    expect(find.text('¥39'), findsWidgets);
    expect(find.text('请使用微信扫码支付'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(http.to('/api/aipet/custom/orders/PX1'), hasLength(1));
    status = 'paid';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(paid, 1);
    await tester.pump(const Duration(seconds: 6));
    expect(http.to('/api/aipet/custom/orders/PX1'), hasLength(2), reason: 'polling stops once paid');
  });

  testWidgets('expiry shows the refresh prompt; refreshing gets a new code', (tester) async {
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    const short = PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'weixin://wxpay/x', expiresIn: Duration(seconds: 3));
    await tester.pumpWidget(MaterialApp(
        home: PayPage(deps: deps, request: request, plan: plan, order: short, onPaid: (_) {})));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.text('二维码已过期，点击刷新'), findsOneWidget);
    await tester.tap(find.text('二维码已过期，点击刷新'));
    await tester.pump();
    await tester.pump();
    expect(http.to('/api/aipet/custom/requests/5/order').single.json, {'plan_code': 'standard'});
    expect(find.text('二维码已过期，点击刷新'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('leaving the page stops polling', () async {
    final m = PayModel(service: svc, requestId: 5, planCode: 'standard', order: order,
        pollEvery: const Duration(milliseconds: 10))
      ..start();
    await Future<void>.delayed(const Duration(milliseconds: 35));
    m.dispose();
    final n = http.sent.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(http.sent.length, n);
  });

  testWidgets('submitted page says what happens next', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(home: SubmittedPage(onDone: (_) => done++)));
    expect(find.text('定制已提交'), findsOneWidget);
    expect(find.text('预计 1 小时左右完成，完成后可在「我的定制」查看'), findsOneWidget);
    await tester.tap(find.text('查看我的定制'));
    expect(done, 1);
  });
}
```

- [ ] **Step 3: 运行，确认失败**

Run: `flutter test test/app/pay_page_test.dart`
Expected: 编译失败。

- [ ] **Step 4: 实现**

`apps/aipet/lib/app/main_window/custom_flow/pay_model.dart`：

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/custom_order.dart';
import '../../../services/custom_service.dart';

/// The WeChat QR and its order: asks every [pollEvery] whether it is paid,
/// stops when paid, expired or disposed (custom order spec 3, step 4).
/// Time left counts down by ticks, not by the wall clock: widget tests run on
/// fake time, and DateTime.now() does not follow it.
class PayModel extends ChangeNotifier {
  PayModel({
    required CustomService service,
    required this.requestId,
    required this.planCode,
    required PayOrder order,
    this.pollEvery = const Duration(seconds: 2),
  })  : _service = service,
        _order = order,
        _left = order.expiresIn;

  final CustomService _service;
  final int requestId;
  final String planCode;
  final Duration pollEvery;

  PayOrder _order;
  Duration _left;
  Timer? _timer;
  bool _paid = false;
  bool _expired = false;
  bool _asking = false;
  bool _disposed = false;
  String? _message;

  PayOrder get order => _order;
  bool get paid => _paid;
  bool get expired => _expired;
  String? get message => _message;
  Duration get left => _left.isNegative ? Duration.zero : _left;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(pollEvery, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_disposed || _paid || _expired) return;
    _left -= pollEvery;
    if (_left <= Duration.zero) {
      _expire();
      return;
    }
    notifyListeners(); // the countdown
    if (_asking) return;
    _asking = true;
    try {
      final s = await _service.status(_order.orderNo);
      if (_disposed) return;
      if (s == PayStatus.paid) {
        _paid = true;
        _timer?.cancel();
        notifyListeners();
      } else if (s == PayStatus.expired || s == PayStatus.failed) {
        _expire();
      }
    } on CustomFailure {
      // A missed poll is not an answer; the next tick asks again.
    } finally {
      _asking = false;
    }
  }

  void _expire() {
    _expired = true;
    _timer?.cancel();
    notifyListeners();
  }

  /// A fresh QR after expiry (the server makes a new order).
  Future<void> refresh() async {
    _message = null;
    try {
      final o = await _service.order(requestId, planCode);
      if (_disposed) return;
      _order = o;
      _left = o.expiresIn;
      _expired = false;
      start();
    } on CustomFailure catch (f) {
      _message = f.message;
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
```

`apps/aipet/lib/app/main_window/custom_flow/pay_page.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../domain/custom_order.dart';
import '../theme.dart';
import 'custom_deps.dart';
import 'pay_model.dart';

/// 微信扫码支付: QR, amount, countdown; [onPaid] once the server says paid.
class PayPage extends StatefulWidget {
  const PayPage({
    super.key,
    required this.deps,
    required this.request,
    required this.plan,
    required this.order,
    required this.onPaid,
  });

  final CustomDeps deps;
  final CustomRequestInfo request;
  final CustomPlan plan;
  final PayOrder order;
  final void Function(BuildContext context) onPaid;

  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends State<PayPage> {
  late final PayModel _m = PayModel(
    service: widget.deps.service,
    requestId: widget.request.id,
    planCode: widget.plan.code,
    order: widget.order,
  )
    ..addListener(_onChange)
    ..start();
  var _reported = false;

  void _onChange() {
    if (_m.paid && !_reported && mounted) {
      _reported = true;
      widget.onPaid(context);
    }
  }

  @override
  void dispose() {
    _m
      ..removeListener(_onChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('微信支付'), centerTitle: true, backgroundColor: AppColors.page),
        body: ListenableBuilder(
          listenable: _m,
          builder: (context, _) {
            final left = _m.left;
            final mm = left.inMinutes.toString().padLeft(2, '0');
            final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
            return ListView(padding: const EdgeInsets.all(24), children: [
              Text('${widget.request.name} · ${widget.plan.name}',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(yuan(_m.order.amountCents),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: AppColors.accent)),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: _m.expired
                      ? SizedBox(
                          width: 220,
                          height: 220,
                          child: Center(
                            child: TextButton(onPressed: _m.refresh, child: const Text('二维码已过期，点击刷新')),
                          ),
                        )
                      : QrImageView(data: _m.order.codeUrl, size: 220),
                ),
              ),
              const SizedBox(height: 12),
              const Text('请使用微信扫码支付', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700)),
              if (!_m.expired)
                Text('二维码 $mm:$ss 后过期', textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
              const SizedBox(height: 8),
              const Text('支付完成后会自动跳转；关闭本页也可以在「我的定制」里继续支付',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              if (_m.message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_m.message!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                ),
            ]);
          },
        ),
      );
}
```

`apps/aipet/lib/app/main_window/custom_flow/submitted_page.dart`：

```dart
import 'package:flutter/material.dart';

import '../theme.dart';

class SubmittedPage extends StatelessWidget {
  const SubmittedPage({super.key, required this.onDone});

  final void Function(BuildContext context) onDone;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.check_circle, color: AppColors.accent, size: 72),
              const SizedBox(height: 16),
              const Text('定制已提交', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('预计 1 小时左右完成，完成后可在「我的定制」查看',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(onPressed: () => onDone(context), child: const Text('查看我的定制')),
              ),
            ]),
          ),
        ),
      );
}
```

- [ ] **Step 5: 运行，确认通过**

Run: `flutter test test/app/pay_page_test.dart`
Expected: All tests passed

- [ ] **Step 6: Commit**

```bash
git add apps/aipet/lib/app/main_window/custom_flow/pay_model.dart apps/aipet/lib/app/main_window/custom_flow/pay_page.dart apps/aipet/lib/app/main_window/custom_flow/submitted_page.dart apps/aipet/test/app/pay_page_test.dart apps/aipet/pubspec.yaml apps/aipet/pubspec.lock
git commit -m "feat(aipet): pay for a custom pet by WeChat QR, polled until paid or expired

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: 入口、「我的定制」、真机接线

**Files:**
- Modify: `apps/aipet/lib/services/account_store.dart`（`readToken()`）
- Modify: `apps/aipet/lib/app/main_window/main_window_model.dart`（`custom` 依赖、`customs` 列表、`loadCustoms()`、`requireLogin()`）
- Modify: `apps/aipet/lib/app/main_window/main_window_app.dart`（横幅入口、导航、「我的定制」）
- Modify: `apps/aipet/lib/app/main_window/main_window_entry.dart`（真实依赖）
- Test: `apps/aipet/test/services/account_store_test.dart`（加一条）、`apps/aipet/test/app/main_window_test.dart`（加几条）

**Interfaces:**
- Consumes: Task 7–11 全部
- Produces:
  - `AccountStore.readToken() → String?`（只读，不隔离、不抛）
  - `MainWindowModel({..., CustomDeps? custom})`；`CustomDeps? get custom`；`List<CustomRequestInfo> get customs`；`Future<void> loadCustoms()`；`void requireLogin()`（切到「我的」并提示「请先登录后再定制」）
  - 「我的」页「我的定制」：每单名字、类别、套餐、状态文字；待支付的显示「去支付」→ 套餐页。

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/account_store_test.dart` 末尾 `main` 里加：

```dart
  test('readToken only reads: a bad file stays where it is', () {
    final store = AccountStore(dir);
    expect(store.readToken(), isNull);
    store.save(const Account(token: '1|abc', user: AccountUser(id: 1, name: 'n', phoneMasked: '138****0000')));
    expect(store.readToken(), '1|abc');
    store.file.writeAsStringSync('{broken');
    expect(store.readToken(), isNull);
    expect(store.file.existsSync(), isTrue);
  });
```

（`dir` 用该测试文件已有的临时目录变量名；若名字不同，照现有 setUp 改。）

`apps/aipet/test/app/main_window_test.dart`：
- 在 `setUp` 之前声明 `late FakeHttp api;`，`setUp` 里 `api = FakeHttp();`，并给 `MainWindowModel` 传
  `custom: CustomDeps(service: CustomService(ApiClient(api, baseUrl: 'https://x', token: () => 't')), uploader: OssUploader(FakeOss()), pick: () async => [])`。
- 文件末尾 `main` 里加：

```dart
  testWidgets('立即定制 while signed out goes to 我的 and asks to sign in', (tester) async {
    await open(tester);
    await tester.tap(find.text('立即定制'));
    await tester.pump();
    expect(model.tab, 1);
    expect(find.text('请先登录后再定制'), findsOneWidget);
  });

  testWidgets('立即定制 while signed in opens the form', (tester) async {
    await open(tester);
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await tester.pump();
    await tester.tap(find.text('立即定制'));
    await tester.pumpAndSettle();
    expect(find.text('定制你的专属宠物'), findsOneWidget);
  });

  testWidgets('我的定制 lists requests with their status; 待支付 offers 去支付', (tester) async {
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            {'id': 2, 'name': '豆豆', 'species': 'cat', 'plan_name': '标准版', 'status': 'making'},
            {'id': 1, 'name': '小白', 'species': 'girl', 'status': 'pending_payment'},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await tester.pump();
    model.setTab(1);
    await tester.pumpAndSettle();
    expect(find.text('我的定制'), findsOneWidget);
    expect(find.text('豆豆'), findsOneWidget);
    expect(find.text('制作中'), findsOneWidget);
    expect(find.text('待支付'), findsOneWidget);
    expect(find.text('去支付'), findsOneWidget);
  });
```

（`petSide.pushAccount` 是登录改动里 `PetWindowBridge` 推账号的方法；执行时 `grep -n "pushAccount\|accounts" lib/services/window_bridge.dart` 核对真实方法名，照实际改。）

- [ ] **Step 2: 运行，确认失败**

Run: `flutter test test/services/account_store_test.dart test/app/main_window_test.dart`
Expected: 编译失败（`readToken`、`custom:` 参数不存在）。

- [ ] **Step 3: 实现**

`apps/aipet/lib/services/account_store.dart`，`load()` 之后加：

```dart
  /// The token for the library window, which only reads (the pet window is the
  /// one writer): null on anything unexpected, and the file is left alone.
  String? readToken() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      final t = j is Map ? j['token'] : null;
      return t is String && t.isNotEmpty ? t : null;
    } catch (_) {
      return null;
    }
  }
```

`apps/aipet/lib/app/main_window/main_window_model.dart`：
- import `'../../domain/custom_order.dart'`、`'../../services/custom_service.dart'`、`'custom_flow/custom_deps.dart'`。
- 构造函数加命名参数 `this.custom`（`final CustomDeps? custom;`）。
- 字段与方法：

```dart
  List<CustomRequestInfo> _customs = const [];

  /// 我的定制, newest first; empty when signed out or not loaded yet.
  List<CustomRequestInfo> get customs => _customs;

  Future<void> loadCustoms() async {
    final c = custom;
    if (c == null || !_account.signedIn) {
      _customs = const [];
      notifyListeners();
      return;
    }
    try {
      _customs = await c.service.list();
    } on CustomFailure {
      // Keep what was shown; the next visit to 我的 asks again.
    }
    notifyListeners();
  }

  /// 立即定制 while signed out.
  void requireLogin() {
    _tab = 1;
    _say('请先登录后再定制');
  }
```

- `setTab(int i)` 里在 `notifyListeners();` 之后加 `if (i == 1) unawaited(loadCustoms());`；账号推送监听（`_accountSub` 回调）里 `notifyListeners();` 之后加 `unawaited(loadCustoms());`。

`apps/aipet/lib/app/main_window/main_window_app.dart`：
- `_Banner` 增加 `onCustom` 回调参数（`final VoidCallback onCustom;`），按钮 `onPressed: onCustom`，删除「即将开放，敬请期待」对话框。
- `_PlazaPage` 里构造 `_Banner(group: model.group, onCustom: () => openCustomFlow(context, model))`。
- 新增顶层函数：

```dart
/// 立即定制 → form → plans → pay → submitted (custom order spec 3).
void openCustomFlow(BuildContext context, MainWindowModel model) {
  final deps = model.custom;
  if (deps == null) return;
  if (!model.account.signedIn) {
    model.requireLogin();
    return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => CustomFormPage(
      deps: deps,
      onSubmitted: (ctx, request) => openPlans(ctx, model, request),
    ),
  ));
}

void openPlans(BuildContext context, MainWindowModel model, CustomRequestInfo request) {
  final deps = model.custom!;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PlanPage(
      deps: deps,
      request: request,
      onOrder: (ctx, plan, order) => Navigator.of(ctx).push(MaterialPageRoute<void>(
        builder: (_) => PayPage(
          deps: deps,
          request: request,
          plan: plan,
          order: order,
          onPaid: (payCtx) => Navigator.of(payCtx).pushReplacement(MaterialPageRoute<void>(
            builder: (_) => SubmittedPage(onDone: (doneCtx) {
              Navigator.of(doneCtx).popUntil((r) => r.isFirst);
              model.setTab(1);
            }),
          )),
        ),
      )),
    ),
  ));
}
```

- 「我的」页：在账号卡片之后、已领养网格之前，`model.account.signedIn && model.customs.isNotEmpty` 时插入：

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
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: r.coverUrl == null
                        ? const Icon(Icons.pets, color: AppColors.accent)
                        : Image.network(r.coverUrl!, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.pets, color: AppColors.accent)),
                  ),
                ),
                title: Text(r.name),
                subtitle: Text([speciesLabel(r.species), ?r.planName].join(' · ')),
                trailing: r.status.awaitingPayment
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(r.status.label, style: const TextStyle(color: AppColors.textMuted)),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: () => openPlans(context, model, r), child: const Text('去支付')),
                      ])
                    : Text(r.status.label, style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
              ),
            ),
        ]),
      );
}
```

  具体插在哪：执行时先读当前 `_MinePage.build`（登录改动后的版本），把 `_CustomList` 放在 `_AccountCard` 那个 `Padding` 之后；若已领养网格在 `Expanded` 里，把 `_CustomList` 和网格一起放进一个 `CustomScrollView`（`SliverToBoxAdapter(child: _CustomList(...))` + 原 `_PetGrid`），保证内容多时整体滚动、不溢出。
- import：`'../../domain/custom_order.dart'`、`'custom_flow/custom_form_page.dart'`、`'custom_flow/plan_page.dart'`、`'custom_flow/pay_page.dart'`、`'custom_flow/submitted_page.dart'`。

`apps/aipet/lib/app/main_window/main_window_entry.dart`：构造 model 时加：

```dart
    custom: CustomDeps(
      service: CustomService(ApiClient(
        IoHttpTransport(),
        token: AccountStore(appDataRoot()).readToken,
      )),
      uploader: OssUploader(IoMultipartTransport()),
      pick: _pickPhotos,
    ),
```

并加：

```dart
Future<List<PickedFile>> _pickPhotos() async {
  const images = XTypeGroup(label: '图片', extensions: ['jpg', 'jpeg', 'png']);
  final files = await openFiles(acceptedTypeGroups: const [images]);
  return [for (final f in files) PickedFile(f.name, await f.readAsBytes())];
}
```

imports：`package:file_selector/file_selector.dart`、`../../services/account_store.dart`、`../../services/api_client.dart`、`../../services/custom_service.dart`、`../../services/oss_uploader.dart`、`custom_flow/custom_deps.dart`。

- [ ] **Step 4: 运行，确认通过**

Run: `flutter analyze` 然后 `flutter test`
Expected: `No issues found!`；All tests passed（全量）

- [ ] **Step 5: Commit**

```bash
git add apps/aipet/lib/services/account_store.dart apps/aipet/lib/app/main_window/main_window_model.dart apps/aipet/lib/app/main_window/main_window_app.dart apps/aipet/lib/app/main_window/main_window_entry.dart apps/aipet/test/services/account_store_test.dart apps/aipet/test/app/main_window_test.dart
git commit -m "feat(aipet): 立即定制 opens the custom-pet flow; 我的 lists the orders

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

（这几个文件含别的会话的未提交改动时，按第二部分开头的规则先问用户。）

---

### Task 13: 联调与真机验收

**Files:** 无代码改动（发现问题按 systematic-debugging 修，修完补测试再提交）

- [ ] **Step 1: release 构建并启动**

Run（PowerShell）：
```powershell
$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"
cd C:\Users\Administrator\code\aipet\apps\aipet
Stop-Process -Name aipet -Force -Confirm:$false -ErrorAction SilentlyContinue
flutter build windows --release
Start-Process build\windows\x64\runner\Release\aipet.exe
```
Expected: 构建成功，宠物出现。

- [ ] **Step 2: 对着线上服务走流程（需要服务端已部署 Task 1–5 并执行迁移；否则对本地 `AIPET_API_BASE` 也连不了库——这一步只能等服务器）**

先问用户：服务端是否已部署、`[OSS]` 是否已配。已部署则用 `tools/dev` 的 `shot.ps1` / `click.ps1`（点击前 `-Expect` 校验像素；宠物在动画，点宠物不加 `-Expect`）：
1. 「我的」登录 → 广场「立即定制」→ 截图核对定制页。
2. 填名字、选 人物 → 女生、上传 1 张照片 → 下一步 → 截图核对套餐页（两档、价格、角标）。
3. 选标准版 → 创建宠物 → 截图核对二维码与倒计时。
4. 后台对该订单「标记已支付」（或用户用微信付 0.01 元测试套餐）→ 2 秒内跳到「定制已提交」→「查看我的定制」显示「待制作」。
5. 后台推进到「制作中」→ 回「我的」刷新显示「制作中」。

用户在用电脑时（前台出现其他窗口）停止一切鼠标操作，把剩余步骤交给用户。

- [ ] **Step 3: 报告**

列出：每个 Task 的提交、本机验证过什么、**没验证什么**（服务端 DB 相关全部在 README 清单里待服务器验收；OSS 实传若用户未配 `.env` 也未验）。
