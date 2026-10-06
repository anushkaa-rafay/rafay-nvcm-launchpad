# User Guide

For anyone **running** a workflow in this repo — not modifying it. If you're changing scripts or workflow
files instead, see [`Dev_Guide.md`](Dev_Guide.md).

## What goes where

Two different kinds of configuration, set by two different people at two different times:

- **Secrets & variables** — set **once**, by whoever administers this repo, in GitHub's Settings →
  Secrets and variables → Actions. Credentials and lab facts that don't change from run to run.
- **Input parameters** — chosen **every time** someone clicks **Run workflow** in the Actions tab. What
  changes per run: which branch, which stages, which site.

The rule of thumb: if it's a credential or something true about the lab regardless of who runs it or when —
it's a secret/variable, set once. If it's a choice specific to *this* run — it's an input, typed fresh
every time.

## One-time setup

Only one thing differs from repo to repo: which workflow you dispatch. Every credential, variable, and lab
host requirement below is shared by both.

**1. Repository variables** (Settings → Secrets and variables → Actions → *Variables*)

| Variable | Example / default |
|---|---|
| `OCI_INSTANCE_ID` | `ocid1.instance.oc1...` (required) |
| `OCI_SSH_USER` | `ubuntu` |
| `OCI_SSH_HOST` | optional. By default the instance's public IP is looked up each run, because ephemeral IPs change on restart |
| `OCI_SSH_KNOWN_HOSTS` | recommended: `ssh-keyscan <host>` output, pasted in as-is (comment lines are fine — they're stripped automatically). Pins the host key by identity, **not** by the address you happened to run `ssh-keyscan` against, so it keeps working after the instance's public IP changes. Without it the key is trusted on first use and the workflow logs a warning |
| `POC_REPO` | `ramakrishna-rafay/rafay_nvcm_poc` |
| `POC_DEFAULT_BRANCH` | `main` (used if `poc_branch` is left blank) |
| `LAB_OCI_IP` | optional value for `simulate_dc.sh --oci`. Defaults to the host's primary private IP |

**2. Repository secrets** (same page, *Secrets* tab) — never typed into a workflow run

| Secret | What |
|---|---|
| `OCI_CLI_USER`, `OCI_CLI_TENANCY`, `OCI_CLI_FINGERPRINT`, `OCI_CLI_REGION` | OCI API-key auth |
| `OCI_CLI_KEY_CONTENT` | the API signing private key (PEM) |
| `OCI_SSH_PRIVATE_KEY` | SSH key authorized on the lab host |
| `POC_DEPLOY_KEY` | private half of a **read-only deploy key** on `rafay_nvcm_poc` (see step 4) |

Give the OCI user the least privilege needed: `use instance-family` (start, stop, read) and `read vnics` on
the lab compartment only.

**3. Where to find each value in the OCI Console**

The five API-auth values (`OCI_CLI_USER`, `OCI_CLI_TENANCY`, `OCI_CLI_REGION`, `OCI_CLI_FINGERPRINT`,
`OCI_CLI_KEY_CONTENT`) come from **one flow**, in one visit to the Console:

1. Console → profile icon (top right) → **My profile**.
2. That page's header already shows your **user OCID** (`OCI_CLI_USER`) and, further down or via the
   profile menu's **Tenancy: `<name>`** link, the **tenancy OCID** (`OCI_CLI_TENANCY`) — each with a copy
   button. The **region** (`OCI_CLI_REGION`, e.g. `ap-mumbai-1`) is shown in the region selector top bar.
3. On the same profile page, left side → **Resources → API keys** → **Add API key** → **Generate API key
   pair** → **Download private key** → **Add**.
4. The Console then shows the **fingerprint** (`OCI_CLI_FINGERPRINT`) and a **Configuration file preview**
   box that already has all five values assembled together — a good place to sanity-check them as a set
   before splitting them into separate GitHub secrets.
5. The private key file you just downloaded — its whole contents, including the `-----BEGIN...`/
   `-----END...` lines — is `OCI_CLI_KEY_CONTENT`.

The lab-instance values are found on the instance itself, not the profile page:

| Value | Where |
|---|---|
| `OCI_INSTANCE_ID` | Console → **Compute → Instances** → click the lab instance → its **OCID** is at the top, with a copy button |
| `OCI_SSH_HOST` *(optional)* | same instance page → **Public IP Address**. Only set this if you want a fixed address; leave it unset to have the workflow look the current IP up each run |
| `OCI_SSH_KNOWN_HOSTS` *(recommended)* | not from the Console — run `ssh-keyscan <host>` from your own machine and paste the output in as-is |

`OCI_SSH_PRIVATE_KEY` is **not** obtained from the Console at all, and it's a different kind of key from
everything above — an SSH key, not an OCI API key. Since the lab instance already exists, use whichever
private key is already authorized to log into it as `OCI_SSH_USER` (whoever set the lab host up will have
this). To use a different or new key instead, generate a pair and append the **public** half to
`~/.ssh/authorized_keys` on the host yourself (over your own existing SSH access) — the private half is
what goes into the secret.

**4. Access to the private POC repo: a read-only deploy key**

`GITHUB_TOKEN` cannot be used — it's scoped to the repository whose workflow is running, even when both
repos have the same owner. A deploy key is the least-privileged option: read-only and limited to one repo.

```bash
ssh-keygen -t ed25519 -N '' -C rafay_nvcm_launchpad -f poc_deploy_key
# rafay_nvcm_poc → Settings → Deploy keys → Add: poc_deploy_key.pub, "Allow write access" UNTICKED (needs repo admin)
# rafay_nvcm_launchpad → secret POC_DEPLOY_KEY = contents of poc_deploy_key
```

The key is forwarded to the host over `ssh -A` for the clone command only — it's never written to the
host's disk.

**5. Lab host requirements**

- Passwordless `sudo` for `OCI_SSH_USER` (host prep and substrate need it). The preflight step checks this.
- Port 22 reachable from GitHub-hosted runners. If the security list must stay closed, use a self-hosted
  runner inside the VCN.
- `sshpass` and `virsh` (brownfield's `bf-discover` stage in `virtual` mode) are already installed by
  `nvcm-host-prep.sh` — no extra host setup beyond the `host-prep` stage either flow already runs.

## Which flow do I run?

|  | `nvcm-greenfield` | `nvcm-brownfield` |
|---|---|---|
| **When** | nothing to preserve — build a fabric from scratch | a fabric already exists and is running — learn from it |
| **Source of intent** | an Excel workbook | the live fabric itself, read over NVUE REST/SSH |
| **Writes before review?** | yes — it's a blank lab, nothing to protect | **no** — discover + blueprint are read-only; only `bf-adopt` writes |

Both are triggered the same way: **Actions tab → pick the workflow → Run workflow → fill in the inputs
below → Run**.

## Running greenfield

**Actions → nvcm-greenfield → Run workflow**

| Input | Default | |
|---|---|---|
| `poc_branch` | *(blank)* | the `rafay_nvcm_poc` branch to clone and run — blank uses the `POC_DEFAULT_BRANCH` repository variable, falling back to `main` if that isn't set either |
| `stages` | `all` | or a comma list, for example `blueprint,substrate,dc-bringup` to rerun only the DC part on an installed platform |
| `blueprint_source` | `generated` | `committed` uses `stc/blueprint_stc.yaml` instead of this run's generated blueprint |
| `tenants` | `3-11,84-100` | passed to `simulate_dc.sh --tenants` |
| `shutdown_oci` | ✔ | untick to leave the instance up for debugging |

What it does, stage by stage: `host-prep` → `platform-install-1` → `platform-install-2` →
`verify-platform` → `blueprint` → `substrate` → `dc-bringup`. See `Dev_Guide.md` if you want the exact
command each stage runs.

## Running brownfield

**Actions → nvcm-brownfield → Run workflow**

| Input | Default | |
|---|---|---|
| `poc_branch` | *(blank)* | the `rafay_nvcm_poc` branch to clone and run — blank uses the `POC_DEFAULT_BRANCH` repository variable, falling back to `main` if that isn't set either |
| `stages` | `bf-discover,bf-blueprint` | stops **before** any write — see "The review gate" below. `all` or a comma list, same convention as greenfield |
| `discover_mode` | `virtual` | `virtual` = the simulated VMs already on this lab host (via `virsh`); `real` = physical switches, needs `seed` |
| `seed` | *(empty)* | `real` mode only — management IPs/hostnames to discover, one per line |
| `site` | `blr-dc01` | the discovered site's name |
| `location` | *(empty)* | blank carries `policy_from`'s own location chain |
| `device_type` | `Cumulus VX` | as modeled in Nautobot |
| `policy_from` | `stc/blueprint_stc.yaml` | reference blueprint to carry `tenant_policy`/supernets from — **a running switch can't reveal design policy**; blank leaves `TODO(confirm)` markers for a genuinely new DC |
| `tenants` | `3-11,84-100` | passed to `provision_site.sh --tenants` at the `bf-adopt` stage |
| `shutdown_oci` | ✔ | untick to leave the instance up for debugging |

### The review gate — read this before onboarding a real DC

`rafay_nvcm_poc`'s own `bf-onboard.sh up` pauses for a human to approve the discovered blueprint before any
SoT write. This repo runs the same pattern across **two separate workflow runs**, because a CI job has no
terminal to pause in:

1. **Run 1** — default `stages=bf-discover,bf-blueprint`. Nothing is written to Nautobot or to any switch.
   The `bf-blueprint` stage prints the full generated blueprint into its own log (and, since logs are
   committed to `logs/<Mon-YYYY>/<DD-Mon-YYYY>/`, into the repo — in that run's `workflow.log`). **Read it.** Resolve every `TODO(confirm)` marker — or
   set `policy_from` to a reference blueprint that already has `tenant_policy` so none appear.
2. **Run 2** — once satisfied, re-run with `stages=bf-adopt`. It re-finds the same discovered blueprint on
   the host and hands it to `provision_site.sh`.

`stages=all` runs discover → blueprint → adopt unattended in one run. That's fine for this lab's own
simulated fabric — there's nothing to protect — but it is **not** the safe first pass on a real production
DC. Use the two-run pattern there.

## What happens during and after a run

- Each stage runs on the OCI host, detached from the GitHub runner — an SSH blip doesn't kill it. Progress
  streams into the job's log in the Actions UI as it goes.
- If a stage fails, the pipeline stops there: its job shows ❌, every later phase job is **skipped** (grey) in
  the run graph — never run — and those stages show ⚪ `skipped` in the Step Summary. The OCI instance is still
  powered off afterward (unless you unticked `shutdown_oci`) and a report is still produced — a failure
  never leaves the lab running or the run unreported.
- Results land in three places every run:
  - The **Step Summary** tab on the run itself — a quick pass/fail table.
  - Downloadable **artifacts** (`logs-*`, `run-report`) on the run page, for 30–90 days.
  - A permanent commit under `logs/<Mon-YYYY>/<DD-Mon-YYYY>/<time>Z-run<id>.<attempt>-<STATUS>/` in this
    repo (e.g. `logs/Oct-2026/04-Oct-2026/220415Z-run36606934354.1-FAILED/`) — the durable record,
    including the brownfield blueprint you need to review before `bf-adopt`.
- Only one run (of either workflow) is ever active against the lab at a time — a second trigger queues
  behind it rather than clashing.

If something goes wrong and you're not sure why, that run's `workflow.log` is the first place to look —
every stage is in it, in order, each ending in a `STAGE STATUS:` line (search for `STAGE STATUS: FAILED`); `Dev_Guide.md` has the internals if you need to go deeper.
