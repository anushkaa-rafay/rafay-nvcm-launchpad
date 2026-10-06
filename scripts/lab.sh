#!/usr/bin/env bash
#
# lab.sh — runner-side control of the EXISTING lab instance: power via the cloud's CLI, access via SSH.
# The cloud is inferred from INSTANCE_ID: an OCID (ocid1.instance.…) is OCI, an EC2 ID (i-…) is AWS.
#
#   lab.sh state          # print the instance lifecycle state
#   lab.sh start          # start (no-op if RUNNING) and wait for RUNNING
#   lab.sh stop           # SOFTSTOP and wait for STOPPED (hard STOP if the soft stop does not complete)
#   lab.sh connect        # resolve the SSH address, write the `lab` ssh alias, wait for SSH + boot to settle
#   lab.sh push-agent     # copy remote/agent.sh + config/common.sh + $LAUNCHPAD_CATALOGUE to ~/launchpad
#                           on the host (the catalogue lands there as ~/launchpad/stages.sh, whichever mode it is)
#   lab.sh ssh [-A] CMD   # run CMD on the host (-A forwards the agent: used only for the git clone)
#
# Env (from the run's lab GitHub Environment): INSTANCE_ID (required; OCI or AWS — see above), SSH_USER
# (default ubuntu), SSH_HOST (optional: fixed address or reserved/Elastic IP; otherwise the instance's public IP
# is looked up each run — ephemeral IPs change on restart),
# SSH_KNOWN_HOSTS (optional: pins the host key; otherwise accept-new, logged as a warning).
# LAUNCHPAD_CATALOGUE (required by push-agent): config/stages-greenfield.sh or config/stages-brownfield.sh.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${INSTANCE_ID:?INSTANCE_ID is not set (a variable of the lab GitHub Environment)}"
WAIT_SECS="${LAB_WAIT_SECS:-900}"
log(){ echo "[lab] $*" >&2; }
out(){ [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

case "$INSTANCE_ID" in
  ocid1.instance.*) PROVIDER=oci ;;
  i-*)              PROVIDER=aws ;;
  *) log "INSTANCE_ID '$INSTANCE_ID' is neither an OCI instance OCID (ocid1.instance.…) nor an EC2 ID (i-…)"; exit 1 ;;
esac

# Provider primitives. Everything above them speaks OCI's state names (RUNNING, STARTING, STOPPING, STOPPED, …)
# and verbs (START, SOFTSTOP, STOP); the AWS side maps onto those, so cmd_start/cmd_stop exist once.
if [ "$PROVIDER" = oci ]; then
  state(){ oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output; }
  wait_state(){ oci compute instance get --instance-id "$INSTANCE_ID" --wait-for-state "$1" --max-wait-seconds "$WAIT_SECS" >/dev/null; }
  action(){ oci compute instance action --instance-id "$INSTANCE_ID" --action "$1" \
              --wait-for-state "$2" --max-wait-seconds "$WAIT_SECS" >/dev/null; }
  public_ip(){ oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output; }
else
  ec2(){ aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].$1" --output text; }
  state(){
    local s; s="$(ec2 State.Name)" || return 1
    case "$s" in
      pending) echo STARTING ;; running) echo RUNNING ;; stopping) echo STOPPING ;; stopped) echo STOPPED ;;
      *) echo "$s" ;;   # shutting-down / terminated: cmd_start reports it as unstartable
    esac
  }
  # A poll, not `aws ec2 wait`: its waiters give up after a fixed 10 min regardless of LAB_WAIT_SECS.
  wait_state(){
    local deadline=$((SECONDS + WAIT_SECS)) s=
    until s="$(state)" && [ "$s" = "$1" ]; do
      [ $SECONDS -lt $deadline ] || { log "instance still $s after ${WAIT_SECS}s (wanted $1)"; return 1; }
      sleep 10
    done
  }
  action(){
    case "$1" in
      START)    aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null ;;
      SOFTSTOP) aws ec2 stop-instances  --instance-ids "$INSTANCE_ID" >/dev/null ;;           # ACPI shutdown
      STOP)     aws ec2 stop-instances  --instance-ids "$INSTANCE_ID" --force >/dev/null ;;
    esac && wait_state "$2"
  }
  public_ip(){ ec2 PublicIpAddress; }
fi

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
  local host="${SSH_HOST:-}"
  if [ -z "$host" ]; then
    # Explicit exit-status check, not just "is the result non-empty": the OCI CLI writes some of its own
    # error output (e.g. "the config file is invalid") to STDOUT, not stderr, on a misconfigured
    # OCI_USER/TENANCY/FINGERPRINT/REGION/PRIVATE_KEY — that text is non-empty and isn't literally
    # "null", so a bare presence check lets it silently become $host, corrupt the ssh config below with an
    # embedded multi-line value, and surface as a baffling "Could not resolve hostname lab" instead of the
    # real cause. Also reject anything containing whitespace: a real public IP never does.
    host="$(public_ip)" \
      || { log "$PROVIDER CLI call failed (see its output above) — check the lab's $PROVIDER credentials (README → Setup)"; exit 1; }
    case "$host" in ""|null|None) log "instance has no public IP — set SSH_HOST"; exit 1;; esac
    case "$host" in *[[:space:]]*) log "unexpected value for the instance's public IP: '$host' (likely a $PROVIDER CLI error, not an address)"; exit 1;; esac
  fi
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  local strict=accept-new
  if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
    # Rewritten keyed to the alias "lab", NOT the literal address ssh-keyscan was run against: OCI's
    # ephemeral public IP (OCI or EC2) can change on restart (that's exactly why SSH_HOST is normally left unset,
    # below), so pinning to that IP literal would silently stop matching the next time it changes — this
    # host would then fail StrictHostKeyChecking on every run until someone re-ran ssh-keyscan by hand.
    # HostKeyAlias (below) makes ssh look the key up under "lab" regardless of what IP it resolves to
    # today. Comment/blank lines from a pasted-as-is `ssh-keyscan` transcript are dropped automatically.
    awk 'NF && $1 !~ /^#/ { $1="lab"; print }' <<< "$SSH_KNOWN_HOSTS" >> ~/.ssh/known_hosts
    strict=yes
  else echo "::warning::SSH_KNOWN_HOSTS not set — trusting the lab host key on first use"; fi
  cat > ~/.ssh/config <<EOF
Host lab
  HostName $host
  HostKeyAlias lab
  User ${SSH_USER:-ubuntu}
  BatchMode yes
  StrictHostKeyChecking $strict
  ConnectTimeout 15
  ServerAliveInterval 30
  ServerAliveCountMax 6
EOF
  log "lab = ${SSH_USER:-ubuntu}@$host; waiting for SSH"
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
