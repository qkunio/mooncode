# AGENTS.md

面向所有协作 AI Agent 的仓库入口指引。开始任何开发或发布任务前，请先阅读以下对应文档：

## 核心文档索引

- **[CLAUDE.md](CLAUDE.md)**：MoonCode（`qkunio/mooncode`）的产品设计、Kimi Code 远程控制协议规范、架构决策与开发约定。
- **[PUBLISH.md](PUBLISH.md)**：App Store 自动发布流程（GitHub Actions + `xcodebuild` + App Store Connect API）、当前发布/审核现状、Secrets 配置清单与历史发布记录。

## 发布文档维护约定

- `PUBLISH.md` 是**动态更新**文档：每当完成发版、版本状态变化（提审/过审/被拒）、修改 `.github/workflows/release.yml` / `scripts/asc_submit.py` / `scripts/release-tag.sh` / `Config/ExportOptions.plist`、或变更证书与 Secrets 配置时，必须同步更新 `PUBLISH.md` 中的现状、待办清单与发布记录。
- 本仓库为**公开仓库**，严禁将 `Config/Local.xcconfig`、Team ID、`.p8` 私钥、`.p12` 证书或任何 Token 提交到仓库或写入文档。
- 如无用户明确指令，**不要**推送 `v*` Tag 或调用 App Store Connect 写接口，以免误触发正式发版或干扰在审版本。
