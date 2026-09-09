#!/usr/bin/env bash
# Polls GitHub Actions for a commit's workflow run(s) until they all finish,
# then prints a final status line per run. Uses the unauthenticated public
# REST API (works for this repo since it's public) -- no `gh` CLI dependency.
#
# Usage: tools/poll-ci.sh [sha] [interval_seconds]
#   sha              defaults to the current HEAD commit (short or full, only
#                    the first 7 chars are matched)
#   interval_seconds defaults to 15

set -euo pipefail

REPO="CanyonTurtle/panelpon4"
SHA="${1:-$(git rev-parse HEAD)}"
SHA_SHORT="${SHA:0:7}"
INTERVAL="${2:-15}"

echo "Polling CI for $REPO@$SHA_SHORT (every ${INTERVAL}s)..."

# The /actions/runs?head_sha=<sha> filter has been unreliable in practice
# (returned total_count: 0 for a commit that in fact had a run) -- listing
# recent runs unfiltered and matching the short sha client-side works
# instead.
while true; do
  runs_json=$(curl -s "https://api.github.com/repos/$REPO/actions/runs?per_page=10")
  matches=$(echo "$runs_json" | jq --arg sha "$SHA_SHORT" '[.workflow_runs[] | select(.head_sha | startswith($sha))]')
  count=$(echo "$matches" | jq 'length')

  if [ "$count" -eq 0 ]; then
    echo "  (no workflow runs found yet for this sha)"
    sleep "$INTERVAL"
    continue
  fi

  # Print current state of every run for this sha.
  echo "$matches" | jq -r '.[] | "  [\(.status)] \(.name): \(.conclusion // "-") \(.html_url)"'

  pending=$(echo "$matches" | jq '[.[] | select(.status != "completed")] | length')
  if [ "$pending" -eq 0 ]; then
    echo "All runs completed."
    fail=$(echo "$matches" | jq '[.[] | select(.conclusion != "success")] | length')
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
