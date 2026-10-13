#!/bin/bash
set -euo pipefail

task_repo_root=$(cd "$(dirname "$0")/.." && pwd)
task_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/mooncode-attachment-checks.XXXXXX")
trap 'rm -rf "$task_check_dir"' EXIT
cd "$task_repo_root"

swiftc -swift-version 6 -parse-as-library \
  KimiCode/Core/{JSONValue,Envelope,Models,Endpoint,Transcript,KapClient,KapServicing,DemoClient,EventStream,RefreshScheduler}.swift \
  KimiCode/Features/Session/{ChatModel,ConversationBuilder}.swift \
  scripts/AttachmentChecks.swift \
  -o "$task_check_dir/attachment-checks"
"$task_check_dir/attachment-checks"
