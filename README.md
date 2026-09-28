# rafay_nvcm_launchpad

GitHub Actions orchestration for the NVCM POC on the OCI lab host. This repo **orchestrates** the run. The
installation and bring-up logic stays in
[`rafay_nvcm_poc`](https://github.com/ramakrishna-rafay/rafay_nvcm_poc), which this repo never copies or
modifies. Every stage calls a documented `rafay_nvcm_poc` entry point on the OCI host.

```
Actions ─ OCI CLI ─▶ start instance ─▶ wait RUNNING + SSH + boot settled
        ─ SSH ─────▶ ~/launchpad/agent.sh prepare   (move old checkout aside, clone <branch> → ~/rafay_nvcm_poc)
                     for each stage:  agent.sh start → detached on the host; runner streams the log + polls
        ─ always ──▶ SOFTSTOP instance (unless shutdown_oci=false) ─▶ report: artifact + logs/YYYY/MM/DD commit
```

## Stages

Defined in [`config/stages.sh`](config/stages.sh). This file is the only place that maps a stage to a POC command.

| Stage | Job | Calls (in `rafay_nvcm_poc`) | Timeout |
|---|---|---|---|
| host-prep | platform | `deploy_scripts/platform/nvcm-host-prep.sh` | 45m |
| platform-install-1 | platform | `platform/platform_install.sh nvcm --yes` | 150m |
| platform-install-2 | platform | `platform/platform_install.sh rafay --platform-only --yes` | 60m |
| verify-platform | platform | `platform/verify_platform_install.sh all` | 20m |
| blueprint | site | `blueprint/xlsx_to_blueprint.py` (STC workbook → `blr-dc01`) + `verify_blueprint.sh` | 20m |
| substrate | site | `substrate/vm_image_operations.sh fetch` + `simulate_dc.sh --apply --from substrate --to substrate` | 120m |
| dc-bringup | bringup | `simulate_dc.sh --apply --auto-approve --from underlay --to accept` | 300m |

To add a stage, add one `name:phase:minutes` line and a `stage_<name>` function to `config/stages.sh`.
Each phase is its own job because GitHub-hosted jobs are capped at 6 hours. Keep each phase's timeouts
under about 340 minutes in total. The timeouts above are estimates. Tune them after the first real runs.

## Running

**Actions → nvcm-e2e → Run workflow**

| Input | Default | |
|---|---|---|
| `poc_branch` | `main` | the `rafay_nvcm_poc` branch to clone and run |
| `stages` | `all` | or a comma list, for example `blueprint,substrate,dc-bringup` to rerun only the DC part on an installed platform |
| `blueprint_source` | `generated` | `committed` uses `stc/blueprint_stc.yaml` instead of this run's generated blueprint |
| `tenants` | `3-11,84-100` | passed to `simulate_dc.sh --tenants` |
| `shutdown_oci` | ✔ | untick to leave the instance up for debugging |

Only one run can be active at a time. A second run waits in the queue and does not cancel the first.
GitHub keeps only one pending run, so a third trigger replaces the queued one.
Scheduled runs are included but commented out in the workflow.

## Setup (one time)

**1. Repository variables** (Settings → Secrets and variables → Actions → Variables)

| Variable | Example / default |
|---|---|
| `OCI_INSTANCE_ID` | `ocid1.instance.oc1...` (required) |
| `OCI_SSH_USER` | `ubuntu` |
| `OCI_SSH_HOST` | optional. By default the instance's public IP is looked up each run, because ephemeral IPs change on restart |
| `OCI_SSH_KNOWN_HOSTS` | recommended: `ssh-keyscan <host>` output. This pins the host key. Without it the key is trusted on first use and the workflow logs a warning |
| `POC_REPO` | `ramakrishna-rafay/rafay_nvcm_poc` |
| `POC_DEFAULT_BRANCH` | `main` (used by scheduled runs) |
| `LAB_OCI_IP` | optional value for `simulate_dc.sh --oci`. Defaults to the host's primary private IP |

**2. Repository secrets**

| Secret | What |
|---|---|
| `OCI_CLI_USER`, `OCI_CLI_TENANCY`, `OCI_CLI_FINGERPRINT`, `OCI_CLI_REGION` | OCI API-key auth |
| `OCI_CLI_KEY_CONTENT` | the API signing private key (PEM) |
| `OCI_SSH_PRIVATE_KEY` | SSH key authorized on the lab host |
| `POC_DEPLOY_KEY` | private half of a **read-only deploy key** on `rafay_nvcm_poc` (see step 3) |

Give the OCI user the least privilege needed: `use instance-family` (start, stop, read) and `read vnics` on
the lab compartment only.

**3. Access to the private POC repo: a read-only deploy key**

`GITHUB_TOKEN` cannot be used. It is scoped to the repository whose workflow is running, even when both
repos have the same owner. `rafay_nvcm_poc` is also owned by a personal account, so a fine-grained PAT would
have to be created by that account's owner. A deploy key is the least-privileged option: read-only and
limited to one repo. Adding one changes a repo *setting*, not any repo content.

```bash
ssh-keygen -t ed25519 -N '' -C rafay_nvcm_launchpad -f poc_deploy_key
# rafay_nvcm_poc → Settings → Deploy keys → Add: poc_deploy_key.pub, "Allow write access" UNTICKED (needs repo admin)
# rafay_nvcm_launchpad → secret POC_DEPLOY_KEY = contents of poc_deploy_key
```

The key is forwarded to the host over `ssh -A` for the clone command only, so it is never written to the
host's disk.

**4. Lab host requirements**

- Passwordless `sudo` for `OCI_SSH_USER` (host prep and substrate need it). The preflight step checks this.
- Port 22 reachable from GitHub-hosted runners. If the security list must stay closed, use a self-hosted
  runner inside the VCN and change `runs-on`.

## Cleanup semantics (read before relying on "clean state")

At the start of every run, the existing `~/rafay_nvcm_poc` is **moved** to `~/launchpad/previous-clones/`
(the newest 5 are kept) and a fresh clone of the requested branch replaces it. Files in `PRESERVE_FILES`
(currently the gitignored `deploy_scripts/params-secrets.env`) are carried into the new clone. Run
workspaces are kept under `~/launchpad/runs/<run_id>-<attempt>/` (the newest 14).

The installed state is **not** reset. The kind cluster, NVCM, the Rafay chart, and the lab VMs are left as
they are, and the POC scripts are idempotent against them. A deeper reset belongs to `rafay_nvcm_poc`
(for example `undeploy_site.sh --apply --destroy-substrate`). To make that part of the run, add it as a
stage once the team agrees it is safe.

## Failures, timeouts, logs

- Each stage runs **detached on the host** (`setsid` + its own `timeout`). An SSH drop or the handoff
  between jobs does not kill it. The runner reconnects and keeps streaming. It gives up only after about
  10 minutes without contact.
- The first failed stage stops the pipeline. Later stages are recorded as `skipped`. Host diagnostics
  (pods, events, VMs, disk) are captured. The workflow fails from that stage's job, so the report and
  power-off steps never hide the failure.
- `poweroff` and `report` use `always()` and run after a success, a failure, or a cancellation. The
  instance is stopped even if it was already running before the run started. The report records that.
- Logs are kept in two places. The `logs-*` and `run-report` artifacts hold the raw logs for 30 and 90
  days. A commit under `logs/<yyyy>/<mm>/<dd>/<HHMMSS>Z-run<id>.<attempt>-<STATUS>/` holds the per-stage
  logs, `summary.md`, and `summary.json`. Files over 20 MB are gzipped in the commit.
- `summary.json` is the contract for future notifiers such as email, a shared drive, or Slack. Add them as
  steps at the end of the `report` job. `scripts/commit-logs.sh` is the one piece to replace if logs move
  to external storage.

## Layout

```
.github/workflows/nvcm-e2e.yml    entry: inputs, concurrency, boot → phases → poweroff → report
.github/workflows/_phase.yml      reusable: one phase of stages
.github/workflows/ci.yml          lint on push/PR: shellcheck, syntax, actionlint — no OCI, no secrets
.github/actions/lab-access/       OCI CLI config + ssh-agent (keys never touch the workspace)
config/stages.sh                  the stage catalogue (the only POC-specific knowledge here)
remote/agent.sh                   runs ON the host: preflight, prepare/clone, detached stage runner, diag
scripts/lab.sh                    runner: OCI power (start/stop/state), SSH connect + readiness
scripts/run-stages.sh             runner: drive a phase, stream logs, record status.tsv
scripts/build-report.sh           merge job logs → summary.md / summary.json
scripts/commit-logs.sh            dated commit of the report
```
