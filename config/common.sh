# shellcheck shell=bash
#
# common.sh — stage bodies + defaults shared by BOTH onboarding modes. Sourced by config/stages-greenfield.sh
# and config/stages-brownfield.sh, never directly. These are exactly the platform bring-up stages: NVCM +
# Nautobot + the Rafay layer, with NO site data. rafay_nvcm_poc's onboarding/README.md ("STC Onboarding — the
# front door") puts it precisely: greenfield and brownfield differ only in HOW the SoT gets filled and the
# deploy posture — both need the platform itself to exist first, and both converge on the same downstream
# render → diff → deploy.

: "${SITE:=blr-dc01}"              # the site name; what changes between modes is how its SoT gets filled
: "${TENANTS:=3-11,84-100}"        # simulate_dc.sh's own default; also what provision_site.sh --tenants reconciles

# platform_install.sh's own internal readiness check runs right after `helm upgrade` returns, before pods
# necessarily finish starting — its failure message says "fix the [FAIL] lines above ... then re-run", but
# per the operator (2026-09-29) that's expected/transient here, not something to stop the run over: the
# pods just take a while to come up, and platform-verify (the next real stage) re-checks full readiness
# once they've had more time. So: NEITHER retry NOR fail on this specific signal — just continue. Any OTHER
# failure (a real problem) still stops the stage normally.
lp_continue_if_not_ready(){
  local desc="$1"; shift
  local out rc=0
  out="$(mktemp)"
  "$@" 2>&1 | tee "$out" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qE 'NOT READY|pod\(s\) not Running' "$out"; then
    echo "[launchpad] $desc: not fully ready yet (pods still starting) — not fatal here, continuing" >&2
    rc=0
  fi
  rm -f "$out"
  return "$rc"
}

# Wraps EVERY stage (called from remote/agent.sh's generated stage script — see there, not per-stage
# functions): if a stage fails with the apt/dpkg lock still held, it retries the WHOLE stage rather than
# failing outright. This is a host-boot race, not a real problem — cloud-init or unattended-upgrades often
# runs its own apt-get in the background right after boot, and any stage that shells out to apt-get
# (currently host-prep, blueprint — but this could be any future one too, hence wrapping centrally here
# rather than teaching each stage_<name> function about it) can lose that race. Re-running the whole stage
# is safe because every stage here is itself documented idempotent/re-runnable. Any OTHER failure (not
# matching this exact signature) propagates immediately on the first attempt, unaffected.
lp_run_stage(){
  local fn="$1" out rc attempt=0 deadline
  local max_wait="${LP_RUN_STAGE_MAX_WAIT:-600}" interval="${LP_RUN_STAGE_INTERVAL:-15}"
  deadline=$((SECONDS + max_wait))
  while :; do
    attempt=$((attempt+1)); rc=0
    out="$(mktemp)"
    "$fn" 2>&1 | tee "$out" || rc=$?
    [ "$rc" -eq 0 ] && { rm -f "$out"; return 0; }
    grep -qE 'Could not get lock|Unable to lock directory|dpkg was interrupted' "$out" || { rm -f "$out"; return "$rc"; }
    rm -f "$out"
    [ $SECONDS -lt $deadline ] || { echo "[launchpad] $fn: apt/dpkg still locked after ${max_wait}s (attempt $attempt) — giving up" >&2; return "$rc"; }
    echo "[launchpad] $fn: apt/dpkg locked (cloud-init/unattended-upgrades likely still finishing after boot) — retrying in ${interval}s (attempt $attempt)" >&2
    sleep "$interval"
  done
}

# setup_guide.md Part II: §6 host prep, §8 NVCM + Nautobot, §10 Rafay customization, §9/§11/§19 verify
stage_host_prep(){           bash deploy_scripts/platform/nvcm-host-prep.sh; }   # group changes apply from the next stage (new login)
stage_platform_nvcm_install(){  lp_continue_if_not_ready "platform-nvcm-install" bash deploy_scripts/platform/platform_install.sh nvcm --yes; }
stage_platform_rafay_install(){  lp_continue_if_not_ready "platform-rafay-install" bash deploy_scripts/platform/platform_install.sh rafay --platform-only --yes; }
# platform-verify: right after the two installs some pods are often still starting, so a NOT READY verdict is
# usually transient. The verifier is read-only, so re-run it every LP_VERIFY_RETRY_SECS (3 min) until it prints
# VERIFIED or LP_VERIFY_MAX_WAIT runs out — kept under the stage's 20 min timeout so the LAST verdict is the
# verifier's own, not a timeout kill.
stage_platform_verify(){
  local every="${LP_VERIFY_RETRY_SECS:-180}" max="${LP_VERIFY_MAX_WAIT:-900}" n=0 deadline
  deadline=$((SECONDS + max))
  while :; do
    n=$((n+1))
    bash deploy_scripts/platform/verify_platform_install.sh all && return 0
    if [ $((SECONDS + every)) -ge "$deadline" ]; then
      echo "[launchpad] platform-verify: still NOT READY after $n attempt(s) over $((SECONDS / 60)) min — giving up" >&2
      return 1
    fi
    echo "[launchpad] platform-verify: NOT READY (attempt $n) — pods may still be starting; re-checking in ${every}s" >&2
    sleep "$every"
  done
}
