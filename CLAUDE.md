# MoonCode（GitHub: qkunio/mooncode）

主屏显示名 `Moon Code`（App 内字标同样带空格），App Store 名「MoonCode - KimiCode远程控制客户端」。App 已在 App Store Connect 建好，
**Bundle ID `com.qinkun.kimicode` 不能改**；Keychain service / 日志 subsystem / 工程与 target 名沿用 KimiCode。
界面里的「Kimi Code」只用来指电脑上的 CLI（如确认卡片「允许 Kimi Code 写入…」），不是本 App 的名字。

iOS 26 原生客户端，目标是把 `kimi rc`（Kimi Code Remote Control）生成的网页端能力完整搬到 App：
用户**用 Kimi 账号登录**后，从账号下的设备列表里选一台跑着 `kimi rc` 的电脑接入，在 App 内完成网页端能做的一切
（浏览/新建会话、发送任务、看实时执行进度与工具调用、批准/拒绝权限确认、回答提问、中断任务、看
diff/文件卡片、看子 agent 与 task 面板、终端流）。

**不做**粘贴链接、扫二维码 —— 接入只走「登录 → 选设备」。

**设计原则**：尽可能使用 iOS 原生组件与 SF Symbols，不做 WebView 套壳（唯一的网页是登录确认页，见 §5）。

### 启动与登录流程（产品定稿）

0. 开场动效（每次启动只放一次，减弱动态效果时跳过）：启动画面是系统默认白底，进欢迎流程时
   0.25s 渐变成整屏蓝的「大脸」→ 眼睛弹出、眨一下 → 平滑收缩成页面上的 bot（不回弹，落定时轻震）→ 开始打字。实现在 `WelcomeView` 的 `SplashFace`。
1. 启动页分两屏逐字出现（每个字轻震一下），打完才出按钮：「欢迎来到Moon Code！」（Moon 蓝色；「！」出来后一拍从两个下角喷彩条 `ConfettiBurst`，停约 1s）+「KimiCode的远程控制客户端」（两行同样式）→「下一步」；
   「你使用的是哪个 / Kimi Code？」+ 两张选择卡（「Kimi Code 桌面端」在上 /「Kimi Code CLI」在下，只有图标 + 名字）→
   CLI：「请你在任意终端运行」+ `kimi rc` →「我已完成」；
   桌面端：「在 Kimi Code 桌面端 / 打开远程控制」+ 循环播放的示例动画（`DesktopRemoteDemo`，SwiftUI 画的小窗口，
   光标点左下角 ⚙︎ → 设置里「远程控制」→ 打开开关）→「我已完成」。
   这两步左上角有返回键回到选择；回到打过的一步不再逐字重打。
2. 点「我已完成」（CLI / 桌面端都一样）：换成「MoonCode」字标 + 大号「登录 Kimi 账号」按钮；字标与登录按钮之间出现灰字
   「支持 GO 及以上订阅」。**同时后台预取 device-code 授权**，不展示给用户。
3. 点「登录」：用系统浏览器（`ASWebAuthenticationSession`）打开确认页 `verification_uri_complete`
   （链接自带 user code）。**界面上不出现验证码、倒计时之类的东西。**
4. 用户在网页里确认 → 后台轮询拿到 token → 浏览器自动收起 → 进入设备列表。
   用户自己关掉浏览器 → 立刻补问一次（可能刚确认完），否则回到「登录」按钮，授权码留着下次复用。

「登录 Kimi 账号」按钮下方是「暂不登录，体验功能」（App Store 审核用）：不登录进入体验模式，
数据全来自本地内存演示后端 `DemoClient`（不连 relay、不连任何电脑），发什么消息都回
「看起来你输入了『xxx』，很高兴认识你，来和我交流体验吧！」。已登录时入口被忽略，
登录状态绝不碰演示后端；侧栏退出按钮在体验模式下变成「退出体验模式」。
体验模式没有 WS 事件流：`ChatModel` 此时不开 `EventStream`，忙时（transcript 显示一轮在跑）
自己 400ms 轮询，发送/停止/撤销后也手动补一次重拉。

### 主界面（产品定稿，按手绘原型）

```
主页                                   侧栏（从左推入，主页被推到右边露出一截）
┌──────────────────────────┐           ┌──────────────────────┬──┐
│ (≡)          (◔)(📁)      │           │ MoonCode             │  │
│                          │           │ 设备 (MAC ▾)          │  │ ← 切设备
│        对话正文            │           │ 📁 Folder1        (+) │  │ ← + 在该文件夹新建会话
│                          │           │   ○ Session1          │  │
│ ┌──────────────────────┐ │           │   ○ Session2          │  │
│ │ 让 Kimi 做点什么…      │ │           │ 📁 Folder2        (+) │  │
│ │ (+) (⚡︎) K3·Low      (↑)│ │           │ ──────────────────── │  │
│ └──────────────────────┘ │           │ (头像) 昵称      [⎋] │  │ ← 退出登录，二次确认
└──────────────────────────┘           └──────────────────────┴──┘
```

登录后自动连上次那台设备（不在线就取第一台在线的），打开最近文件夹里的新对话草稿。
不再有单独的「选设备」页面，切设备在侧栏。

**每个元素的数据来源（照抄官方网页端的做法，见 `dist-web` bundle）：**

