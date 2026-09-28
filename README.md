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

## Two flows — greenfield and brownfield

`rafay_nvcm_poc` supports onboarding a data center two ways (its `onboarding/README.md` — "the front door" —
is the source of truth this mirrors), and this repo runs both as **two separate workflows**:

|  | [`nvcm-greenfield.yml`](.github/workflows/nvcm-greenfield.yml) | [`nvcm-brownfield.yml`](.github/workflows/nvcm-brownfield.yml) |
|---|---|---|
| **When** | nothing to preserve — build a fabric from scratch | a fabric already exists and is running — learn from it |
| **Trust direction** | trusts the SoT — push freely, no running config to protect | trusts the switch — the running config is truth; nothing is written until proven |
| **Catalogue** | [`config/stages-greenfield.sh`](config/stages-greenfield.sh) | [`config/stages-brownfield.sh`](config/stages-brownfield.sh) |
| **Source of intent** | an Excel workbook (`stc/STCS-GPUaaS_Network-Schema_v0.3.xlsx`) | the live fabric itself, read over NVUE REST/SSH |
| **rafay_nvcm_poc flow it mirrors** | `onboarding/greenfield/greenfield_adoption_plan.md` | `onboarding/brownfield/brownfield_adoption_plan.md` (`bf-onboard.sh`) |
| **Writes before review?** | yes — it's a blank lab, nothing to protect | **no** — discover + blueprint are read-only; only `bf-adopt` writes |

Both land on the exact same downstream: `deploy_scripts/fabric/provision_site.sh`. Both share every job,
script, and piece of host plumbing below (`_phase.yml`, `lab.sh`, `agent.sh`, `build-report.sh`,
`commit-logs.sh`, the `lab-access` action) — a `catalogue` input is the only thing that differs between the
two workflow calls. The four platform stages (`host-prep`, `platform-install-1`, `platform-install-2`,
`verify-platform`) are defined **once**, in [`config/common.sh`](config/common.sh), and sourced by both
catalogues — neither mode reimplements them, because both need the exact same bare NVCM+Nautobot platform
before anything mode-specific happens.

Both workflows share **one concurrency group** (`nvcm-oci-lab`): they drive the same physical OCI host, so a
greenfield run and a brownfield run can never overlap.

## Greenfield stages

| Stage | Job | Calls (in `rafay_nvcm_poc`) | Timeout |
|---|---|---|---|
| host-prep | platform | `deploy_scripts/platform/nvcm-host-prep.sh` | 45m |
| platform-install-1 | platform | `platform/platform_install.sh nvcm --yes` | 150m |
| platform-install-2 | platform | `platform/platform_install.sh rafay --platform-only --yes` | 60m |
| verify-platform | platform | `platform/verify_platform_install.sh all` | 20m |
| blueprint | site | `blueprint/xlsx_to_blueprint.py` (STC workbook → `blr-dc01`) + `verify_blueprint.sh` | 20m |
| substrate | site | `substrate/vm_image_operations.sh fetch` + `simulate_dc.sh --apply --from substrate --to substrate` | 120m |
| dc-bringup | bringup | `simulate_dc.sh --apply --auto-approve --from underlay --to accept` | 300m |

**Actions → nvcm-greenfield → Run workflow**

| Input | Default | |
|---|---|---|
| `poc_branch` | `main` | the `rafay_nvcm_poc` branch to clone and run |
| `stages` | `all` | or a comma list, for example `blueprint,substrate,dc-bringup` to rerun only the DC part on an installed platform |
| `blueprint_source` | `generated` | `committed` uses `stc/blueprint_stc.yaml` instead of this run's generated blueprint |
| `tenants` | `3-11,84-100` | passed to `simulate_dc.sh --tenants` |
| `shutdown_oci` | ✔ | untick to leave the instance up for debugging |

## Brownfield stages

| Stage | Job | Calls (in `rafay_nvcm_poc`) | Timeout |
|---|---|---|---|
| host-prep | platform | `deploy_scripts/platform/nvcm-host-prep.sh` | 45m |
| platform-install-1 | platform | `platform/platform_install.sh nvcm --yes` | 150m |
| platform-install-2 | platform | `platform/platform_install.sh rafay --platform-only --yes` | 60m |
| verify-platform | platform | `platform/verify_platform_install.sh all` | 20m |
| bf-discover | site | `onboarding/brownfield/scripts/bf-onboard.sh discover` — **read-only** | 30m |
| bf-blueprint | site | `bf-onboard.sh blueprint` → `blueprint_<site>.yaml` — **read-only**, prints the blueprint for review | 20m |
| bf-adopt | bringup | `deploy_scripts/fabric/provision_site.sh --blueprint <discovered> --apply --auto-approve` — **the only write** | 240m |

**Actions → nvcm-brownfield → Run workflow**

| Input | Default | |
|---|---|---|
| `poc_branch` | `main` | the `rafay_nvcm_poc` branch to clone and run |
| `stages` | `bf-discover,bf-blueprint` | stops **before** any write — see "The review gate" below. `all` or a comma list, same convention as greenfield |
| `discover_mode` | `virtual` | `virtual` = the simulated VMs already on this lab host (via `virsh`); `real` = physical switches, needs `seed` |
| `seed` | *(empty)* | `real` mode only — management IPs/hostnames to discover, one per line |
| `site` | `blr-dc01` | the discovered site's name |
| `location` | *(empty)* | blank carries `policy_from`'s own location chain |
| `device_type` | `Cumulus VX` | as modeled in Nautobot |
| `policy_from` | `stc/blueprint_stc.yaml` | reference blueprint to carry `tenant_policy`/supernets from — **a running switch can't reveal design policy**; blank leaves `TODO(confirm)` markers for a genuinely new DC |
| `tenants` | `3-11,84-100` | passed to `provision_site.sh --tenants` at the `bf-adopt` stage |
| `shutdown_oci` | ✔ | untick to leave the instance up for debugging |

