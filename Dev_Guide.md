# Dev Guide

For anyone **modifying** this repo — adding a stage, changing a workflow, debugging the orchestration
itself. If you just want to run a workflow, see [`User_Guide.md`](User_Guide.md) instead.

## Architecture

```
Actions ─ OCI CLI ─▶ start instance ─▶ wait RUNNING + SSH + boot settled
        ─ SSH ─────▶ ~/launchpad/agent.sh prepare   (move old checkout aside, clone <branch> → ~/rafay_nvcm_poc)
                     for each stage:  agent.sh start → detached on the host; runner streams the log + polls
        ─ always ──▶ SOFTSTOP instance (unless shutdown_oci=false) ─▶ report: artifact + logs/<Mon-YYYY>/<DD-Mon-YYYY> commit
```

This repo **orchestrates**; it never contains installation logic. Every stage is an invocation of a
documented `rafay_nvcm_poc` entry point, executed on the OCI host over SSH — never on the GitHub runner,
and never reimplemented here. If a stage needs more than a few lines of glue, that glue is missing from
`rafay_nvcm_poc`, not something to build here.

**Why stages run detached on the host** (`setsid` + `nohup` + the stage's own `timeout`, in
`remote/agent.sh`): an SSH drop, or the hand-off between one GitHub job and the next, must never kill a
multi-hour install. The runner just reconnects and keeps polling/streaming; the host-side process doesn't
care whether anyone's watching.

**Why phases are separate jobs** (`platform` / `site` / `bringup`, each calling `_phase.yml`): GitHub-hosted
jobs are hard-capped at 6 hours. Splitting the pipeline into three jobs gives each phase its own fresh
budget. Keep each phase's *stage timeouts* summed under ~340 minutes so there's slack left for SSH/connect
overhead.

**Why one concurrency group across both workflows** (`nvcm-oci-lab`): both drive the *same physical OCI
host*. A greenfield run and a brownfield run must never execute simultaneously any more than two greenfield
runs should — a new run queues behind whichever is active, never cancels it.

## The four workflows, and which ones you actually run

| Workflow | Triggered how | Purpose |
|---|---|---|
| `nvcm-greenfield.yml` | `workflow_dispatch` — a person clicks Run | the real entry point for building a fabric from scratch |
| `nvcm-brownfield.yml` | `workflow_dispatch` — a person clicks Run | the real entry point for adopting an existing fabric |
| `_phase.yml` | `workflow_call` **only** — called by the two above, three times each | one phase (platform/site/bringup) of stages; exists so the phase logic (plan → lab access → connect → run stages → upload logs) is written once instead of duplicated 3×2 times |
| `ci.yml` | `push`/`pull_request`/manual | **not part of the OCI automation at all** — lints this repo's own scripts (shellcheck, `bash -n`, actionlint) and runs the stage-catalogue self-tests below. Never touches OCI, SSH, or any secret |

`_phase.yml` shows up in the Actions tab because GitHub lists every workflow file regardless of trigger
type — it has no meaningful "Run workflow" button of its own (its inputs are only meaningful when supplied
by a caller). That's expected, not a misconfiguration.

`ci.yml` is the one genuinely optional file here: delete it if you'd rather the Actions list only show the
two real entry points. Keeping it means a shell syntax error or a broken stage-name gets caught on a PR
instead of on a real (slow, shared) lab run.

## Layout

