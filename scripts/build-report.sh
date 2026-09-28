#!/usr/bin/env bash
#
# build-report.sh — merge every job's logs into one run report.
#
#   build-report.sh <collected_dir> <report_dir>
#
# <collected_dir> holds the downloaded logs-* artifacts (one sub-directory per job). Writes to <report_dir>:
# the flattened logs, status.tsv (every stage, in order), summary.md (human) and summary.json (the stable
# contract for any future notifier: email / shared drive / Slack read this file, never the workflow).
#
# Env (set by the workflow): RUN_ID RUN_ATTEMPT RUN_URL TRIGGER ACTOR
#   RESULT_BOOT RESULT_PLATFORM RESULT_SITE RESULT_BRINGUP RESULT_POWEROFF   (needs.<job>.result)
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/stages.sh
. "$ROOT/config/stages.sh"
IN="$1"; OUT="$2"; mkdir -p "$OUT"

# boot metadata (absent if the run died before boot uploaded anything)
declare -A M=()
if [ -f "$IN/logs-boot/meta.env" ]; then
  while IFS='=' read -r k v; do [ -n "$k" ] && M[$k]="$v"; done < "$IN/logs-boot/meta.env"
fi

# flatten logs + merge status rows
shopt -s nullglob
for d in "$IN"/logs-*/; do
  job="$(basename "$d")"; job="${job#logs-}"
  for f in "$d"*.log; do cp "$f" "$OUT/"; done
  [ -f "$d/diagnostics.txt" ] && cp "$d/diagnostics.txt" "$OUT/diagnostics-$job.txt"
done
rows="$(cat "$IN"/logs-*/status.tsv 2>/dev/null || true)"

# every catalogue stage gets a row. run-stages.sh creates a stage's log file the moment it starts the
# stage, before it can write a status.tsv row — so a missing row WITH a log file means the job died
# mid-stage (cancelled / timed out / crashed): "interrupted", not "skipped". A missing row with no log
# file at all means the stage was never reached — that one really is "skipped".
: > "$OUT/status.tsv"
idx=0
for e in "${LAUNCHPAD_STAGES[@]}"; do
  idx=$((idx+1)); IFS=: read -r name ph _ <<< "$e"
  row="$(awk -F'\t' -v n="$name" '$2==n' <<< "$rows" | tail -n1)"
  if [ -z "$row" ]; then
    label=skipped
    [ -f "$OUT/$(printf '%02d' "$idx")-$name.log" ] && label=interrupted
    row="$(printf '%s\t%s\t%s\t%s\t\t\t\t' "$idx" "$name" "$ph" "$label")"
  fi
  printf '%s\n' "$row" >> "$OUT/status.tsv"
done

failed_stage="$(awk -F'\t' '$4!="passed" && $4!="skipped" && $4!="not-selected"{print $2; exit}' "$OUT/status.tsv")"
jobs="${RESULT_BOOT:-} ${RESULT_PLATFORM:-} ${RESULT_SITE:-} ${RESULT_BRINGUP:-}"
if   [ -n "$failed_stage" ] || [[ " $jobs " == *" failure "* ]]; then status=FAILED
elif [[ " $jobs " == *" cancelled "* ]]; then status=CANCELLED
else status=PASSED; fi
[ -z "$failed_stage" ] && [ "${RESULT_BOOT:-}" != success ] && [ "$status" != PASSED ] && failed_stage="boot (OCI start / SSH / clone)"

sha="${M[POC_SHA]:-}"; started="${M[STARTED_AT]:-}"; finished="$(date -u +%FT%TZ)"
jq -n \
  --arg status "$status" --arg failed_stage "$failed_stage" \
  --arg repo "${M[POC_REPO]:-}" --arg branch "${M[POC_BRANCH]:-}" --arg sha "${M[POC_SHA]:-}" \
  --arg run_id "${RUN_ID:-}" --arg attempt "${RUN_ATTEMPT:-}" --arg run_url "${RUN_URL:-}" \
  --arg trigger "${TRIGGER:-}" --arg actor "${ACTOR:-}" \
  --arg started "$started" --arg finished "$finished" \
  --arg host "${M[HOST]:-}" --arg instance "${OCI_INSTANCE_ID:-}" --arg was_running "${M[WAS_RUNNING]:-}" \
  --arg poweroff "${RESULT_POWEROFF:-}" --arg blueprint_source "${M[BLUEPRINT_SOURCE]:-}" --arg tenants "${M[TENANTS]:-}" \
  --rawfile tsv "$OUT/status.tsv" '
  { status:$status, failed_stage:($failed_stage|select(.!="") // null),
    poc:{repo:$repo, branch:$branch, sha:$sha},
    run:{id:$run_id, attempt:$attempt, url:$run_url, trigger:$trigger, actor:$actor, started:$started, finished:$finished},
    oci:{instance:$instance, host:$host, was_running_before:$was_running, poweroff_job:$poweroff},
    options:{blueprint_source:$blueprint_source, tenants:$tenants},
    stages:[ $tsv | split("\n")[] | select(length>0) | split("\t")
             | {index:(.[0]|tonumber), name:.[1], phase:.[2], result:.[3], rc:.[4], started:.[5], finished:.[6],
                seconds:(if .[7]=="" then null else (.[7]|tonumber) end)} ] }' > "$OUT/summary.json"

icon(){ case "$1" in passed) echo "✅";; skipped|not-selected) echo "⏭️";; *) echo "❌";; esac; }
{
  echo "## NVCM e2e — $( [ "$status" = PASSED ] && echo "✅" || echo "❌") $status"
  echo
  echo "| | |"; echo "|---|---|"
  echo "| Branch | \`${M[POC_BRANCH]:-?}\` @ \`${sha:0:12}\` |"
  echo "| Failed stage | ${failed_stage:-—} |"
  echo "| Run | [${RUN_ID:-}#${RUN_ATTEMPT:-}](${RUN_URL:-}) · ${TRIGGER:-} by ${ACTOR:-} |"
  echo "| Started / finished (UTC) | ${started:-?} → $finished |"
  echo "| OCI | \`${OCI_INSTANCE_ID:-?}\` @ ${M[HOST]:-?} · already running before: ${M[WAS_RUNNING]:-?} · power-off job: ${RESULT_POWEROFF:-?} |"
  echo
  echo "| # | Stage | Phase | Result | rc | Duration |"; echo "|---|---|---|---|---|---|"
  while IFS=$'\t' read -r i n p r rc _ _ s; do
    d=""; [ -n "$s" ] && d="$((s/60))m $((s%60))s"
    echo "| $i | $n | $p | $(icon "$r") $r | $rc | $d |"
  done < "$OUT/status.tsv"
} > "$OUT/summary.md"

echo "status=$status" >> "${GITHUB_OUTPUT:-/dev/null}"
cat "$OUT/summary.md"
