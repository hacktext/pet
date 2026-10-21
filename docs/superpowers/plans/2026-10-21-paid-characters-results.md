# 付费人物——执行结果（2026-10-21）

计划：`2026-10-21-paid-characters.md`；设计：`../specs/2026-10-21-paid-characters-design.md`。

## 分支与提交（都未推送）

- 客户端 `aipet`，分支 `feat/paid-characters`：`2d370c0`（设计+计划）→ P1 `851bd17` → C1 `da4d9be` → C2 `c70c0f3` → C3 `9e94925` → C4 `96f225a`、`fc02451` → C5 `464b88b` → C6 `cc76642` → 终审修复 `4a93e57`。`flutter analyze` 零问题，`flutter test` 598 个全过，release 构建成功。
- 后端 `pixpickweb-tp`，分支 `feat/paid-characters`：B1 `1810fb8` → B2 `05f0b36` → B3 `b6024a4` → B4 `78e86a6`、`0f89266` → 终审修复 `d3b47bc`。**本机没有 MySQL，后端代码只做过 `php -l`，一行都没运行过。**

每个任务都过了独立审查，最后做了两个仓库的整体终审；终审提出的 4 个重要问题和 5 个次要问题已在 `4a93e57` / `d3b47bc` 修好，复审确认。

## 素材（不进 git、不进安装包）

`tools/petgen/work/chars/paid-out/paid-{suwan,guchen,luyu,xiaxia,zhiyi}/`，每人 31 个文件、7–9 MB：4 段 pro 动作（20 段全过 `qa`）、3 种声音 × 8 句（男声 103–148 Hz）、`cover.png`、`card.jpg`、`pet.json`（`origin: paid`）。成片调色按原图手选（苏晚 / 顾沉 / 陆屿 0.65，夏夏 / 林知意 0.8，见裁定 R8）。可灵视频额度已用到约 0.6。

## 上架前必须做（按顺序）

1. **测试服跑迁移两遍**：`database/migrations/2026-10-21_aipet_characters.sql`（第二遍不报错、仍是 5 行、全部 `enabled=0`）。
2. **接口冒烟**（支付通道 `fake`，用一个测试账号）：
   1. `UPDATE aipet_characters SET enabled=1 WHERE code='suwan';`
   2. `GET /api/aipet/characters` → code 0，含 suwan，`price_cents` 1990。
   3. `POST /api/aipet/characters/suwan/order` → 拿到 `order_no`；再发一次 → 同一个 `order_no`。
   4. `GET /api/aipet/characters/orders/<order_no>` → `pending`；换个账号 → 404。
   5. 后台该订单「标记已支付」→ 提示已解锁；`GET /api/aipet/characters/owned` → 含 suwan 的完整条目；再标记一次 → 不报错，`aipet_character_unlocks` 仍 1 行。
   6. 再下单 → code 5016。
   7. `GET /api/aipet/characters/suwan/assets` → `pet_id: paid-suwan`；换个账号 → HTTP 403。
   8. 后台退款 → `owned` 不再含 suwan，`assets` → 403。
   9. 冒烟后 `enabled=0`。
3. **上传素材**（开发机，每人一次）：
   `cd tools/petgen && HTTPS_PROXY=http://127.0.0.1:1 NO_PROXY=* .venv/Scripts/python -m petgen publish work/chars/paid-out/paid-suwan --code suwan --server <测试服地址>`
   后台「付费人物」页核对：卡片照「有」、文件数 ≥ 4 个 mp4。
4. **端到端（计划 Task C7）**：客户端设 `AIPET_API_BASE` 指向测试服 → 未登录看到「付费」卡片 → 解锁 → 登录 → 扫码（或后台标记已支付）→「下载」→ 下载 →「带TA回家」→ 桌面上动作和声音正常 → 登出后人物离开桌面、卡片回到「解锁」→ 再登录直接可用 → 后台退款后锁定。
5. 全部通过后，在后台设价格、上架；再把两个分支合进 master、推送、发版。

## 我替你做的裁定（错了的代价）

- R1 价格文案用现有 `yuan()`，显示「¥19.90 解锁」而不是「¥19.9」——改一行格式。
- R2 目录缓存按写入方拆文件：桌宠窗口只写 owned.json，宠物库只写 catalog.json 和卡片照——无功能影响。
- R3 两个仓库都在功能分支上做、不推送——之后多一步合并。
- R4 5 个人物的声音分配（种子与素材一致）——改一列 JSON。
- R5/R7 本机没有 MySQL，后端冒烟全部留到测试服——测试服第一次跑时才会暴露后端问题（上面的清单就是为此）。
- R6 素材生产由我直接操作，不派子代理——无代码影响。
- R8 付费人物的成片调色按原图手选，而不是自动提亮（自动提亮把黑色和酒红衣服提成灰色）——想换可免费重跑 finish。
- R9 素材表批量删除依赖产品作用域；该表只有 aipet 的数据——实际无影响。
- R10 「订单 15 分钟过期后才扫码付款」只对付费人物订单补上了照样解锁；**定制宠物和会员订单仍有这个老漏洞**（付了款但过期不发货），需要你决定是否另修。
- R11 `/characters/owned` 改为返回已购人物的完整条目（含已下架的），让下架后的买家仍能看到并下载——每项多带一些字段。
- R12 终审时顺手修了 5 个小问题（路径校验、上传必须完整、换账号清空已购、下载前先刷新已购、窗口再次显示时重拉目录）。

## 留着没修的小问题

- 退款提示在「解锁改指向另一单」时仍写「已重新锁定」。
- 过期订单上的迟到重复付款只记日志，后台看不到，需要人工留意退款。
- 刚买完立刻连点两次「下载」，可能第一次提示失败（再点即可）。
- 旧格式 owned.json（无所属账号）遇到换账号登录且刷新失败时，会暂时保留上一个账号的已购。
- 后台「付费人物」页只显示已购人数，看具体买家要去订单页按 `aipet_character` 筛选。
- 后台复用订单时逐个加载订单、标签多于 3 个会被静默截掉等，见各任务审查记录（已随工作区清理，git 提交信息里有摘要）。
