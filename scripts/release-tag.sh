#!/usr/bin/env bash
# 本地发版辅助脚本：更新 MARKETING_VERSION、打带注释的 Git Tag 并推送触发 GitHub Actions。
#
# 用法：
#   ./scripts/release-tag.sh 1.9 "修复若干问题，优化交互体验。"
#   ./scripts/release-tag.sh 1.9 -f /tmp/notes.txt
#   ./scripts/release-tag.sh 1.9              # 自动打开编辑器输入多行更新日志

set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  ./scripts/release-tag.sh <版本号> [更新日志文本 | -f <文件路径>]

示例:
  ./scripts/release-tag.sh 1.9 "1. 新增 xxx\n2. 修复 xxx"
  ./scripts/release-tag.sh 1.9 -f release_notes.txt
  ./scripts/release-tag.sh 1.9
EOF
}

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
fi

RAW_VERSION="$1"
VERSION="${RAW_VERSION#v}"
TAG="v${VERSION}"
shift

if ! [[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "错误：版本号 '${RAW_VERSION}' 格式不合法，应为 X.Y 或 X.Y.Z（如 1.9 或 1.9.1）。" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

if [ -n "$(git status --porcelain)" ]; then
  echo "错误：当前工作区有未提交的改动，请先 commit 或 stash 后再发版。" >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "错误：Tag '${TAG}' 已存在。" >&2
  exit 1
fi

TMP_NOTES="$(mktemp)"
trap 'rm -f "${TMP_NOTES}"' EXIT

if [ $# -ge 2 ] && [ "$1" = "-f" ]; then
  cp "$2" "${TMP_NOTES}"
elif [ $# -ge 1 ]; then
  printf '%b\n' "$1" > "${TMP_NOTES}"
else
  cat <<EOF > "${TMP_NOTES}"
# 请在下方填写 MoonCode ${TAG} 的 App Store 更新日志（简体中文 zh-Hans）
# 以 # 开头的行会被自动忽略

EOF
  "${EDITOR:-vi}" "${TMP_NOTES}"
  grep -v '^[[:space:]]*#' "${TMP_NOTES}" > "${TMP_NOTES}.clean" || true
  mv "${TMP_NOTES}.clean" "${TMP_NOTES}"
fi

# 去除首尾空行并校验非空
python3 - "${TMP_NOTES}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8").strip()
if not text:
    raise SystemExit("错误：更新日志不能为空。")
if len(text) > 4000:
    raise SystemExit(f"错误：更新日志超过 4000 字上限（当前 {len(text)} 字）。")
p.write_text(text + "\n", encoding="utf-8")
PY

echo "=== 即将发布的版本 ==="
echo "Tag:       ${TAG}"
echo "Version:   ${VERSION}"
echo "分支:      $(git branch --show-current)"
echo "--- 更新日志（zh-Hans）---"
cat "${TMP_NOTES}"
echo "-------------------------"
read -r -p "确认更新版本号、创建 Tag 并推送到 origin 触发自动发版？[y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "已取消。"
  exit 0
fi

# 同步更新 project.pbxproj 里的 MARKETING_VERSION（Debug + Release）
PBXPROJ="KimiCode.xcodeproj/project.pbxproj"
python3 - "${PBXPROJ}" "${VERSION}" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
ver = sys.argv[2]
src = p.read_text(encoding="utf-8")
dst, count = re.subn(r'(?m)^(\t\t\t\tMARKETING_VERSION = )[^;]+(;)$', rf'\g<1>{ver}\g<2>', src)
if count == 0:
    raise SystemExit("未在 project.pbxproj 中找到 MARKETING_VERSION")
if dst != src:
    p.write_text(dst, encoding="utf-8")
    print(f"已更新 {p} 中的 MARKETING_VERSION -> {ver}（{count} 处）")
else:
    print(f"{p} 中的 MARKETING_VERSION 已是 {ver}，无需修改")
PY

if ! git diff --quiet -- "${PBXPROJ}"; then
  git add "${PBXPROJ}"
  git commit -m "chore: bump version to ${VERSION}"
fi

git tag -a "${TAG}" -F "${TMP_NOTES}"
git push origin HEAD
git push origin "${TAG}"

echo "✅ 已推送 ${TAG}，GitHub Actions 将自动执行 Archive、上传、写更新日志并提交审核。"
echo "查看进度：gh run list --workflow=release.yml"
