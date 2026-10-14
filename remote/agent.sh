#!/usr/bin/env bash
#
# agent.sh — the launchpad's only footprint ON the OCI host (copied to ~/launchpad/ each run). Orchestration
# only: prepares a run workspace, clones the requested rafay_nvcm_poc branch, and runs ONE stage at a time
# DETACHED from SSH — so a dropped connection, or the hand-off between workflow jobs, never kills a long
# install. The runner polls `status` and streams the log.
#
#   agent.sh preflight                                        # sudo -n works, no stage already running
#   agent.sh clean                                            # GREENFIELD ONLY: delete the kind cluster + every libvirt VM
#   agent.sh prepare <run_key> <owner/repo> <branch> [K=V..]  # workspace + update/clone the checkout (needs ssh -A)
#   agent.sh start   <run_key> <stage> <timeout_minutes>      # launch detached; returns immediately
#   agent.sh status  <run_key> <stage>                        # running | done <rc> | absent
#   agent.sh diag    <run_key>                                # read-only host snapshot for a failed run
#
# CHECKOUT POLICY: an existing ~/rafay_nvcm_poc that is a clone of the SAME repo is updated IN PLACE ("git
# pull"): fetch <branch> and check it out at exactly origin/<branch>, so the run always tests the latest commit.
# Tracked local edits are saved to the run dir as local-changes.patch first; untracked + gitignored files
# (params-secrets.env, .venv, …) are left alone. Anything else at that path (not a git repo, another repo) is
# MOVED to ~/launchpad/previous-clones/ (newest $KEEP_CLONES kept) and freshly cloned, carrying PRESERVE_FILES.
#
# INSTALLED STATE: `clean` (greenfield only — brownfield must never run it: it adopts the fabric that is
# running) deletes the kind cluster ($KIND_CLUSTER) and undefines EVERY libvirt domain on the host with its
# storage, so the run installs the platform and builds the substrate from nothing.
#
set -uo pipefail
LP="$HOME/launchpad"
RUNS="$LP/runs"
POC_DIR="$HOME/rafay_nvcm_poc"           # the platform scripts default --repo to exactly this path
KIND_CLUSTER="${KIND_CLUSTER:-nv-config-manager}"   # rafay_nvcm_poc deploy_scripts/_nvcm-common.sh default
VIRSH=(sudo -n virsh -c qemu:///system)
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

cmd_clean(){
  cmd_preflight
  # ssh runs a non-login shell: make sure kind (often ~/.local/bin or /usr/local/bin) is on PATH
  PATH="$PATH:$HOME/.local/bin:/usr/local/bin"
  if command -v kind >/dev/null; then
    log "deleting kind cluster '$KIND_CLUSTER'"
    kind delete cluster --name "$KIND_CLUSTER" 2>&1 \
      || sudo -n env "PATH=$PATH" kind delete cluster --name "$KIND_CLUSTER" 2>&1 \
      || die "kind delete cluster --name $KIND_CLUSTER failed"
  else
    log "kind not installed — no cluster to delete (fresh host?)"
  fi

  if command -v virsh >/dev/null; then
    local vm failed=0 n=0
    while IFS= read -r vm; do
      [ -n "$vm" ] || continue
      n=$((n+1))
      # a running domain must be stopped first: undefine on a live VM only makes it transient (it keeps running)
      [ "$("${VIRSH[@]}" domstate "$vm" 2>/dev/null)" = "shut off" ] || "${VIRSH[@]}" destroy "$vm" >/dev/null 2>&1 || true
      if "${VIRSH[@]}" undefine "$vm" --remove-all-storage >/dev/null 2>&1 \
         || "${VIRSH[@]}" undefine "$vm" --remove-all-storage --nvram --snapshots-metadata >/dev/null 2>&1; then
        log "deleted VM $vm (+ storage)"
      else
        echo "[agent] could not undefine VM $vm" >&2; failed=$((failed+1))
      fi
    done < <("${VIRSH[@]}" list --all --name)
    [ "$failed" -eq 0 ] || die "$failed of $n VM(s) could not be deleted (see above)"
    log "deleted $n VM(s)"
  else
    log "virsh not installed — no VMs to delete (fresh host?)"
  fi
}

# owner/repo of a git remote URL (git@github.com:o/r.git | https://github.com/o/r[.git] | ssh://git@github.com/o/r)
repo_of(){ sed -E 's#^.*github\.com[:/]+##; s#/+$##; s#\.git$##' <<< "$1"; }

cmd_prepare(){
  local key="$1" repo="$2" branch="$3"; shift 3
  local run="$RUNS/$key" ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  cmd_preflight
  mkdir -p "$run" "$LP/previous-clones"

  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  local url="git@github.com:${repo}.git" old=""
  if [ -d "$POC_DIR/.git" ] && [ "$(repo_of "$(git -C "$POC_DIR" config --get remote.origin.url 2>/dev/null)")" = "$repo" ]; then
    # existing clone of the same repo → pull the latest <branch> in place. Fetch by explicit URL + refspec: the
    # host's origin may be https (no creds here) or a --single-branch clone of a different branch.
    log "updating existing checkout in place: $(git -C "$POC_DIR" rev-parse --abbrev-ref HEAD)@$(git -C "$POC_DIR" rev-parse --short HEAD)"
    git -C "$POC_DIR" fetch --quiet "$url" "+refs/heads/${branch}:refs/remotes/origin/${branch}" \
      || die "fetch of ${repo}@${branch} failed (deploy key forwarded? branch exists?)"
    if ! git -C "$POC_DIR" diff --quiet HEAD --; then
      git -C "$POC_DIR" diff HEAD > "$run/local-changes.patch"
      echo "[agent] WARNING: tracked local edits in $POC_DIR discarded — saved to $run/local-changes.patch" >&2
    fi
    git -C "$POC_DIR" checkout --quiet -f -B "$branch" "refs/remotes/origin/${branch}" \
      || die "checkout of origin/${branch} failed"
    git -C "$POC_DIR" branch --quiet --set-upstream-to="origin/${branch}" "$branch" 2>/dev/null || true
  else
    if [ -e "$POC_DIR" ]; then
      old="$LP/previous-clones/rafay_nvcm_poc.$ts"
      mv "$POC_DIR" "$old" && log "not a clone of $repo — moved it aside -> $old"
    fi
    git clone --quiet --branch "$branch" --single-branch "$url" "$POC_DIR" \
      || die "clone of ${repo}@${branch} failed (deploy key forwarded? branch exists?)"
    local f
    for f in "${PRESERVE_FILES[@]}"; do
      [ -n "$old" ] && [ -f "$old/$f" ] || continue
      mkdir -p "$(dirname "$POC_DIR/$f")" && cp -p "$old/$f" "$POC_DIR/$f" && log "carried forward $f"
    done
  fi

  {
    printf 'RUN_KEY=%q\nRUN_DIR=%q\nPOC_DIR=%q\nPOC_REPO=%q\nPOC_BRANCH=%q\n' "$key" "$run" "$POC_DIR" "$repo" "$branch"
    printf 'POC_SHA=%q\n' "$(git -C "$POC_DIR" rev-parse HEAD)"
    printf 'LAB_IP=%q\n' "${LAB_IP:-$(hostname -I | awk '{print $1}')}"
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
lp_run_stage stage_${stage//-/_}
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
  clean)     cmd_clean ;;
  prepare)   [ $# -ge 3 ] || die "usage: prepare <run_key> <owner/repo> <branch> [K=V..]"; cmd_prepare "$@" ;;
  start)     [ $# -eq 3 ] || die "usage: start <run_key> <stage> <timeout_minutes>"; cmd_start "$@" ;;
  status)    [ $# -eq 2 ] || die "usage: status <run_key> <stage>"; cmd_status "$@" ;;
  diag)      cmd_diag ;;
  *) awk 'NR>2{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit 2 ;;
esac
