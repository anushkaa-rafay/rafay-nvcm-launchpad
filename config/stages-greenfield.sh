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
# function (dashes become underscores). Phases map 1:1 to workflow jobs — the four steps of the flow:
#   platform   1 · Installation        host deps → NVCM + Nautobot → Rafay layer → verify       (guide Part II)
#   blueprint  2 · Blueprint           generate (or take the existing one) → verify            (guide Part III)
#   substrate  3 · Substrate           recover it if it already exists, otherwise create it    (guide Part IV S2 + S4 slice)
#   bringup    4 · Site bring-up       underlay → overlay → servers → accept                   (guide Part IV S4–S5)
# Keep each phase's timeouts summed under ~340 min — GitHub-hosted jobs are hard-capped at 6 h.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# shellcheck disable=SC2034  # consumed by every file that sources this one (run-stages.sh, build-report.sh, agent.sh)
LAUNCHPAD_STAGES=(
  host-prep:platform:45            # 1 Installation — dependencies: OS packages, KVM/libvirt, docker, k8s tools   §6
  nvcm-install:platform:150        # 1 Installation — NVCM + Nautobot (+ telemetry)                                §8
  rafay-install:platform:60        # 1 Installation — Rafay customization                                          §10
  platform-verify:platform:20      # 1 Installation — verify the whole platform (verify … all)                     §9/§11/§19
  blueprint-generate:blueprint:20  # 2 Blueprint — generate from the workbook, or take the existing one           III-2
  blueprint-verify:blueprint:10    # 2 Blueprint — verify whichever blueprint this run uses (offline door)         III-3
  substrate:substrate:120          # 3 Substrate — exists → recover it; missing → stage images + create it         S2 + S4
  site-bringup:bringup:300         # 4 Site bring-up — underlay → overlay → servers → accept, gated per layer      S4–S5
)

# ── greenfield-only: the STC reference site shipped in rafay_nvcm_poc/stc ────────────────────────────────
: "${BP_XLSX:=stc/STCS-GPUaaS_Network-Schema_v0.3.xlsx}"
: "${BP_PROFILE:=stc/sheet_profiles/stcs-v0.3.yaml}"
: "${BP_FACTS:=stc/site_facts/${SITE}.yaml}"
: "${BP_COMMITTED:=stc/blueprint_stc.yaml}"
: "${BLUEPRINT_SOURCE:=generate}"      # generate = built by this run's blueprint-generate stage | existing = BP_COMMITTED

# The blueprint every later stage consumes. A "generate" run needs blueprint-generate to have run in THIS run.
lp_blueprint(){
  case "$BLUEPRINT_SOURCE" in
    existing) echo "$POC_DIR/$BP_COMMITTED"; return ;;
    generate) ;;
    *) echo "unknown BLUEPRINT_SOURCE '$BLUEPRINT_SOURCE' (generate | existing)" >&2; return 1 ;;
  esac
  local bp="$RUN_DIR/blueprint_${SITE}.yaml"
  [ -f "$bp" ] || { echo "no generated blueprint at $bp — run the 'blueprint-generate' stage in this run, or use blueprint_source=existing" >&2; return 1; }
  echo "$bp"
}

# The python toolchain both blueprint stages need (setup_guide.md Runbook for deployment, step 3). Idempotent.
lp_venv(){
  [ -x .venv/bin/python3 ] || { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip && python3 -m venv .venv; }
  .venv/bin/python3 -m pip install -q -r test/render/requirements.txt
}

# Does this blueprint's substrate already exist on the host? Echoes "<defined> <planned>" for the FABRIC VMs
# (the ones deploy_fabric_vms.sh builds — server VMs arrive later, in the servers layer, so they don't count).
# The plan comes from rafay_nvcm_poc's own plan_substrate.py — the same source recover/deploy use.
lp_substrate_count(){
  local bp="$1" plan
  plan="$(python3 deploy_scripts/substrate/plan_substrate.py --blueprint "$bp" --emit bash)" || return 1
  ( eval "$plan"; have=0; want=0
    for vm in "${VMS[@]}"; do
      [ "${IMAGES[$vm]:-}" = ubuntu ] && continue
      want=$((want+1))
      sudo virsh -c qemu:///system dominfo "$vm" >/dev/null 2>&1 && have=$((have+1))
    done
    echo "$have $want" )
}

# ── stage bodies (host-prep / nvcm-install / rafay-install / platform-verify: common.sh) ─────────────────
stage_blueprint_generate(){  # setup_guide.md III-2
  if [ "$BLUEPRINT_SOURCE" = existing ]; then
    local bp; bp="$(lp_blueprint)"
    [ -f "$bp" ] || { echo "blueprint_source=existing but $bp is not in this rafay_nvcm_poc checkout" >&2; return 1; }
    echo "[launchpad] blueprint_source=existing — nothing to generate; this run uses $bp"
    return 0
  fi
  lp_venv
  .venv/bin/python3 deploy_scripts/blueprint/xlsx_to_blueprint.py \
      --xlsx "$BP_XLSX" --profile "$BP_PROFILE" --facts "$BP_FACTS" --site "$SITE" --out "$RUN_DIR/blueprint_${SITE}.yaml"
  echo "[launchpad] blueprint generated: $RUN_DIR/blueprint_${SITE}.yaml"
}

stage_blueprint_verify(){    # setup_guide.md III-3 — the offline acceptance door, for BOTH sources
  local bp; bp="$(lp_blueprint)"
  lp_venv
  echo "[launchpad] verifying ($BLUEPRINT_SOURCE) blueprint: $bp"
  bash deploy_scripts/verify_blueprint.sh --blueprint "$bp"
}

stage_substrate(){           # setup_guide.md Part IV S2 + the substrate slice of S4 — recover OR create
  local bp counts have want; bp="$(lp_blueprint)"
  counts="$(lp_substrate_count "$bp")" || { echo "could not plan the substrate from $bp" >&2; return 1; }
  read -r have want <<< "$counts"
  if [ "$want" -gt 0 ] && [ "$have" -eq "$want" ]; then
    echo "[launchpad] substrate EXISTS ($have/$want fabric VMs defined) → recover it"
    sudo DC_BLUEPRINT="$bp" bash deploy_scripts/substrate/recover_substrate.sh
    DC_BLUEPRINT="$bp" bash deploy_scripts/verify/verify_layers.sh L1   # same proof the create path ends with
    DC_BLUEPRINT="$bp" bash deploy_scripts/verify/verify_layers.sh L2
    return 0
  fi
  if [ "$have" -eq 0 ]; then
    echo "[launchpad] substrate MISSING (0/$want fabric VMs) → create it"
  else
    echo "[launchpad] substrate PARTIAL ($have/$want fabric VMs) → recover what exists, then create the rest"
    sudo DC_BLUEPRINT="$bp" bash deploy_scripts/substrate/recover_substrate.sh
  fi
  sudo bash deploy_scripts/substrate/vm_image_operations.sh fetch      # S2 — no-op once the images are staged
  bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$LAB_IP" --apply --auto-approve \
      --tenants "$TENANTS" --from substrate --to substrate             # builds cabling + VMs, gates L1 + L2
}

stage_site_bringup(){        # setup_guide.md Part IV S4 (rest) + S5: underlay → overlay → servers → accept, each behind a hard gate
  local bp; bp="$(lp_blueprint)"
  bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$LAB_IP" --apply --auto-approve \
      --tenants "$TENANTS" --from underlay --to accept
}
