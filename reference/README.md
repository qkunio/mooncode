# 接口规范（从运行中的 kap-server 抓的）

两份都是 2026-09-18 从 `kimi-code/2.0.0` 的本地服务经隧道下载的，**免鉴权**即可拉取：

```bash
curl -H "Authorization: Bearer $REFRESH_TOKEN" \
  https://code-rc.kimi.com/devices/<device_id>/openapi.json  -o reference/openapi.json
curl -H "Authorization: Bearer $REFRESH_TOKEN" \
  https://code-rc.kimi.com/devices/<device_id>/asyncapi.json -o reference/asyncapi.json
```

- `openapi.json` — REST，106 条路径，OpenAPI 3.0.3。生成 Swift 模型的来源。
- `asyncapi.json` — WebSocket，28 种消息。注意 `session_event` 的 payload 是个极大的联合体，
  **不要**整体映射成类型，见 CLAUDE.md 里的架构决定。

服务端升级后重新抓一次再比对。

## 2.4–2.5 协议兼容（2026-11-09）

已对照 2.0.0、2.4.1、2.5.2 的发布产物和真实回环服务，并参考官方变更
[#4428](https://github.com/MoonshotAI/kimi-code/pull/4428)、
[#4470](https://github.com/MoonshotAI/kimi-code/pull/4470)、
[#4606](https://github.com/MoonshotAI/kimi-code/pull/4606)：

- 2.4+ 删除旧 approvals / questions 列表与回写路由，改为平铺 `interaction` 帧和
  `POST /sessions/{id}/interactions/{interaction_id}`。每次订阅确认后重发当前 pending 全量。
- 2.5+ 只保留 `subscribe_v2`，删除旧 `subscribe` 的 seq/epoch 回放；transcript 仍按
  `transcript_since` 续传。`GET /api/v1/sessions/{id}/status` 返回 HTTP 404。
- 2.5+ 状态通过扁平 `agent` / `usage` 帧发送，字段在顶层。`agent.status` 是在跑状态；
  `model`、`thinking`、`permission_mode` 等是全量替换；`usage` 带 `context_tokens` 和可选的
  `max_context_tokens`，比例由客户端计算。transcript 不再提供 `meta` / `todos`。
- iOS 分别建模旧 REST status、全量 agent / usage 与 interaction。新帧优先；旧接口只作回退，
  旧响应不得覆盖新帧。只有旧接口的 HTTP 404 可触发协议降级，其它错误保留。
- 当时尚未进入 2.5.2 的 `turns` / `turn.*` / `item.*`（#4663）不在该次兼容范围内。

## 2.6 对话协议（2026-11-13）

已对照并实测 2.6.0 发布产物与隔离的本地服务：

- `GET /api/v1/sessions/{id}/transcript` 已删除并返回 HTTP 404；改为
  `GET /sessions/{id}/agents/{agent_id}/turns?page_size=N&before_ordinal=M`，返回
  `{turns,has_more}`。turn 内含 header、step summaries 和扁平 items。
- WS 不再有 `server_hello` / `client_hello`；连接后直接发送
  `{type:"subscribe",request_id,session_id,agent_ids}`，由 `{type:"response",request_id,code}` 确认。
  服务端每 10 秒发 `ping`，客户端必须回 `pong`。
- 订阅后先推 `turns` 最新整页；随后用 `turn.started/updated/ended`、
  `item.started/updated/ended/delta/removed` 和 `turns.removed` 增量更新。
  `item.delta` 直接携带追加文本，不再使用旧的 UTF-16 offset 游标。
  `item.output` 依类型可为字符串（tool_call）或对象（notification），必须按任意 JSON 解码。
- 撤销从 `{count}` 改为 `{turn_id,agent_id}`；App 用 opener 所在 turn 的 id。
- iOS 的 `ConversationState` 实现官方 reducer 语义，再投影为现有 transcript 视图模型；
  `KapClient` 优先请求 turns，只在 HTTP 404 / 40401 时回退旧 transcript。

## 2.7 / KAP 1.0.0 协议兼容（2026-11-24）

已对照 Kimi Code Desktop 1.4.2 内置的 `2.7.2`（KAP `1.0.0`）服务端与 `GET /api/v1/kap.md` / AsyncAPI 3.1：

- `Session` 删除 `busy` / `main_turn_active` / `last_turn_reason` / `usage` / `agent_config`，改为
  `activity: "idle" | "turn" | "background"`、`last_turn_outcome`，`pending_interaction` 变为可选，
  `cwd` 提到顶层。`SessionSummary` 兼容新旧两种结构。
- `POST /sessions/{id}/profile` 返回 `{ session, agent }` 而非扁平 `Session`，通过
  `SessionProfileResponse` 兼容新旧响应。
- 停止任务路由从 `POST /sessions/{id}:abort` 改为 `POST /sessions/{id}:cancel`；`KapClient.abort`
  优先调用 `:cancel`，遇到 40001 / HTTP 404 时回退 `:abort`。
- WS 上下文帧从 `usage` 改名为 `context`；`EventStream` 同时接收 `context` 与 `usage`。
- WS `agent` 帧的 `status` 为 `idle | running | ended`，压缩中改为独立布尔字段 `compacting`；
  `SessionAgentState.isWorking` 将 `ended` 视为非运行态，`isCompacting` 同时兼容新旧字段。
- 新增 `GET /sessions/{id}/interactions` 拉取 pending 审批与提问；`ServerMeta` 新增
  `kimi_agent_protocol_version` 与 `capabilities.interactions_list / session_wait`（`terminal` 变为可选），
  并在首屏失败时辅助判定 2.6+ WS 协议。供应商协议新增 `bedrock`。

上面的 JSON 快照仍是 2.0.0 协议，不代表 2.5.2 / 2.6.0 / 2.7.2 的完整接口。