| 元素 | 接口 | 备注 |
|---|---|---|
| 设备下拉 | relay `GET /v1/remote/devices` | 离线的列出但禁用 |
| 添加项目（设备下方） | `GET /fs:home` → `GET /fs:browse?path=` 逐级浏览 → `POST /workspaces {root}`（按 root 幂等） | 照网页端 AddWorkspaceDialog：上一级 / 面包屑 / 子文件夹列表 / 当前目录下模糊搜索（最多 6 层、600 个目录、150 条，同批 6 并发）/「打开此文件夹」；加完在新项目开新对话并收起侧栏 |
| 文件夹 | `GET /workspaces` → `{items:[{id,root,name,last_opened_at,session_count}]}` | 按 `last_opened_at` 倒序 |
| 文件夹下的会话 | `GET /sessions` 按 `workspace_id` 分组；点文件夹名展开/收起（无箭头） | 已归档的、挂不上任何文件夹的都不显示 |
| 文件夹旁 + | 草稿；第一条消息时 `POST /sessions {metadata:{cwd:root}, workspace_id, agent_config}` | 与网页端 `createSession` 同形 |
| 头像 + 昵称 | `GET /oauth/userinfo` → `userInfo.{nickname, avatar}` | 响应里还有手机号等，**只解码这两个字段**。无昵称显示「Kimi 用户」 |
| 退出登录 | 本地清凭证 | alert「是否退出登录？」→ 取消 / 退出 |
| 权限图标 | `GET /sessions/{id}/status` 的 `permission` | composer 上只显示图标（hand.raised / checkmark.shield / bolt.shield），文字只在菜单里。**标签映射别弄反**：`manual`=始终询问、`yolo`=必要时询问、`auto`=完全自动 |
| 右上角 📁（上下文环右边） | 目录：`POST /sessions/{id}/fs:list {path, limit:1000}`；文本预览：`POST /sessions/{id}/fs:read {path, offset:0, length:1MiB, encoding:auto}`；整个文件：`fs:read` 按 3 MiB 分块读 `encoding:base64` | 上拉栏（默认半屏 medium，可拉到 large），点文件夹逐级推入。点文件直接加载预览，右上角 ⋯ 菜单：「下载」走系统分享面板；「保存到相册」（仅图片，`PHPhotoLibrary` addOnly 权限）；「添加到会话」收起文件栏、在 composer 附件条加一张文件卡（`Attachment.mention`），发送时照网页端 `rv` 写成 `[名字](相对路径)` 拼在正文开头，不上传。正文里的这种提及由 `ConversationBuilder.splitMentions` 拆成气泡上的附件标签。输入框里的文件卡、气泡上的文件标签点一下弹出 `FilePreviewSheet`（经环境值 `openFilePreview`，读文件用的会话同 📁），从这里打开时菜单里没有「添加到会话」（含「保存到"文件"」）。文本用只读 UITextView 等宽显示、可自由选择，截断时提示总大小；二进制、图片/PDF/音视频拉整个文件交给 Quick Look。**不用 `GET fs/{path}:download`**：kap-server 2.0.1 把文件名原样写进 `content-disposition`，中文名直接 500；`fs:read` 又整体拒绝 >10 MiB 的文件（41302，与 offset 无关），所以超过 10 MB 直接显示「因 Kimi 官方限制，无法预览或下载 10MB 以上文件」，下载图标置灰。临时文件放 `tmp/MoonCodePreview/`，离开页面删、启动时清。草稿借同文件夹里最近的会话（workDir 相同）；文件夹里一个会话都没有时提示发第一条消息后再看（`fs:browse` 只回文件夹，拿不到文件） |
| 右上角上下文环（📁 左边） | 环：`/status` 的 `context_usage`，之后由事件里的 `contextUsage` 实时更新（输入框上不放上下文圈）。点开「用量」上拉栏（左上角 ✕，medium/large），每项一张卡片、卡片上方灰色小标题：「此对话上下文」卡片 = 已使用 x% + 横条 + `context_tokens / max_context_tokens`；「5 小时 / 每周 / 每月使用限额」卡片 = `GET /oauth/usage` → `quota.usages.{limit5h,limit7d,monthTotal}` 的**已使用** `usedRatio` + 横条 +「21小时59分钟后重置」（`resetAt`） | 按 5 小时 → 每周 → 每月 顺序显示存在的项。打开时刷新用量 |
| K3·Low | 同上 `model` + `thinking_level`；名字查 `GET /models` 的 `display_name`，可选强度查 `support_efforts` | `thinking` 取值是强度名或 `on`/`off`；只有一个选项（如恒开无强度）时只显示名字，`off` 显示「Off」 |
| 模型菜单 | `GET /models` 全部列出，按 provider 分组（`managed:kimi-code` 组名「Kimi 订阅」排最前，其他照原 id 显示，同网页端） | 面板左上 ✕、右上 ⚙︎，点选即生效（无「完成」）；面板只放模型：provider 分组名（Kimi 订阅 / deepseek…）就是一级标题，同用量面板卡片上方的灰色小标题，不再套「模型来源」。composer 上「模型名 High」一个按钮，开 `ModelPanel`（`ThinkingSlider.swift`）：首页两张同样式卡片（标题 + 灰色副标题 + ›）：「当前模型」（模型名 / 来源）、「思考强度」（当前档位 / 全部档位）。点卡片在面板内推入子页（模型列表 / 思考强度），左上角返回；面板高度跟当前页走（各页量高度报给 detent，只有当前页报）。思考强度子页是大号分档滑杆，左低右高、「关闭」最左，拖动吸附、每档轻震、松手才写入；不用弹出菜单（iOS 26 菜单会从整行胶囊变形出来）。拉到最高档轨道变紫、白色小气泡不断向左飘，刚到顶档位名弹一下 + 迸一圈星星 + 重震（彩蛋，减弱动态效果时不动）。拖动位置用 `@GestureState` + `highPriorityGesture`，否则上拉栏抢走手势时滑块会卡在两档中间。⚙︎ 打开「模型配置」（`ProviderSettingsView.swift`）：最上面「默认配置」卡片（摘要「模型 · 权限 · 思考」）→ 默认模型 / 默认权限 / 默认思考三项（照网页端「Agent 默认值」前三项；读 `GET /config` 的 `default_model`、`default_permission_mode`（空=manual）、`thinking{enabled,effort?}`，每改一项 `POST /config` 只带该字段，思考按网页端 `q8`/`bpe` 写）；下面是模型供应商（照网页端「供应商管理」）：`GET /providers` 列表（状态点、左滑刷新 `POST /providers/{id}:refresh` / 删除 `DELETE`，204）；编辑表单模型表来自 `GET /config` 的 `models` 段（驼峰键，只解码这一段），保存 `PUT /providers/{id}`（改名带 `new_id`，key 三态：不带=保留、`""`=清空），手动添加 `POST /providers`（名称 / key / Base URL 必填）；从目录添加 `GET /catalog/providers` → `POST /providers:import_catalog`。Kimi 订阅（`managed:kimi-code`）OAuth 托管只读。注册表导入没做。改完 `AppModel.reloadModels()`。思考选项照网页端 `ov`/`sv`/`z1`：`always_thinking`+强度 → 选强度；只有 `thinking` → 开/关；都没有 → 固定 `off`（见 `ModelInfo.thinkingOptions`） |
| 改权限 / 模型 / 强度 | `POST /sessions/{id}/profile {agent_config:{permission_mode?, model?, thinking?}}` | 只带改动的字段 |
| 新对话默认值 | 上次的选择（UserDefaults）；第一次：`auto` + `GET /config` 的 `default_model` + 该模型默认思考（`defaultThinking`） | 模型已不在这台电脑上就退到列表第一个。建会话时显式带全，界面显示 == 真实值。电脑上模型凭证有问题时服务端回 40111/40112/40113（HTTP 200 信封），App 提示去电脑上配置，**不登出** |
| + 菜单：图片 | prompt 的 `{type:"image", source:{kind:"base64", media_type, data}}` | 长边缩到 1600px JPEG（隧道单请求 10 MiB 上限）；模型无 `image_in` 时禁用 |
| + 菜单：文件 | 先 multipart `POST /files`（字段 `file`+`name`）→ `{id,name,media_type,size}`，再发 `{type:"file", file_id, name, media_type, size}` | 与网页端 `uploadFile` 同形；选中时读进内存，发送时上传；单文件上限 9 MB |
| ↑ / ■ | `POST /sessions/{id}/prompts`（每条都带 `model / thinking / permission_mode`，与网页端 `submitPrompt` 同形）；停止 `POST /sessions/{id}:abort {}` | **不做排队**：本轮在跑时只显示 ■，不能再发。也不做斜杠命令 |