### The review gate

`rafay_nvcm_poc`'s own `bf-onboard.sh up` pauses for a human to approve the discovered blueprint before any
SoT write, and — non-interactively — tells the operator to resume with `--from adopt`. This repo runs the
**same pattern across two separate workflow runs**, because a CI job has no terminal to pause in:

1. **Run 1** — default `stages=bf-discover,bf-blueprint`. Nothing is written to Nautobot or to any switch.
   The `bf-blueprint` stage prints the full generated blueprint into its own log (and, since logs are
   committed to `logs/YYYY/MM/DD/`, into the repo). Read it. Resolve every `TODO(confirm)` marker — or set
   `policy_from` to a reference blueprint that already has `tenant_policy` so none appear.
2. **Run 2** — once satisfied, re-run with `stages=bf-adopt`. It re-finds the same discovered blueprint on
   the host (discovery output lives under `~/launchpad/bf-discover/` — deliberately **not** `/tmp`, since it
   has to survive the OCI instance being stopped between the two runs) and hands it to `provision_site.sh`.

`stages=all` runs discover → blueprint → adopt unattended in one run. That's fine for this lab's own
simulated fabric — there's nothing to protect — but it is **not** the safe first pass on a real production
DC. Use the two-run pattern there.

## Common setup for both workflows

Only one thing differs from repo to repo: which workflow you dispatch. Every credential, variable, and lab
host requirement below is shared.

**1. Repository variables** (Settings → Secrets and variables → Actions → Variables)

| Variable | Example / default |
|---|---|
| `OCI_INSTANCE_ID` | `ocid1.instance.oc1...` (required) |
| `OCI_SSH_USER` | `ubuntu` |
| `OCI_SSH_HOST` | optional. By default the instance's public IP is looked up each run, because ephemeral IPs change on restart |
| `OCI_SSH_KNOWN_HOSTS` | recommended: `ssh-keyscan <host>` output. This pins the host key. Without it the key is trusted on first use and the workflow logs a warning |
| `POC_REPO` | `ramakrishna-rafay/rafay_nvcm_poc` |
| `POC_DEFAULT_BRANCH` | `main` (used if `poc_branch` is left blank) |
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
- `sshpass` and `virsh` (brownfield's `bf-discover` stage in `virtual` mode) are already installed by
  `nvcm-host-prep.sh` — no extra host setup beyond the `host-prep` stage either mode already runs.

## Cleanup semantics (read before relying on "clean state")

At the start of every run (either workflow), the existing `~/rafay_nvcm_poc` is **moved** to
`~/launchpad/previous-clones/` (the newest 5 are kept) and a fresh clone of the requested branch replaces it.
Files in `PRESERVE_FILES` (currently the gitignored `deploy_scripts/params-secrets.env`) are carried into the
new clone. Run workspaces are kept under `~/launchpad/runs/<run_id>-<attempt>/` (the newest 14).

Brownfield's discovered blueprints live separately, under `~/launchpad/bf-discover/`, and are **not** cleaned
up by this policy — they need to survive across the two runs of the review-gate pattern above.

The installed state is **not** reset. The kind cluster, NVCM, the Rafay chart, and the lab VMs are left as
they are, and the POC scripts are idempotent against them. A deeper reset belongs to `rafay_nvcm_poc`
(for example `undeploy_site.sh --apply --destroy-substrate`). To make that part of the run, add it as a
stage once the team agrees it is safe.

## Failures, timeouts, logs

- Each stage runs **detached on the host** (`setsid` + its own `timeout`). An SSH drop or the handoff
  between jobs does not kill it. The runner reconnects and keeps streaming. It gives up only after about
  10 minutes without contact.
- The first failed stage stops the pipeline. Later stages are recorded as `skipped`. A stage that was
  running when the job itself died (cancelled/timed out) is recorded as `interrupted`, not `skipped` — the
  two are genuinely different and the report distinguishes them (`scripts/build-report.sh`). Host
  diagnostics (pods, events, VMs, disk) are captured. The workflow fails from that stage's job, so the
  report and power-off steps never hide the failure.
- `poweroff` and `report` use `always()` and run after a success, a failure, or a cancellation. The
  instance is stopped even if it was already running before the run started. The report records that.
- Logs are kept in two places. The `logs-*` and `run-report` artifacts hold the raw logs for 30 and 90
  days. A commit under `logs/<yyyy>/<mm>/<dd>/<HHMMSS>Z-run<id>.<attempt>-<STATUS>/` holds the per-stage
  logs, `summary.md`, and `summary.json`. Files over 20 MB are gzipped in the commit. Both workflows commit
  to the same `logs/` tree.
- `summary.json` is the contract for future notifiers such as email, a shared drive, or Slack. Add them as
  steps at the end of the `report` job. `scripts/commit-logs.sh` is the one piece to replace if logs move
  to external storage.

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
scripts/run-stages.sh                   runner: drive a phase (from $LAUNCHPAD_CATALOGUE), stream logs, record status.tsv
scripts/build-report.sh                 merge job logs → summary.md / summary.json
scripts/commit-logs.sh                  dated commit of the report
```

`$LAUNCHPAD_CATALOGUE` (set as a job `env` by each workflow, and as a `catalogue` input to `_phase.yml`) is
the only thing that switches `run-stages.sh`, `build-report.sh`, and `lab.sh push-agent` between modes. On
the host, whichever catalogue was selected is copied over as `~/launchpad/stages.sh` — `remote/agent.sh`
always sources that one fixed name, so it never needs to know which mode is active.
