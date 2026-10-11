# aipet 官网 + 账号 + 统计后台 · 设计

日期：2026-10-02
服务端仓库：`pixpick/pixpickweb-tp`（ThinkPHP 6.1 多产品平台），分支 `feat/aipet`
客户端仓库：`aipet/apps/aipet`（Flutter Windows）

## 1. 目标

1. 官网：aipet 的展示型官网（首页 + 隐私政策 / 用户协议 / 常见问题），仅中文，网站不做登录。
2. 账号：桌面客户端用**手机号 + 短信验证码**登录（登录即注册），短信走阿里云短信。
3. 同步：登录用户的领养列表 / 当前宠物、每只宠物的养成数值、语音选择跨电脑同步。
4. 统计：后台看装机与活跃（新增设备、日活、留存、版本分布）、注册、宠物与互动行为、官网下载量。

不做：注销账号接口、网页用户中心、英文版、安装包打包、定制宠物素材下发（留给生成服务）。

## 2. 接入方式

pixpickweb-tp 不是 think-multi-app，是「单应用 + 按域名识别产品」。aipet 按平台约定做成**新产品**：

- `products` 行 code = `aipet`，名称「AI 桌宠」，`billing_mode = membership`，`site_only = 0`；
  域名 `aipei.pixpickai.com`（用户给定；上线前确认拼写），本地 `aipet.localhost`（`config/platform.php` 的 `dev_products`）。
- 业务表都带 `product_id`，模型继承 `ProductScoped`。
- aipet 接口只在 aipet 域名上开放：`AipetProduct::guard()`（照 `AppleProduct`）。
- 配置 `config/aipet.php`；`.env` 新增 `[SMS]` 段。

## 3. 数据

迁移脚本 `database/migrations/2026-10-02_aipet.sql`（幂等，手工执行）：

| 表 | 用途 | 关键字段 |
|---|---|---|
| `users`（加列） | 手机号账号 | `phone VARCHAR(20) NULL`，唯一键 `(product_id, phone)` |
| `sms_codes` | 验证码 + 限频计数 | phone, purpose, code_hash, ip, attempts, expires_at, used_at |
| `aipet_devices` | 每台设备一行 | device_id(UUID, 唯一 `(product_id, device_id)`), user_id, os, app_version, first_seen_at, last_seen_at, first_day |
| `aipet_events` | 原始事件 | event_uid(唯一 `(product_id, event_uid)`), device_id, user_id, name, pet_id, props JSON, occurred_at, day |
| `aipet_daily_stats` | 每日汇总 | day + metric + dim（唯一 `(product_id, day, metric, dim)`）, value |
| `aipet_user_data` | 同步文档 | user_id(唯一), version, data JSON |
| `aipet_downloads` | 官网下载点击 | day, ip_hash, ua, referer |

手机号账号的 `users` 行：`email` 填占位 `phone_<sha1前16>@users.aipet.invalid`，`password` 随机 bcrypt，`name` = 「用户」+ 手机尾号 4 位。现有 `users` 结构与 Token 体系不变。

## 4. 接口

挂在现有 `api` 路由组下，前缀 `aipet/`，统一信封 `{code, message, data}`。错误码 5001 起：

- 5001 `SMS_TOO_FREQUENT` 发送太频繁（data.retry_after 秒）
- 5002 `SMS_CODE_INVALID` 验证码错误或过期
- 5003 `SMS_SEND_FAILED` 短信服务商发送失败
- 5004 `SYNC_TOO_LARGE` 同步文档超过 256KB

| 接口 | 鉴权 | 说明 |
|---|---|---|
| `POST /api/aipet/device/hello` | 无（带 token 则绑定用户） | `{device_id, os, app_version}` → upsert 设备，返回 `{server_time}` |
| `POST /api/aipet/events` | 无（带 token 则记用户） | `{device_id, events:[{uid, name, ts, pet_id?, props?}]}`，≤200 条，按 uid 去重，返回 `{accepted}` |
| `POST /api/aipet/sms/send` | 无 | `{phone}` |
| `POST /api/aipet/auth/login` | 无，Throttle | `{phone, code, device_id, device_name}` → `{token, user}`，不存在则注册 |
| `POST /api/aipet/auth/logout` | token | 吊销当前 token |
| `GET  /api/aipet/me` | token | `{user}` |
| `GET  /api/aipet/sync` | token | `{version, data}` |
| `PUT  /api/aipet/sync` | token | `{base_version, data}` → 服务端合并 → `{version, data}` |

`user` = `{id, name, phone_masked}`。`device/hello` 与 `events` 不挂 Throttle（全站按 IP 共享计数，HANDOFF 坑 #38）。

### 4.1 短信

- 6 位数字，有效 5 分钟，只存 `sha256(phone|code|app_secret)`；同一验证码错 5 次作废。
- 限频（按 `sms_codes` 计数）：同一手机号 60 秒 1 次、每天 10 次；同一 IP 每天 30 次。
- 驱动 `sms.driver`：`log`（本地，验证码写日志）/ `aliyun`（`dysmsapi.aliyuncs.com` SendSms，RPC 签名同 `AliyunDmClient`）。
- 手机号只收中国大陆 11 位 `^1[3-9]\d{9}$`。

