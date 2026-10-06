#!/usr/bin/env bash
#
# lab.sh — runner-side control of the EXISTING OCI lab instance: power via OCI CLI, access via SSH.
#
#   lab.sh state          # print the instance lifecycle state
#   lab.sh start          # start (no-op if RUNNING) and wait for RUNNING
#   lab.sh stop           # SOFTSTOP and wait for STOPPED (hard STOP if the soft stop does not complete)
#   lab.sh connect        # resolve the SSH address, write the `lab` ssh alias, wait for SSH + boot to settle
#   lab.sh push-agent     # copy remote/agent.sh + config/common.sh + $LAUNCHPAD_CATALOGUE to ~/launchpad
#                           on the host (the catalogue lands there as ~/launchpad/stages.sh, whichever mode it is)
#   lab.sh ssh [-A] CMD   # run CMD on the host (-A forwards the agent: used only for the git clone)
#
# Env: OCI_INSTANCE_ID (required), OCI_SSH_USER (default ubuntu), OCI_SSH_HOST (optional: fixed address or
# reserved IP; otherwise the primary VNIC's public IP is looked up each run — ephemeral IPs change on restart),
# OCI_SSH_KNOWN_HOSTS (optional: pins the host key; otherwise accept-new, logged as a warning).
# LAUNCHPAD_CATALOGUE (required by push-agent): config/stages-greenfield.sh or config/stages-brownfield.sh.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${OCI_INSTANCE_ID:?OCI_INSTANCE_ID is not set (repository variable)}"
WAIT_SECS="${LAB_WAIT_SECS:-900}"
log(){ echo "[lab] $*" >&2; }
out(){ [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

state(){ oci compute instance get --instance-id "$OCI_INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output; }
wait_state(){ oci compute instance get --instance-id "$OCI_INSTANCE_ID" --wait-for-state "$1" --max-wait-seconds "$WAIT_SECS" >/dev/null; }
action(){ oci compute instance action --instance-id "$OCI_INSTANCE_ID" --action "$1" \
            --wait-for-state "$2" --max-wait-seconds "$WAIT_SECS" >/dev/null; }

cmd_start(){
  local s; s="$(state)"; log "instance state: $s"
  out "was_running=$([ "$s" = RUNNING ] && echo true || echo false)"
  case "$s" in
    RUNNING)                 log "already RUNNING — nothing to start" ;;
    STARTING|PROVISIONING)   wait_state RUNNING ;;
    STOPPING)                wait_state STOPPED; action START RUNNING ;;
    STOPPED)                 action START RUNNING ;;
    *) log "cannot start from state $s"; exit 1 ;;
  esac
  log "instance RUNNING"
}

cmd_stop(){
  local s; s="$(state)"; log "instance state: $s"
  case "$s" in
    STOPPED)  log "already STOPPED"; return ;;
    STOPPING) wait_state STOPPED ;;
    *) action SOFTSTOP STOPPED || { log "soft stop did not complete — forcing STOP"; action STOP STOPPED; } ;;
  esac
  log "instance STOPPED"
}

cmd_connect(){
  local host="${OCI_SSH_HOST:-}"
  if [ -z "$host" ]; then
    # Explicit exit-status check, not just "is the result non-empty": the OCI CLI writes some of its own
    # error output (e.g. "the config file is invalid") to STDOUT, not stderr, on a misconfigured
    # OCI_CLI_USER/TENANCY/FINGERPRINT/REGION/KEY_CONTENT — that text is non-empty and isn't literally
    # "null", so a bare presence check lets it silently become $host, corrupt the ssh config below with an
    # embedded multi-line value, and surface as a baffling "Could not resolve hostname lab" instead of the
    # real cause. Also reject anything containing whitespace: a real public IP never does.
    host="$(oci compute instance list-vnics --instance-id "$OCI_INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)" \
      || { log "OCI CLI call failed (see its output above) — check OCI_CLI_USER/TENANCY/FINGERPRINT/REGION/KEY_CONTENT"; exit 1; }
    [ -n "$host" ] && [ "$host" != null ] || { log "instance has no public IP — set OCI_SSH_HOST"; exit 1; }
    case "$host" in *[[:space:]]*) log "unexpected value for the instance's public IP: '$host' (likely an OCI CLI error, not an address)"; exit 1;; esac
  fi
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  local strict=accept-new
  if [ -n "${OCI_SSH_KNOWN_HOSTS:-}" ]; then
    # Rewritten keyed to the alias "lab", NOT the literal address ssh-keyscan was run against: OCI's
    # ephemeral public IP can change on restart (that's exactly why OCI_SSH_HOST is normally left unset,
    # below), so pinning to that IP literal would silently stop matching the next time it changes — this
    # host would then fail StrictHostKeyChecking on every run until someone re-ran ssh-keyscan by hand.
    # HostKeyAlias (below) makes ssh look the key up under "lab" regardless of what IP it resolves to
    # today. Comment/blank lines from a pasted-as-is `ssh-keyscan` transcript are dropped automatically.
    awk 'NF && $1 !~ /^#/ { $1="lab"; print }' <<< "$OCI_SSH_KNOWN_HOSTS" >> ~/.ssh/known_hosts
    strict=yes
  else echo "::warning::OCI_SSH_KNOWN_HOSTS not set — trusting the lab host key on first use"; fi
  cat > ~/.ssh/config <<EOF
Host lab
  HostName $host
  HostKeyAlias lab
  User ${OCI_SSH_USER:-ubuntu}
  BatchMode yes
  StrictHostKeyChecking $strict
  ConnectTimeout 15
  ServerAliveInterval 30
  ServerAliveCountMax 6
EOF
  log "lab = ${OCI_SSH_USER:-ubuntu}@$host; waiting for SSH"
  local deadline=$((SECONDS + WAIT_SECS))
  until ssh lab true 2>/dev/null; do
    [ $SECONDS -lt $deadline ] || { log "SSH did not come up within ${WAIT_SECS}s"; exit 1; }
    sleep 10
  done
  # SSH up is not "operational": let cloud-init and systemd finish booting (degraded is reported, not fatal).
  ssh lab "timeout $WAIT_SECS cloud-init status --wait >/dev/null 2>&1; timeout $WAIT_SECS systemctl is-system-running --wait" \
    | sed 's/^/[lab] systemd: /' >&2 || true
  out "host=$host"
}

cmd_push_agent(){
  : "${LAUNCHPAD_CATALOGUE:?LAUNCHPAD_CATALOGUE not set (e.g. config/stages-greenfield.sh) — set by the workflow}"
  ssh lab 'mkdir -p ~/launchpad'
  scp -q "$ROOT/remote/agent.sh" "$ROOT/config/common.sh" lab:launchpad/
  scp -q "$ROOT/$LAUNCHPAD_CATALOGUE" lab:launchpad/stages.sh   # renamed on the host: agent.sh always sources ~/launchpad/stages.sh
  ssh lab 'chmod +x ~/launchpad/agent.sh'
}

sub="${1:-}"; shift || true
case "$sub" in
  state) state ;; start) cmd_start ;; stop) cmd_stop ;;
  connect) cmd_connect ;; push-agent) cmd_push_agent ;;
  ssh) if [ "${1:-}" = -A ]; then shift; ssh -A lab "$@"; else ssh lab "$@"; fi ;;
  *) awk 'NR>2{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit 2 ;;
esac
