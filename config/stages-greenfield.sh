# shellcheck shell=bash
#
# stages-greenfield.sh — the GREENFIELD stage catalogue: nothing to preserve; author intent from scratch and
# push it to blank switches. Mirrors rafay_nvcm_poc's onboarding/greenfield/greenfield_adoption_plan.md — "this
# path is already built and documented" in deploy_scripts/, via datacenters/examples/<dc>/ (e.g. stc/stc_dc_deploy.md)'s spreadsheet → blueprint
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
#   substrate  3 · Substrate           stage images + create the fabric VMs and cabling       (guide Part IV S2 + S4 slice)
#   bringup    4 · Site bring-up       underlay → overlay → servers → accept                   (guide Part IV S4–S5)
# Keep each phase's timeouts summed under ~340 min — GitHub-hosted jobs are hard-capped at 6 h.

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# shellcheck disable=SC2034  # consumed by every file that sources this one (run-stages.sh, build-report.sh, agent.sh)
LAUNCHPAD_STAGES=(
  host-prep:platform:45            # 1 Installation — dependencies: OS packages, KVM/libvirt, docker, k8s tools   §6
  platform-nvcm-install:platform:150        # 1 Installation — NVCM + Nautobot (+ telemetry)                                §8
  platform-rafay-install:platform:60        # 1 Installation — Rafay customization                                          §10
  platform-verify:platform:20      # 1 Installation — verify the whole platform (verify … all)                     §9/§11/§19
  blueprint-generate:blueprint:20  # 2 Blueprint — generate from the workbook, or take the existing one           III-2
  blueprint-verify:blueprint:10    # 2 Blueprint — verify whichever blueprint this run uses (offline door)         III-3
  substrate:substrate:120          # 3 Substrate — stage images + create the fabric VMs and cabling (gates L1+L2)  S2 + S4
  site-bringup:bringup:300         # 4 Site bring-up — underlay → overlay → servers → accept, gated per layer      S4–S5
)

# ── greenfield-only: the datacenter folder the blueprint comes from ─────────────────────────────────────────
# rafay_nvcm_poc layout (prototype_demo_v1 and later): blueprint tools under blueprint/, the example sites under
# datacenters/examples/<datacenter>/, the virtual-fabric substrate tools under targets/virtual/fabric_maintenance/twin_clos/.
: "${DATACENTER:=stc}"                 # a folder of datacenters/examples/ (the workflow's `datacenter` dropdown)
: "${BLUEPRINT_SOURCE:=generate}"      # generate = built from the folder's workbook by this run's blueprint-generate stage
                                       # existing = the folder's committed blueprint_*.yaml
DC_DIR="datacenters/examples/$DATACENTER"
BP_GENERATE=blueprint/greenfield/xlsx_to_blueprint.py
BP_VERIFY=blueprint/validate/verify_blueprint.sh
SUBSTRATE_DIR=targets/virtual/fabric_maintenance/twin_clos

# lp_one <what> <candidate...>: print the ONE candidate that exists, else explain on stderr and fail. The folders
# are not uniform (slab has five blueprints, nava two workbooks, tm no sheet profile), so a folder that doesn't
# give exactly one file fails loudly, naming what it found, instead of quietly picking one of them.
lp_one(){
  local what="$1" f m=(); shift
  for f in "$@"; do [ -e "$f" ] && m+=("$f"); done
  case ${#m[@]} in
    1) echo "${m[0]}" ;;
    0) echo "[launchpad] datacenter '$DATACENTER' ($BLUEPRINT_SOURCE): no $what in $DC_DIR/" >&2; return 1 ;;
    *) echo "[launchpad] datacenter '$DATACENTER' ($BLUEPRINT_SOURCE): ${#m[@]} $what files in $DC_DIR/ — need exactly one: ${m[*]}" >&2; return 1 ;;
  esac
}

