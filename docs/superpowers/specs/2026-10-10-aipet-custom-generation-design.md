# aipet 定制宠物：自动生成 + 审核 + 下发 · 设计

日期：2026-10-10
服务端仓库：`pixpick/pixpickweb-tp`（ThinkPHP 6.1 多产品平台）
生成程序：`aipet/tools/petgen`（Python）
客户端：`aipet/apps/aipet`（Flutter Windows）
前置：
- `2026-10-02-aipet-web-platform-design.md`（手机号登录、`ApiClient`、`AccountStore`、宠物窗口唯一写者）
- `2026-10-02-aipet-custom-order-design.md`（定制表单、OSS 直传、套餐、微信支付）。本文**修订**其状态流与套餐功能列表，见第 9 节。

## 1. 目标

用户付款后，由服务端自动调用 AI 把用户照片做成桌面宠物；人工审核通过后，客户端自动下载并出现在宠物库。

成功标准：
1. 付款成功的单在无人干预下进入「生成中」，约 1 小时内进入「待审核」。
2. 后台能逐个动作预览、单独重做、交付。
3. 交付后用户的客户端（任一登录的电脑）自动下载，宠物库出现新宠物，可设为当前宠物。
4. 任何失败都有明确去向（自动重试 → 失败待人工），不会无限花钱，不会卡死。

不做：人物类定制（girl/boy/anime）和「其他小宠」的自动生成、转圈/摸摸头/后空翻三个新动作、鼠标跟随与放大放小（客户端功能）、全自动免审交付、语音。

## 2. 已定决定

| 问题 | 决定 |
|---|---|
| 收费 | 沿用下单设计：选套餐 → 微信支付 → 付款成功才生成 |
| 交付 | 生成完进入「待审核」，后台人工交付 |
| 动作 | 标准版 5 个：stand、walk、feed、play、sleep；高级版 7 个：再加 lick_paw、act_cute（petgen 已调好的 7 个） |
| 类别 | 自动生成只支持狗、猫。定制页「其他小宠」与「人物」标签显示「即将开放」，不可提交 |
| 生成在哪跑 | 独立 Python 生成程序（petgen 的 `worker` 命令），经内部 HTTPS 接口向 PHP 领任务（方案 A）；PHP 是唯一的数据源 |
| 存储 | 用户照片与成品都在下单设计里的 OSS 私有 bucket |

## 3. 状态流

定制单 `aipet_custom_requests.status`：

```
draft → pending_payment → paid → generating → review → delivered
                                     ↓  ↑          ↓
                                   failed ←──── (重做/重新生成回到 paid)
paid / generating / review / failed / delivered → refunded（后台退款）
```

- `paid`：待生成。生成程序只领这个状态的单。
- `generating`：已被领取；`claimed_at`、`heartbeat_at` 记录在单上。
- `review`：成品已上传，待人工审核。
- `delivered`：已交付，客户端可下载。
- `failed`：自动重试后仍失败或超预算，`fail_reason` 写明哪一步、什么原因。

重做：审核时对单个动作「重做」或整单「重新生成」→ 写入 `redo`（见 4.1）→ 状态回到 `paid`。

## 4. 服务端（pixpickweb-tp）

### 4.1 数据

迁移 `database/migrations/2026-10-10_aipet_generation.sql`（幂等）：

`aipet_custom_requests` 加列：

| 列 | 说明 |
|---|---|
| `pet_id` VARCHAR(64) | 建生成任务时写入：`custom-<id>`（满足客户端 `^[a-z0-9-]+$`） |
| `actions` JSON | 按套餐确定的动作列表 |
| `stage` VARCHAR(32)、`stage_done` INT、`stage_total` INT、`stage_message` VARCHAR(255) | 最近一次进度 |
| `claimed_at`、`heartbeat_at`、`review_at`、`delivered_at` DATETIME | |
| `delivered_by` VARCHAR(64) | 交付的管理员 |
| `redo` JSON | 待重做：`{"actions": ["play"], "refs": false, "hint": "尾巴摆慢一点"}`；整单重新生成为 `{"all": true}`；领取时下发、完成后清空 |
| `walk_facing` VARCHAR(8) | 生成程序猜测，审核时可改 |
| `cost_image_units`、`cost_video_units` INT、`cost_cents` INT | 累计花费 |
| `fail_reason` VARCHAR(255) | |
| `attempts` INT | 领取次数（卡单回收计数） |

