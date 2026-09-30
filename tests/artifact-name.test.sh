#!/usr/bin/env bash
# A re-run of failed jobs gets a new run_attempt, so an artifact name that embeds it
# cannot be found by the re-run jobs.
set -euo pipefail
workflow="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/ci.yml"
if grep -Eq '^ +name: .*github\.run_attempt' "$workflow"; then
  echo 'artifact name embeds run_attempt' >&2
  exit 1
fi
test "$(grep -c 'overwrite: true' "$workflow")" -eq "$(grep -c 'actions/upload-artifact@' "$workflow")"
