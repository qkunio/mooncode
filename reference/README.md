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

## 2.5.2 状态接口兼容（2026-11-08）

已对照本机 `@moonshot-ai/kimi-code@2.5.2` 的发布产物与
[官方变更 #4606](https://github.com/MoonshotAI/kimi-code/pull/4606) 确认：

- `GET /api/v1/sessions/{id}/status` 已移除，旧调用返回 HTTP 404。
- 状态通过 `subscribe_v2` 的扁平 WS `agent` / `usage` 帧发送，字段在顶层，不在 `payload` 内。
- `agent` 带 `session_id`、`agent_id`、`model`、`thinking`、`permission_mode` 等；
  `usage` 带 `context_tokens`、可选的 `max_context_tokens`，用量比例由客户端计算。
- iOS 仅将旧 status 请求的 HTTP 404 作为兼容降级；正文读取等其它请求的错误仍保留。
  收到主 agent 的状态帧后停止请求旧 status；旧版服务端仍使用 REST status。

上面的 JSON 快照仍是旧版协议，不代表 2.5.2 的完整接口。
