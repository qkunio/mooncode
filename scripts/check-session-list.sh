#!/bin/bash
set -euo pipefail

task_repo_root=$(cd "$(dirname "$0")/.." && pwd)
task_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/mooncode-session-list-checks.XXXXXX")
trap 'rm -rf "$task_check_dir"' EXIT
cd "$task_repo_root"

swiftc -swift-version 6 -parse-as-library \
  KimiCode/Core/{JSONValue,Envelope,Models,Endpoint,Transcript,Conversation,RuntimeFrames,EventStream,SessionListPool}.swift \
  scripts/SessionListChecks.swift \
  -o "$task_check_dir/session-list-checks"
"$task_check_dir/session-list-checks"
