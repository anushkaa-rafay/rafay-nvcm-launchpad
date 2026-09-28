#!/usr/bin/env bash
#
# run-stages.sh — drive one PHASE of stages on the lab host, from the GitHub runner.
#
#   run-stages.sh validate <selection>                     # fail on an unknown stage name
#   run-stages.sh plan     <phase> <selection>             # print the stages this phase would run
#   run-stages.sh run      <phase> <run_key> <selection> <out_dir>
#
# <selection> is "all" or a comma list of stage names (config/stages.sh). For each selected stage: start it
# detached on the host (remote/agent.sh), stream its log into the job output and <out_dir>, poll until it
# exits, and record one row in <out_dir>/status.tsv. The first failure stops the phase; the remaining
# stages are recorded as skipped. Exit non-zero iff a stage failed — that is what fails the workflow.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/stages.sh
. "$ROOT/config/stages.sh"
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

# append the bytes of the remote log we have not seen yet to the local copy + the job output
pull_log(){
  local rlog="$1" llog="$2" off tmp
  off=$(stat -c %s "$llog" 2>/dev/null || echo 0)
  tmp="$(mktemp)"
  if ssh lab "tail -c +$((off+1)) $rlog 2>/dev/null" > "$tmp"; then
    cat "$tmp" >> "$llog"; cat "$tmp"; rm -f "$tmp"
  else rm -f "$tmp"; return 1; fi
}

cmd_run(){
  local phase="$1" key="$2" sel="$3" out="$4"
  mkdir -p "$out"; : > "$out/status.tsv"
  local idx=0 e name ph mins failed=""
  for e in "${LAUNCHPAD_STAGES[@]}"; do
    idx=$((idx+1)); IFS=: read -r name ph mins <<< "$e"
    [ "$ph" = "$phase" ] || continue
    local llog; llog="$out/$(printf '%02d' "$idx")-$name.log"
    if ! selected "$sel" "$name"; then
      printf '%s\t%s\t%s\tnot-selected\t\t\t\t\n' "$idx" "$name" "$phase" >> "$out/status.tsv"; continue
    fi
    if [ -n "$failed" ]; then
      printf '%s\t%s\t%s\tskipped\t\t\t\t\n' "$idx" "$name" "$phase" >> "$out/status.tsv"; continue
    fi

    local t0 rc="" result fails=0 st
    t0="$(date -u +%FT%TZ)"; : > "$llog"
    echo "::group::stage $name (timeout ${mins}m)"
    ssh lab "launchpad/agent.sh start $key $name $mins" || rc=not-started
    local deadline=$((SECONDS + mins*60 + 600))    # agent's timeout fires first; this only catches a wedged host
    while [ -z "$rc" ]; do
      sleep "$POLL"
      if pull_log "launchpad/runs/$key/$name.log" "$llog" && st="$(ssh lab "launchpad/agent.sh status $key $name")"; then
        fails=0
        case "$st" in done\ *) rc="${st#done }"; pull_log "launchpad/runs/$key/$name.log" "$llog" || true; break ;; esac
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
    local t1; t1="$(date -u +%FT%TZ)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$name" "$phase" "$result" "$rc" "$t0" "$t1" \
        "$(( $(date -d "$t1" +%s) - $(date -d "$t0" +%s) ))" >> "$out/status.tsv"
    if [ "$result" = passed ]; then log "stage $name passed"
    else
      failed="$name"
      echo "::error title=Stage $name $result::rc=$rc — last lines:%0A$(tail -n 15 "$llog" | sed 's/%/%25/g' | awk '{printf "%s%%0A",$0}')"
    fi
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
