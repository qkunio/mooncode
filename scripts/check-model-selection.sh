#!/bin/bash
set -euo pipefail

task_repo_root=$(cd "$(dirname "$0")/.." && pwd)
task_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/mooncode-model-checks.XXXXXX")
trap 'rm -rf "$task_check_dir"' EXIT
cd "$task_repo_root"

swiftc -swift-version 6 -parse-as-library \
  KimiCode/Core/{JSONValue,Envelope,Models,Endpoint,ComposerConfig,ModelCatalog,Transcript,KapClient,KapServicing,DemoClient,EventStream,RefreshScheduler}.swift \
  KimiCode/Features/Root/AppModel.swift \
  KimiCode/Features/Session/{ChatModel,ConversationBuilder}.swift \
  scripts/ModelSelectionChecks.swift \
  -o "$task_check_dir/model-checks"
"$task_check_dir/model-checks"