---

## 1. 上游实现调研结论（2026-09-18 逆向）

调研对象：本机 `@moonshot-ai/kimi-code@2.0.1`（`/opt/homebrew/lib/node_modules/@moonshot-ai/kimi-code`）
+ 开源仓 `github.com/MoonshotAI/kimi-code`。

### 1.1 链路

```
iOS App / 浏览器 ──HTTPS/WSS──► code-rc.kimi.com (Kimi 中转 "kfc-relay"，闭源)
                                      │ 三条 WS：管理 / HTTP 隧道 / 每连接 stream
                                      ▼
                            本机 `kimi rc` 进程（packages/remote-control，开源）
                                      │ http:// + ws:// 到回环地址
                                      ▼
                            本地 kap-server（127.0.0.1:port）+ dist-web
```

**关键结论：RC 没有独立的"远程控制前端"。** 前端就是本地那套 Web UI（`dist-web`，Vue 3），
被隧道以 URL 重写的方式挂到 `https://code-rc.kimi.com/devices/<deviceId>/` 路径前缀下原样运行。
Web UI 源码**不在开源仓**：`apps/kimi-code/scripts/check-web-assets.mjs` 注明它在内部 `code-app` 仓的
`apps/web`，只有构建产物被 force-add 到 `apps/kimi-code/dist-web`。仓里的 `apps/vis`（React）是
session 调试可视化工具，与 RC 无关。

### 1.2 本机侧隧道客户端（`packages/remote-control/src/remote-control.ts`）

