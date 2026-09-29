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
# necessarily finish starting — its failure message literally says "fix the [FAIL] lines above ... then
# re-run". This automates exactly that re-run instead of leaving a human to notice and retrigger the stage.
# Safe because platform_install.sh is documented idempotent (an already-installed release is detected and
# reconciled, not duplicated), so a retry after "not ready yet" is cheap — it just re-checks. $max_wait must
# stay comfortably under the stage's own external timeout (config/stages-*.sh), or a genuine hang gets a
# hard `timeout --kill-after` kill instead of this loop's own clean "giving up" message.
lp_retry_until_ready(){
  local desc="$1" max_wait="$2" interval="$3"; shift 3
  [ "${1:-}" = "--" ] && shift   # cosmetic separator at the call site; harmless if omitted
  local deadline=$((SECONDS + max_wait)) attempt=0
  until "$@"; do
    attempt=$((attempt+1))
    [ $SECONDS -lt $deadline ] || { echo "[launchpad] $desc still not ready after ${max_wait}s (attempt $attempt) — giving up" >&2; return 1; }
    echo "[launchpad] $desc not ready yet — retrying in ${interval}s (attempt $attempt, $((deadline-SECONDS))s left)" >&2
    sleep "$interval"
  done
}

stage_host_prep(){           bash deploy_scripts/platform/nvcm-host-prep.sh; }   # group changes apply from the next stage (new login)
stage_platform_install_1(){  lp_retry_until_ready "platform-install-1 (NVCM+Nautobot readiness)" 3600 30 -- bash deploy_scripts/platform/platform_install.sh nvcm --yes; }
stage_platform_install_2(){  lp_retry_until_ready "platform-install-2 (Rafay layer readiness)" 1800 30 -- bash deploy_scripts/platform/platform_install.sh rafay --platform-only --yes; }
stage_verify_platform(){     bash deploy_scripts/platform/verify_platform_install.sh all; }
