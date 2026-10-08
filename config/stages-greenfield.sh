# shellcheck shell=bash
#
# stages-greenfield.sh — the GREENFIELD stage catalogue: nothing to preserve; author intent from scratch and
# push it to blank switches. Mirrors rafay_nvcm_poc's onboarding/greenfield/greenfield_adoption_plan.md — "this
# path is already built and documented" in deploy_scripts/, via stc/stc_dc_deploy.md's spreadsheet → blueprint
# → deploy flow. Sourced in two places:
#   * on the GitHub runner (scripts/run-stages.sh) via $LAUNCHPAD_CATALOGUE — reads LAUNCHPAD_STAGES for
#     order, phase, timeout;
#   * on the OCI host (remote/agent.sh), copied there as ~/launchpad/stages.sh — calls stage_<name> inside
#     the rafay_nvcm_poc checkout, with run.env sourced and `set -euo pipefail`.
#
# RULE: a stage body is an INVOCATION of a documented rafay_nvcm_poc command (setup_guide.md §0, Part IV).
# Installation logic belongs in rafay_nvcm_poc, never here. If a stage needs more than a few lines of glue,
# that glue is missing from rafay_nvcm_poc — raise it there.
#
# ADDING A STAGE: one "name:phase:timeout_minutes" line below (order = execution order) + a stage_<name>
# function (dashes become underscores). Phases map to workflow jobs (platform | site | bringup); keep each
# phase's timeouts summed under ~340 min — GitHub-hosted jobs are hard-capped at 6 h.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# shellcheck disable=SC2034  # consumed by every file that sources this one (run-stages.sh, build-report.sh, agent.sh)
LAUNCHPAD_STAGES=(
  host-prep:platform:45
  platform-install-1:platform:150
  platform-install-2:platform:60
  verify-platform:platform:20
  blueprint:site:20
  substrate:site:120
  dc-bringup:bringup:300
)

# ── greenfield-only: the STC reference site shipped in rafay_nvcm_poc/stc ────────────────────────────────
: "${BP_XLSX:=stc/STCS-GPUaaS_Network-Schema_v0.3.xlsx}"
: "${BP_PROFILE:=stc/sheet_profiles/stcs-v0.3.yaml}"
: "${BP_FACTS:=stc/site_facts/${SITE}.yaml}"
: "${BP_COMMITTED:=stc/blueprint_stc.yaml}"
: "${BLUEPRINT_SOURCE:=generate}"      # generate = this run's blueprint stage output | existing = BP_COMMITTED

# The blueprint the DC stages consume. A "generate" run needs the blueprint stage to have run in THIS run.
lp_blueprint(){
  case "$BLUEPRINT_SOURCE" in
    existing) echo "$POC_DIR/$BP_COMMITTED"; return ;;
    generate) ;;
    *) echo "unknown BLUEPRINT_SOURCE '$BLUEPRINT_SOURCE' (generate | existing)" >&2; return 1 ;;
  esac
  local bp="$RUN_DIR/blueprint_${SITE}.yaml"
  [ -f "$bp" ] || { echo "no generated blueprint at $bp — run the 'blueprint' stage in this run, or use blueprint_source=existing" >&2; return 1; }
  echo "$bp"
}

# ── stage bodies (host-prep / platform-install-1 / platform-install-2 / verify-platform: common.sh) ───────
stage_blueprint(){           # setup_guide.md G2 (toolchain) + G4 (generate, then verify offline)
  [ -x .venv/bin/python3 ] || { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip && python3 -m venv .venv; }
  .venv/bin/python3 -m pip install -q -r test/render/requirements.txt
  .venv/bin/python3 deploy_scripts/blueprint/xlsx_to_blueprint.py \
      --xlsx "$BP_XLSX" --profile "$BP_PROFILE" --facts "$BP_FACTS" --site "$SITE" --out "$RUN_DIR/blueprint_${SITE}.yaml"
  bash deploy_scripts/verify_blueprint.sh --blueprint "$RUN_DIR/blueprint_${SITE}.yaml"
}

stage_substrate(){           # setup_guide.md G6 + the substrate slice of G8
  local bp; bp="$(lp_blueprint)"
  sudo bash deploy_scripts/substrate/vm_image_operations.sh fetch
  sudo DC_BLUEPRINT="$bp" bash deploy_scripts/substrate/recover_substrate.sh
  bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$LAB_IP" --apply --auto-approve \
      --tenants "$TENANTS" --from substrate --to substrate
}

stage_dc_bringup(){          # the rest of G8: underlay → overlay → servers → accept, each behind a hard gate
  local bp; bp="$(lp_blueprint)"
  bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$LAB_IP" --apply --auto-approve \
      --tenants "$TENANTS" --from underlay --to accept
}
