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
- 尚未进入 2.5.2 的 `turns` / `turn.*` / `item.*`（#4663）不在本次兼容范围内。

上面的 JSON 快照仍是旧版协议，不代表 2.5.2 的完整接口。