- relay 默认 `https://code-rc.kimi.com`（可用 `KIMI_CODE_REMOTE_CONTROL_RELAY_URL` 覆盖，便于自建/抓包）。
- 三条 WS，鉴权用**本机 OAuth 的 refreshToken**，优先塞 subprotocol `kimi-code.bearer.<token>`，
  失败回退 `Authorization` 头：
  - `/v1/remote/create` — 管理通道。`register{device_id, alias, platform, client_version, local_base_url}`
    → `register_ack` / `register_nak`；之后收 `open_ws` / `close_ws` / `disconnect`。
  - `/v1/remote/http?device_id=…` — HTTP 隧道。relay 下发 `{type:"request", request_id, body_base64, is_last}`，
    内容是**裸 HTTP/1.1 报文**；本地解析→转发回环→把裸响应 base64 回传。限 10 MiB / 30s。
  - `/v1/remote/stream/<stream_id>` — 浏览器每条 WS 对应一条隧道 WS，与本地 WS 双向桥接。
- `device_id` = `~/.kimi-code/device_id` 里的随机 UUID（重启后链接不变）；`deviceName` = hostname。
- 头部策略：剥掉客户端的 `authorization/cookie/host/origin/...`，**由隧道注入
  `Authorization: Bearer <本地 server token>`**。所以远程客户端**拿不到也不需要**本地 token。
- 单实例锁 `~/.kimi-code/server/rc.json`（pid + nonce + url，按 pid 存活判断）。一机只能一个 RC 实例；
  必须绑回环；不能与 `--dangerous-bypass-auth` 并用。
- 终端二维码：`apps/kimi-code/src/utils/remote-control-qr.ts`，PNG 落 `~/.kimi-code/rc-qrcode.png`。

### 1.3 链接格式（上游行为，App 不使用）

```
https://code-rc.kimi.com/devices/<deviceId>/?rc=1&from=kimi_code_cli
https://code-rc.kimi.com/devices/<deviceId>/sessions/<sessionId>?rc=1&from=kimi_code_cli
```

`deviceId` 是 URL-encoded UUID。`/rc` 在会话中启动时会直接带上 sessionId。
→ App **不解析**这些链接（产品决定不做链接/扫码接入），设备 id 从 `/v1/remote/devices` 拿。

### 1.4 Web 前端如何适配路径前缀（对原生客户端的意义）

隧道对响应做即时重写（`rewriteRemoteControlResponse`）：HTML 注入一段 script 写
`sessionStorage['kimi-desktop-server-origin'] = location.origin + '/devices/<id>'` 并包装
`history.pushState/replaceState` 补前缀；同时批量替换 `src="/`、`href="/`、`"/assets/` 等。
前端据此推导基址：

```js
serverHttpUrl = origin                       // 含 /devices/<id> 前缀
REST  = `${origin}/api/v1${path}`
WS    = `${origin}/api/v1/ws?client_id=<uuid>`   // http→ws, https→wss
```

**原生客户端不需要这套重写**：直接把 `https://code-rc.kimi.com/devices/<id>` 当 baseURL 即可。

### 1.5 bundle 里真正的 RC 专有代码（仅此一小块）

- `"/devices/"` 前缀常量、`sessionStorage` key `kimi-rc-device-id`、`rc=1` 判定；
- 路由适配：剥前缀给内部 router、pushState 时把 `rc`/`from` 带回去；
- 组件 `RcDeviceSwitcher`：`fetch("/v1/remote/devices", {credentials:"same-origin"})` →
  `{devices:[{device_id, platform, status}], max_devices}`，在线/离线分组，切设备＝跳
  `/devices/<id>/?rc=1&…`；
- i18n `sidebar.rc*`（Online/Offline/Connectable/Unavailable/Select device）。另一组 `rc*`
  （`rcLead`/`rcDeniedTitle`/`rcExpiredTitle`/`rcUnsupportedHintWechat` + "在浏览器打开"引导）
  在 CLI 包内无调用方 → **属于 relay 托管的登录/授权页**，代码不在 bundle 里。

### 1.6 鉴权模型（三段分离）

| 段 | 凭证 |
|---|---|
| 客户端 ↔ relay | Kimi 账号（浏览器用 same-origin cookie）；需与本机同账号、需付费会员；每账号约 3 台设备 |
| 本机 ↔ relay | 本机 OAuth refreshToken（WS subprotocol `kimi-code.bearer.<token>`） |
| 隧道 ↔ 本地服务 | 本地 server token，隧道注入，客户端永不接触 |

RC 链接本身不含 token、不含会话数据，但它是这台机器的控制入口（CLI 横幅明确警告勿外传）。

**已实测确认**（2026-09-18，用本机 `kimi login` 的凭证打 relay）：

| 试法 | 结果 |
|---|---|
| `GET /v1/remote/devices` 无凭证 | 401 `{"error":{"message":"missing token","type":"invalid_authentication_error"}}` |
| `Authorization: Bearer <access_token>` | 401 `Incorrect API key provided` |
| **`Authorization: Bearer <refresh_token>`** | **200 ✅** |
| `GET /devices/<id>/api/v1/meta` 同上 bearer | 200，穿透到本机 kap-server |
| `GET /devices/<id>/openapi.json` 同上 | 200，378 KB 完整 OpenAPI |
| `wss://…/devices/<id>/api/v1/ws` + `Authorization` 头 | **✅ server_hello → client_hello → ack code=0** |
| 同上，改用 subprotocol `kimi-code.bearer.<refresh_token>` | ✅ 同样可用 |
| 同上，不带任何凭证 | 401 Unauthorized |