新表 `aipet_custom_assets`（成品文件，一个文件一行）：product_id、request_id、`path`（相对宠物目录，如 `stand.mp4`、`cover.png`、`pet.json`；参考图为 `refs/front.png` 等，不下发）、`object_key`、`bytes`、`sha256`、`qa` JSON（质检分数）、`deliverable` TINYINT（是否下发给客户端）、timestamps；唯一键 `(product_id, request_id, path)`。重做覆盖同一行。

### 4.2 建任务

`Fulfillment` 中 `aipet_custom` 分支（下单设计 4.2）在置 `paid` 时同时写入 `pet_id`、`actions`（按套餐 code：`standard` → 5 个，`pro` → 7 个，映射写在 `config/aipet.php` 的 `custom.plan_actions`）。species 不是 dog/cat 的单不应出现（客户端拦、`POST requests` 服务端也校验）。

### 4.3 内部接口（给生成程序）

路由组 `internal/aipet`，`completeMatch()`，不挂 session/CSRF/ResolveProduct；中间件 `WorkerAuth`：`X-Worker-Key` 与 `.env [AIPET] WORKER_KEY` 用 `hash_equals` 比对，可选 `WORKER_IPS`（逗号分隔，空 = 不限）。控制器内以 aipet 产品身份执行（`CurrentProduct::runAs`）。

| 接口 | 说明 |
|---|---|
| `POST jobs/claim` | 在事务里 `SELECT … WHERE status='paid' ORDER BY paid_at LIMIT 1 FOR UPDATE` → 置 `generating`、`claimed_at=heartbeat_at=now`、`attempts+1`。返回 `{job: {id, pet_id, name, species, actions, redo, budget_cents, spent_cents, photos: [{url}]}}`（碗、球道具是生成程序本地的共用素材，不经服务端），无任务返回 `{job: null}`。生成程序暂停领单时（见 4.5）也返回 null 并带 `paused_reason` |
| `POST jobs/:id/progress` | `{stage, done, total, message, cost: {image_units, video_units, cents}}` → 更新进度、累加花费、刷新 `heartbeat_at`。单已不是 `generating`（被后台改了）→ 返回 `{abort: true}`，程序应停下 |
| `POST jobs/:id/upload-urls` | `{files: [{path, bytes, content_type}]}` → 每个文件的 OSS 签名 PUT 地址（object key `aipet/custom/<userId>/<id>/<path>`，有效 30 分钟） |
| `POST jobs/:id/finish` | `{walk_facing, files: [{path, bytes, sha256, qa, deliverable}]}` → 校验每个对象已存在且大小一致 → upsert `aipet_custom_assets` → 置 `review`、清 `redo`、写 `review_at` |
| `POST jobs/:id/fail` | `{stage, reason}` → 置 `failed`、写 `fail_reason` |
| `POST worker/status` | `{paused, reason, balance: {image, video}}` → 记入 settings（`aipet_worker_status`），后台显示 |

### 4.4 卡单回收

`php think aipet:reap`（crontab 每 5 分钟）：`generating` 且 `heartbeat_at` 超过 20 分钟 → 回到 `paid`；`attempts ≥ 3` 则置 `failed`（`fail_reason = 生成程序多次中断`）。

### 4.5 成本控制

- 预算：`config/aipet.php` `custom.budget_cents`，默认 8000（80 元）。领取时下发预算与已花费；生成程序在每次调用可灵前检查，超出则 `fail`（原因「超出单笔预算」）。
- 额度：生成程序在每单开始前查可灵余额；低于一单所需（图片 8×4 单位、视频按动作数 × 4）时不领新单，调 `worker/status` 上报暂停，后台显示「生成额度不足」。**不降级、不自动购买**。
- 价格表（每单位多少分）放在生成程序配置里，用于估算 `cost_cents`。

