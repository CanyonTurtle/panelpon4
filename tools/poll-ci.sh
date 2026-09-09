#!/usr/bin/env bash
# Polls GitHub Actions for a commit's workflow run(s) until they all finish,
# then prints a final status line per run. Uses the unauthenticated public
# REST API (works for this repo since it's public) -- no `gh` CLI dependency.
#
# Usage: tools/poll-ci.sh [sha] [interval_seconds]
#   sha              defaults to the current HEAD commit
#   interval_seconds defaults to 10

set -euo pipefail

REPO="CanyonTurtle/panelpon4"
SHA="${1:-$(git rev-parse HEAD)}"
INTERVAL="${2:-10}"

echo "Polling CI for $REPO@$SHA (every ${INTERVAL}s)..."

while true; do
  runs_json=$(curl -s "https://api.github.com/repos/$REPO/actions/runs?head_sha=$SHA&per_page=10")
  count=$(echo "$runs_json" | jq '.total_count // 0')

  if [ "$count" -eq 0 ]; then
    echo "  (no workflow runs found yet for this sha)"
    sleep "$INTERVAL"
    continue
  fi

  # Print current state of every run for this sha.
  echo "$runs_json" | jq -r '.workflow_runs[] | "  [\(.status)] \(.name): \(.conclusion // "-") \(.html_url)"'

  pending=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.status != "completed")] | length')
  if [ "$pending" -eq 0 ]; then
    echo "All runs completed."
    fail=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.conclusion != "success")] | length')
    if [ "$fail" -eq 0 ]; then
      echo "RESULT: SUCCESS"
      exit 0
    else
      echo "RESULT: FAILURE"
      exit 1
    fi
  fi

  sleep "$INTERVAL"
done
