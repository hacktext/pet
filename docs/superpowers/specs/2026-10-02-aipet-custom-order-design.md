# aipet 定制宠物下单 · 设计

日期：2026-10-02
服务端仓库：`pixpick/pixpickweb-tp`（ThinkPHP 6.1 多产品平台），分支 `feat/aipet`
客户端仓库：`aipet/apps/aipet`（Flutter Windows）
前置：`2026-10-02-aipet-web-platform-design.md`（手机号登录、`ApiClient`、`AccountStore`）

## 1. 目标

宠物库「立即定制」从「即将开放」变成可用的下单流程：

1. 登录用户填写名字、选择类别、上传 1–3 张照片（宠物或人物）。
2. 选择套餐（后台可配置），微信扫码支付。
3. 支付成功后，后台能看到名字、类别、照片、套餐，由人工制作并更新状态。
4. 用户在「我的定制」里看到每单状态，待支付的单可以继续付款。

不做（留给后续）：成品下发到客户端（生成服务那一期）、「修改机会」流程、支付宝、退款界面（沿用后台已有的订单退款）、按套餐限制功能。

## 2. 决定

| 问题 | 决定 |
|---|---|
| 是否要求登录 | 必须手机号登录；复用 web 平台 spec 的登录，不另做 |
| 支付 | 只做微信 Native 扫码，客户端内显示二维码；支付宝按钮显示「即将上线」 |
| 套餐 | 服务端表 `aipet_plans`，后台可编辑，客户端从接口拉取 |
| 照片存储 | 阿里云 OSS 私有 bucket；客户端凭服务端签发的一次性凭证直传；密钥只在服务端 `.env` |
| 流程位置 | 全部是宠物库窗口里的原生页面（方案 A）；不跳浏览器 |

## 3. 客户端流程

宠物库窗口内用 `Navigator` 逐页推进：

1. **入口**：横幅「立即定制」。未登录 → 跳到「我的」页登录卡片（web 平台 spec 第 8 节），登录后回来继续。
2. **定制页**（参考图 1、2）：
   - 名字：1–8 个字，去掉首尾空白后计数，实时显示 `n/8`。
   - 类别：一级 宠物 / 人物，二级复用 `Category`（不含「全部」），默认 宠物 → 猫猫。
   - 照片：「点击上传照片」用 `file_selector` 选 JPG/PNG，最多 3 张，可删除单张；缩略图预览。
   - 拍照小贴士；「预计 1 小时左右定制完成」提示卡。
   - 「下一步」：名字合法且至少 1 张照片才可点。点击后先压缩（长边 ≤ 2048，JPEG 质量 88，`image` 包，放到后台 isolate），再申请凭证并逐张上传（显示「正在上传 2/3」），全部成功后创建定制单，进入套餐页。某张失败：提示第几张失败，可重试，已成功的不重传。
3. **套餐页**（参考图 3）：`GET plans` 渲染卡片（图标、名称、推荐角标、副标题、价格、有效期文字、标签、还原度、修改次数、包含功能），默认选中第一个上架套餐。底部「已选 xx  ¥xx」、支付方式（微信选中；支付宝灰显「即将上线」）、「创建宠物」。
4. **支付页**：`POST requests/:id/order` → 用 `qr_flutter` 画 `code_url`，显示金额与倒计时；每 2 秒 `GET orders/:orderNo`（`Timer`，不阻塞 UI）。
   - `paid` → 进入「已提交」页。
   - 过期 → 「二维码已过期，点击刷新」，重新请求下单（服务端会建新单）。
   - 离开页面停止轮询；可在「我的定制」里继续付款。
5. **已提交页**：「定制已提交，预计 1 小时左右完成，完成后可在我的定制查看」，按钮回到「我的」。
6. **「我的」页**新增「我的定制」列表（登录后显示）：名字、类别、首张照片缩略图（服务端限时 URL）、套餐、状态文字；`pending_payment` 的单显示「去支付」→ 支付页。

状态文字：`pending_payment` 待支付、`paid` 待制作、`making` 制作中、`done` 已完成、`refunded` 已退款。`draft`（已建单未下过订单）也显示为待支付。

### 3.1 客户端结构

- `lib/services/custom_service.dart`：`CustomService`，经已有 `ApiClient` 调 `api/aipet/custom/*`，返回强类型结果（`Plan`、`UploadTicket`、`CustomRequest`、`PayOrder`）。
- `lib/services/oss_uploader.dart`：`OssUploader`，按凭证发 multipart/form-data POST；传输层抽象（`MultipartTransport`），测试用假实现。
- `lib/services/photo_prep.dart`：压缩/转 JPEG（纯函数 + `Isolate.run`）。
- `lib/app/main_window/custom_flow/`：`custom_form_page.dart`、`plan_page.dart`、`pay_page.dart`、`submitted_page.dart`，各自一个 `ChangeNotifier` 模型（页面只渲染）。
- 主窗口只读 `account.json` 取 token；写入仍只由宠物窗口做（web 平台 spec 第 8 节）。token 失效（401）→ 提示重新登录并回到「我的」。
- 新依赖：`file_selector`、`image`、`qr_flutter`。

