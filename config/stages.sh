# shellcheck shell=bash
#
# stages.sh — the stage catalogue. The ONLY place that knows which rafay_nvcm_poc entry point each stage
# calls. Sourced in two places:
#   * on the GitHub runner (scripts/run-stages.sh) — reads LAUNCHPAD_STAGES for order, phase, timeout;
#   * on the OCI host (remote/agent.sh)            — calls stage_<name> inside the rafay_nvcm_poc checkout,
#                                                    with run.env sourced and `set -euo pipefail`.
#
# RULE: a stage body is an INVOCATION of a documented rafay_nvcm_poc command (setup_guide.md §0, Part IV).
# Installation logic belongs in rafay_nvcm_poc, never here. If a stage needs more than a few lines of glue,
# that glue is missing from rafay_nvcm_poc — raise it there.
#
# ADDING A STAGE: one "name:phase:timeout_minutes" line below (order = execution order) + a stage_<name>
# function (dashes become underscores). Phases map to workflow jobs (platform | site | bringup); keep each
# phase's timeouts summed under ~340 min — GitHub-hosted jobs are hard-capped at 6 h.

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

# ── site defaults (the STC reference site shipped in rafay_nvcm_poc/stc) ─────────────────────────────────
: "${SITE:=blr-dc01}"
: "${BP_XLSX:=stc/STCS-GPUaaS_Network-Schema_v0.3.xlsx}"
: "${BP_PROFILE:=stc/sheet_profiles/stcs-v0.3.yaml}"
: "${BP_FACTS:=stc/site_facts/${SITE}.yaml}"
: "${BP_COMMITTED:=stc/blueprint_stc.yaml}"
: "${BLUEPRINT_SOURCE:=generated}"     # generated = this run's blueprint stage output | committed = BP_COMMITTED
: "${TENANTS:=3-11,84-100}"            # simulate_dc.sh's own default

# The blueprint the DC stages consume. A "generated" run needs the blueprint stage to have run in THIS run.
lp_blueprint(){
  if [ "$BLUEPRINT_SOURCE" = committed ]; then echo "$POC_DIR/$BP_COMMITTED"; return; fi
  local bp="$RUN_DIR/blueprint_${SITE}.yaml"
  [ -f "$bp" ] || { echo "no generated blueprint at $bp — run the 'blueprint' stage in this run, or use blueprint_source=committed" >&2; return 1; }
  echo "$bp"
}

# ── stage bodies ─────────────────────────────────────────────────────────────────────────────────────────
stage_host_prep(){           bash deploy_scripts/platform/nvcm-host-prep.sh; }   # group changes apply from the next stage (new login)
stage_platform_install_1(){  bash deploy_scripts/platform/platform_install.sh nvcm --yes; }
stage_platform_install_2(){  bash deploy_scripts/platform/platform_install.sh rafay --platform-only --yes; }
stage_verify_platform(){     bash deploy_scripts/platform/verify_platform_install.sh all; }

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
  bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$OCI_IP" --apply --auto-approve \
      --tenants "$TENANTS" --from substrate --to substrate
}

stage_dc_bringup(){          # the rest of G8: underlay → overlay → servers → accept, each behind a hard gate
  local bp; bp="$(lp_blueprint)"
  bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$OCI_IP" --apply --auto-approve \
      --tenants "$TENANTS" --from underlay --to accept
}
