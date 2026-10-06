# rafay_nvcm_launchpad

## 1. Problem

Bringing up the NVCM POC on the OCI lab host was a manual, SSH-driven process: someone logs into the host,
clones/checks out `rafay_nvcm_poc` by hand, runs the right sequence of install/bring-up scripts in the
right order, and watches the output scroll by. Nothing records whether the last run actually succeeded,
nothing reminds anyone to power the instance back off, and there is no repeatable way to re-run just part
of the sequence (say, only the DC bring-up, once the platform is already installed) without redoing
everything by hand.

Pain points this project set out to fix:

- No CI-triggerable, audited way to run a bring-up — only "someone SSHed in and ran things."
- No automatic OCI instance lifecycle management — an engineer has to remember to stop it.
- No structured logs or pass/fail record; output lived only in a terminal scrollback.
- No safe, repeatable pattern for **brownfield** adoption specifically — onboarding an already-running,
  potentially production fabric needs a real human review step before anything gets written to it, and a
  manual process has no way to enforce that consistently.
- No handling for known-flaky steps (e.g. a pod that hasn't finished starting right after a helm upgrade)
  other than a human noticing and re-running by hand.

## 2. Objective

Build a GitHub Actions orchestration layer that reliably automates the existing OCI-based NVCM POC
bring-up — both the **greenfield** (build a fabric from scratch) and **brownfield** (adopt an
already-running fabric) flows `rafay_nvcm_poc` itself defines — without moving, copying, or duplicating any
of the actual installation implementation, which stays entirely in `rafay_nvcm_poc`.

The final system should, from a single "Run workflow" click: start the OCI lab instance, clone the
requested `rafay_nvcm_poc` branch onto it, run the correct stage sequence for the chosen mode, stream and
persist logs throughout, enforce a real review gate before any brownfield write, produce a clear pass/fail
report, and power the instance back off — every time, including on failure.

## 3. Scope

### In Scope

- Two GitHub Actions workflows (`nvcm-greenfield`, `nvcm-brownfield`) orchestrating the **existing** OCI lab
  host via the OCI CLI (power) and SSH (execution) — never provisioning a new instance.
- The stage-catalogue system: shared platform bring-up (`host-prep`, `platform-install-1`/`-2`,
  `verify-platform`), plus mode-specific stages (`blueprint`/`substrate`/`dc-bringup` for greenfield;
  `bf-discover`/`bf-blueprint`/`bf-adopt` for brownfield).
- The brownfield review gate: discover and blueprint are read-only; adopting (the only write) is a
  deliberate, separate step.
- Structured logging: live streaming to the Actions UI, artifact upload, and a permanent dated commit.
- Local validation tooling (lint + self-tests) for the orchestration layer itself, requiring no OCI access.

### Out of Scope

- Any installation or bring-up **logic** — that is `rafay_nvcm_poc`'s domain; this repo only invokes its
  documented entry points and never reimplements them.
- Provisioning a new OCI instance from scratch — the lab instance already exists.
- A deep/destructive environment reset (e.g. `undeploy_site.sh --apply --destroy-substrate`) as an
  automated stage — not wired in until the team decides it's safe to automate.
- Email / shared-drive / Slack notification of results — designed for (the report's `summary.json` is a
  stable contract for this) but not yet built.
- A hard technical lock on the brownfield review gate (e.g. a GitHub Environment with required reviewers) —
  currently enforced by workflow-input defaults and documentation, not a platform-level gate.

## 4. Proposed Solution

A separate repository, `rafay_nvcm_launchpad`, holding only orchestration: GitHub Actions workflows and a
small set of shell scripts. It drives the OCI lab host over SSH and the OCI CLI, cloning the requested
`rafay_nvcm_poc` branch fresh on every run and invoking its documented entry-point scripts stage by stage.
Two parallel workflows mirror `rafay_nvcm_poc`'s own greenfield/brownfield onboarding model — see
`onboarding/README.md` in that repo for the model this mirrors.

|  | Greenfield | Brownfield |
|---|---|---|
| When | nothing to preserve — build from scratch | a fabric already exists and is running |
| Trust direction | trusts the SoT — push freely | trusts the switch — nothing written until proven |
| Writes before review? | yes, it's a blank lab | **no** — only the final `bf-adopt` stage writes |

## 5. Architecture / Design

Two kinds of input drive every run: things set up once and reused forever, and things chosen each time
the workflow is triggered. Both funnel into `rafay_nvcm_launchpad`, which drives the OCI lab host, which
in turn runs `rafay_nvcm_poc`'s own entry-point scripts.

```
                 ONE TIME                         EVERY RUN
                   │                                  │
                   ▼                                  ▼
        GitHub Secrets + Variables             Workflow inputs
                   │                                  │
                   │                                  │
        ┌──────────┴──────────┐              ┌────────┴────────┐
        │                     │              │                 │
   OCI credentials       POC deploy key   branch          stages/site
   SSH credentials       lab details      tenants         mode/options
        │                     │              │                 │
        └──────────┬──────────┘              └────────┬────────┘
                   │                                  │
                   └──────────────┬───────────────────┘
                                  ▼
                       rafay_nvcm_launchpad
                                  │
                                  ▼
                            OCI lab host
                                  │
                                  ▼
                         rafay_nvcm_poc
```

Once inputs land on the lab host, the run itself follows a fixed pipeline:

```
Actions ─ OCI CLI ─▶ start instance ─▶ wait RUNNING + SSH + boot settled
        ─ SSH ─────▶ ~/launchpad/agent.sh prepare   (move old checkout aside, clone <branch> → ~/rafay_nvcm_poc)
                     for each stage:  agent.sh start → detached on the host; runner streams the log + polls
        ─ always ──▶ SOFTSTOP instance (unless shutdown_oci=false) ─▶ report: artifact + logs/<Mon-YYYY>/<DD-Mon-YYYY> commit
```

Major components:

- **Two entry-point workflows** (`nvcm-greenfield.yml`, `nvcm-brownfield.yml`) — `workflow_dispatch`,
  sharing one concurrency group *per lab* (GitHub Environment = one OCI instance), so runs on different labs
  go in parallel while runs on the same host queue.
- **A reusable phase workflow** (`_phase.yml`) — one phase (`platform`/`site`/`bringup`) of stages, called
  three times per run by each entry point so the phase logic exists once, not duplicated six times.
- **The stage-catalogue system** (`config/common.sh` + `config/stages-greenfield.sh` +
  `config/stages-brownfield.sh`) — the only place that maps a stage name to a `rafay_nvcm_poc` command.
  Platform bring-up is defined once and shared; only the site/bringup stages differ by mode.
- **The host agent** (`remote/agent.sh`) — the only thing copied onto the OCI host. Runs each stage
  **detached** (`setsid` + its own `timeout`), so an SSH drop or a hand-off between GitHub jobs never kills
  a multi-hour install.
- **The report pipeline** (`scripts/build-report.sh`, `scripts/commit-logs.sh`) — merges every job's logs
  into one `workflow.log` + pass/fail summary and commits it under `logs/<Mon-YYYY>/<DD-Mon-YYYY>/`.

Full internals, including *why* each of these design choices was made, live in [`Dev_Guide.md`](Dev_Guide.md).

## 6. Workflow

1. An operator triggers `nvcm-greenfield` or `nvcm-brownfield` (Actions → Run workflow), choosing the
   `rafay_nvcm_poc` branch, which stages to run, and mode-specific inputs.
2. Inputs are validated; the run queues behind any other active run against the same lab host.
3. The OCI CLI starts the lab instance (a no-op if it's already running) and the runner waits until it's
   reachable over SSH and has finished booting.
4. The requested `rafay_nvcm_poc` branch is cloned fresh onto the host — any previous checkout is moved
   aside, not deleted.
5. The stage catalogue and host agent are copied onto the host.
6. Each selected stage is started **detached** on the host; the runner polls its status and streams its log
   into the Actions UI as it runs.
7. *(Brownfield only)* discovery and blueprint generation are read-only and, by default, the run stops
   there for a human to review the generated blueprint before anything is written.
8. Whatever happens — success, failure, or cancellation — the OCI instance is powered off (unless disabled
   for that run) and a report is always produced.
9. Results land in the Step Summary, as downloadable artifacts, and as a permanent dated commit under
   `logs/`.

**What should happen automatically**

The user should not have to SSH into the machine and manually execute installation commands. The
pipeline should do:

```
1. Start OCI instance
        ↓
2. Wait for RUNNING
        ↓
3. Wait for SSH
        ↓
4. Wait for boot to settle
        ↓
5. SSH into host
        ↓
6. Move previous rafay_nvcm_poc checkout aside
        ↓
7. Clone requested POC branch
        ↓
8. Run host-prep
        ↓
9. Install NVCM
        ↓
10. Install Rafay platform
        ↓
11. Verify platform
        ↓
12. Generate blueprint
        ↓
13. Prepare substrate
        ↓
14. Bring up DC
        ↓
15. Collect logs
        ↓
16. Generate report
        ↓
17. Commit logs
        ↓
18. Stop OCI instance
```

## 7. Repository / Code Structure

```
rafay_nvcm_launchpad/
├── .github/workflows/
│   ├── nvcm-greenfield.yml    entry point: greenfield
│   ├── nvcm-brownfield.yml    entry point: brownfield
│   ├── _phase.yml             reusable: one phase of stages, shared by both
│   └── ci.yml                 lint/self-test on push/PR — optional, never touches OCI
├── .github/actions/lab-access/  OCI CLI config + ssh-agent setup
├── config/
│   ├── common.sh               shared platform stages (both modes)
│   ├── stages-greenfield.sh     greenfield-only stages + catalogue
│   └── stages-brownfield.sh     brownfield-only stages + catalogue
├── remote/agent.sh             the only file copied onto the OCI host
├── scripts/
│   ├── lab.sh                  OCI power + SSH connect
│   ├── run-stages.sh           drives one phase, streams logs
│   ├── build-report.sh         merges logs → summary.md / summary.json
│   └── commit-logs.sh          dated commit of the report
├── User_Guide.md               how to run a workflow
└── Dev_Guide.md                architecture, internals, how to extend

rafay_nvcm_poc/                 (a separate, private repository — never modified by this one)
├── deploy_scripts/             the actual install/bring-up scripts this repo invokes
├── onboarding/                 the greenfield/brownfield model this repo mirrors
└── stc/                        the reference site (workbook, blueprint) used by greenfield
```

Full annotated layout, including what each script does internally, is in [`Dev_Guide.md`](Dev_Guide.md).

## 8. Configuration & Prerequisites

- **Permissions**: an OCI IAM user scoped to least privilege (`use instance-family`, `read vnics` on the lab
  compartment only) and a **read-only** GitHub deploy key on `rafay_nvcm_poc` (`GITHUB_TOKEN` can't be used
  across repositories, even under the same owner).
- **Secrets** (GitHub Settings → Secrets and variables → Actions): `OCI_CLI_USER`, `OCI_CLI_TENANCY`,
  `OCI_CLI_FINGERPRINT`, `OCI_CLI_REGION`, `OCI_CLI_KEY_CONTENT` (OCI API-key auth), `OCI_SSH_PRIVATE_KEY`
  (lab host login), `POC_DEPLOY_KEY` (read-only clone access).
- **Per-lab variables** (one GitHub Environment per OCI instance, chosen by the `lab` input):
  `OCI_INSTANCE_ID` (required), `OCI_SSH_USER`, `OCI_SSH_HOST`, `OCI_SSH_KNOWN_HOSTS`, `LAB_OCI_IP`.
- **Repository variables**: `DEFAULT_LAB`, `POC_REPO`, `POC_DEFAULT_BRANCH`.
- **SSH keys**: two distinct ones — a lab-host login key, and the POC repo's read-only deploy key — see
  [Security](#9-security) for why they're kept separate.
- **Cloud resources**: one existing OCI compute instance per lab; nothing else is provisioned.
- **Dependencies**: `sshpass` and `virsh` (brownfield's virtual-mode discovery) are installed on the host by
  the shared `host-prep` stage itself — no separate setup needed.

Full step-by-step instructions, including exactly where to find each value in the OCI Console, are in
[`User_Guide.md`](User_Guide.md).

## 9. Security

- **Authentication**: OCI API-key auth (a matched user OCID + fingerprint + private key) for the OCI
  control plane; SSH key auth for the lab host itself — two unrelated credentials for two unrelated
  systems, never conflated.
- **Authorization**: the OCI IAM user is scoped to start/stop/read on the lab compartment only, nothing
  broader.
- **Secrets management**: all credentials live in GitHub Actions secrets, never in source; the OCI API key
  is written to `~/.oci` only inside the runner's ephemeral job filesystem. Free-text workflow inputs that
  reach a remote shell are either regex-validated to a safe charset or `%q`-escaped before being embedded in
  a single SSH command string, so a value containing a space can't silently break word-splitting.
- **SSH/deploy keys**: the `rafay_nvcm_poc` deploy key is forwarded to the host over `ssh -A` for the one
  clone command only — it is never written to the host's disk. The lab host's own SSH key is separate and
  does persist for the run's duration.
- **Access between repositories**: a read-only GitHub deploy key, not a personal access token — the
  least-privileged option available, limited to exactly one repository.
- **Sensitive data handling**: host-key pinning (`OCI_SSH_KNOWN_HOSTS`) is rewritten to a stable alias so it
  survives the lab's ephemeral public IP changing, rather than being silently bypassed after a restart.
  OCIDs and key material should never be pasted into a chat session or committed to source — only into the
  GitHub secret/variable fields they belong in.

## 10. Logging & Monitoring

Logs are kept in three places on every run:

- **Live**: streamed into the Actions UI as each stage runs on the host.
- **Artifacts**: `logs-*` (one per job: `boot.log`, or that phase's `workflow.log` + `status.tsv`, 30 days)
  and `run-report` (the merged report, 90 days), downloadable from the run page.
- **Permanent**: a commit in this repo, one directory per run, filed by the month and full date the run
  **started** (UTC), gzipped if a file is over 20 MB:

```
logs/
└── <Mon-YYYY>/                                    e.g. Oct-2026          — one per month
    └── <DD-Mon-YYYY>/                             e.g. 04-Oct-2026       — one per day
        └── <HHMMSS>Z-run<id>.<attempt>-<STATUS>/  e.g. 220415Z-run36606934354.1-FAILED  — one per run
            ├── workflow.log              every stage's output, in run order (below)
            ├── boot.log                  start OCI → wait operational → clone
            ├── diagnostics-<job>.txt     host snapshot, only when a stage in that job failed (e.g. diagnostics-bringup.txt)
            ├── status.tsv                one row per catalogue stage
            ├── summary.json              machine-readable result — the contract for notifiers
            └── summary.md                the Step Summary table
```

There are **no per-stage log files** (the old `01-host-prep.log`, `02-platform-install-1.log`, …): every
stage writes into the single `workflow.log`, in execution order, each in its own section that ends with the
stage's result — `PASSED`, `FAILED`, `TIMED-OUT`, `LOST-CONTACT`, `INTERRUPTED` (its job was cancelled or
died mid-stage), `SKIPPED` or `NOT-SELECTED`. A stage's stdout and stderr are copied in verbatim:

```
============================================================
STAGE 06: substrate (phase: site)
============================================================

[2026-10-04 22:31:40 UTC] INFO  Starting stage substrate (timeout 120m, run key 36606934354-1)
<stage output>
[2026-10-04 22:32:02 UTC] ERROR Stage substrate failed (rc=1, 22s)

------------------------------------------------------------
STAGE STATUS: FAILED
------------------------------------------------------------
```

The file ends with `WORKFLOW STATUS: <PASSED|FAILED|CANCELLED> (failed stage: …)`. The stage sequence for
greenfield is explicitly documented as:

```
host-prep
→ platform-install-1
→ platform-install-2
→ verify-platform
→ blueprint
→ substrate
→ dc-bringup
```

To debug a failure: start with the Step Summary's pass/fail table, then search the committed
`workflow.log` for `STAGE STATUS: FAILED` (or the failed stage's `STAGE NN:` header). Host diagnostics (pods, events, VMs, disk) are captured automatically on any
failure.

## 11. Error Handling

| Situation | Behavior |
|---|---|
| OCI CLI auth is misconfigured | Fails fast in a preflight check with a clear, named-secret error, rather than surfacing as a confusing downstream SSH failure. |
| Repository clone fails | The `boot` job fails; later phases run but do nothing; the instance is still powered off and a report is still produced. |
| A stage's own readiness check fails because pods haven't finished starting yet | Recognized as non-fatal and the pipeline continues — the later `verify-platform` stage is the real gate once more time has passed. Any other failure from that same command still stops the stage normally. |
| An installation stage fails for a real reason | The pipeline stops at that stage; later stages are recorded `skipped` (or `interrupted` if they were themselves running when the job died); the failure is never hidden by a later job. |
| A stage times out or hangs | Each stage has its own timeout, enforced on the host independent of the GitHub job's own budget, so a hung install is killed cleanly rather than silently continuing forever. |
| The job itself fails or is cancelled | Power-off and report generation still run — a longstanding GitHub Actions quirk where a skipped dependency can defeat `always()` is worked around explicitly (see `Dev_Guide.md`), so the lab is never left running unreported. |

## 12. Deployment / Setup

One-time setup, done once by whoever administers this repo: create the OCI IAM user and API key, add the
GitHub secrets and variables listed in [§8](#8-configuration--prerequisites), and add the read-only deploy
key to `rafay_nvcm_poc`. Full walkthrough, including exact OCI Console navigation for every value, is in
[`User_Guide.md`](User_Guide.md).

## 13. Usage

Actions tab → pick `nvcm-greenfield` or `nvcm-brownfield` → **Run workflow** → fill in the branch and
stage selection → **Run**. Full input tables for both flows, and the brownfield review-gate walkthrough,
are in [`User_Guide.md`](User_Guide.md).

### What does the "any user" experience become?

Once the admin has completed the one-time setup above, running a bring-up takes no more than clicking
through the GitHub Actions UI:
```
1. Open GitHub
2. Open `rafay_nvcm_launchpad`
3. Go to Actions
4. Choose:
   ├── nvcm-greenfield
   └── nvcm-brownfield
5. Click "Run workflow"
6. Select the required branch/options
7. Click Run
```

No OCI API keys, SSH private keys, deploy keys, instance OCID, or OCI CLI configuration to handle —
and no need to know how to clone `rafay_nvcm_poc`, start or SSH into the VM, run individual POC scripts,
stop the VM, or collect logs by hand. 

That's exactly the purpose of the orchestration layer.

## 14. Testing

There is no OCI-dependent CI yet — everything below runs with no lab access and no secrets:

- **Static checks**: `bash -n` (syntax) and `shellcheck` (warning severity and above) on every script;
  `actionlint` on every workflow file. Enforced automatically by `ci.yml` on push/PR.
- **Stage-selection self-tests**: both catalogues' `validate`/`plan` logic, including the specific assertion
  that the brownfield review gate's default selection plans nothing for the write stage, and that the
  resume run finds it correctly.
- **Targeted bug reproduction**: several fixes (the SSH known-hosts alias, the `pipefail` masking gap, the
  pods-not-ready continue logic) were verified by actually reproducing the failing behavior first — a real
  `sshd` in a container, a fake failing `oci` binary, the exact two-line step under both candidate shell
  invocations — then confirming the fix resolves that exact reproduction, not just by inspection.

**Not yet done**: an end-to-end run of either workflow against the real OCI lab host. Everything above
verifies the orchestration logic is internally correct; it doesn't yet prove the full pipeline against live
infrastructure.

## 15. Limitations / Known Issues

- The brownfield review gate is enforced by a workflow-input default, not a platform-level lock — nothing
  technically prevents dispatching straight to `stages=all` against a real DC.
- No automated destructive-reset stage; a deeper environment reset stays a manual `rafay_nvcm_poc` command.
- No notification integration yet (email / shared drive / Slack) — `summary.json` is a stable contract for
  one, not yet consumed by anything.
- Concurrency is a soft GitHub Actions queue (one pending run per lab), adequate for the current ~1
  run/day scale, not a distributed lock suitable for much higher concurrency.
- No true end-to-end validation against the real OCI host yet (see [§14](#14-testing)).

## 16. Future Improvements

- Wire an actual notifier (email, shared drive, or Slack) off the existing `summary.json` contract.
- Consider a hard technical gate for brownfield adoption (e.g. a GitHub Environment with required
  reviewers) if the input-default approach proves insufficient in practice.
- Add an automated destructive-reset stage once the team agrees on when it's safe.
- Move log storage off git if run volume grows meaningfully past the current ~1/day assumption.
- Add further stages as the team's automation needs grow — the catalogue system is designed for this (see
  "To add a stage" in `Dev_Guide.md`).

## 17. References

- `rafay_nvcm_poc` — [`onboarding/README.md`](https://github.com/ramakrishna-rafay/rafay_nvcm_poc) (the
  greenfield/brownfield model this repo mirrors), `onboarding/greenfield/greenfield_adoption_plan.md`,
  `onboarding/brownfield/brownfield_adoption_plan.md` (`bf-onboard.sh`'s own design).
- Key `rafay_nvcm_poc` entry points this repo invokes: `deploy_scripts/platform/platform_install.sh`,
  `deploy_scripts/fabric/provision_site.sh`, `deploy_scripts/simulate_dc.sh`,
  `onboarding/brownfield/scripts/bf-onboard.sh`.
- [`User_Guide.md`](User_Guide.md) — full setup and usage instructions.
- [`Dev_Guide.md`](Dev_Guide.md) — full architecture, internals, and extension guide.