### 4.6 客户端接口（追加到下单设计 4.4）

| 接口 | 说明 |
|---|---|
| `GET custom/requests` | 每单增加 `pet_id`、`stage`、`stage_done`、`stage_total`、`fail_reason`（仅 failed） |
| `GET custom/deliveries` | 本人所有 `delivered` 单：`[{id, pet_id, name, delivered_at}]`——客户端据此判断缺哪些 |
| `GET custom/requests/:id/assets` | 仅 `delivered` 且本人：`{pet_id, files: [{path, bytes, sha256, url}]}`，只含 `deliverable=1`，url 为 30 分钟限时 GET |

### 4.7 后台

定制订单详情页（下单设计 4.5）增加「生成」面板：

- 进度、耗时、花费、领取次数、失败原因。
- 用户照片与生成的参考图并排。
- 每个动作：`<video>` 预览（限时 URL）、质检分数、「重做」按钮（可填一句补充提示）。
- 朝向 left/right 切换（写 `walk_facing`，交付时以它重写 `pet.json`）。
- 「交付」（仅 review）、「整单重新生成」（review / failed）、「标记失败」。退款走已有订单退款，退款后定制单置 `refunded`。
- 列表按状态筛选；侧栏「定制订单」显示待审核数角标；概览页显示生成程序状态（最后心跳、是否暂停、余额）。

交付时服务端重写 `pet.json`（用审核后的 `walk_facing`）并更新其 sha256。

## 5. 生成程序（tools/petgen）

### 5.1 从 CLI 到流水线

把现有按宠物名硬编码的命令重构为以「任务目录」为单位的函数，CLI 与 worker 共用：

- `petgen/pipeline.py`：`Job`（id、species、photos、actions、redo、预算）与各步骤函数，输入输出都在 `work/jobs/<id>/`。
- 步骤与产物：
  1. `fetch`：下载照片 → `photos/1.jpg…`
  2. `refs`：每个所需姿态（front 必需；walk 若有 walk；lie 若有 sleep）用 Kling image reference「subject」生成 2k、bright → `gate`（不贴边、blob_core < 200），不过重试 1 次（换一张用户照片做参考）→ `ref-<pose>-green.png`、`ref-<pose>-cutout.png`
  3. `propref`：feed / play 需要时把共用碗、球贴到正面图
  4. `video`（每个动作）：Kling image2video pro，`image = image_tail =` 绿底参考，`external_task_id = aipet-<id>-<action>-<n>`
  5. `finish` + `qa`：不过重试该动作 1 次
  6. `package`：`pet.json`（`origin: custom`、`id: pet_id`、`name`、`species`、`actions`、`walkFacing` 猜测）、`cover.png`
  7. `upload`：申请 PUT 地址并上传，`finish` 上报
- 每步完成写 `state.json`（步骤 → 完成 + 产物 + 花费）。重启或重新领取时跳过已完成的步骤。`redo` 里列出的动作（或 `all`）在开始前清除对应完成标记；`refs: true` 时清除参考图及所有依赖它的视频。
- 下载 Kling 结果：流式写临时文件，失败重试 3 次（断点续传优先，不支持则重下），成功后改名；任务 id 与结果 URL 先写入 `state.json`，下载失败不必重新付费生成。

### 5.2 worker 命令

`python -m petgen worker --server https://aipei.pixpickai.com`，密钥从 `secrets/worker.env`（`AIPET_WORKER_KEY`）读取：

- 循环：查余额 → 不够则上报暂停并每 5 分钟重查；够则 `claim`，无任务 sleep 15 秒。
- 一次只处理一单；每步开始与结束调 `progress`（同时是心跳，长步骤内每 60 秒补一次）；收到 `abort` 立即停止当前单。
- 未捕获异常 → `fail`（带步骤名），继续下一单；Ctrl+C / SIGTERM → 当前步骤结束后退出，不上报 fail（交给卡单回收续做）。
- 部署：Linux 服务器上 Python 3.11+、ffmpeg、`requirements.txt`，宝塔进程守护或 systemd 启动；rembg 模型目录 `U2NET_HOME` 指向持久目录。

