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
# pods just take a while to come up, and verify-platform (the next real stage) re-checks full readiness
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

stage_host_prep(){           bash deploy_scripts/platform/nvcm-host-prep.sh; }   # group changes apply from the next stage (new login)
stage_platform_install_1(){  lp_continue_if_not_ready "platform-install-1" bash deploy_scripts/platform/platform_install.sh nvcm --yes; }
stage_platform_install_2(){  lp_continue_if_not_ready "platform-install-2" bash deploy_scripts/platform/platform_install.sh rafay --platform-only --yes; }
stage_verify_platform(){     bash deploy_scripts/platform/verify_platform_install.sh all; }
