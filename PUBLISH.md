# MoonCode 发布手册与现状（动态更新）

> 本文件记录 MoonCode（`com.qinkun.kimicode`）的 App Store 自动发布方案、当前发版状态、一次性配置清单与日常发版操作。  
> **维护约定**：每次发版、变更发布配置、更新证书/Secrets 或调整发版流程时，同步更新本文档中的「当前现状」与「发布记录」。

---

## 1. 当前发布现状

- **更新日期**：2026-11-25
- **GitHub 仓库**：`qkunio/mooncode`（Public，GitHub Actions `macos-26` Runner 免费）
- **Bundle ID**：`com.qinkun.kimicode`（不可变更）
- **App Store 名称**：MoonCode - KimiCode远程控制客户端
- **目标语言**：仅简体中文（`zh-Hans`）
- **上架策略**：审核通过后自动上架（`AFTER_APPROVAL`）
- **签名证书有效期**：`Apple Distribution` 证书有效期至 **2027-11-25**（到期前需重新导出 `.p12` 更新 Secret）
- **Xcode Cloud**：原 `Default`（监听 `main` 分支自动 Archive）工作流已于 2026-11-25 停用，发版统一走 GitHub Actions。
- **当前线上 / 审核状态**：
  - App Store 版本 **`1.9`** 已过审上线（**可分发**，所挂构建包为包内版本 `1.8` / Build `2`）。
  - 因为 `1.9` 已上线，**下一版请直接从 `v1.10`（或 `v2.0`）开始打 Tag**；从下一版起，`Git Tag = 包内 MARKETING_VERSION = App Store 版本号` 将由 CI 自动强制对齐，构建号自动按 `YYYYMMDD.<run_number>` 递增。

### 自动化接入清单

- [x] 添加共享 Xcode Scheme（`KimiCode.xcodeproj/xcshareddata/xcschemes/KimiCode.xcscheme`）
- [x] 添加导出配置模板（`Config/ExportOptions.plist`）
- [x] 实现 App Store Connect API 自动化脚本（`scripts/asc_submit.py`）
- [x] 实现 GitHub Actions 自动发版流水线（`.github/workflows/release.yml`）
- [x] 实现基于清单文件的发版触发器（`Config/release-manifest.json` + `.github/workflows/release-from-manifest.yml`）
- [x] 实现本地打 Tag 辅助脚本（`scripts/release-tag.sh`）
- [x] 本地离线校验（YAML / plist / XML / `pbxproj` 替换逻辑 / Mock API 单测）
- [x] 将自动化配置文件 commit 并 push 到 `main`
- [x] 在 App Store Connect 生成 API Key（App 管理 / 管理权限）
- [x] 从本机钥匙串导出 `Apple Distribution` `.p12` 证书（已本地验证导入与序列号解析，有效期至 2027-11-25）
- [x] 在 GitHub 仓库创建 `appstore-release` Environment 并填入全部 6 个 Secrets
- [x] 停用 App Store Connect 中旧的 Xcode Cloud `Default`（`main` 分支）工作流
- [ ] 在 `v1.10` 完成首次云端联调（建议首次先 `submit_for_review=false` 验证一次，或直接推 `v1.10` 全自动提审）

---

## 2. 自动发布架构与相关文件

推 `v*` 带注释 Tag，或在 `main` 分支更新 `Config/release-manifest.json`（`enabled: true`）后，GitHub Actions（`macos-26`）全自动完成：