**relay 认的是 refresh_token，不是 access_token** —— 与隧道客户端一致（`startRemoteControl` 读的就是
`token.refreshToken`）。该 refresh_token 是 JWT，payload 含 `client_id / user_id / scope:"kimi-code" /
token_id / device_id / region / type:"refresh"`，`exp - iat ≈ 30 天`。注意它**绑定签发时那台机器的
device_id** —— iOS 端自己跑 device-code flow 会拿到属于自己 device_id 的 token，不要复制桌面端的。

实测时 relay 回的 `server_hello`：`protocol_version=2`、`heartbeat_ms=10000`（比协议默认的 30s 短）、
`capabilities={event_batching:false, compression:false}`。`client_hello` 的 ack 形如
`{accepted_subscriptions:[], resync_required:[], cursors:{}}`。

探测脚本：`scripts/probe-ws.mjs`（可重跑，凭证不落日志）。

---

## 2. 本地服务 API（隧道后面的真实后端，`packages/kap-server`）

baseURL = `https://code-rc.kimi.com/devices/<deviceId>`，全部走 `/api/v1`。
鉴权由隧道注入，**客户端只需带 relay 那一层凭证**（见 §5）。

### 2.1 REST（Envelope 统一包装，`okEnvelope`/`errEnvelope`）

`GET /api/v1/meta`、`/config`、`/models`、`/capabilities`、`/workspaces`、`/tools`、`/plugins`、`/skills`

会话：
```
GET|POST /sessions                        列表 / 新建
GET|PATCH|DELETE /sessions/{id}
GET  /sessions/{id}/status | /history | /transcript | /goal | /warnings | /children
POST /sessions/{id}/prompts               发任务（忙时服务端自动排队，status="queued"）
POST /sessions/{id}/prompts:steer         入参是 {prompt_ids}：把已排队的提前插入，**不是发文本**
POST /sessions/{id}:abort                 停止当前 turn（网页端停止按钮）
GET  /sessions/{id}/status                composer 的模式/模型/思考强度/上下文圈
POST /sessions/{id}/profile               改 agent_config（model / thinking / permission_mode）
GET  /sessions/{id}/messages
GET|POST /sessions/{id}/questions[/{tail}]
GET  /sessions/{id}/tasks[/{task_id}]     子 agent / workflow 面板
GET  /sessions/{id}/terminals[/{id}]
GET  /sessions/{id}/file-history/changes | /file-history/content    diff
GET  /sessions/{id}/media/{file_id}
GET  /sessions/{id}/snapshot | /export
POST /sessions/{id}/title/generate
```

权限确认（App 的核心交互之一）：
```
GET  /sessions/{id}/approvals?status=pending → { items: [ApprovalRequest] }
POST /sessions/{id}/approvals/{approval_id}  → { decision, scope?, feedback?, selected_label? }
     decision: "approved" | "rejected" | "cancelled"；scope: "session"
     ApprovalRequest: { approval_id, session_id, turn_id?, tool_call_id, tool_name,
                        action, tool_input_display, created_at, expires_at }
     已被别处解决时返回 { resolved: false }
```

文件/工作区：`/fs::browse`、`/fs::content`、`/fs::home`、`/fs::mkdir`、`/fs::suggest`、
`/workspace/fs::search`、`/workspace/fs::suggest`、`/sessions/{id}/fs/*`、`/files[/{file_id}]`、`/search`。

RC 自身开关（本地 UI 用，远程一般用不到）：`GET|POST /api/v1/remote-control`
→ `{enabled, state: off|starting|on|stopping, url?, device_id?, device_name?, error?}`。
状态机在 `packages/remote-control/src/manager.ts`（xstate）。

### 2.2 WebSocket（实时事件主通道）

```
wss://code-rc.kimi.com/devices/<id>/api/v1/ws?client_id=<uuid>
subprotocol（本地直连时）: kimi-code.bearer.<token>
WS_PROTOCOL_VERSION = 2, heartbeat ≈ 30s
```

握手：
1. 服务端 → `server_hello{ws_connection_id, protocol_version, heartbeat_ms, max_event_buffer_size, capabilities{event_batching, compression}}`
2. 客户端 → `client_hello{client_id, subscriptions?, cursors?, agent_filter?}`
3. `ack` → `{accepted_subscriptions, resync_required, cursors}`

控制消息：`subscribe` / `subscribe_v2{session_id, transcript, transcript_since}` /
`unsubscribe(_v2)` / `abort` / `terminal_attach|detach|input|resize|close` / `ping`-`pong`，
每条带 `id`，服务端回 `ack{id, code, msg, payload}`。

事件信封：`{type, seq, epoch?, volatile?, offset?, session_id?, timestamp, payload}`。
**`seq`+`epoch` 是断线续传的游标**：重连时在 `client_hello.cursors` 里带上，
服务端用 `resync_required` 告知哪些 session 必须全量重拉（对应前端 `historyCompacted` 处理）。
事件类型（`src/protocol/events-zod.ts`）包括 `assistant.delta`、`activity.*`、`agent.status.updated`、
`compaction.*`、`event.session.created|deleted|archived|status_changed|work_changed`、
`event.config.changed`、`awaiting_approval`、`awaiting_question`、`background.task.*` 等。
另有独立的 transcript 通道（前端用 `client_id + "-transcript"` 再开一条 WS）。

