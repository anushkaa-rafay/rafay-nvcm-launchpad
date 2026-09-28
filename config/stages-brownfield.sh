# shellcheck shell=bash
#
# stages-brownfield.sh — the BROWNFIELD stage catalogue: a live fabric already exists — learn from it, never
# author over it. Mirrors rafay_nvcm_poc's onboarding/brownfield/brownfield_adoption_plan.md: bf-onboard.sh's
# own discover → blueprint → review → adopt flow, landing on the SAME provision_site.sh the greenfield
# catalogue uses (onboarding/README.md: "both branches converge on the same SoT and the same downstream").
# Sourced the same two places as stages-greenfield.sh (see that file's header).
#
# THE REVIEW GATE — do not skip it on a real DC. discover and blueprint are READ-ONLY: nothing is written to
# Nautobot or to any switch (rafay_nvcm_poc's own design principle: "the fabric is in production" — trust the
# switch, prove a zero-diff before anything is written). adopt is the ONLY stage that writes. The safe pattern
# for a real DC is TWO runs of this workflow:
#   1. stages=bf-discover,bf-blueprint — read the generated blueprint in that run's log / committed report,
#      resolve every `TODO(confirm)` marker (or set policy_from so none are left).
#   2. stages=bf-adopt — once satisfied. It re-finds the SAME discovered blueprint on the host (see OUT below).
# `stages=all` (the default) runs discover → blueprint → adopt unattended in one go — fine for the lab's own
# simulated fabric (this repo's default target), but never the first pass on a real production DC.
#
# ADDING A STAGE: same convention as stages-greenfield.sh.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# shellcheck disable=SC2034
LAUNCHPAD_STAGES=(
  host-prep:platform:45
  platform-install-1:platform:150
  platform-install-2:platform:60
  verify-platform:platform:20
  bf-discover:site:30
  bf-blueprint:site:20
  bf-adopt:bringup:240
)

# ── brownfield-only ──────────────────────────────────────────────────────────────────────────────────────
: "${BF_MODE:=virtual}"                        # virtual = VMs on this host via virsh | real = --seed FILE, LLDP cabling
: "${LOCATION:=}"                              # blank = carry the policy_from reference's own location chain
: "${DEVICE_TYPE:=Cumulus VX}"
: "${POLICY_FROM:=stc/blueprint_stc.yaml}"     # a running switch can't reveal tenant_policy/supernets — carry it from a reference
: "${SEED_B64:=}"                              # base64 of the real-mode seed file (mgmt IPs, one per line); empty for virtual

# Discovery output lives under $HOME, NOT bf-onboard.sh's own /tmp default: a brownfield run spans TWO
# workflow runs (discover+blueprint, human review, then adopt) with the OCI instance stopped in between by
# default (shutdown_oci) — /tmp on some cloud images is tmpfs and would not survive that power cycle.
export OUT="$HOME/launchpad/bf-discover"
BF="onboarding/brownfield/scripts/bf-onboard.sh"

bf_blueprint_path(){
  local bp; bp="$(ls -t "$OUT"/blueprint_*.yaml 2>/dev/null | head -1)"
  [ -n "$bp" ] || { echo "no discovered blueprint under $OUT — run the 'bf-discover' + 'bf-blueprint' stages first" >&2; return 1; }
  echo "$bp"
}

# ── stage bodies (host-prep / platform-install-1 / platform-install-2 / verify-platform: common.sh) ───────
stage_bf_discover(){         # READ-ONLY: nothing written to Nautobot or any switch
  mkdir -p "$OUT"
  if [ "$BF_MODE" = real ]; then
    [ -n "$SEED_B64" ] || { echo "BF_MODE=real needs a seed (mgmt IPs) — set the workflow's seed input" >&2; return 1; }
    printf '%s' "$SEED_B64" | base64 -d > "$RUN_DIR/seed.txt"
    bash "$BF" discover --mode real --seed "$RUN_DIR/seed.txt"
  else
    bash "$BF" discover --mode virtual
  fi
}

stage_bf_blueprint(){        # READ-ONLY: discovery -> blueprint_<site>.yaml (the reuse path; no SoT write)
  BF_SITE="$SITE" BF_LOCATION="$LOCATION" BF_DEVICE_TYPE="$DEVICE_TYPE" BF_POLICY_FROM="$POLICY_FROM" \
    bash "$BF" blueprint
  local bp; bp="$(bf_blueprint_path)"
  echo "──────────────────────── discovered blueprint: $bp ────────────────────────"
  cat "$bp"
  echo "─────────────────────────────────────────────────────────────────────────"
  if grep -q 'TODO(confirm)' "$bp"; then
    echo "NOTE: unresolved TODO(confirm) markers above — resolve them (policy_from=<reference blueprint>) before the bf-adopt stage."
  fi
}

stage_bf_adopt(){            # the ONLY brownfield stage that writes: reuses the EXISTING greenfield generator
  local bp; bp="$(bf_blueprint_path)"
  DC_BLUEPRINT="$bp" bash deploy_scripts/fabric/provision_site.sh --blueprint "$bp" --apply --auto-approve --tenants "$TENANTS"
}