# lp_dc_inputs: resolve the chosen datacenter folder (relative to the rafay_nvcm_poc checkout, the stages' cwd) into
#   existing → BP_COMMITTED  = $DC_DIR/blueprint_*.yaml
#   generate → BP_XLSX       = $DC_DIR/*.xlsx
#              BP_PROFILE    = $DC_DIR/sheet_profiles/*.yaml      (the generator requires one)
#              BP_FACTS      = $DC_DIR/site_facts/*.yaml
#              GEN_SITE      = the facts file's name (site_facts/blr-dc01.yaml → blr-dc01), the generated site
# Any of them already set in the environment wins. Also run at boot (`agent.sh check`), so a folder that doesn't
# resolve fails the run there — not hours later, after the platform install.
lp_dc_inputs(){
  [[ "$DATACENTER" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "[launchpad] invalid datacenter '$DATACENTER'" >&2; return 1; }
  [ -d "$DC_DIR" ] || { echo "[launchpad] datacenter '$DATACENTER': $DC_DIR/ is not in this rafay_nvcm_poc checkout (branch ${POC_BRANCH:-?}) — have: $(cd datacenters/examples 2>/dev/null && ls -d -- */ | tr -d / | tr '\n' ' ')" >&2; return 1; }
  case "$BLUEPRINT_SOURCE" in
    existing)
      BP_COMMITTED="${BP_COMMITTED:-$(lp_one "blueprint_*.yaml" "$DC_DIR"/blueprint_*.yaml)}" || return ;;
    generate)
      BP_XLSX="${BP_XLSX:-$(lp_one "*.xlsx workbook" "$DC_DIR"/*.xlsx)}" || return
      BP_PROFILE="${BP_PROFILE:-$(lp_one "sheet_profiles/*.yaml" "$DC_DIR"/sheet_profiles/*.yaml)}" || return
      BP_FACTS="${BP_FACTS:-$(lp_one "site_facts/*.yaml" "$DC_DIR"/site_facts/*.yaml)}" || return
      GEN_SITE="$(basename "$BP_FACTS" .yaml)" ;;
    *) echo "[launchpad] unknown BLUEPRINT_SOURCE '$BLUEPRINT_SOURCE' (generate | existing)" >&2; return 1 ;;
  esac
}

# Boot-time check (agent.sh check, right after the checkout): the chosen datacenter resolves for this source.
lp_check(){
  lp_dc_inputs || return
  case "$BLUEPRINT_SOURCE" in
    existing) echo "[launchpad] datacenter $DATACENTER (existing): $BP_COMMITTED" ;;
    generate) echo "[launchpad] datacenter $DATACENTER (generate): site $GEN_SITE from $BP_XLSX + $BP_PROFILE + $BP_FACTS" ;;
  esac
}

# The blueprint every later stage consumes. A "generate" run needs blueprint-generate to have run in THIS run.
lp_blueprint(){
  lp_dc_inputs || return
  if [ "$BLUEPRINT_SOURCE" = existing ]; then echo "$POC_DIR/$BP_COMMITTED"; return; fi
  local bp="$RUN_DIR/blueprint_${GEN_SITE}.yaml"
  [ -f "$bp" ] || { echo "no generated blueprint at $bp — run the 'blueprint-generate' stage in this run, or untick 'generate'" >&2; return 1; }
  echo "$bp"
}

# --tenants for simulate_dc.sh: TENANTS=blueprint (the workflow's blank `tenants`) leaves the flag off, so the
# blueprint's own full tenant range is used. One arg per line; callers read it into an array.
lp_tenant_args(){ [ "$TENANTS" = blueprint ] || printf '%s\n' --tenants "$TENANTS"; }

# The python toolchain both blueprint stages need (setup_guide.md Runbook for deployment, step 3). Idempotent.
lp_venv(){
  [ -x .venv/bin/python3 ] || { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip && python3 -m venv .venv; }
  .venv/bin/python3 -m pip install -q -r test/render/requirements.txt
}

# ── stage bodies (host-prep / platform-nvcm-install / platform-rafay-install / platform-verify: common.sh) ─────────────────
stage_blueprint_generate(){  # setup_guide.md III-2
  # Every step is `|| return`ed: lp_run_stage runs this as `"$fn" | tee || rc=$?`, which turns set -e off inside
  # the function — without it a failed generator still "passes" the stage (2026-11-12, run 43194653667).
  lp_dc_inputs || return
  if [ "$BLUEPRINT_SOURCE" = existing ]; then
    echo "[launchpad] generate is off — nothing to generate; this run uses $POC_DIR/$BP_COMMITTED"
    return 0
  fi
  local out="$RUN_DIR/blueprint_${GEN_SITE}.yaml"
  lp_venv || return
  echo "[launchpad] generating $DATACENTER blueprint (site $GEN_SITE) from $BP_XLSX"
  .venv/bin/python3 "$BP_GENERATE" \
      --xlsx "$BP_XLSX" --profile "$BP_PROFILE" --facts "$BP_FACTS" --site "$GEN_SITE" --out "$out" || return
  [ -s "$out" ] || { echo "[launchpad] $BP_GENERATE exited 0 but wrote no blueprint at $out" >&2; return 1; }
  echo "[launchpad] blueprint generated: $out"
}

stage_blueprint_verify(){    # setup_guide.md III-3 — the offline acceptance door, for BOTH sources
  local bp; bp="$(lp_blueprint)" || return
  lp_venv || return
  echo "[launchpad] verifying $DATACENTER ($BLUEPRINT_SOURCE) blueprint: $bp"
  bash "$BP_VERIFY" --blueprint "$bp"
}

# After a failed L1/L2 gate: put this blueprint's fabric VMs back in shape for the next attempt. recover_substrate.sh
# (site-scoped) recreates missing bridges and starts every VM that is off; a VM STILL not running after that is
# deleted with its disk, so the next simulate_dc.sh pass recreates it from the image (deploy_fabric_vms.sh skips the
# VMs that exist). Server VMs (ubuntu image) belong to the Servers layer and are left alone. Subshell: the plan's
# `declare -gA` arrays stay out of the stage's environment.
lp_substrate_repair()(
  bp="$1"; V="sudo virsh -c qemu:///system"
  sudo DC_BLUEPRINT="$bp" bash "$SUBSTRATE_DIR/recover_substrate.sh" || true
  plan="$(python3 "$SUBSTRATE_DIR/plan_substrate.py" --blueprint "$bp" --emit bash)" || exit 1
  eval "$plan"
  for vm in "${VMS[@]}"; do
    [ "${IMAGES[$vm]:-}" = ubuntu ] && continue
    st="$($V domstate "$vm" 2>/dev/null)" || continue      # not defined: the next pass creates it
    [ "$st" = running ] && continue
    echo "[launchpad] $vm is '$st' and did not start — deleting it so the next pass recreates it" >&2
    $V destroy "$vm" >/dev/null 2>&1 || true
    $V undefine "$vm" --remove-all-storage >/dev/null 2>&1 || $V undefine "$vm" --remove-all-storage --nvram >/dev/null 2>&1 \
      || echo "[launchpad] could not delete $vm — the next pass will gate on it again" >&2
  done
)

# The L1 gate checks "every VM running" the moment the last VM is created, and a fresh Cumulus VM can be caught
# between boots (2026-10-14: leaf04 "not running" at the gate, running seconds later in the diagnostics). So a failed
# pass is repaired (above), given LP_SUBSTRATE_SETTLE_SECS to boot, and re-run — LP_SUBSTRATE_ATTEMPTS passes in all.
# Re-running is safe: cabling and VM creation skip what exists, then the gates check again.
stage_substrate(){           # setup_guide.md Part IV S2 + the substrate slice of S4 — always built fresh (clean_lab removed the VMs)
  local bp n=0 max="${LP_SUBSTRATE_ATTEMPTS:-3}" settle="${LP_SUBSTRATE_SETTLE_SECS:-60}"; bp="$(lp_blueprint)" || return
  local ta; mapfile -t ta < <(lp_tenant_args)
  sudo bash "$SUBSTRATE_DIR/vm_image_operations.sh" fetch || return    # S2 — no-op once the images are staged
  while :; do
    n=$((n+1))
    bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$LAB_IP" --apply --auto-approve \
        ${ta[@]+"${ta[@]}"} --from substrate --to substrate && return 0   # builds cabling + VMs, gates L1 + L2
    if [ "$n" -ge "$max" ]; then
      echo "[launchpad] substrate: still failing after $n attempt(s) — giving up" >&2
      return 1
    fi
    echo "[launchpad] substrate: attempt $n/$max failed — repairing this blueprint's fabric VMs, retrying in ${settle}s" >&2
    lp_substrate_repair "$bp"
    sleep "$settle"
  done
}

stage_site_bringup(){        # setup_guide.md Part IV S4 (rest) + S5: underlay → overlay → servers → accept, each behind a hard gate
  local bp ta; bp="$(lp_blueprint)" || return; mapfile -t ta < <(lp_tenant_args)
  # Recover first: site-scoped and idempotent (recreates this blueprint's missing bridges, sets autostart, starts
  # its VMs). A no-op straight after the substrate stage; it is what makes a stages=site-bringup rerun work on a lab
  # that was powered off since its substrate was built (runtime bridges don't survive a host reboot).
  sudo DC_BLUEPRINT="$bp" bash "$SUBSTRATE_DIR/recover_substrate.sh" || return
  # --dc up turns the servers layer ON (without it simulate_dc.sh SKIPS servers: "fabric is the deliverable").
  # ORDER MATTERS: simulate_dc.sh parses left to right and `--dc up` resets --from to substrate, so it must come
  # BEFORE `--from underlay` — the other way round would rebuild the substrate the previous phase just made.
  bash deploy_scripts/simulate_dc.sh --blueprint "$bp" --oci "$LAB_IP" --apply --auto-approve \
      ${ta[@]+"${ta[@]}"} --dc up --from underlay
}