规范文件：`packages/kap-server/src/openapi/`、`src/protocol/asyncapi.ts`（本地服务在线暴露
`/openapi.json`、`/asyncapi.json`，**免鉴权**，是生成 Swift 模型最快的路子）。

---

## 3. iOS 26 客户端架构建议

```
App
├─ Welcome         欢迎 → 下一步 → kimi rc → 我已完成 → 登录（§5）
├─ Devices         账号下的设备列表
├─ KapClient       REST（URLSession + Codable，Envelope 解包）
│                  WS（URLSessionWebSocketTask + cursor 续传）
├─ Store           SwiftData 或内存 actor，事件流 → 会话/消息/工具调用/approval
└─ UI (SwiftUI)    会话列表 → 会话详情（流式消息、工具卡片、diff、终端）
                   + approval 弹层、task 面板
```

原生组件对照：

| 需求 | iOS 原生方案 |
|---|---|
| 选设备 | `List` + `/v1/remote/devices`，在线的可点、离线的置灰 |
| 导航 | iPad/Mac `NavigationSplitView`，iPhone `NavigationStack` |
| 登录确认页 | `ASWebAuthenticationSession`（共享 Safari cookie；成功后代码 `cancel()` 自动收起） |
| 实时连接 | `URLSessionWebSocketTask` + `NWPathMonitor`；后台用 BGTask 只做重连与拉取 |
| 权限确认 | `.alert` / `.confirmationDialog` / `.sheet(.presentationDetents)`；配合本地通知 |
| 通知 | `UNUserNotificationCenter` 本地通知（App 在前台/后台连着 WS 时提醒 approval） |
| 终端流 | `Text` + 等宽 `.monospaced()`，或 Metal/`CATextLayer` 自绘；输入走 `terminal_input` |
| diff | `Text` + `AttributedString`，`.monospaced()`，语法高亮可后置 |
| 图标 | **仅用 SF Symbols**：`laptopcomputer`、`server.rack`、`bubble.left.and.text.bubble.right`、`hammer`、`checkmark.shield`、`xmark.shield`、`terminal`、`doc.text.magnifyingglass`、`sidebar.leading` |
| 视觉 | iOS 26 Liquid Glass：`.glassEffect(...)` / `GlassEffectContainer`、`.buttonStyle(.glass)`；配色走 `Color.accentColor` + 语义色，别硬编码 |
| 其他系统集成 | App Intents / Siri（"继续那个任务"）、Live Activity（长任务进度）、Keychain 存凭证 |

工程约定：
- Swift 6 严格并发；网络层用 `actor`，UI 用 `@Observable`。
- 凭证只进 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），**不要**落 UserDefaults。
- 所有 REST 响应先过 Envelope 解包，错误码集中映射（`src/protocol/error-codes.ts`）。
- 断线重连必须带 `seq/epoch` 游标，并正确处理 `resync_required`；否则消息会错序/丢。

---

## 4. 上游限制（会直接影响 App 体验，需在 UI 里说明）

- 一台机器同时只能有一个 RC 实例；本机休眠/断网/`Ctrl+C` 后远程立即不可用。
- 每账号约 3 台设备。
- 必须与本机同一 Kimi 账号，且需付费会员。
- 手机端无法脱离会话浏览本机文件系统（只能看会话里暴露的 diff/文件卡片，以及 `/fs::*` 接口允许的范围）。
- HTTP 隧道单请求上限 10 MiB、30s 超时 → 大文件/长响应要分页或走 WS。

---

## 5. 鉴权方案（已定：全原生，无 WebView）

**方案 A 已验证可行**：

1. App 内跑 §1.7 的 device-code flow（`https://auth.kimi.com`，`client_id`
   `17e5f671-d194-4dfb-9706-5516cb48c098`，自己生成并持久化一个 iOS 端 device_id 走 `X-Msh-Device-Id`）
   → 拿到 `refresh_token`（JWT，~30 天）。确认页用 `ASWebAuthenticationSession` 打开（只是个浏览器窗口，
   token 不经过它，靠轮询拿；callback scheme `kimicode` 永远不会触发）。首次打开会有系统弹窗
   "“KimiCode”想要使用“kimi.com”登录"，这是 `ASWebAuthenticationSession` 固有的，去不掉。
2. **所有** relay 请求带 `Authorization: Bearer <refresh_token>`：
   - `GET {relay}/v1/remote/devices` → 设备列表
   - `{relay}/devices/<id>/api/v1/**` → REST
   - `wss://{relay}/devices/<id>/api/v1/ws?client_id=<uuid>` → 事件流（`Authorization` 头即可，
     `URLSessionWebSocketTask` 直接 `URLRequest.setValue(_:forHTTPHeaderField:)`）
3. refresh_token 存 Keychain；过期前用 `grant_type=refresh_token` 换新的（注意服务端可能轮换，
   换到新的要立刻写回，否则会把自己登出）。

App 只走 relay。要绕开隧道单独调接口，用 curl 直连 `kimi web` 的 `http://127.0.0.1:<port>`，
Bearer 用 `~/.kimi-code/server.token`，两边 API 完全一致。

## 6. 工程结构与开发流程

