#!/usr/bin/env bash
#
# run-stages.sh — drive one PHASE of stages on the lab host, from the GitHub runner.
#
#   run-stages.sh validate <selection>                     # fail on an unknown stage name
#   run-stages.sh plan     <phase> <selection>             # print the stages this phase would run
#   run-stages.sh run      <phase> <run_key> <selection> <out_dir>
#
# <selection> is "all" or a comma list of stage names, from the catalogue named by $LAUNCHPAD_CATALOGUE (one
# of config/stages-greenfield.sh / config/stages-brownfield.sh — set as a job env by the calling workflow).
# For each selected stage: start it detached on the host (remote/agent.sh), stream its log into the job
# output and <out_dir>/workflow.log (one section per stage, in catalogue order — format: scripts/lib-log.sh),
# poll until it exits, and record one row in <out_dir>/status.tsv. The first failure stops the phase; the
# remaining stages are recorded as skipped. Exit non-zero iff a stage failed — that is what fails the workflow.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LAUNCHPAD_CATALOGUE:?LAUNCHPAD_CATALOGUE not set (e.g. config/stages-greenfield.sh) — set by the workflow}"
# shellcheck source=/dev/null
. "$ROOT/$LAUNCHPAD_CATALOGUE"
# shellcheck source=scripts/lib-log.sh
. "$ROOT/scripts/lib-log.sh"
POLL="${LAB_POLL_SECS:-20}"
MAX_SSH_FAILS="${LAB_MAX_SSH_FAILS:-30}"     # consecutive failed polls before declaring the host lost (~10 min)
log(){ echo "[stages] $*" >&2; }

selected(){ [ "$1" = all ] || [[ ",$1," == *",$2,"* ]]; }

cmd_validate(){
  [ "$1" = all ] && return 0
  local want known=" " e
  for e in "${LAUNCHPAD_STAGES[@]}"; do known+="${e%%:*} "; done
  IFS=, read -ra want <<< "$1"
  for e in "${want[@]}"; do
    [[ "$known" == *" $e "* ]] || { log "unknown stage '$e' (known:$known)"; exit 2; }
  done
}

cmd_plan(){
  local phase="$1" sel="$2" e name ph
  for e in "${LAUNCHPAD_STAGES[@]}"; do
    IFS=: read -r name ph _ <<< "$e"
    [ "$ph" = "$phase" ] && selected "$sel" "$name" && echo "$name"
  done
  return 0
}

# append the bytes of the remote stage log we have not seen yet to workflow.log + the job output.
# Uses cmd_run's $wlog, and its $seen (bytes of THIS stage's remote log already pulled) — the local file
# holds every stage, so its size is no longer the offset.
pull_log(){
  local rlog="$1" tmp
  tmp="$(mktemp)"
  if ssh lab "tail -c +$((seen+1)) $rlog 2>/dev/null" > "$tmp"; then
    seen=$((seen + $(stat -c %s "$tmp")))
    cat "$tmp" >> "$wlog"; cat "$tmp"; rm -f "$tmp"
  else rm -f "$tmp"; return 1; fi
}

cmd_run(){
  local phase="$1" key="$2" sel="$3" out="$4"
  local wlog="$out/workflow.log"
  mkdir -p "$out"; : > "$out/status.tsv"; : > "$wlog"
  local idx=0 e name ph mins failed=""
  for e in "${LAUNCHPAD_STAGES[@]}"; do
    idx=$((idx+1)); IFS=: read -r name ph mins <<< "$e"
    [ "$ph" = "$phase" ] || continue
    if ! selected "$sel" "$name"; then
      lp_stage_stub "$idx" "$name" "$phase" not-selected >> "$wlog"
      printf '%s\t%s\t%s\tnot-selected\t\t\t\t\n' "$idx" "$name" "$phase" >> "$out/status.tsv"; continue
    fi
    if [ -n "$failed" ]; then
      lp_stage_stub "$idx" "$name" "$phase" skipped >> "$wlog"
      printf '%s\t%s\t%s\tskipped\t\t\t\t\n' "$idx" "$name" "$phase" >> "$out/status.tsv"; continue
    fi

    local t0 rc="" result fails=0 st seen=0 start
    t0="$(date -u +%FT%TZ)"
    { lp_stage_header "$idx" "$name" "$phase"; lp_line INFO "Starting stage $name (timeout ${mins}m, run key $key)"; } >> "$wlog"
    start=$(stat -c %s "$wlog")    # where this stage's own output begins — for the ::error:: excerpt below
    echo "::group::stage $name (timeout ${mins}m)"
    ssh lab "launchpad/agent.sh start $key $name $mins" 2>&1 | tee -a "$wlog" || rc=not-started
    local deadline=$((SECONDS + mins*60 + 600))    # agent's timeout fires first; this only catches a wedged host
    while [ -z "$rc" ]; do
      sleep "$POLL"
      if pull_log "launchpad/runs/$key/$name.log" && st="$(ssh lab "launchpad/agent.sh status $key $name")"; then
        fails=0
        case "$st" in done\ *) rc="${st#done }"; pull_log "launchpad/runs/$key/$name.log" || true; break ;; esac
      else
        fails=$((fails+1)); log "poll failed ($fails/$MAX_SSH_FAILS)"
        [ "$fails" -lt "$MAX_SSH_FAILS" ] || { rc=lost; break; }
      fi
      [ $SECONDS -lt $deadline ] || { rc=lost; log "no exit status past the stage timeout"; break; }
    done
    echo "::endgroup::"

    case "$rc" in
      0)        result=passed ;;
      124|137)  result=timed-out ;;
      lost)     result=lost-contact ;;
      *)        result=failed ;;
    esac
    local t1 secs; t1="$(date -u +%FT%TZ)"; secs=$(( $(date -d "$t1" +%s) - $(date -d "$t0" +%s) ))
    if [ "$result" = passed ]; then log "stage $name passed"
    else
      failed="$name"
      echo "::error title=Stage $name $result::rc=$rc — last lines:%0A$(tail -c +$((start+1)) "$wlog" | tail -n 15 | sed 's/%/%25/g' | awk '{printf "%s%%0A",$0}')"
    fi
    {
      [ -z "$(tail -c 1 "$wlog")" ] || echo     # the stage's last line may lack a newline
      if [ "$result" = passed ]; then lp_line INFO "Stage $name passed (rc=0, ${secs}s)"
      else lp_line ERROR "Stage $name $result (rc=$rc, ${secs}s)"; fi
      lp_stage_footer "$result"
    } >> "$wlog"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$name" "$phase" "$result" "$rc" "$t0" "$t1" "$secs" >> "$out/status.tsv"
  done

  if [ -n "$failed" ]; then
    ssh lab "launchpad/agent.sh diag $key" > "$out/diagnostics.txt" 2>&1 || true
    exit 1
  fi
}

sub="${1:-}"; shift || true
case "$sub" in
  validate) cmd_validate "$@" ;;
  plan)     cmd_plan "$@" ;;
  run)      cmd_run "$@" ;;
  *) awk 'NR>2{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit 2 ;;
esac
