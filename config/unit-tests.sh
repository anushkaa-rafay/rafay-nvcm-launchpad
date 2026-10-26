# shellcheck shell=bash
#
# unit-tests.sh — the UNIT-TEST manifest: which rafay_nvcm_poc offline gate runs in which unit workflow.
# Read by scripts/run-unit-tests.sh only (on the GitHub runner — never on a lab host). See Unit_Tests_Plan.md.
#
# RULE: the gates themselves live in rafay_nvcm_poc/test/ and are listed by its test/run-tests.sh — that suite
# stays the authority. This file only PLACES each gate in a phase + group; it never copies test code.
#
# Entry format  "phase:group:path"  — path relative to the rafay_nvcm_poc checkout. Order = run order inside
# the group (kept in run-tests.sh's relative order). `@preflight` is the verify_blueprint.sh block run-tests.sh
# runs inline (it isn't a python file).
#   phase  = unit-tests.yml's `phase` input: common | platform | blueprint | substrate | bringup  (or all of them)
#            — the launchpad phases of config/stages-*.sh, plus `common` for repo-wide hygiene gates
#   group  = one parallel matrix job of a unit-tests.yml run (a `phase · group` row in its run graph)
#
# ADDING A GATE: one line below, under the phase whose stage runs the code it tests (test/README.md's
# "Primary inputs" column). Forget it and every unit run fails `run-unit-tests.sh coverage` — on purpose:
# a gate rafay_nvcm_poc runs but no unit workflow does would otherwise go quietly untested here.

# shellcheck disable=SC2034  # consumed by scripts/run-unit-tests.sh
LAUNCHPAD_UNIT_PHASES=(common platform blueprint substrate bringup)

