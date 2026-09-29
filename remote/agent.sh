#!/usr/bin/env bash
#
# agent.sh — the launchpad's only footprint ON the OCI host (copied to ~/launchpad/ each run). Orchestration
# only: prepares a run workspace, clones the requested rafay_nvcm_poc branch, and runs ONE stage at a time
# DETACHED from SSH — so a dropped connection, or the hand-off between workflow jobs, never kills a long
# install. The runner polls `status` and streams the log.
#
#   agent.sh preflight                                        # sudo -n works, no stage already running
#   agent.sh prepare <run_key> <owner/repo> <branch> [K=V..]  # workspace + fresh clone (needs ssh -A)
#   agent.sh start   <run_key> <stage> <timeout_minutes>      # launch detached; returns immediately
#   agent.sh status  <run_key> <stage>                        # running | done <rc> | absent
#   agent.sh diag    <run_key>                                # read-only host snapshot for a failed run
#
# CLEANUP POLICY (deliberately non-destructive): an existing ~/rafay_nvcm_poc is MOVED to
# ~/launchpad/previous-clones/ (newest $KEEP_CLONES kept), never deleted in place, and the operator's
# gitignored files in PRESERVE_FILES are carried into the fresh clone. Installed state (kind cluster, NVCM,
# VMs) is NOT touched — resetting that is a rafay_nvcm_poc decision (undeploy_site.sh), not ours.
#
set -uo pipefail
LP="$HOME/launchpad"
RUNS="$LP/runs"
POC_DIR="$HOME/rafay_nvcm_poc"           # the platform scripts default --repo to exactly this path
KEEP_CLONES=5
KEEP_RUNS=14
PRESERVE_FILES=(deploy_scripts/params-secrets.env)

die(){ echo "[agent] ERROR: $*" >&2; exit 1; }
log(){ echo "[agent] $*"; }

running_stage(){   # prints "<run>/<stage>" of any live stage, else nothing
  local p
  for p in "$RUNS"/*/*.pid; do
    [ -f "$p" ] || continue
    [ -f "${p%.pid}.rc" ] && continue
    kill -0 "$(cat "$p")" 2>/dev/null && { echo "${p#"$RUNS"/}"; return; }
  done
}

cmd_preflight(){
  sudo -n true 2>/dev/null || die "passwordless sudo is required for $(id -un) (host prep and substrate use sudo)"
  local r; r="$(running_stage)"
  [ -z "$r" ] || die "a stage is still running from an earlier run: ${r%.pid} — wait for it or stop it by hand"
  log "preflight ok: $(hostname) · $(. /etc/os-release && echo "$PRETTY_NAME") · $(nproc) cpu · $(free -g | awk '/Mem/{print $2}') GiB · $(df -h "$HOME" | awk 'NR==2{print $4}') free"
}

cmd_prepare(){
  local key="$1" repo="$2" branch="$3"; shift 3
  local run="$RUNS/$key" ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  cmd_preflight
  mkdir -p "$run" "$LP/previous-clones"

  local old=""
  if [ -e "$POC_DIR" ]; then
    old="$LP/previous-clones/rafay_nvcm_poc.$ts"
    mv "$POC_DIR" "$old" && log "moved previous checkout aside -> $old"
  fi

  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
    git clone --quiet --branch "$branch" --single-branch "git@github.com:${repo}.git" "$POC_DIR" \
    || die "clone of ${repo}@${branch} failed (deploy key forwarded? branch exists?)"

  local f
  for f in "${PRESERVE_FILES[@]}"; do
    [ -n "$old" ] && [ -f "$old/$f" ] || continue
    mkdir -p "$(dirname "$POC_DIR/$f")" && cp -p "$old/$f" "$POC_DIR/$f" && log "carried forward $f"
  done

  {
    printf 'RUN_KEY=%q\nRUN_DIR=%q\nPOC_DIR=%q\nPOC_REPO=%q\nPOC_BRANCH=%q\n' "$key" "$run" "$POC_DIR" "$repo" "$branch"
    printf 'POC_SHA=%q\n' "$(git -C "$POC_DIR" rev-parse HEAD)"
    printf 'OCI_IP=%q\n' "${LAB_OCI_IP:-$(hostname -I | awk '{print $1}')}"
    local kv; for kv in "$@"; do [ -n "${kv#*=}" ] && printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
  } > "$run/run.env"
  log "checked out ${repo}@${branch} ($(git -C "$POC_DIR" log -1 --format='%h %s'))"

  # retention: previous clones + old run dirs
  ls -1dt "$LP"/previous-clones/rafay_nvcm_poc.* 2>/dev/null | tail -n +$((KEEP_CLONES+1)) | xargs -r rm -rf
  ls -1dt "$RUNS"/*/ 2>/dev/null | tail -n +$((KEEP_RUNS+1)) | xargs -r rm -rf
  cat "$run/run.env"
}