### 4.2 同步文档与合并

```json
{
  "settings": {"updatedAt": 0, "currentPetId": "builtin-gold", "adoptedPetIds": ["builtin-gold"]},
  "stats":    {"<petId>": {"updatedAt": 0, "intimacy": 0, "satiety": 0, "health": 0,
                           "companionStartedAt": 0, "interactionDay": 0, "todayInteractions": 0}},
  "voice":    {"updatedAt": 0, "choices": {"<petId>": "<voiceId>|off"}}
}
```

- `updatedAt` 为毫秒时间戳。合并按块「后写者胜」：`settings` 整块、`voice` 整块、`stats` 每只宠物各自比较。相等取服务器。
- 服务端只校验结构（三块都是对象、数值字段是数字），不理解宠物业务；未知字段原样保留在块内。
- `PUT` 总是合并后保存并 `version + 1`（`base_version` 只用于日志/诊断，不拒绝），返回合并结果；客户端用返回结果覆盖本地。
- 文档 JSON 超过 256KB 返回 5004。

### 4.3 事件

`name` 白名单：`app_start`、`heartbeat`（运行中每 10 分钟）、`pet_adopt`、`pet_switch`、`interact`（props.kind）、`voice_change`、`login`、`logout`。未知名字丢弃但计入 accepted 之外。`ts` 为客户端毫秒时间戳；服务端 `occurred_at` 取 ts，但偏离服务器时间超过 7 天（过去）或 1 天（未来）时改用服务器时间。

## 5. 统计

命令 `php think aipet:rollup [--date=YYYY-MM-DD]`（默认昨天；crontab 每天 00:10）：对给定日期重算并覆盖 `aipet_daily_stats`，然后删除 90 天前的 `aipet_events`。指标（metric / dim）：

- `new_devices` / ''、`dau` / ''、`registrations` / ''、`downloads` / ''、`downloads_unique` / ''
- `active_minutes` / ''（心跳数 × 10，按设备求和）
- `dau_version` / 版本号
- `interact` / kind、`adopt` / petId、`switch_to` / petId
- `retention_d1|d7|d30` / ''：以该日为第 N 天、首日为 day−N 的设备中当日活跃的数量（分母取当时的 new_devices）

后台「今日」卡片实时查询；趋势图读汇总表。

## 6. 后台

现有 `/admin`，当前产品是 aipet 时侧栏出现「桌宠」组（helper `aipet_mode()`）：

- `/admin/aipet` 概览：今日新增设备 / 日活 / 注册 / 下载点击 + 累计设备 / 用户；近 30 天趋势（Chart.js，`public/p/aipet/admin/chart.umd.min.js` 本地文件）。
- `/admin/aipet/retention` 留存表（近 30 个首日）。
- `/admin/aipet/devices` 设备列表（按版本、是否绑定筛选）+ 版本分布。
- `/admin/aipet/pets` 宠物领养 / 切换排行、互动类型趋势、平均使用时长。
- 用户管理复用：列表/详情显示脱敏手机号，搜索支持手机号；详情显示该用户设备和同步文档摘要。

## 7. 官网

- `app/products/aipet/view/{layout,home}.html`、`pages/{privacy,terms,faq}.html`，资源 `public/p/aipet/`（独立 CSS，不依赖平台 Tailwind 构建）。
- 首页：首屏（名称、一句话、下载按钮、宠物封面/短视频）、功能（陪伴 / 互动 / 养成 / 语音 / 定制即将开放）、宠物展示墙、FAQ 摘要。
- 下载：按钮指向 `/download`（aipet 专属路由，注册在 `:page` 兜底前），记一条 `aipet_downloads` 后 302 到 `Downloads::windowsUrl()`；未配置地址则 302 回首页 `#download` 并提示「即将上线」。

## 8. 客户端

新增（`lib/services/`）：

- `ApiClient`：抽象 `HttpTransport`（便于测试）+ `dart:io HttpClient` 实现；基址默认 `https://aipei.pixpickai.com`，环境变量 `AIPET_API_BASE` 覆盖；解析信封，401 → 清 token。
- `DeviceIdentity`：`device.json` 持久化 UUID。
- `AccountStore`：`account.json` 存 token 与用户。
- `TelemetryQueue`：事件追加到内存 + `telemetry.jsonl`，每 60 秒或满 50 条批量上报，失败保留，文件上限 5000 条。
- `SyncService`：组装/应用同步文档；`sync_meta.json` 记录 settings / voice 的 updatedAt；登录后、启动、有改动且距上次 ≥5 分钟时同步。

全部在宠物窗口（唯一写者）里构建；主窗口「我的」页加登录卡片（手机号 + 验证码），通过窗口桥请求宠物窗口执行登录。

## 9. 验证

- 服务端：按 pixpick 约定不写测试；`php -l`、`php think run` + `curl -H 'Host: aipet.localhost'` 验证页面与参数校验；DB 相关在服务器上按 README 清单验收。
- 客户端：按 aipet 约定 TDD，假传输层放 `test/support/`。

## 10. 分期

1. 服务端核心（迁移、短信、登录、设备/事件、同步、汇总命令）
2. 后台页面
3. 官网 + 下载统计
4. 客户端对接
