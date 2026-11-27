#!/bin/bash
set -euo pipefail

task_repo_root=$(cd "$(dirname "$0")/.." && pwd)
task_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/mooncode-defaults-checks.XXXXXX")
trap 'rm -rf "$task_check_dir"' EXIT
cd "$task_repo_root"

swiftc -swift-version 6 -parse-as-library \
  KimiCode/Core/{JSONValue,Envelope,Models,Endpoint,Transcript,Conversation,KapClient,KapServicing,DemoClient,EventStream,RefreshScheduler,PreviewStorage,RuntimeFrames,SessionListPool}.swift \
  KimiCode/Features/Session/{StreamPipeline,ChatModel,ConversationBuilder}.swift \
  scripts/DefaultsChecks.swift \
  -o "$task_check_dir/defaults-checks"
"$task_check_dir/defaults-checks"