### 5.3 去掉 Windows 专属假设

`SPIKE_OUT`、写入 `apps/aipet/assets` 的 `package` 路径改为参数；ffmpeg 调用不依赖盘符。内置宠物的原有命令行为不变（回归测试覆盖）。

## 6. 客户端（apps/aipet）

### 6.1 下载器

`lib/services/custom_downloader.dart`，在宠物窗口构建（唯一写者）：

- 时机：启动后、登录后、每次同步后、收到主窗口「刷新」请求时；同一时间只跑一个。
- `GET custom/deliveries` → 对本机 `pets/<pet_id>/` 不存在或不完整的单 → `GET …/assets` → 逐个下载到 `pets/.downloading/<pet_id>/<path>`，sha256 校验；已存在且校验通过的文件跳过（续传）。
- 全部通过 → 原子改名为 `pets/<pet_id>/`（目标已存在则先改名为 `.old` 再删）→ `PetLibrary` 重新扫描 → 推送给主窗口。
- 失败（网络、校验不符、URL 过期）→ 保留已下好的文件，下次时机再试；不弹错误。
- `PetLibrary` 扫描时跳过以 `.` 开头的目录。

### 6.2 界面

- 定制页：类别「其他小宠」与「人物」标签显示「即将开放」并不可选。
- 「我的定制」状态文字：待支付 / 待生成 / 生成中 n/m / 审核中 / 已完成 / 生成失败（附「我们会联系你处理或退款」）/ 已退款。`generating` 时每 30 秒刷新一次（仅页面可见时）。
- 新宠物下载完成：主窗口提示「你的「<名字>」做好了」，按钮「换它陪我」（复用宠物库已有的切换）。
- 已完成的定制宠物在宠物库「我的」分组里与内置宠物一样展示。

## 7. 安全

- 内部接口只认 `WORKER_KEY`（服务端 `.env`）与可选 IP 白名单；不接受用户 token。
- 生成程序拿到的照片地址与上传地址都是限时签名 URL，单次任务范围内的 key。
- 客户端只能拿到本人已交付单的下载地址。
- 可灵、OSS 密钥分别只在生成程序 `secrets/` 与服务端 `.env`，均不入库。

## 8. 验证

- **先行验证（写代码前）**：3–5 张真实宠物照片（含正脸近照与半身），用现有 `pose` + `gate` 各跑一次；判断像不像、是否全身、能否过 gate。不达标则先调参考图提示词，本设计的其余部分暂停。
- 服务端：`php -l`；本地 curl 走通 claim → progress → upload-urls → finish → 后台交付 → deliveries/assets；卡单回收、预算、暂停用手工改库验证。
- 生成程序：pytest，Kling 与 PHP 均为假实现：断点续跑（每步中断后重启）、重做清标记、重试一次、预算超限、abort、下载失败重试、余额不足暂停；原有 CLI 回归。
- 客户端：TDD：下载器的跳过已存在、sha256 不符、改名原子性、`.downloading` 被扫描忽略；「我的定制」状态文字与刷新。
- 端到端：真实下单（0.01 元测试套餐）→ 生成 → 审核 → 交付 → 客户端出现新宠物。

## 9. 对下单设计（2026-10-02）的修订

- 状态 `making`、`done` 由本文第 3 节的 `generating`、`review`、`delivered`、`failed` 取代；后台不再手动切换 paid → making → done。
- 套餐功能列表：高级版中「转圈 · 摸摸头 · 后空翻 · 鼠标跟随」标为「后续追加」；生成动作以 4.2 的 `plan_actions` 为准。
- 定制页只开放狗、猫。

## 10. 实施顺序

1. 先行验证（需要真实照片与可灵正式额度）。
2. 下单设计（套餐、OSS 上传、微信支付），按其已有计划实施，并带上第 9 节修订。
3. 服务端：迁移、内部接口、卡单回收、客户端追加接口。
4. 生成程序：pipeline 重构 + worker。
5. 后台生成面板与审核。
6. 客户端：下载器、状态与提示。
7. 端到端验收。
