# Unit-test workflows — plan

**Status:** IMPLEMENTED (first cut, 2026-10-12): manual dispatch + `workflow_call`. The decisions are recorded in [§9](#9-decisions). The first real GitHub run (rollout steps 3–4) is still pending.

## 1. Goal

Run the offline unit tests ("gates") from `rafay_nvcm_poc/test/` as GitHub Actions workflows in this repo.

- **One workflow per launchpad phase.** Every gate for a phase runs inside that phase's single workflow.
  There is no workflow per test file.
- **No test code moves here.** This follows the same rule as the stage catalogues: the gates stay in
  `rafay_nvcm_poc`, and this repo only decides *which* gates run *where* and reports the results.
- **No lab is needed.** `test/run-tests.sh` is the offline suite ("no cluster, no switches, no hardware").
  So these workflows run on GitHub-hosted runners. They don't touch OCI or AWS, don't use SSH, and need no
  GitHub Environment. They can run in parallel with a lab run on any lab.

## 2. What exists today (inputs to this plan)

| Item | Fact |
|---|---|
| POC test runner | `test/run-tests.sh`: a flat list of **199 `run "<desc>" <file>` lines**, plus one inline preflight (`verify_blueprint.sh --blueprint stc/blueprint_stc.yaml --tenants 3-100`) |
| Test files | 199 files under `test/{allocations,api,blueprint,drift,ib,intake,render}`. Every file appears in `run-tests.sh` exactly once (checked) |
| Runner contract | Each gate is a standalone `python3 <file>`. Exit 0 = pass, **77 = skipped**, anything else = fail. With `DC_REQUIRE_ALL_GATES=1`, a skip counts as a fail |
| Suite-wide env | `DC_NO_PUBLISH=1` (no gate may push a customer repo) and `DC_BLUEPRINT=$PWD/stc/blueprint_stc.yaml` (the tenant policy fails closed without it) |
| Dependencies | `test/render/requirements.txt` (jinja2, pyyaml, openpyxl), bash 4 or later (two substrate gates skip on bash 3), `git`, `helm` (2 gates). `ubuntu-latest` already has all of these except the pip packages |
| Gate index | `test/README.md` maps each gate to its primary inputs. `test_gate_index_complete.py` and `test_suite_completeness.py` keep it in sync with `run-tests.sh` |
| Existing CI | `run-tests.sh` says "No CI currently runs this automatically". The 3 POC workflows (`greenfield-intake-*`, `brownfield-adopt`) are lab runs on self-hosted runners, not unit runs |
| Launchpad phases | `platform` (1 · Installation), `blueprint` (2), `substrate` (3), `bringup` (4). Defined in `config/stages-*.sh` and run one per job by `_phase.yml` |
| POC access | `POC_DEPLOY_KEY` (read-only deploy key) and `vars.POC_REPO` / `vars.POC_DEFAULT_BRANCH`, already configured |

## 3. Design

### 3.1 Workflow = phase; job = group inside the phase

```
unit-common.yml     ─┐
unit-platform.yml   ─┤  each one is a thin caller (inputs + triggers) of ──►  _unit.yml (reusable)
unit-blueprint.yml  ─┤                                                         plan  → coverage check, group matrix
unit-substrate.yml  ─┤                                                         test  → matrix: one job per GROUP
unit-bringup.yml    ─┘                                                         summary → one table for the phase
```

- **5 workflows.** One for each of the 4 launchpad phases, plus `common` for repo-wide hygiene gates
  that belong to no single phase (see the [open questions](#9-open-questions)).
- **Groups are matrix jobs inside the one workflow.** A large phase (bringup has 101 gates) is split into
  groups such as `fabric`, `tenants` and `servers`. The groups run in parallel with `fail-fast: false`, and
  each one shows up as its own row in the run graph. A red `tenants` row doesn't hide whether `servers`
  passed. It is still one workflow and one run.
- **One reusable workflow `_unit.yml`.** It follows the `_phase.yml` pattern: the mechanics are written
  once, and only the `phase` input changes.

### 3.2 The manifest: `config/unit-tests.sh`

This is a bash array in the same idiom as `LAUNCHPAD_STAGES`, so the runner script and `_unit.yml`'s manifest
self-test can read it the same way:

```bash
# shellcheck disable=SC2034
LAUNCHPAD_UNIT_TESTS=(          # phase:group:path-relative-to-rafay_nvcm_poc   (order = run order)
  platform:install:test/blueprint/test_install_verify_pairs.py
  platform:api:test/api/test_outcomes.py
  blueprint:intake:test/intake/test_identify_topology.py
  blueprint:generate-verify:@preflight          # the inline verify_blueprint.sh step from run-tests.sh
  ...
)
```

- Inside each group, gates keep their **relative order from `run-tests.sh`**. This avoids surprises if any
  gate relies on an earlier one's side effects (step 1 of the [rollout](#7-rollout) checks this).
- `@preflight` is a pseudo-entry for the `verify_blueprint.sh` block in `run-tests.sh`, which isn't a
  Python file.
- **ADDING A GATE:** add one line here. If you forget, the coverage check in §3.4 fails the run.

### 3.3 The runner: `scripts/run-unit-tests.sh`

It works like `scripts/run-stages.sh` (`plan` / `run` subcommands) and runs on the GitHub runner, never on
a lab host:

| Subcommand | Does |
|---|---|
| `groups <phase>` | Prints the phase's groups as JSON, used as the `plan` job's output for the matrix |
| `list <phase> [group]` | Prints the gate paths |
| `coverage <poc_dir>` | Compares `run "…" <file>` lines in `<poc_dir>/test/run-tests.sh` with the manifest. It **fails** on a gate the manifest doesn't map ("new POC gate, unrun here") and on a manifest entry the POC no longer has (stale) |
| `run <phase> <group> <poc_dir> <out>` | Runs each gate in `<poc_dir>` with the suite env (`DC_NO_PUBLISH=1`, `DC_BLUEPRINT=…/stc/blueprint_stc.yaml`, `DC_REQUIRE_ALL_GATES=1`). Uses the same exit-77 rules as `run-tests.sh`. Writes `<out>/<gate>.log`, `<out>/results.tsv` (gate, status, seconds) and a Markdown table for `$GITHUB_STEP_SUMMARY`. Keeps going after a failure and exits non-zero at the end if any gate failed |

`run` copies `run-tests.sh`'s pass/skip/fail rules on purpose instead of calling `run-tests.sh` itself,
because `run-tests.sh` can only run everything. If the POC later adds a filter (for example
`run-tests.sh --only <files>`), `run` should switch to it so the rules have one source.

### 3.4 `_unit.yml` (reusable)

```yaml
on:
  workflow_call:
    inputs:
      phase:      { type: string, required: true }    # common | platform | blueprint | substrate | bringup
      poc_branch: { type: string, default: "" }       # blank → vars.POC_DEFAULT_BRANCH → main
      groups:     { type: string, default: all }      # 'all' or a comma list, validated against the manifest
jobs:
  plan:     # checkout this repo + POC (actions/checkout, repository: vars.POC_REPO, ssh-key: secrets.POC_DEPLOY_KEY)
            # → validate inputs → `coverage` (fails the run on drift) → outputs: matrix of groups, poc_sha
  test:     # needs: plan · strategy.matrix.group from plan · fail-fast: false · timeout-minutes: 30
            # checkout both repos at plan's poc_sha (every group tests the SAME commit)
            # → setup-python 3.12 + pip cache keyed on test/render/requirements.txt → pip install
            # → run-unit-tests.sh run → upload-artifact unit-<phase>-<group> (logs + results.tsv)
  summary:  # needs: test · if: !cancelled() · download every results.tsv → one phase table in the step summary
```

- `permissions: contents: read` only. Nothing is committed (see the [open questions](#9-open-questions)).
- No `environment:`. The deploy key is read from repo-level secrets. If it is only stored on a lab
  Environment today, add a repo-level copy. It stays read-only.

### 3.5 The caller workflows (`unit-<phase>.yml`)

Each one is about 25 lines:

```yaml
name: unit-bringup
run-name: "unit-bringup · ${{ inputs.poc_branch || vars.POC_DEFAULT_BRANCH || 'main' }} · ${{ inputs.groups || 'all' }}"
on:
  workflow_dispatch:
    inputs:
      poc_branch: { description: "rafay_nvcm_poc branch (blank = POC_DEFAULT_BRANCH)", default: "", type: string }
      groups:     { description: "'all' or a comma list — fabric,tenants,servers,day2", default: all, type: string }
  workflow_call:          # lets nvcm-greenfield/brownfield run it as a pre-flight gate later (§8)
    inputs: { poc_branch: { type: string, default: "" }, groups: { type: string, default: all } }
  # schedule:             # nightly — uncomment to enable (same convention as nvcm-greenfield.yml)
  #   - cron: "0 20 * * *"
concurrency:
  group: unit-bringup-${{ inputs.poc_branch || vars.POC_DEFAULT_BRANCH || 'main' }}
  cancel-in-progress: true     # no shared host here, so a newer run can safely replace an older one
jobs:
  unit:
    uses: ./.github/workflows/_unit.yml
    with: { phase: bringup, poc_branch: "${{ inputs.poc_branch }}", groups: "${{ inputs.groups || 'all' }}" }
    secrets: inherit
```

### 3.6 Changes to existing files

| File | Change |
|---|---|
| `_unit.yml` (plan job) | A manifest self-test, before the POC checkout (there is no push/PR workflow to host it): every entry is `phase:group:path`, phases are in the known set, there are no duplicate paths, and `groups`/`list` work for each phase. `bash -n` and shellcheck already pick up `scripts/` and `config/` |
| `README.md` / `Dev_Guide.md` | Add the 5 workflows and `_unit.yml` to the workflows table and the layout tree. Add "ADDING A GATE" to the catalogue section |
| `User_Guide.md` | Add a short "Running unit tests" section: which workflow to pick and what the inputs mean |

## 4. Phase → group → gate mapping (199 gates + preflight)

The mapping is by **primary input** (the `test/README.md` gate table): the gate goes to the phase whose
stage runs the code it tests.

| Workflow | Group | Gates | What the group covers |
|---|---|---:|---|
| `unit-common` | `hygiene` | 9 | Repo-wide invariants: gate index, suite completeness, sources parse, doc links, no hard-coded credentials or customer data, undefined names in jobs, script-path refs |
| `unit-platform` | `install` | 11 | `deploy_scripts/platform`, `charts/rafay-nvcm-stack`, catalog bootstrap, job delivery paths, observability, release verify (stages `nvcm-install`, `rafay-install`, `platform-verify`) |
| | `api` | 16 | `deploy_scripts/api` (the REST door shipped with the Rafay layer), OpenAPI/Postman and the route contract, the mock Nautobot |
| `unit-blueprint` | `intake` | 14 | `deploy_scripts/intake/*`, `configuration_to_blueprint` (the workbook/diagram → blueprint front end) |
| | `generate-verify` | 31 + preflight | `blueprint.py`, `site_designs.py`, `xlsx_to_blueprint`, schema/closure/round-trip, topology families, gitops layout, customer repo, and the `verify_blueprint.sh` preflight (stages `blueprint-generate`, `blueprint-verify`) |
| | `brownfield` | 3 | `bf_core.py` discovery and raw round-trip (stages `bf-discover`, `bf-blueprint-generate`) |
| `unit-substrate` | `substrate` | 14 | `plan_substrate.py`, `deploy_fabric_vms.sh` / `deploy_server_vms.sh`, `recover_substrate.sh`, VM identity, mgmt addressing, substrate backup/restore |
| `unit-bringup` | `fabric` | 27 | `provision_site.sh`, `configure_devices.sh`, `seed_site_jobs.sh`, deploy/lock, NVUE render goldens, `verify_layers`, drift (underlay → overlay, `bf-adopt`) |
| | `tenants` | 45 | `allocations.py`, the tenant lifecycle Jobs + `tenant_operations.sh` CLI, InfiniBand render/provision, storage plane |
| | `servers` | 23 | Server Jobs + `server_operations.sh` CLI, netplan, GPU allocation |
| | `day2` | 6 | `backup_dc` / `restore_dc` / `replicate_dc`, switch-config restore, `undeploy_site.sh` |
| **Total** | | **199** | Checked: every gate is mapped exactly once, none missing, none duplicated |

### 4.1 Full list (becomes `config/unit-tests.sh`)

Paths are relative to `rafay_nvcm_poc/test/`. They are listed in `run-tests.sh` order.

#### `common` / `hygiene` — 9 gates

`blueprint/test_script_path_refs_resolve.py`, `blueprint/test_gate_index_complete.py`, `blueprint/test_jobs_undefined_names.py`, `blueprint/test_axis_a_no_customer_values.py`, `blueprint/test_sources_parse.py`, `blueprint/test_suite_completeness.py`, `blueprint/test_doc_links_resolve.py`, `blueprint/test_no_hardcoded_credentials.py`, `blueprint/test_no_customer_data_in_deploy_scripts.py`

#### `platform` / `install` — 11 gates

`blueprint/test_catalog_bootstrap.py`, `blueprint/test_gitops_doors_agree.py`, `blueprint/test_install_verify_pairs.py`, `blueprint/test_foundation_doors_agree.py`, `blueprint/test_release_verify_script.py`, `blueprint/test_helm_payload_packaging.py`, `blueprint/test_job_delivery_paths_agree.py`, `blueprint/test_observability_extras.py`, `blueprint/test_rafay_helm_blueprint_preserve.py`, `blueprint/test_web_watchdog_cronjob.py`, `blueprint/test_ops_hook_loader_suppress_retry.py`

#### `platform` / `api` — 16 gates

`api/test_list_servers_missing_role.py`, `api/test_register_server_upsert_omission.py`, `api/test_outcomes.py`, `api/test_core_routing.py`, `api/test_dedup_thread_safety.py`, `api/test_door_http.py`, `api/test_server_job_results.py`, `api/test_no_nautobot_dependency.py`, `api/test_shared_constants_single_source.py`, `api/test_tenant_deployed_tag_alias.py`, `api/test_job_references_exist.py`, `api/test_postman_collection_matches_routes.py`, `api/test_cli_client_end_to_end.py`, `api/test_openapi_matches_routes.py`, `api/test_mock_nautobot_http.py`, `api/test_cli_client_wait_for.py`

#### `blueprint` / `intake` — 14 gates

`intake/test_identify_topology.py`, `intake/test_topology_api.py`, `intake/test_topology_gate_dc_up.py`, `intake/test_topology_from_diagram.py`, `intake/test_network_configuration.py`, `intake/test_door_verdict_on_v2.py`, `intake/test_workbook_evidence.py`, `intake/test_requirements_docs_current.py`, `intake/test_structural_roles_and_uplinks.py`, `blueprint/test_configuration_to_blueprint.py`, `intake/test_requirements_sheet.py`, `intake/test_rack_layout.py`, `intake/test_default_layout_end_to_end.py`, `intake/test_oob_cabling_proposal.py`

#### `blueprint` / `generate-verify` — 31 gates

`blueprint/test_blueprint_consistency.py`, `blueprint/test_designs_match.py`, `blueprint/test_nspine_clos.py`, `blueprint/test_foundation_closure.py`, `blueprint/test_gitops_rbac.py`, `blueprint/test_blueprint_schema_closure.py`, `blueprint/test_device_type_heights.py`, `blueprint/test_device_bays_reproducible.py`, `blueprint/test_blueprint_round_trip.py`, `blueprint/test_shape_matrix.py`, `blueprint/test_committed_designs_regenerate.py`, `blueprint/test_plane_interface_policy.py`, `blueprint/test_rack_defaults_not_silent.py`, `blueprint/test_plane_objects_in_sot.py`, `blueprint/test_topology_page_regenerates.py`, `blueprint/test_supported_topologies_current.py`, `blueprint/test_blueprint_loader_copies_agree.py`, `blueprint/test_rails_schema.py`, `blueprint/test_rails_emission.py`, `blueprint/test_accelerator_standins.py`, `blueprint/test_blueprint_acceptance.py`, `blueprint/test_collapsed_designs.py`, `blueprint/test_topology_families.py`, `blueprint/test_xlsx_collapsed_family.py`, `blueprint/test_xlsx_collapsed_customer.py`, `blueprint/test_gitops_layout.py`, `blueprint/test_customer_data_repo.py`, `blueprint/test_xlsx_to_blueprint.py`, `blueprint/test_xlsx_second_customer.py`, `blueprint/test_minimal_blueprint.py`, `blueprint/test_second_site_acceptance.py`

#### `blueprint` / `brownfield` — 3 gates

`blueprint/test_brownfield_discovery.py`, `blueprint/test_bf_core_copies_agree.py`, `blueprint/test_brownfield_raw_roundtrip.py`

#### `substrate` / `substrate` — 14 gates

`blueprint/test_server_layer_ownership.py`, `blueprint/test_clos_bonded_server_cabling.py`, `blueprint/test_vm_index_stable.py`, `blueprint/test_server_builder_contract.py`, `blueprint/test_recover_substrate_behaviour.py`, `blueprint/test_server_builder_behaviour.py`, `blueprint/test_substrate_plan_golden.py`, `blueprint/test_substrate_plan_shell_safety.py`, `blueprint/test_backup_restore_agree.py`, `blueprint/test_backup_restore_behaviour.py`, `blueprint/test_attachment_order_contract.py`, `blueprint/test_vm_identity_derivations_agree.py`, `blueprint/test_collapsed_substrate.py`, `blueprint/test_mgmt_addressing.py`

#### `bringup` / `fabric` — 27 gates

`drift/test_drift_compare.py`, `blueprint/test_deploy_device_network_resilience.py`, `blueprint/test_deploy_device_retry.py`, `blueprint/test_roce_intent.py`, `blueprint/test_readonly_verify_safety.py`, `blueprint/test_template_tree_resolver.py`, `blueprint/test_device_record_tab_safety.py`, `blueprint/test_seed_restarts_stale_connections.py`, `blueprint/test_provision_site_approve_env.py`, `blueprint/test_approve_mode_default.py`, `blueprint/test_shared_nvcm_endpoints.py`, `blueprint/test_rail_manifests.py`, `blueprint/test_deploy_concurrency.py`, `blueprint/test_device_lock.py`, `blueprint/test_never_configured_switch.py`, `blueprint/test_context_ownership_doors_agree.py`, `render/test_emitted_context_is_rendered.py`, `blueprint/test_verify_layers_atomic_snapshot.py`, `blueprint/test_provision_preserves_day2_keys.py`, `blueprint/test_audit_trail_persistent.py`, `render/test_collapsed_render.py`, `blueprint/test_batch_mode_r0.py`, `blueprint/test_batch_mode_r1.py`, `blueprint/test_configure_devices_reliability.py`, `blueprint/test_configure_devices_invariants.py`, `render/render_test.py`, `render/blueprint_render_test.py`

#### `bringup` / `tenants` — 45 gates

`allocations/test_allocations.py`, `ib/test_ib_render.py`, `ib/test_ib_provision.py`, `blueprint/test_allocations_policy_equivalence.py`, `blueprint/test_tenant_names.py`, `blueprint/test_tenant_create_delete_cli.py`, `blueprint/test_tenant_create_cli_pins.py`, `blueprint/test_tenant_lifecycle_resolve.py`, `blueprint/test_tenant_lifecycle_run_refusal.py`, `blueprint/test_tenant_lifecycle_batch_delete.py`, `blueprint/test_tenant_backfill_numbers_cli.py`, `blueprint/test_tenant_list_get_cli.py`, `blueprint/test_tenant_rollback_batch.py`, `blueprint/test_sync_ipam_delete_order.py`, `blueprint/test_tenant_run_locked_integration.py`, `blueprint/test_tenant_alias_aware_hook_consistency.py`, `blueprint/test_tenant_workflow_reap.py`, `blueprint/test_tenant_list_job.py`, `blueprint/test_tenant_details_shape.py`, `blueprint/test_tenant_get_detail_cli.py`, `blueprint/test_tenant_get_job.py`, `blueprint/test_tenant_number_of_name_first.py`, `blueprint/test_tenant_create_capacity_refusal_cli.py`, `blueprint/test_check_site_readiness_dual_layout.py`, `blueprint/test_tenant_held_gate_queue_depth.py`, `blueprint/test_tenant_offboard_server_guard.py`, `blueprint/test_tenant_delete_server_refusal_cli.py`, `blueprint/test_tenant_delete_batch_cli.py`, `blueprint/test_tenant_policy_mismatch_refusal.py`, `blueprint/test_tenant_v2_network_overrides.py`, `blueprint/test_reconcile_refusal_detection.py`, `blueprint/test_reconcile_atomic_rollback.py`, `blueprint/test_tenant_core_equivalence.py`, `blueprint/test_policy_write_once_guard.py`, `blueprint/test_edge_map_derivation.py`, `blueprint/test_op_script_config.py`, `blueprint/test_backfill_mgmt_guard.py`, `blueprint/test_shared_vrfs_l8.py`, `blueprint/test_ib_lifecycle_fold.py`, `blueprint/test_storage_plane.py`, `blueprint/test_storage_plane_wiring.py`, `blueprint/test_reconcile_dry_run.py`, `blueprint/test_tenant_scope_from_blueprint.py`, `blueprint/test_collapsed_tenant_engine.py`, `blueprint/test_overlay_isolation_at_scale.py`

#### `bringup` / `servers` — 23 gates

`blueprint/test_server_rollback_single_device.py`, `blueprint/test_server_consistency.py`, `blueprint/test_server_consistency_cli.py`, `blueprint/test_server_backfill_host_ip_cli.py`, `blueprint/test_server_ib_membership.py`, `blueprint/test_server_params.py`, `blueprint/test_server_core_extraction.py`, `blueprint/test_server_validations.py`, `blueprint/test_server_register_availability_unregister_cli.py`, `blueprint/test_server_availability_unregister_job.py`, `blueprint/test_server_attach_detach_preconditions_job.py`, `blueprint/test_server_attach_detach_cli.py`, `blueprint/test_server_verbatim_input.py`, `blueprint/test_server_list_get_cli.py`, `blueprint/test_server_register_devicetype_casing.py`, `blueprint/test_server_uuid_of_injection.py`, `blueprint/test_server_register_bonded_node_cli.py`, `blueprint/test_server_cli_refusal_exit_code.py`, `blueprint/test_server_attach_tenant_alias.py`, `blueprint/test_server_deploy_time_budget.py`, `blueprint/test_netplan_tagged_plane.py`, `blueprint/test_server_guidance_never_fails.py`, `blueprint/test_gpu_allocation_jobs.py`

#### `bringup` / `day2` — 6 gates

`blueprint/test_backup_dc_behaviour.py`, `blueprint/test_restore_dc_behaviour.py`, `blueprint/test_replicate_dc_behaviour.py`, `blueprint/test_recovery_no_silent_noop.py`, `blueprint/test_switch_restore_conversion.py`, `blueprint/test_undeploy_teardown_self_sufficient.py`

The `blueprint` / `generate-verify` group also runs `@preflight` (`verify_blueprint.sh` on `stc/blueprint_stc.yaml`, tenants `3-100`).

## 5. Behaviour and reporting

- **Pass / skip / fail** follow `run-tests.sh` exactly. `DC_REQUIRE_ALL_GATES=1` is always set, so a gate
  that skips fails the group: a green group must have actually run every check.
- **One run = one POC commit.** The `plan` job resolves the branch to a SHA, and every group checks out that
  SHA, so groups can't test different commits if the branch moves during the run.
- **Results:** the run graph has one row per group, and the step summary has a gate × status × seconds table
  per group plus a phase total. Each group uploads its logs and `results.tsv` as an artifact (30-day
  retention, like `_phase.yml`).
- **Timeouts:** 30 min per group as a first estimate. Step 1 of the rollout measures real timings and adjusts it.

## 6. Files to add

```
.github/workflows/_unit.yml              reusable: plan (coverage + matrix) → test (per group) → summary
.github/workflows/unit-common.yml        caller, phase=common
.github/workflows/unit-platform.yml      caller, phase=platform
.github/workflows/unit-blueprint.yml     caller, phase=blueprint
.github/workflows/unit-substrate.yml     caller, phase=substrate
.github/workflows/unit-bringup.yml       caller, phase=bringup
config/unit-tests.sh                     the manifest (§4.1)
scripts/run-unit-tests.sh                groups | list | coverage | run
```

## 7. Rollout

1. **Baseline locally.** On a Linux box with bash 5, run the full `run-tests.sh` against
   `POC_DEFAULT_BRANCH`. Record which gates pass and how long each takes, and fix the group timeouts from that.
   Then run each group alone through `run-unit-tests.sh run` and confirm that each group gives the same
   result in isolation as in the full suite (this checks for order dependencies).
2. **Manifest and runner.** Add `config/unit-tests.sh` and `scripts/run-unit-tests.sh`, plus the manifest
   self-test (in `_unit.yml`'s plan job).
3. **One workflow end to end.** Add `_unit.yml` and `unit-substrate.yml` (the smallest phase, 14 gates) and
   run them manually.
4. **The rest.** Add the other 4 callers and run each one manually against the same POC SHA. The union of
   their results must equal step 1's full-suite result.
5. **Docs.** Update the README, Dev_Guide and User_Guide tables.
6. **Optional, later (§8).** Nightly schedule, a pre-flight gate in front of lab runs, and dashboard integration.

## 8. Later options (not in the first cut)

- **Pre-flight before a lab run:** `nvcm-greenfield.yml` could call `unit-blueprint` (plus the others)
  before `boot`, so a red unit suite stops the run before it costs lab time. The `workflow_call` trigger in
  §3.5 already allows this.
- **Nightly:** uncomment `schedule:` in each caller.
- **Logs under `logs/`:** reuse `build-report.sh` / `commit-logs.sh` so unit runs appear on the dashboard.
- **A per-topology view:** a matrix over the families in `test/run-topology-tests.sh`, if per-family
  verdicts turn out to be useful.

## 9. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Granularity | **Per phase.** 5 workflows: `unit-common`, `unit-platform`, `unit-blueprint`, `unit-substrate`, `unit-bringup` |
| 2 | Hygiene gates | **Their own `unit-common` workflow**, so they run once |
| 3 | `day2` gates | They stay as a group under `unit-bringup` |
| 4 | Triggers | **`workflow_dispatch` + `workflow_call` only.** No schedule, and nothing is wired in front of the lab runs yet |
| 5 | New POC gates | **Strict.** `coverage` fails the run until the gate is placed in `config/unit-tests.sh` |
| — | Logs under `logs/` | Not committed. Results go to artifacts and the step summary only |

## 10. Verified locally (2026-10-12)

- `coverage` against the POC's `prototype_fixes` branch passes: 199 of 199 gates mapped. It fails as expected
  on a test copy of the POC that has one unmapped gate, one stale entry and a missing preflight.
- `groups` and `list` work for every phase, and unknown phases or groups are rejected. The manifest self-test
  step passes when run locally. `actionlint` and `shellcheck` are clean.
- `run common hygiene`: 9 of 9 passed. `run substrate substrate`: 11 passed, 2 skipped (macOS bash 3.2, as
  expected; this can't happen on `ubuntu-latest`), and **1 failed: `test_collapsed_substrate.py`**. It fails
  the same way when run directly in the POC with the suite env, so it is a POC-side failure on this Mac
  (Python 3.9.6, bash 3.2), not a runner problem. Recheck it on the first GitHub run (Python 3.12, bash 5).
