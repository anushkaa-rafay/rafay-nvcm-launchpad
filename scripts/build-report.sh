#!/usr/bin/env bash
#
# build-report.sh — merge every job's logs into one run report.
#
#   build-report.sh <collected_dir> <report_dir>
#
# <collected_dir> holds the downloaded logs-* artifacts (one sub-directory per job). Writes to <report_dir>:
# workflow.log (every stage's output, in catalogue order, one section per stage — see scripts/lib-log.sh),
# boot.log, diagnostics-<job>.txt, status.tsv (every stage, in order), summary.md (human) and summary.json
# (the stable contract for any future notifier: email / shared drive / Slack read this file, never the workflow).
#
# Env (set by the workflow): RUN_ID RUN_ATTEMPT RUN_URL TRIGGER ACTOR
#   RESULT_BOOT RESULT_PLATFORM RESULT_SITE RESULT_BRINGUP RESULT_POWEROFF   (needs.<job>.result)
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LAUNCHPAD_CATALOGUE:?LAUNCHPAD_CATALOGUE not set (e.g. config/stages-greenfield.sh) — set by the workflow}"
# shellcheck source=/dev/null
. "$ROOT/$LAUNCHPAD_CATALOGUE"
# shellcheck source=scripts/lib-log.sh
. "$ROOT/scripts/lib-log.sh"
IN="$1"; OUT="$2"; mkdir -p "$OUT"   # deliberately reassigned after sourcing: the catalogue may export its own OUT (brownfield's host-side discovery dir) — this OUT is this script's own report dir, on the runner, unrelated

# boot metadata (absent if the run died before boot uploaded anything)
declare -A M=()
if [ -f "$IN/logs-boot/meta.env" ]; then
  while IFS='=' read -r k v; do [ -n "$k" ] && M[$k]="$v"; done < "$IN/logs-boot/meta.env"
fi

# boot.log + per-job diagnostics as-is (each phase's workflow.log is stitched below) + merge status rows
shopt -s nullglob
for d in "$IN"/logs-*/; do
  job="$(basename "$d")"; job="${job#logs-}"
  [ -f "$d/boot.log" ] && cp "$d/boot.log" "$OUT/"
  [ -f "$d/diagnostics.txt" ] && cp "$d/diagnostics.txt" "$OUT/diagnostics-$job.txt"
done
rows="$(cat "$IN"/logs-*/status.tsv 2>/dev/null || true)"

# true iff the phase job wrote this stage's header into its workflow.log: stage_started <idx> <name> <phase>
stage_started(){ grep -qFx "$(lp_stage_title "$1" "$2" "$3")" "$IN/logs-$3/workflow.log" 2>/dev/null; }

# every catalogue stage gets a row. run-stages.sh writes a stage's header into its phase's workflow.log the
# moment it starts the stage, before it can write a status.tsv row — so a missing row WITH a header means
# the job died mid-stage (cancelled / timed out / crashed): "interrupted", not "skipped". A missing row with
# no header at all means the stage was never reached — that one really is "skipped".
: > "$OUT/status.tsv"
idx=0
for e in "${LAUNCHPAD_STAGES[@]}"; do
  idx=$((idx+1)); IFS=: read -r name ph _ <<< "$e"
  row="$(awk -F'\t' -v n="$name" '$2==n' <<< "$rows" | tail -n1)"
  if [ -z "$row" ]; then
    label=skipped
    stage_started "$idx" "$name" "$ph" && label=interrupted
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

# workflow.log: each phase job's workflow.log, in phase order, already holds its stages' sections in run
# order. Close what a job could not write itself: the stage it died inside gets its footer, and every stage
# it never reached (or every stage of a phase that never ran) gets a stub section.
{
  echo "$LP_RULE_STAGE"
  echo "WORKFLOW RUN ${RUN_ID:-?}.${RUN_ATTEMPT:-?} · ${LAUNCHPAD_CATALOGUE} · ${M[POC_BRANCH]:-?} @ ${sha:0:12}"
  echo "Started ${started:-?} · ${RUN_URL:-}"
  echo "$LP_RULE_STAGE"
  echo
  phases=" "
  while IFS=$'\t' read -r i n p r _; do
    if [[ "$phases" != *" $p "* ]]; then
      phases+="$p "
      [ -f "$IN/logs-$p/workflow.log" ] && cat "$IN/logs-$p/workflow.log"
    fi
    if [ "$r" = interrupted ]; then
      echo; lp_line ERROR "Stage $n did not finish: its job ended (cancelled / timed out / crashed) before recording a result"
      lp_stage_footer "$r"
    elif ! stage_started "$i" "$n" "$p"; then
      lp_stage_stub "$i" "$n" "$p" "$r"
    fi
  done < "$OUT/status.tsv"
  echo "$LP_RULE_STAGE"
  echo "WORKFLOW STATUS: $status${failed_stage:+ (failed stage: $failed_stage)}"
  echo "$LP_RULE_STAGE"
} > "$OUT/workflow.log"

echo "status=$status" >> "${GITHUB_OUTPUT:-/dev/null}"
cat "$OUT/summary.md"