```text
push Tag (v1.10 + 中文更新日志注释) 或 push Config/release-manifest.json (自动补打 Tag)
  → 校验版本号与更新日志
  → 导入临时 Keychain 中的 Apple Distribution .p12 证书
  → scripts/asc_submit.py fetch-profile（自动复用或重建 IOS_APP_STORE 描述文件）
  → 仅在 CI 临时工作区覆写 KimiCode target 的 Release 签名与版本号（不污染 SwiftMath）
  → xcodebuild archive（Release / generic/platform=iOS）
  → xcodebuild -exportArchive（destination=upload，直传 App Store Connect）
  → scripts/asc_submit.py submit（轮询 Build VALID → 创建 AFTER_APPROVAL 版本 → 写 zh-Hans 更新日志 → 绑 Build → Review Submissions API 提交审核）
  → 自动创建对应 GitHub Release
  → 清理临时 Keychain、证书与私钥
```

| 文件 | 作用 |
|---|---|
| `.github/workflows/release.yml` | GitHub Actions 核心发版工作流（响应 `v*` Tag、`workflow_dispatch` 与 `workflow_call`） |
| `.github/workflows/release-from-manifest.yml` | 监听 `main` 分支 `Config/release-manifest.json` 变动，自动打带注释 Tag 并调用 `release.yml` |
| `Config/release-manifest.json` | 声明式发版清单（用于通过 GitHub 网页端或 MCP 触发发版，默认 `enabled: false`） |
| `scripts/asc_submit.py` | App Store Connect REST API 脚本（`fetch-profile` 自动管描述文件；`submit` 等构建 + 写 `zh-Hans` 日志 + `AFTER_APPROVAL` 提审） |
| `scripts/release-tag.sh` | 本地一键发版脚本：更新 `MARKETING_VERSION`、编辑/校验中文日志、二次确认后打带注释 Tag 并推送 |
| `Config/ExportOptions.plist` | `xcodebuild -exportArchive` 基础模板（`app-store-connect` + `upload` + `manual` + `manageAppVersionAndBuildNumber=false`） |
| `KimiCode.xcodeproj/xcshareddata/xcschemes/KimiCode.xcscheme` | CI 构建所需的共享 Scheme |

---

## 3. 一次性外部配置指南

> 出于公开仓库安全考虑，所有敏感凭证只存在 GitHub Environment Secrets 中，不写入仓库；工作流也绝不在 `pull_request` 上运行。

### 步骤 A：生成 App Store Connect API Key
1. 登录 App Store Connect → **用户和访问** → **集成** → **App Store Connect API** → 生成团队密钥。
2. 权限选择 **App 管理（App Manager）** 或 **管理（Admin）**（Developer 权限无法创建版本/提审）。
3. 记录 `Issuer ID`、`Key ID`，并下载 `.p8` 私钥文件（仅可下载一次）。

### 步骤 B：导出 Apple Distribution `.p12` 证书
1. 打开本机「钥匙串访问」→「登录」→「我的证书」→ 找到有效的 `Apple Distribution` 证书（展开需包含私钥）。
2. 右键导出为 `.p12`，设置一个导出密码。
3. 在终端转成 base64：
   ```bash
   base64 -i /path/to/AppleDistribution.p12 | pbcopy
   ```

### 步骤 C：配置 GitHub Environment 与 Secrets
在 GitHub 仓库 `Settings → Environments` 新建名为 **`appstore-release`** 的 Environment，添加以下 6 个 Secrets：

| Secret 名称 | 说明 |
|---|---|
| `APPLE_TEAM_ID` | 10 位 Apple Developer Team ID（见本机 `Config/Local.xcconfig`，不提交进仓库） |
| `ASC_ISSUER_ID` | App Store Connect API 的 Issuer ID（UUID） |
| `ASC_KEY_ID` | App Store Connect API 的 10 位 Key ID |
| `ASC_PRIVATE_KEY` | `.p8` 私钥文件的完整 PEM 内容（含 `BEGIN/END PRIVATE KEY`） |
| `DIST_CERT_P12_BASE64` | 上一步导出的 `.p12` base64 编码字符串 |
| `DIST_CERT_PASSWORD` | 导出 `.p12` 时设置的密码 |

---

## 4. 日常发版操作