# shellcheck disable=SC2034
LAUNCHPAD_UNIT_TESTS=(
  # ── common / hygiene (9) — repo-wide invariants — gate index, completeness, doc links, no credentials / customer data
  common:hygiene:test/blueprint/test_script_path_refs_resolve.py
  common:hygiene:test/blueprint/test_gate_index_complete.py
  common:hygiene:test/blueprint/test_jobs_undefined_names.py
  common:hygiene:test/blueprint/test_axis_a_no_customer_values.py
  common:hygiene:test/blueprint/test_sources_parse.py
  common:hygiene:test/blueprint/test_suite_completeness.py
  common:hygiene:test/blueprint/test_doc_links_resolve.py
  common:hygiene:test/blueprint/test_no_hardcoded_credentials.py
  common:hygiene:test/blueprint/test_no_customer_data_in_deploy_scripts.py
  # ── platform / install (11) — deploy_scripts/platform, charts/rafay-nvcm-stack, catalog bootstrap, release verify
  platform:install:test/blueprint/test_catalog_bootstrap.py
  platform:install:test/blueprint/test_gitops_doors_agree.py
  platform:install:test/blueprint/test_install_verify_pairs.py
  platform:install:test/blueprint/test_foundation_doors_agree.py
  platform:install:test/blueprint/test_release_verify_script.py
  platform:install:test/blueprint/test_helm_payload_packaging.py
  platform:install:test/blueprint/test_job_delivery_paths_agree.py
  platform:install:test/blueprint/test_observability_extras.py
  platform:install:test/blueprint/test_rafay_helm_blueprint_preserve.py
  platform:install:test/blueprint/test_web_watchdog_cronjob.py
  platform:install:test/blueprint/test_ops_hook_loader_suppress_retry.py
  # ── platform / api (16) — deploy_scripts/api — the REST door shipped with the Rafay layer
  platform:api:test/api/test_list_servers_missing_role.py
  platform:api:test/api/test_register_server_upsert_omission.py
  platform:api:test/api/test_outcomes.py
  platform:api:test/api/test_core_routing.py
  platform:api:test/api/test_dedup_thread_safety.py
  platform:api:test/api/test_door_http.py
  platform:api:test/api/test_server_job_results.py
  platform:api:test/api/test_no_nautobot_dependency.py
  platform:api:test/api/test_shared_constants_single_source.py
  platform:api:test/api/test_tenant_deployed_tag_alias.py
  platform:api:test/api/test_job_references_exist.py
  platform:api:test/api/test_postman_collection_matches_routes.py
  platform:api:test/api/test_cli_client_end_to_end.py
  platform:api:test/api/test_openapi_matches_routes.py
  platform:api:test/api/test_mock_nautobot_http.py
  platform:api:test/api/test_cli_client_wait_for.py
  # ── blueprint / intake (14) — deploy_scripts/intake — workbook / diagram → configuration
  blueprint:intake:test/intake/test_identify_topology.py
  blueprint:intake:test/intake/test_topology_api.py
  blueprint:intake:test/intake/test_topology_gate_dc_up.py
  blueprint:intake:test/intake/test_topology_from_diagram.py
  blueprint:intake:test/intake/test_network_configuration.py
  blueprint:intake:test/intake/test_door_verdict_on_v2.py
  blueprint:intake:test/intake/test_workbook_evidence.py
  blueprint:intake:test/intake/test_requirements_docs_current.py
  blueprint:intake:test/intake/test_structural_roles_and_uplinks.py
  blueprint:intake:test/blueprint/test_configuration_to_blueprint.py
  blueprint:intake:test/intake/test_requirements_sheet.py
  blueprint:intake:test/intake/test_rack_layout.py
  blueprint:intake:test/intake/test_default_layout_end_to_end.py
  blueprint:intake:test/intake/test_oob_cabling_proposal.py
  # ── blueprint / generate-verify (31 + preflight) — blueprint.py, site_designs.py, xlsx_to_blueprint, verify_blueprint.sh
  blueprint:generate-verify:test/blueprint/test_blueprint_consistency.py
  blueprint:generate-verify:test/blueprint/test_designs_match.py
  blueprint:generate-verify:test/blueprint/test_nspine_clos.py
  blueprint:generate-verify:test/blueprint/test_foundation_closure.py
  blueprint:generate-verify:test/blueprint/test_gitops_rbac.py
  blueprint:generate-verify:test/blueprint/test_blueprint_schema_closure.py
  blueprint:generate-verify:test/blueprint/test_device_type_heights.py
  blueprint:generate-verify:test/blueprint/test_device_bays_reproducible.py
  blueprint:generate-verify:test/blueprint/test_blueprint_round_trip.py
  blueprint:generate-verify:test/blueprint/test_shape_matrix.py
  blueprint:generate-verify:test/blueprint/test_committed_designs_regenerate.py
  blueprint:generate-verify:test/blueprint/test_plane_interface_policy.py
  blueprint:generate-verify:test/blueprint/test_rack_defaults_not_silent.py
  blueprint:generate-verify:test/blueprint/test_plane_objects_in_sot.py
  blueprint:generate-verify:test/blueprint/test_topology_page_regenerates.py
  blueprint:generate-verify:test/blueprint/test_supported_topologies_current.py
  blueprint:generate-verify:test/blueprint/test_blueprint_loader_copies_agree.py
  blueprint:generate-verify:test/blueprint/test_rails_schema.py
  blueprint:generate-verify:test/blueprint/test_rails_emission.py
  blueprint:generate-verify:test/blueprint/test_accelerator_standins.py
  blueprint:generate-verify:test/blueprint/test_blueprint_acceptance.py
  blueprint:generate-verify:test/blueprint/test_collapsed_designs.py
  blueprint:generate-verify:test/blueprint/test_topology_families.py
  blueprint:generate-verify:test/blueprint/test_xlsx_collapsed_family.py
  blueprint:generate-verify:test/blueprint/test_xlsx_collapsed_customer.py
  blueprint:generate-verify:test/blueprint/test_gitops_layout.py
  blueprint:generate-verify:test/blueprint/test_customer_data_repo.py
  blueprint:generate-verify:test/blueprint/test_xlsx_to_blueprint.py
  blueprint:generate-verify:test/blueprint/test_xlsx_second_customer.py
  blueprint:generate-verify:test/blueprint/test_minimal_blueprint.py
  blueprint:generate-verify:test/blueprint/test_second_site_acceptance.py
  blueprint:generate-verify:@preflight
  # ── blueprint / brownfield (3) — onboarding/brownfield bf_core.py — discovery → blueprint
  blueprint:brownfield:test/blueprint/test_brownfield_discovery.py
  blueprint:brownfield:test/blueprint/test_bf_core_copies_agree.py
  blueprint:brownfield:test/blueprint/test_brownfield_raw_roundtrip.py
  # ── substrate / substrate (14) — plan_substrate.py, deploy_*_vms.sh, recover_substrate.sh, substrate backup
  substrate:substrate:test/blueprint/test_server_layer_ownership.py
  substrate:substrate:test/blueprint/test_clos_bonded_server_cabling.py
  substrate:substrate:test/blueprint/test_vm_index_stable.py
  substrate:substrate:test/blueprint/test_server_builder_contract.py
  substrate:substrate:test/blueprint/test_recover_substrate_behaviour.py
  substrate:substrate:test/blueprint/test_server_builder_behaviour.py
  substrate:substrate:test/blueprint/test_substrate_plan_golden.py
  substrate:substrate:test/blueprint/test_substrate_plan_shell_safety.py
  substrate:substrate:test/blueprint/test_backup_restore_agree.py
  substrate:substrate:test/blueprint/test_backup_restore_behaviour.py
  substrate:substrate:test/blueprint/test_attachment_order_contract.py
  substrate:substrate:test/blueprint/test_vm_identity_derivations_agree.py
  substrate:substrate:test/blueprint/test_collapsed_substrate.py
  substrate:substrate:test/blueprint/test_mgmt_addressing.py
  # ── bringup / fabric (27) — provision_site / configure_devices / seed_site_jobs, deploy + lock, render goldens, verify, drift
  bringup:fabric:test/drift/test_drift_compare.py
  bringup:fabric:test/blueprint/test_deploy_device_network_resilience.py
  bringup:fabric:test/blueprint/test_deploy_device_retry.py
  bringup:fabric:test/blueprint/test_roce_intent.py
  bringup:fabric:test/blueprint/test_readonly_verify_safety.py
  bringup:fabric:test/blueprint/test_template_tree_resolver.py
  bringup:fabric:test/blueprint/test_device_record_tab_safety.py
  bringup:fabric:test/blueprint/test_seed_restarts_stale_connections.py
  bringup:fabric:test/blueprint/test_provision_site_approve_env.py
  bringup:fabric:test/blueprint/test_approve_mode_default.py
  bringup:fabric:test/blueprint/test_shared_nvcm_endpoints.py
  bringup:fabric:test/blueprint/test_rail_manifests.py
  bringup:fabric:test/blueprint/test_deploy_concurrency.py
  bringup:fabric:test/blueprint/test_device_lock.py
  bringup:fabric:test/blueprint/test_never_configured_switch.py
  bringup:fabric:test/blueprint/test_context_ownership_doors_agree.py
  bringup:fabric:test/render/test_emitted_context_is_rendered.py
  bringup:fabric:test/blueprint/test_verify_layers_atomic_snapshot.py
  bringup:fabric:test/blueprint/test_provision_preserves_day2_keys.py
  bringup:fabric:test/blueprint/test_audit_trail_persistent.py
  bringup:fabric:test/render/test_collapsed_render.py
  bringup:fabric:test/blueprint/test_batch_mode_r0.py
  bringup:fabric:test/blueprint/test_batch_mode_r1.py
  bringup:fabric:test/blueprint/test_configure_devices_reliability.py
  bringup:fabric:test/blueprint/test_configure_devices_invariants.py
  bringup:fabric:test/render/render_test.py
  bringup:fabric:test/render/blueprint_render_test.py
  # ── bringup / tenants (45) — allocations.py, tenant lifecycle Jobs + tenant_operations.sh, InfiniBand, storage plane
  bringup:tenants:test/allocations/test_allocations.py
  bringup:tenants:test/ib/test_ib_render.py
  bringup:tenants:test/ib/test_ib_provision.py
  bringup:tenants:test/blueprint/test_allocations_policy_equivalence.py
  bringup:tenants:test/blueprint/test_tenant_names.py
  bringup:tenants:test/blueprint/test_tenant_create_delete_cli.py
  bringup:tenants:test/blueprint/test_tenant_create_cli_pins.py
  bringup:tenants:test/blueprint/test_tenant_lifecycle_resolve.py
  bringup:tenants:test/blueprint/test_tenant_lifecycle_run_refusal.py
  bringup:tenants:test/blueprint/test_tenant_lifecycle_batch_delete.py
  bringup:tenants:test/blueprint/test_tenant_backfill_numbers_cli.py
  bringup:tenants:test/blueprint/test_tenant_list_get_cli.py
  bringup:tenants:test/blueprint/test_tenant_rollback_batch.py
  bringup:tenants:test/blueprint/test_sync_ipam_delete_order.py
  bringup:tenants:test/blueprint/test_tenant_run_locked_integration.py
  bringup:tenants:test/blueprint/test_tenant_alias_aware_hook_consistency.py
  bringup:tenants:test/blueprint/test_tenant_workflow_reap.py
  bringup:tenants:test/blueprint/test_tenant_list_job.py
  bringup:tenants:test/blueprint/test_tenant_details_shape.py
  bringup:tenants:test/blueprint/test_tenant_get_detail_cli.py
  bringup:tenants:test/blueprint/test_tenant_get_job.py
  bringup:tenants:test/blueprint/test_tenant_number_of_name_first.py
  bringup:tenants:test/blueprint/test_tenant_create_capacity_refusal_cli.py
  bringup:tenants:test/blueprint/test_check_site_readiness_dual_layout.py
  bringup:tenants:test/blueprint/test_tenant_held_gate_queue_depth.py
  bringup:tenants:test/blueprint/test_tenant_offboard_server_guard.py
  bringup:tenants:test/blueprint/test_tenant_delete_server_refusal_cli.py
  bringup:tenants:test/blueprint/test_tenant_delete_batch_cli.py
  bringup:tenants:test/blueprint/test_tenant_policy_mismatch_refusal.py
  bringup:tenants:test/blueprint/test_tenant_v2_network_overrides.py
  bringup:tenants:test/blueprint/test_reconcile_refusal_detection.py
  bringup:tenants:test/blueprint/test_reconcile_atomic_rollback.py
  bringup:tenants:test/blueprint/test_tenant_core_equivalence.py
  bringup:tenants:test/blueprint/test_policy_write_once_guard.py
  bringup:tenants:test/blueprint/test_edge_map_derivation.py
  bringup:tenants:test/blueprint/test_op_script_config.py
  bringup:tenants:test/blueprint/test_backfill_mgmt_guard.py
  bringup:tenants:test/blueprint/test_shared_vrfs_l8.py
  bringup:tenants:test/blueprint/test_ib_lifecycle_fold.py
  bringup:tenants:test/blueprint/test_storage_plane.py
  bringup:tenants:test/blueprint/test_storage_plane_wiring.py
  bringup:tenants:test/blueprint/test_reconcile_dry_run.py
  bringup:tenants:test/blueprint/test_tenant_scope_from_blueprint.py
  bringup:tenants:test/blueprint/test_collapsed_tenant_engine.py
  bringup:tenants:test/blueprint/test_overlay_isolation_at_scale.py
  # ── bringup / servers (23) — server Jobs + server_operations.sh, netplan, GPU allocation
  bringup:servers:test/blueprint/test_server_rollback_single_device.py
  bringup:servers:test/blueprint/test_server_consistency.py
  bringup:servers:test/blueprint/test_server_consistency_cli.py
  bringup:servers:test/blueprint/test_server_backfill_host_ip_cli.py
  bringup:servers:test/blueprint/test_server_ib_membership.py
  bringup:servers:test/blueprint/test_server_params.py
  bringup:servers:test/blueprint/test_server_core_extraction.py
  bringup:servers:test/blueprint/test_server_validations.py
  bringup:servers:test/blueprint/test_server_register_availability_unregister_cli.py
  bringup:servers:test/blueprint/test_server_availability_unregister_job.py
  bringup:servers:test/blueprint/test_server_attach_detach_preconditions_job.py
  bringup:servers:test/blueprint/test_server_attach_detach_cli.py
  bringup:servers:test/blueprint/test_server_verbatim_input.py
  bringup:servers:test/blueprint/test_server_list_get_cli.py
  bringup:servers:test/blueprint/test_server_register_devicetype_casing.py
  bringup:servers:test/blueprint/test_server_uuid_of_injection.py
  bringup:servers:test/blueprint/test_server_register_bonded_node_cli.py
  bringup:servers:test/blueprint/test_server_cli_refusal_exit_code.py
  bringup:servers:test/blueprint/test_server_attach_tenant_alias.py
  bringup:servers:test/blueprint/test_server_deploy_time_budget.py
  bringup:servers:test/blueprint/test_netplan_tagged_plane.py
  bringup:servers:test/blueprint/test_server_guidance_never_fails.py
  bringup:servers:test/blueprint/test_gpu_allocation_jobs.py
  # ── bringup / day2 (6) — backup / restore / replicate DC, switch-config restore, undeploy
  bringup:day2:test/blueprint/test_backup_dc_behaviour.py
  bringup:day2:test/blueprint/test_restore_dc_behaviour.py
  bringup:day2:test/blueprint/test_replicate_dc_behaviour.py
  bringup:day2:test/blueprint/test_recovery_no_silent_noop.py
  bringup:day2:test/blueprint/test_switch_restore_conversion.py
  bringup:day2:test/blueprint/test_undeploy_teardown_self_sufficient.py
)