```
KimiCode.xcodeproj/          objectVersion 77，用 PBXFileSystemSynchronizedRootGroup
                             → 新增文件不用改 pbxproj，放进 KimiCode/ 就会被编进去
KimiCode/
├─ KimiCodeApp.swift         入口
├─ Core/
│  ├─ Envelope.swift         {code,msg,data,request_id} + 错误码 + KapError
│  ├─ JSONValue.swift        不定型字段（tool_input_display / WS payload）
│  ├─ Models.swift           FlexibleDate、设备、会话、history 联合体、approval
│  ├─ Endpoint.swift         relay + deviceID → baseURL / WS 地址；KimiConfig 常量
│  ├─ Keychain.swift         凭证存储，不可用时退化为内存并上报给 UI
│  ├─ AuthStore.swift        device-code OAuth：预取 → 开浏览器 → 轮询 → 自动收起
│  ├─ BrowserSession.swift   ASWebAuthenticationSession 包装（可由代码关闭）
│  ├─ KapClient.swift        REST（+ RelayClient 拉设备列表）
│  ├─ KapServicing.swift     会话后端协议：KapClient（真机）/ DemoClient（体验模式）
│  ├─ DemoClient.swift       体验模式的内存演示后端（不连任何服务器）
│  └─ EventStream.swift      WS actor：握手、游标续传、心跳、指数退避重连
└─ Features/
   ├─ Root/                  AppModel（设备/侧栏数据/当前对话）、RootView、WelcomeView
   ├─ Main/                  MainView（抽屉容器）、ChatScreen（主页）、ComposerView（输入卡片）
   ├─ Sidebar/               SidebarView（头部/设备/文件夹/用量）
   └─ Session/               ChatModel（会话或草稿）、TranscriptRow、ApprovalCard
```

构建与运行：

```bash
xcodebuild -project KimiCode.xcodeproj -scheme KimiCode -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```

`KimiCode/zh-Hans.lproj/` 不能删：有它系统才认为 App 支持简体中文，选字菜单、相册 / 文件选择器等系统界面才显示中文（开发语言是 en）。

Xcode 26.2 / iOS 26.2 SDK / Swift 6 / deployment target 26.0。模拟器用临时签名（`CODE_SIGN_IDENTITY = "-"`），
上真机要在 target 里选自己的 Team。

模拟器里跳过浏览器登录（**仅 DEBUG**；token 不落 Keychain，也**绝不会被刷新** —— 刷新会让服务端轮换它，
把桌面端 CLI 登出）：

```bash
SIMCTL_CHILD_KIMI_DEBUG_REFRESH_TOKEN="$(python3 -c "import json;print(json.load(open('$HOME/.kimi-code/credentials/kimi-code.json'))['refresh_token'])")" \
  xcrun simctl launch booted com.qinkun.kimicode
```

### 已落地的架构决定

- **对话运行时照搬官方网页端的 transcript 通道。** 正文不走 `/history`：
  首屏 `GET /sessions/{id}/transcript?agent_id=main&page_size=30`（按轮分页，「加载更早的消息」带 `before_turn`），
  之后 WS `subscribe_v2 {session_id, transcript:{main:"delta"}, transcript_since:{main:seq}}` 推
  `transcript.reset / transcript.ops`，本地按开源仓 `packages/transcript/src/ops/apply.ts` 应用（`Core/Transcript.swift`），
  `append` 的 offset 按 UTF-16 对齐，对不上就全量重拉。逐字流式靠它，不再整段重拉。
- **视图模型照搬网页端管线**（`Features/Session/ConversationBuilder.swift`）：turn → 用户 / 助手消息（`RE` + `C6`），
  连续的思考 + 工具 ≥2 个合成一组（`$At`，摘要「读取了 2 个文件 · 运行了 1 条命令」），
  最后一段正文之前的全部折叠成「已工作 X」（`FAt` / TurnFold），思考时长用客户端计时（`thinkingTiming`，不含等确认的时间）。
- **运行态全从 transcript 派生**：`meta.activity == "turn"` = 在跑；`meta.agent.phase` 的 `retrying` → 「正在重试（第 n/max 次）」，
  `interrupted/aborted` 或末轮 `cancelled` → 「已手动终止」分隔线，`max_steps` / `error` / `failed` → 红色失败卡 +「继续」（发「继续」）。
  确认 / 提问走 REST pending 列表（`/approvals?status=pending`、`/questions?status=pending`），有 `interaction.upsert` 或相关事件时重拉。
- **确认卡片的类型映射照搬网页端 `PJ`**：`command → shell`、`file_io`（write→file / edit→diff / 其他→fileop）、
  `url_fetch → url`、`agent_call / skill_call → invocation`、`todo_list → todo`、`plan_review`。
- **正文原地自由选择**：iOS 上 `Text` 的 `.textSelection` 长按只能整段拷贝，所以助手 Markdown、用户气泡、思考段落改用不可编辑的
  UITextView 排版（`Features/Session/SelectableText.swift`），长按选词、拖手柄任意调整。连续的段落 / 标题 / 列表排在同一个视图里可跨段选；
  代码块、表格、引用、分隔线是隔断。长按选词全交给 UITextView 自己，不加自定义手势；只在外面让路：对话页点空白收起键盘时跳过选中的字和手柄附近，选字时横滑不开侧栏。
  取消选择时别立刻改选区（系统会自己藏高亮），否则正在缩回的菜单会跟着滑走；旧选区等动画完再清。
  表格长按弹系统菜单「拷贝」（`.contextMenu`，制表符分列），代码块用自带复制按钮。
  UIKit 读不到 SwiftUI 环境的 `.font` / `.foregroundStyle`，`MarkdownText` 要换字号颜色得传 `tone`。工具输出面板仍是 `.textSelection` 整段拷贝。