平时往 `main` 正常 `git push` **不会**触发发版；仅在推送 `v*` Tag，或在 `main` 上修改 `Config/release-manifest.json`（且 `enabled: true`）时触发。

### 方式一：使用本地辅助脚本（推荐）
```bash
# 单行 / 换行文本直接传入
./scripts/release-tag.sh 1.10 "1. 新增 xxx\n2. 修复 xxx"

# 从文件读取更新日志
./scripts/release-tag.sh 1.10 -f /tmp/notes.txt

# 不传日志参数，自动打开编辑器输入多行中文更新日志
./scripts/release-tag.sh 1.10
```

### 方式二：原生 Git 命令
```bash
git tag -a v1.10 -m "1. 新增 xxx
2. 修复 xxx"
git push origin v1.10
```
> 注意：必须使用 **带注释的 Tag（`-a`）**，轻量 Tag 没有更新日志文本会被工作流拦截报错。

### 方式三：手动触发 / 仅传包不提审
在 GitHub 仓库 **Actions → Release to App Store → Run workflow** 中：
- 填入已存在的 `tag`（如 `v1.10`）；
- 可选填写 `release_notes` 覆盖 Tag 注释；
- 如需先只上传并填写更新日志、暂不点提审，将 `submit_for_review` 设为 `false`。

### 方式四：通过 `Config/release-manifest.json` 触发（支持 GitHub MCP / 网页端）
在 `main` 分支更新 `Config/release-manifest.json` 并提交：
```json
{
  "enabled": true,
  "version": "1.10",
  "submit_for_review": true,
  "release_notes": "1. 新增 xxx\n2. 修复 xxx"
}
```
- `release-from-manifest.yml` 会在 `ubuntu-latest` 上校验字段并自动创建、推送带注释的 `v1.10` Tag，随后直接调用 `release.yml` 完成打包、上传与提审。
- 若 `enabled` 为 `false` 或对应 `v<version>` Tag 已存在，工作流会安全跳过，不会重复发版。

查看运行进度：
```bash
gh run list --workflow=release.yml
```

---

## 5. 审核继承、防呆与周期维护

- **自动沿用的项**：新版本创建后，App 审核信息（联系人、审核备注、演示说明）、截图、描述、隐私声明、年龄分级、价格与销售范围、国区备案信息均自动继承自上一版；`ITSAppUsesNonExemptEncryption = NO` 已写入 `project.pbxproj`，上传后自动免答出口合规。
- **内置安全保护**：
  - 目标版本已处于 `WAITING_FOR_REVIEW` / `IN_REVIEW` / `READY_FOR_SALE` 等锁定状态，或已存在进行中的 iOS `reviewSubmission` 时，`scripts/asc_submit.py` 会直接报错退出，避免误伤正在审核中的版本。
  - 若 App Store Connect 中已有另一个未提交的草稿版本阻塞新建版本，脚本会明确打印冲突版本号。
- **低频人工维护项**：
  1. **Apple Distribution 证书**：有效期 1 年，到期前重新导出 `.p12` 并更新 `DIST_CERT_P12_BASE64` / `DIST_CERT_PASSWORD`（Provisioning Profile 由脚本自动续期，无需人工维护）。
  2. **Apple 开发者协议更新**：每年 WWDC 后若 Apple 更新《Apple Developer Program 许可协议》，需账号持有人登录网页点击「同意」，之后在 Actions 页面重跑即可。
  3. **审核被拒（Rejected）**：按审核意见修复后，可调整版本或重跑 workflow 重新提审。

---

## 6. 发布记录

| App Store 版本 | 包内版本 / Build | Git Tag | 日期 | 发布方式 | 状态 | 备注 |
|---|---|---|---|---|---|---|
| `1.9` | `1.8` / `2` | — | 2026-11-24 | Xcode 手动 | 已上架（可分发） | 2026-11-25 确认过审上线；历史版本错位，下版起由 CI 从 `v1.10` 自动对齐 |