cmd_start(){
  local key="$1" stage="$2" minutes="$3" run="$RUNS/$1"
  [ -f "$run/run.env" ] || die "run $key was never prepared on this host"
  local r; r="$(running_stage)"; [ -z "$r" ] || die "refusing to start $stage: ${r%.pid} is still running"
  rm -f "$run/$stage".{rc,pid,log}
  cat > "$run/$stage.sh" <<EOF
set -euo pipefail
set -a; . '$run/run.env'; set +a
. '$LP/stages.sh'
cd "\$POC_DIR"
echo "[launchpad] stage=$stage branch=\$POC_BRANCH sha=\$POC_SHA started=\$(date -u +%FT%TZ)"
stage_${stage//-/_}
EOF
  # bash -l: a fresh login profile (PATH ~/.local/bin, docker/libvirt groups from host prep) per stage.
  # timeout: the stage's own ceiling; --kill-after escalates if it ignores SIGTERM.
  setsid nohup bash -c 'timeout --kill-after=2m "$1" bash -l "$2" >"$3" 2>&1; echo $? >"$4"' _ \
      "${minutes}m" "$run/$stage.sh" "$run/$stage.log" "$run/$stage.rc" </dev/null >/dev/null 2>&1 &
  echo $! > "$run/$stage.pid"
  log "started $stage (pid $!, timeout ${minutes}m)"
}

cmd_status(){
  local run="$RUNS/$1" stage="$2"
  if   [ -f "$run/$stage.rc" ]; then echo "done $(cat "$run/$stage.rc")"
  elif [ -f "$run/$stage.pid" ] && kill -0 "$(cat "$run/$stage.pid")" 2>/dev/null; then echo running
  elif [ -f "$run/$stage.pid" ]; then echo "done 255"     # died without writing rc (host rebooted / killed)
  else echo absent; fi
}

cmd_diag(){
  local c
  for c in "uptime" "df -h" "free -m" "docker ps -a" "kind get clusters" \
           "kubectl get pods -A -o wide" "kubectl get events -A --sort-by=.lastTimestamp" "sudo -n virsh list --all"; do
    echo "===== \$ $c"; timeout 60 bash -lc "$c" 2>&1 | tail -n 200 || true
  done
}

sub="${1:-}"; shift || true
case "$sub" in
  preflight) cmd_preflight ;;
  prepare)   [ $# -ge 3 ] || die "usage: prepare <run_key> <owner/repo> <branch> [K=V..]"; cmd_prepare "$@" ;;
  start)     [ $# -eq 3 ] || die "usage: start <run_key> <stage> <timeout_minutes>"; cmd_start "$@" ;;
  status)    [ $# -eq 2 ] || die "usage: status <run_key> <stage>"; cmd_status "$@" ;;
  diag)      cmd_diag ;;
  *) awk 'NR>2{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit 2 ;;
esac