- **LaTeX 用 SwiftMath 原生排版**（`Features/Session/MathText.swift`，不用 WebView）：`$…$` / `\(…\)` 行内公式先换成占位符再解析 Markdown，
  再换成 `MathAttachment`（图片附件，跟文字一起可选，拷贝 / 添加到会话框时换回 `$源码$`）；`$$…$$` / `\[…\]` 独占几行是 `MarkdownBlock.math`
  （放得下居中、太宽横滑、长按拷贝公式）；表格格子里嵌图片。`$5 和 $10` 这种不算公式，行内代码 / 代码块里不解析。SwiftMath 1.7.3 不认的
  `\dfrac`、`\operatorname`、`\lVert`、`\boxed`、`\tag`、`\overset`、`align` / `equation` 环境等在 `MathRenderer.normalized` 里换掉（加新映射前先用 1.7.3 实测，main 分支支持得更多，别拿它测）；仍排不出来就显示源码。排好的图按（源码, 字号, 颜色）缓存，换深浅色重排。
  体验模式（仅 DEBUG）发「md」回一段 Markdown / 公式样例。
- **样式对齐官方、字号走我们的系统动态字体**：正文 `.body`，工具行 / 思考 / 折叠头 `.subheadline`，元信息 `.caption`；
  颜色 token（用户气泡 #f5f5f5 / #292929、面板 3% 底、diff 绿红、Kimi 蓝）在 `MarkdownText.swift` 的 `Palette`。
  用户气泡是胶囊（单行）/ 大圆角（多行）、中等字重；下面的复制 / 撤回 / 时间默认收着，点气泡才展开。
  思考不在正文里展开：进行中是一行「〰 思考中 最新那句」（涂鸦线 `scribble.variable` 用 Draw 效果循环描画；句子放不下时跟着新字往左滚，不可点）；
  结束后是「〰 已思考 N秒 第一句… ›」（涂鸦线静止），
  点开从底部弹出全文（标题「思考了 N秒」，左上角 ✕，不透明底）。
- **新建会话不采纳 `agent_config`**（实测建出来 `model:""`、`permission:manual`）：第一条消息发出前不用 `/status` 覆盖 composer 上的选择，
  空的 model / thinking 不往请求里带（服务端会拒 `thinking: Too small`）。
- **执行轮数**：`loop_control.max_steps_per_turn` 不设或为 0 都是不限（`maxSteps > 0` 才限制），是电脑上的全局配置，App 不去改。
- **心跳读 `server_hello`，不硬编码。** 实测服务端给的是 `heartbeat_ms=10000`，不是协议默认的 30s。
- **游标续传。** 每条非 `volatile` 事件的 `seq`/`epoch` 按会话记下，重连时放进 `client_hello.cursors`，
  并处理 ack 里的 `resync_required`。
- **发任务一律 `POST /prompts`，不排队。** 忙时 composer 只给停止。（早期版本误把文本发给 `prompts:steer`，
  那个接口收的是 `{prompt_ids}`，已改掉。）
- **停止走 REST `:abort`，不走 WS `abort`** —— 与网页端一致。
- **草稿会话。** 在文件夹旁点 + 不会立刻建会话，第一条消息发出时才 `POST /sessions`，
  避免空会话污染侧栏。
- **乐观发送。** 用户消息先本地显示，失败给"重试/丢弃"，成功后由正文里的真实消息顶替（按文本去重）。
- **正文只订阅主 agent**（`agent_id=main`），子 agent 的留给 task 面板。

### 下一步（尚未实现）

1. 子 agent / workflow 的 task 面板（`/sessions/{id}/tasks`）
2. diff 与文件卡片（`/file-history/changes`、`/file-history/content`）
3. 终端流（`terminal_attach/input/resize` + `/sessions/{id}/terminals`）
4. 新建会话的目录选择（`/fs:browse`、`/workspaces`）
5. 待确认时的本地通知（`UNUserNotificationCenter`）、长任务 Live Activity
6. 对话流里官方有、这版还没搬的：每轮「N 个文件已修改」（`/file-history/changes`）、Agent / Todo / Plan 等专用工具卡、
   用户消息里的图片缩略图、代码语法高亮

## 7. 参考位置

- 开源仓：`github.com/MoonshotAI/kimi-code`（本次调研 clone 在 scratchpad，已不保留）
  - `packages/remote-control/src/{remote-control,manager,lock}.ts` — 隧道客户端全部逻辑
  - `packages/kap-server/src/{protocol,routes,openapi}/` — 待对接的 API 面
  - `packages/oauth/src/{oauth,constants,identity,region}.ts` — 账号登录
  - `docs/zh/guides/remote-control.md`、`docs/zh/guides/web.md` — 官方行为说明
- 本机安装：`/opt/homebrew/lib/node_modules/@moonshot-ai/kimi-code`
  - `dist-web/assets/index-*.js` — 网页端构建产物（Vue 3），RC 适配逻辑在里面
- 本机状态：`~/.kimi-code/`（`device_id`、`server.token`、`credentials/`、`server/rc.json`、`rc-qrcode.png`）