```
.github/workflows/nvcm-greenfield.yml   entry: inputs, boot → phases → poweroff → report (catalogue: stages-greenfield.sh)
.github/workflows/nvcm-brownfield.yml   entry: inputs, boot → phases → poweroff → report (catalogue: stages-brownfield.sh)
.github/workflows/_phase.yml            reusable: one phase of stages — shared by both, parameterized by `catalogue`
.github/workflows/ci.yml                lint on push/PR: shellcheck, syntax, both catalogues' self-tests, actionlint
.github/actions/lab-access/             OCI CLI config + ssh-agent (keys never touch the workspace)
config/common.sh                        the 4 platform stages, shared by both catalogues (SITE/TENANTS defaults too)
config/stages-greenfield.sh             greenfield-only stages (blueprint/substrate/dc-bringup) + LAUNCHPAD_STAGES
config/stages-brownfield.sh             brownfield-only stages (bf-discover/bf-blueprint/bf-adopt) + LAUNCHPAD_STAGES
remote/agent.sh                         runs ON the host: preflight, prepare/clone, detached stage runner, diag
scripts/lab.sh                          runner: OCI power (start/stop/state), SSH connect + readiness, pushes the selected catalogue
scripts/run-stages.sh                   runner: drive a phase (from $LAUNCHPAD_CATALOGUE), stream into the phase's workflow.log, record status.tsv
scripts/build-report.sh                 merge job logs → one workflow.log + summary.md / summary.json
scripts/commit-logs.sh                  commit the report under logs/<Mon-YYYY>/<DD-Mon-YYYY>/<run>/
scripts/lib-log.sh                      the log format + committed path, shared by the three above
tests/logging.sh                        self-test of that pipeline against a fake lab (run by ci.yml)
dashboard/                              Workflow Operations dashboard — static page over the Actions API (dashboard/README.md)
.github/workflows/dashboard.yml         dashboard tests on PR/push; opt-in GitHub Pages publish (no OCI, no secrets)
```

## The stage-catalogue system

Both onboarding modes need the identical bare NVCM+Nautobot platform before anything mode-specific happens,
so the four platform stages (`host-prep`, `platform-install-1`, `platform-install-2`, `verify-platform`) are
defined **once**, in `config/common.sh`, and sourced by both `config/stages-greenfield.sh` and
`config/stages-brownfield.sh`. Neither catalogue reimplements them.

`$LAUNCHPAD_CATALOGUE` (set as a job `env` by each workflow, and threaded through `_phase.yml`'s `catalogue`
input) is the only thing that switches `scripts/run-stages.sh`, `scripts/build-report.sh`, and
`scripts/lab.sh push-agent` between modes. On the host, whichever catalogue was selected is copied over as
the fixed name `~/launchpad/stages.sh` — `remote/agent.sh` always sources that one name, so it never needs
to know which mode is active.

### Greenfield catalogue (`config/stages-greenfield.sh`)

| Stage | Job | Calls (in `rafay_nvcm_poc`) | Timeout |
|---|---|---|---|
| host-prep | platform | `deploy_scripts/platform/nvcm-host-prep.sh` | 45m |
| platform-install-1 | platform | `platform/platform_install.sh nvcm --yes` | 150m |
| platform-install-2 | platform | `platform/platform_install.sh rafay --platform-only --yes` | 60m |
| verify-platform | platform | `platform/verify_platform_install.sh all` | 20m |
| blueprint | site | `blueprint/xlsx_to_blueprint.py` (STC workbook → `blr-dc01`) + `verify_blueprint.sh` | 20m |
| substrate | site | `substrate/vm_image_operations.sh fetch` + `simulate_dc.sh --apply --from substrate --to substrate` | 120m |
| dc-bringup | bringup | `simulate_dc.sh --apply --auto-approve --from underlay --to accept` | 300m |

### Brownfield catalogue (`config/stages-brownfield.sh`)

| Stage | Job | Calls (in `rafay_nvcm_poc`) | Timeout |
|---|---|---|---|
| host-prep | platform | `deploy_scripts/platform/nvcm-host-prep.sh` | 45m |
| platform-install-1 | platform | `platform/platform_install.sh nvcm --yes` | 150m |
| platform-install-2 | platform | `platform/platform_install.sh rafay --platform-only --yes` | 60m |
| verify-platform | platform | `platform/verify_platform_install.sh all` | 20m |
| bf-discover | site | `onboarding/brownfield/scripts/bf-onboard.sh discover` — **read-only** | 30m |
| bf-blueprint | site | `bf-onboard.sh blueprint` → `blueprint_<site>.yaml` — **read-only**, prints the blueprint for review | 20m |
| bf-adopt | bringup | `deploy_scripts/fabric/provision_site.sh --blueprint <discovered> --apply --auto-approve` — **the only write** | 240m |

Keep each catalogue's *stage timeouts summed per phase* under ~340 minutes — GitHub-hosted jobs are
hard-capped at 6 hours (see "Why phases are separate jobs" above); the timeouts here are estimates, tune
them after real runs.

**To add a stage:**