## 4. 服务端

### 4.1 配置

`.env` 新增（`.example.env` 只写键名，值留空）：

```
[OSS]
ENDPOINT =
BUCKET =
ACCESS_KEY_ID =
ACCESS_KEY_SECRET =
```

`config/aipet.php` 新增 `oss` 段（读上面四项）与 `custom` 段：`max_photos = 3`、`photo_max_bytes = 10MB`、`ticket_ttl = 900` 秒、`ticket_valid_for_request = 3600` 秒、`daily_tickets = 30`、`daily_requests = 10`、`view_url_ttl = 600` 秒、`key_prefix = aipet/custom/`。OSS 未配置时定制接口返回 5014。

### 4.2 数据

迁移 `database/migrations/2026-10-02_aipet_custom.sql`（幂等，手工执行）：

| 表 | 关键字段 |
|---|---|
| `aipet_plans` | product_id, code（唯一 `(product_id, code)`）, name, subtitle, price_cents, valid_days（0 = 永久）, tags JSON, features JSON, feature_count, fidelity（百分比）, revisions, badge（如「推荐」，可空）, icon（`standard`/`pro`，客户端内置图标）, sort, enabled, timestamps |
| `aipet_upload_tickets` | product_id, user_id, object_key（唯一）, created_at, used_at |
| `aipet_custom_requests` | product_id, user_id, name, species（`dog/cat/other/girl/boy/anime`）, photo_keys JSON, plan_code, price_cents（下单时快照）, order_no（最近一次）, status, admin_note, paid_at, timestamps；索引 `(user_id, created_at)` |

初始套餐（与参考图一致）：

- `standard` 标准版：¥39，valid_days 365，「还原你家爱宠的专属形象」，8 项功能，还原度 85%，2 次修改，功能：站立 · 行走 · 喂食 · 玩耍 · 休眠 · 放大放小 · 互动面板 · 饱食度等数值统计。
- `pro` 高级Pro版：¥59，永久，badge「推荐」，「更丰富的动作与桌面互动」，13 项功能，还原度 98%，5 次修改，功能：站立 · 行走 · 喂食 · 玩耍 · 休眠 · 转圈 · 舔爪 · 摸摸头 · 后空翻 · 鼠标跟随 · 放大放小 · 互动面板 · 饱食度等数值统计。

定制单状态：`draft → pending_payment → paid → making → done`，`paid/making/done → refunded`（后台退款时）。

支付复用 `orders`：`plan_code = 'aipet_custom'`，`period = 'once'`，`payload = {"custom_request_id": id, "aipet_plan": code}`，金额取套餐表。`Fulfillment::fulfill()` 新增分支：`plan_code === 'aipet_custom'` → 定制单置 `paid`、写 `paid_at`（幂等：已是 paid 及之后不动）。微信回调、`order:expire` 不改。

### 4.3 OSS（`app/service/aipet/OssClient.php`，纯 PHP，不引 SDK）

- `postPolicy(key)`：PostObject V1 签名。policy 条件：`bucket`、`["eq", "$key", key]`、`["content-length-range", 1, photo_max_bytes]`、`["in", "$content-type", ["image/jpeg","image/png"]]`，过期 `ticket_ttl`。返回 `{url: "https://<bucket>.<endpoint>", fields: {key, policy, OSSAccessKeyId, Signature, success_action_status: "204", Content-Type}}`。
- `exists(key)`：签名 HEAD，200 为真。
- `signedGetUrl(key, ttl)`：URL 签名 GET（`Expires`/`OSSAccessKeyId`/`Signature`）。
- bucket 保持私有；需在 OSS 控制台配 CORS（允许 POST，来源 `*`）。

### 4.4 接口

挂在 `api` 路由组、需 token（`SanctumAuth`）、`AipetProduct::guard()`，前缀 `aipet/custom/`，信封 `{code, message, data}`。新错误码：

- 5010 `CUSTOM_INVALID` 参数或照片无效（data.field 指出哪项）
- 5011 `CUSTOM_ALREADY_PAID` 定制单已支付
- 5012 `CUSTOM_TOO_FREQUENT` 超过每日上限
- 5013 `CUSTOM_PLAN_UNAVAILABLE` 套餐不存在或已下架
- 5014 `CUSTOM_STORAGE_UNCONFIGURED` OSS 未配置