1. Pick the catalogue file (`stages-greenfield.sh` or `stages-brownfield.sh`) — or `common.sh` if it belongs
   to both modes.
2. Add one `name:phase:timeout_minutes` line to that file's `LAUNCHPAD_STAGES` array (order = execution
   order; phase must be `platform`, `site`, or `bringup`).
3. Add a `stage_<name>` function (dashes become underscores) whose body is an **invocation** of a
   documented `rafay_nvcm_poc` command — never new installation logic. If the underlying command's own
   readiness check can transiently fail right after a helm upgrade (pods still starting, not a real
   error — its own message usually says as much, e.g. "fix the [FAIL] lines above, then re-run"), wrap it in
   `common.sh`'s `lp_continue_if_not_ready "<description>" <cmd...>` rather than letting the stage fail on a
   timing fluke: it treats a matching "not ready yet" signal as non-fatal and continues (the operator's own
   call — pods just need more time, and a later stage re-checks full readiness once they've had it), while
   any other failure from the same command still propagates normally. See `stage_platform_install_1`/`_2`
   for the pattern.
4. Update the catalogue table above, and if you also changed a workflow input, its input table in
   `User_Guide.md` too.
5. Run the local validation below before pushing.

## Cleanup semantics (read before relying on "clean state")

At the start of every run (either workflow), the existing `~/rafay_nvcm_poc` is **moved** to
`~/launchpad/previous-clones/` (the newest 5 are kept) and a fresh clone of the requested branch replaces
it. Files in `PRESERVE_FILES` (currently the gitignored `deploy_scripts/params-secrets.env`) are carried
into the new clone. Run workspaces are kept under `~/launchpad/runs/<run_id>-<attempt>/` (the newest 14).

Brownfield's discovered blueprints live separately, under `~/launchpad/bf-discover/` — deliberately **not**
`bf-onboard.sh`'s own `/tmp` default, and **not** cleaned up by the policy above: a brownfield run spans two
workflow invocations (discover+blueprint, human review, then adopt) with the OCI instance stopped in
between by default (`shutdown_oci`), and `/tmp` on some cloud images is tmpfs — it would not survive that
power cycle. `~/launchpad/bf-discover/` is on the persistent home-directory filesystem.

The installed state is **not** reset by any of this. The kind cluster, NVCM, the Rafay chart, and the lab
VMs are left as they are, and the POC scripts are idempotent against them. A deeper reset belongs to
`rafay_nvcm_poc` (for example `undeploy_site.sh --apply --destroy-substrate`) — add it as a stage only once
the team agrees it's safe.

## Failures, timeouts, logs — the internals

- The first failed stage stops the pipeline; later stages in that run are recorded `skipped`.
- A stage that was **running** when the job itself died (cancelled, timed out, runner crashed) is recorded
  `interrupted`, not `skipped` — `scripts/build-report.sh` tells the two apart by checking whether that
  stage's `STAGE NN:` header was ever written to its phase's `workflow.log` (it is, the instant the stage
  starts, before any status row exists). Note an interrupted stage counts as the failed stage, so the run's
  status is `FAILED`; `CANCELLED` is a run cancelled between stages.
  Treat this distinction as load-bearing if you touch that script: collapsing it back to a blanket
  `skipped` silently hides exactly the stage that was actually running when something went wrong.
- Host diagnostics (pods, events, VMs, disk) are captured on any failure via `remote/agent.sh diag`.
- **One `workflow.log` per run, no per-stage log files.** Phases run in separate GitHub jobs, so no single
  file can stay open across them: each phase job's `run-stages.sh` writes its stages, in order, into that
  job's own `workflow.log` (header → verbatim output pulled from the host → result line → `STAGE STATUS`
  footer), and `build-report.sh` concatenates the phase logs in catalogue order. It also writes what a job
  could not: the footer of a stage the job died inside, and a stub section for every stage never reached.
  The format and the committed path (`logs/<Mon-YYYY>/<DD-Mon-YYYY>/<HHMMSS>Z-run<id>.<attempt>-<STATUS>/`,
  English month names whatever the locale) live in `scripts/lib-log.sh` only. `tests/logging.sh` exercises
  pass / fail / cancel / boot-failure end to end — run it after touching any of these scripts.
- `poweroff` and `report` jobs use `if: always()` and run after a success, a failure, or a cancellation —
  the instance is stopped even if it was already running before the run started (the report records that),
  and a report is always produced so a failure can never hide behind a job that never ran.
- `summary.json` (written by `build-report.sh`) is the stable contract for any future notifier — email, a
  shared drive, Slack. Add such a step at the end of the `report` job, reading that file; never parse the
  workflow's own state instead. `scripts/commit-logs.sh` is the one piece to replace if logs move to
  external storage.

## Validating a change locally, without touching OCI

Everything below runs in a plain `ubuntu:24.04` container — no lab access, no secrets, and it's exactly
what `ci.yml` runs on every push/PR. Run it before pushing a change to any script or workflow.

```bash
# from the repo root
docker run --rm -v "$PWD:/repo" -w /repo ubuntu:24.04 bash -ec '
  # 1) every script parses
  find scripts remote config tests -name "*.sh" -print0 | xargs -0 -n1 bash -n

  # 2) shellcheck, warning severity and above
  apt-get update -qq >/dev/null && apt-get install -qq -y shellcheck jq git >/dev/null
  shellcheck -x --severity=warning scripts/*.sh remote/*.sh config/*.sh tests/*.sh

  # 3) stage-selection logic, both catalogues — pure logic, no SSH
  for cat in config/stages-greenfield.sh config/stages-brownfield.sh; do
    echo "=== $cat ==="
    LAUNCHPAD_CATALOGUE=$cat scripts/run-stages.sh validate all
    LAUNCHPAD_CATALOGUE=$cat scripts/run-stages.sh plan platform all
  done

  # 4) log layout: run-stages → build-report → commit-logs against a fake lab
  tests/logging.sh
'

# 5) workflow YAML itself
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

For the brownfield review-gate logic specifically, the assertion worth re-running after any change to
`config/stages-brownfield.sh` or `scripts/run-stages.sh`:

```bash
# the default selection (bf-discover,bf-blueprint) must plan NOTHING for bringup —
# a regression here would silently skip the safety stop before any SoT write
[ -z "$(LAUNCHPAD_CATALOGUE=config/stages-brownfield.sh scripts/run-stages.sh plan bringup bf-discover,bf-blueprint)" ]
# the resume run (stages=bf-adopt) must still find it
[ "$(LAUNCHPAD_CATALOGUE=config/stages-brownfield.sh scripts/run-stages.sh plan bringup bf-adopt)" = "bf-adopt" ]
```

`ci.yml` runs all of this automatically; the commands above are for iterating locally before you push.

## Design decisions worth knowing before you touch these files

- **Values that reach the remote host over SSH are `%q`-escaped, not trusted to be space-free.** The
  brownfield workflow's free-text inputs (`device_type` defaults to `"Cumulus VX"` — a real space) are
  escaped with bash's `printf '%q'` before being joined into the single command string handed to
  `ssh -A lab "..."`. SSH sends that string as *one* argument; the remote shell parses it exactly once, so
  a value with an unescaped space would silently split into two words. Greenfield's equivalent values
  (`blueprint_source`, `tenants`) don't need this because they're already regex-validated to space-free
  charsets in the `Resolve + validate options` step — pick whichever guarantee is easier to keep true
  (tight validation, or `%q`) rather than assuming plain interpolation is safe.
- **Brownfield's `OUT` directory is `~/launchpad/bf-discover`, overriding `bf-onboard.sh`'s own `/tmp`
  default.** See "Cleanup semantics" above — this is the reason a real brownfield onboarding survives the
  gap between the discover+blueprint run and the reviewed adopt run.
- **The review gate is enforced by input defaults, not a technical lock.** Nothing stops someone from
  dispatching `nvcm-brownfield` with `stages=all` against a real DC. The safety is documentation + the
  default (`bf-discover,bf-blueprint`) stopping short of any write — if this ever needs to be a hard
  technical gate instead (e.g. a GitHub Environment with required reviewers), that's a real design change,
  not a bug fix.
- **`_phase.yml`'s `Run stages` step runs even when nothing is selected for that phase.** This is
  intentional — a resume run like `stages=bf-adopt` needs the `platform` and `site` phase jobs to execute
  and do nothing, rather than being skipped outright, so the job graph stays uniform across every stage
  selection.
- **`OCI_SSH_KNOWN_HOSTS` is rewritten to the alias `lab`, never stored keyed to the literal address it was
  captured against.** `scripts/lab.sh cmd_connect` sets `HostKeyAlias lab` and pipes the secret's content
  through `awk 'NF && $1 !~ /^#/ { $1="lab"; print }'` before appending it to `known_hosts`. Without this,
  pinning the host key to whatever address `ssh-keyscan` was run against would break the moment the
  instance's public IP changes — which is exactly the case `OCI_SSH_HOST` being left unset is meant to
  handle, since OCI's ephemeral public IP changes on restart. `HostKeyAlias` makes OpenSSH look the key up
  by the alias instead of the current connection address, so the pin survives an IP change; the `awk`
  filter also means a raw pasted `ssh-keyscan` transcript (comment lines included) works without manual
  cleanup. Verified by actually reproducing the failure (`Host key verification failed` when the known
  address and the connect address differ, no alias) and then the fix (`HostKeyAlias` + rewritten entries →
  connects successfully via a different address than the one the key was captured against) against a real
  sshd in a container — not just reasoned about.
- **Every `run:` step that pipes a command through `tee` starts with `set -o pipefail`.** A `run:` step
  with no explicit `shell:` key is **not** `bash -eo pipefail` by default — empirically confirmed (not
  assumed from docs, which are themselves inconsistent on this point): under plain `bash -e {0}`, a
  pipeline's exit status is `tee`'s (always 0), so a failing `scripts/lab.sh connect | tee -a ...` is
  silently swallowed and the script falls through to the *next* line — which was exactly how a malformed
  `OCI_CLI_USER` secret once surfaced as a baffling `ssh: Could not resolve hostname lab` from
  `push-agent`, instead of the real OCI CLI config error one line above it in the same log. Confirmed by
  running the identical two-line step under both candidate shell invocations against a fake failing `oci`
  binary: only the no-`pipefail` case reproduced the reported symptom exactly. `scripts/lab.sh start`'s
  single-line `run:` had the same gap in a worse form — that step would report *success* even though the
  instance never started. If you add a new `run:` step that pipes anything through `tee` (or any command
  whose failure matters, not just its last stage), it needs `set -o pipefail` first; don't assume GitHub
  Actions supplies it.
- **Jobs run strictly in sequence, and stop at the first failure.** `platform`/`site`/`bringup` each run
  only if every earlier phase succeeded (`if: !cancelled() && needs.<each>.result == 'success'`); after a
  failure (❌) the later phases show **skipped** (grey) in the run graph, and their stages ⚪ in the Step
  Summary. `poweroff` and `report` still run (`!cancelled()`). Every `if:` spells out its status function
  and the `needs.*.result` values it needs, on purpose: a job left on the *implicit* `success()` check can be
  wrongly skipped when any job further upstream was skipped (`actions/runner#2205`), and explicit conditions
  are that issue's documented workaround. (An earlier version never let a phase show `skipped` — it ran a
  no-op green job instead — blaming that bug for `poweroff` being skipped on 2026-09-29. The committed
  reports don't support it: `poweroff` was `skipped` on every run that day, including PASSED run
  36585500700 where nothing upstream was skipped, i.e. its own `shutdown_oci` condition was false.)
  Pass/fail per stage comes from `status.tsv`, not job results — a skipped phase's stages show `skipped`.
- **Every stage runs through `lp_run_stage` (`config/common.sh`), not called directly**, wired in
  `remote/agent.sh`'s generated stage script. If a stage fails with the apt/dpkg lock still held — cloud-init
  or `unattended-upgrades` running their own background `apt-get` right after boot is a common race any
  stage that shells out to `apt-get` (`host-prep`, `blueprint`, and potentially a future one) can lose — it
  retries the **whole stage**, up to `LP_RUN_STAGE_MAX_WAIT` seconds (default 600), rather than failing
  outright. Safe because every stage here is itself documented idempotent/re-runnable. Any other failure
  (not matching that exact signature) propagates immediately on the first attempt. This is wrapped centrally
  in the agent, not opt-in per stage like `lp_continue_if_not_ready` above — new stages get it automatically.