| 接口 | 说明 |
|---|---|
| `GET plans` | 上架套餐按 sort：`[{code, name, subtitle, price_cents, valid_days, tags, features, feature_count, fidelity, revisions, badge, icon}]` |
| `POST upload-tickets` | `{count: 1–3}` → 为每张生成 key `aipet/custom/<userId>/<uuid>.jpg`，记入 `aipet_upload_tickets`，返回 `[{key, url, fields}]`；当日已发凭证数 + count > 30 → 5012 |
| `POST requests` | `{name, species, photo_keys}` → 校验：名字去空白 1–8 字；species 在白名单；1–3 个 key、无重复，每个都是本人 `ticket_valid_for_request` 内未使用的凭证且 `exists`；当日已建单 ≥ 10 → 5012。通过后凭证置 used，建单 `draft`，返回定制单 |
| `POST requests/:id/order` | `{plan_code}` → 本人的单；状态 paid 及之后 → 5011；套餐下架 → 5013；同一单同一套餐有未过期 pending 订单则复用，否则新建（金额取套餐表）并调用网关拿 `code_url`；定制单写 plan_code、price_cents、order_no，状态 `pending_payment`。返回 `{order_no, amount_cents, code_url, expired_at}` |
| `GET orders/:orderNo` | 本人订单 → `{status: pending/paid/expired/failed/refunded}`（pending 但已过 expired_at 报 expired） |
| `GET requests` | 本人定制单（新到旧，最多 50）：`[{id, name, species, plan_code, plan_name, price_cents, status, created_at, paid_at, order_no, cover_url}]`，`cover_url` 为首张照片限时 URL |

不是本人的定制单 / 订单一律 404。

### 4.5 后台

当前产品为 aipet 时，侧栏「桌宠」组新增：

- `/admin/aipet/custom`「定制订单」：按状态筛选、按手机号搜索；列表显示名字、类别、套餐、金额、状态、脱敏手机号、时间。详情页：照片（限时 URL，可点开原图/下载）、订单号与支付信息、状态切换（paid → making → done，不能回退；退款走已有 `/admin/orders`，退款后定制单同步为 refunded）、备注。
- `/admin/aipet/plans`「定制套餐」：列表、新建、编辑（features/tags 以每行一项输入）、上下架、排序。已被订单引用的套餐只能下架不能删除。

## 5. 安全

- OSS AccessKey 只在服务端 `.env`；客户端只拿到单个 key、限大小与类型、15 分钟失效的上传凭证。建议用只有该 bucket 权限的 RAM 子账号。
- 照片 key 由服务端生成并登记，建单时校验归属、时效、未使用、对象存在——客户端无法引用别人的或伪造的对象。
- 金额只取服务端套餐表；定制单保存价格快照。
- 防重复：同单同套餐复用未过期订单；已支付的单不能再下单。
- 每用户每日上限：凭证 30 张、定制单 10 张。

## 6. 错误处理（客户端）

| 情况 | 表现 |
|---|---|
| 未登录 / 401 | 「请先登录」，跳「我的」登录卡片 |
| 压缩失败（图坏了） | 该张标红「无法读取这张图片」，不阻止删除换图 |
| 上传某张失败 | 「第 n 张上传失败」+ 重试；已成功的保留 key |
| 5010 | 按 data.field 在对应输入下显示原因 |
| 5012 | 「今天提交次数太多了，明天再来吧」 |
| 5013 | 刷新套餐列表并提示「该套餐已下架」 |
| 5014 / 网络错误 / 超时 | 「服务暂时不可用，请稍后再试」，按钮恢复 |
| 二维码过期 | 「二维码已过期，点击刷新」 |

## 7. 验证

- 客户端（TDD）：
  - `CustomService`：每个接口的请求体、解析、各错误码（假 `HttpTransport`）。
  - `OssUploader`：multipart 字段顺序（`file` 必须最后）、204 成功、非 2xx 失败（假传输）。
  - `photo_prep`：大图缩到长边 2048、PNG 转 JPEG、坏图抛错。
  - 页面：名字计数与校验、最多 3 张、上传进度与单张重试、套餐渲染与选择、二维码轮询到 paid 跳转、过期刷新、「我的定制」状态文字与「去支付」。
- 服务端（按 pixpick 约定不写测试）：`php -l`；本地 `php think run` + `curl -H 'Host: aipet.localhost'` 走通 套餐 → 凭证 → 建单 → 下单（fake 驱动 + simulate）→ 状态 paid → 定制单 paid；校验路径（别人的 key、过期凭证、不存在对象、超限、下架套餐）逐条 curl；OSS 用真实 bucket 上传一张图并 HEAD/限时 GET 验证。
- 真机：release 构建走一遍完整流程（微信真付 0.01 元的测试套餐，验证后下架）。

## 8. 分期

1. 服务端：迁移、OssClient、接口、Fulfillment 分支。
2. 服务端：后台两个页面。
3. 客户端：`CustomService` / `OssUploader` / `photo_prep`。
4. 客户端：四个页面 + 「我的定制」。
5. 联调与真机验收。

客户端第 3、4 步在 web 平台 spec 的客户端对接（登录卡片、`ApiClient`、`AccountStore`）提交之后开始，避免同时修改同一批文件。
