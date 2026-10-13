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

**0. One GitHub Environment per OCI lab** (Settings → Environments → *New environment*)

Each OCI lab host is a GitHub Environment, and its name is what users type into the `lab` input (letters,
digits, `.`, `_`, `-` — e.g. `lab-1`, `blr-lab`). Different users can run on different labs at the same time;
two runs on the same lab still queue behind each other, greenfield and brownfield alike.

- Put the **lab-specific variables** from step 1 on the Environment — at minimum `INSTANCE_ID`, plus
  `SSH_HOST` / `SSH_KNOWN_HOSTS` / `SSH_USER` / `LAB_IP` as that lab needs.
- Put any **secret from step 2 that differs for this lab** (another tenancy or region, another SSH key) on
  the Environment too, under the same name. An Environment value overrides the repository-level one; a
  lab that sets nothing falls back to the repository secrets.
- Set the repository variable `DEFAULT_LAB` to the lab used when the `lab` input is left blank (and by the
  daily greenfield run, unless `SCHEDULE_LAB` names another one).

Adding a lab is just adding an Environment — no workflow change. A `lab` that isn't an Environment fails
the run at its first job, before anything touches OCI.

**1. Variables** (Settings → Secrets and variables → Actions → *Variables*, or on the lab's Environment)

| Variable | Level | Example / default |
|---|---|---|
| `DEFAULT_LAB` | Repo only | the lab used when the `lab` input is blank |
| `POC_REPO` | Repo only | `ramakrishna-rafay/rafay_nvcm_poc` |
| `POC_DEFAULT_BRANCH` | Repo only | `main` (used if `poc_branch` is left blank) |
| `SCHEDULE_LAB` | Repo only | the lab the [daily greenfield run](#the-daily-greenfield-run) uses, e.g. `aa-nvcm-vlab-3` (blank → `DEFAULT_LAB`) |
| `SCHEDULE_POC_BRANCH` | Repo only | the `rafay_nvcm_poc` branch the daily run tests, e.g. `prototype_fixes` (blank → `POC_DEFAULT_BRANCH`, then `main`) |
| `OCI_USER`, `OCI_TENANCY`, `OCI_FINGERPRINT`, `OCI_REGION` | Repo (lab may override) | **OCI labs**: API-key auth IDs (see step 3) |
| `AWS_ACCESS_KEY_ID`, `AWS_REGION` | Repo (lab may override) | **AWS labs**: IAM access key ID (`AKIA…`) and the instance's region (e.g. `ap-south-1`) |
| `INSTANCE_ID` | Lab Environment | required. An OCI OCID (`ocid1.instance.oc1...`) or an AWS EC2 ID (`i-0abc…`); its shape decides which cloud the lab is driven through |
| `SSH_USER` | Lab Environment | `ubuntu` |
| `SSH_HOST` | Lab Environment | the address the runner connects to over SSH — a DNS name or an IP, e.g. `lab3.example.com` or `203.0.113.7`. Optional. By default the instance's public IP is looked up each run, because ephemeral IPs change on restart (an Elastic IP or OCI reserved IP is stable — then this can be set) |
| `SSH_KNOWN_HOSTS` | Lab Environment | recommended: `ssh-keyscan <host>` output, pasted in as-is (comment lines are fine — they're stripped automatically). Pins the host key by identity, **not** by the address you happened to run `ssh-keyscan` against, so it keeps working after the instance's public IP changes. Without it the key is trusted on first use and the workflow logs a warning |
| `LAB_IP` | Lab Environment | the host's private IP as seen from on the box, e.g. `10.0.0.12` — passed to `simulate_dc.sh --oci`. Optional. Defaults to the host's primary private IP (first address of `hostname -I`) |

**2. Secrets** (same page, *Secrets* tab; or on a lab's Environment to override for that lab) — never typed into a workflow run

| Secret | Level | What |
|---|---|---|
| `POC_DEPLOY_KEY` | Repo only | private half of a **read-only deploy key** on `rafay_nvcm_poc` (see step 4) |
| `OCI_API_KEY` | Repo (lab may override) | **OCI labs**: the API signing private key (PEM) |
| `AWS_SECRET_ACCESS_KEY` | Repo (lab may override) | **AWS labs**: the IAM access key's secret |
| `SSH_PRIVATE_KEY` | Repo (lab may override) | SSH key authorized on the lab host |
| `SMTP_PASSWORD` | Repo only | optional — the Gmail **App Password** the run mails are sent with (see step 6) |

Only private keys (and the mail password) are secrets; every other value is read from variables. Every run checks the values for its
lab's cloud only (an AWS lab needs no `OCI_*` credentials and vice versa) before touching the instance: a
missing value is reported by name together with the lab it was looked up for, and a value of the wrong shape
fails there instead of as the cloud's opaque `404 NotAuthorizedOrNotFound` / `InvalidInstanceID`. A value saved on one lab's Environment is
invisible to runs on any other lab — put shared values at repository level.

Give the OCI user the least privilege needed: `use instance-family` (start, stop, read) and `read vnics` on
the lab compartment only. For an AWS lab, give the IAM user only `ec2:DescribeInstances` (any resource) and
`ec2:StartInstances` / `ec2:StopInstances` on the lab instance's ARN.

**AWS labs:** the stages run the simulated switches as KVM VMs, so the EC2 instance must expose `/dev/kvm` —
a bare-metal (`*.metal`) type, or one with nested virtualization enabled. Check with `ls /dev/kvm` on the host.

**3. Where to find each value in the OCI Console**

The five API-auth values (`OCI_USER`, `OCI_TENANCY`, `OCI_REGION`, `OCI_FINGERPRINT`,
`OCI_API_KEY`) come from **one flow**, in one visit to the Console:

1. Console → profile icon (top right) → **My profile**.
2. That page's header already shows your **user OCID** (`OCI_USER`) and, further down or via the
   profile menu's **Tenancy: `<name>`** link, the **tenancy OCID** (`OCI_TENANCY`) — each with a copy
   button. The **region** (`OCI_REGION`, e.g. `ap-mumbai-1`) is shown in the region selector top bar.
3. On the same profile page, left side → **Resources → API keys** → **Add API key** → **Generate API key
   pair** → **Download private key** → **Add**.
4. The Console then shows the **fingerprint** (`OCI_FINGERPRINT`) and a **Configuration file preview**
   box that already has all five values assembled together — a good place to sanity-check them as a set
   before splitting them into separate GitHub variables (and the key into a secret).
5. The private key file you just downloaded — its whole contents, including the `-----BEGIN...`/
   `-----END...` lines — is `OCI_API_KEY`.

The lab-instance values are found on the instance itself, not the profile page:

| Value | Where |
|---|---|
| `INSTANCE_ID` | Console → **Compute → Instances** → click the lab instance → its **OCID** is at the top, with a copy button |
| `SSH_HOST` *(optional)* | same instance page → **Public IP Address**. Only set this if you want a fixed address; leave it unset to have the workflow look the current IP up each run |
| `SSH_KNOWN_HOSTS` *(recommended)* | not from the Console — run `ssh-keyscan <host>` from your own machine and paste the output in as-is |

`SSH_PRIVATE_KEY` is **not** obtained from the Console at all, and it's a different kind of key from
everything above — an SSH key, not an OCI API key. Since the lab instance already exists, use whichever
private key is already authorized to log into it as `SSH_USER` (whoever set the lab host up will have
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

- Passwordless `sudo` for `SSH_USER` (host prep and substrate need it). The preflight step checks this.
- Port 22 reachable from GitHub-hosted runners. If the security list must stay closed, use a self-hosted
  runner inside the VCN.
- `sshpass` and `virsh` (brownfield's `bf-discover` stage in `virtual` mode) are already installed by
  `nvcm-host-prep.sh` — no extra host setup beyond the `host-prep` stage either flow already runs.

**6. Email (optional)**

Runs mail their result through a Gmail account (Python's own SMTP client, from the runner — no third-party
action ever sees the password). Until `MAIL_TO` is set nothing is sent and nothing fails; the run just notes
"no mail sent". All of these are repository-level — the report job doesn't run in a lab's Environment.

| Name | Kind | Value |
|---|---|---|
| `MAIL_TO` | variable | comma-separated recipients, e.g. `a@rafay.co,b@rafay.co` |
| `SMTP_USERNAME` | variable | the Gmail address that sends — also the mail's From. Example: `nvcm-launchpad-alerts@gmail.com` (or a Google Workspace address such as `nvcm-alerts@rafay.co`) |
| `SMTP_PASSWORD` | **secret** | an **App Password** for that account (Google Account → Security → 2-Step Verification → App passwords; 2-Step Verification must be on). Gmail refuses the normal account password over SMTP. Example shape: Google shows it as `abcd efgh ijkl mnop` (16 letters) — paste it as `abcdefghijklmnop`, without the spaces |
| `SMTP_SERVER`, `SMTP_PORT` | variable | optional — default `smtp.gmail.com` and `465` (TLS); `587` uses STARTTLS |

The example values above are illustrations, not real accounts. Use a dedicated sender account rather than a
person's own mailbox: its App Password can then be revoked (Google Account → App passwords) without
affecting anyone, and replies to the alerts don't land in a personal inbox.

What happens with a partial setup — none of it ever fails a lab run:

| Set up | Result |
|---|---|
| `MAIL_TO` unset | no mail; the report job notes "no mail sent — the MAIL_TO repository variable is not set" |
| `MAIL_TO` set, `SMTP_USERNAME` or `SMTP_PASSWORD` missing | no mail; a **warning** on the run names what's missing |
| everything set, but Gmail refuses the login | no mail; an error on the step says to use an App Password (the account password, or an account without 2-Step Verification, is refused) |

The weekly report behaves the same way, except that a refused login turns its own run red.

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
| `lab` | *(blank)* | which OCI lab to run on — the name of a GitHub Environment set up as in [One-time setup](#one-time-setup). Blank uses the `DEFAULT_LAB` repository variable. Runs on different labs go in parallel; a run on a lab that is busy queues behind it |
| `poc_branch` | *(blank)* | the `rafay_nvcm_poc` branch to clone and run — blank uses the `POC_DEFAULT_BRANCH` repository variable, falling back to `main` if that isn't set either |
| `stages` | `all` | or a comma list, for example `blueprint-generate,blueprint-verify,substrate,site-bringup` to rerun only the DC part on an installed platform |
| `blueprint_source` | `generate` | `generate` builds the blueprint in this run's `blueprint-generate` stage; `existing` uses `stc/blueprint_stc.yaml` from `rafay_nvcm_poc` instead. Either way `blueprint-verify` checks it before anything is built |
| `tenants` | `3-11,84-100` | passed to `simulate_dc.sh --tenants` |
| `shutdown` | ✔ | untick to leave the instance up for debugging |

What it does — four jobs, in order:

| Job | Stages | |
|---|---|---|
| 1 · Installation | `host-prep` → `nvcm-install` → `rafay-install` → `platform-verify` | dependencies, NVCM + Nautobot, the Rafay layer, then one verdict for the whole platform |
| 2 · Blueprint | `blueprint-generate` → `blueprint-verify` | generate from the workbook (or take the existing one), then verify it offline |
| 3 · Substrate | `substrate` | if this blueprint's fabric VMs already exist → recover them; if none exist → stage images and create them; if only some exist → recover those, create the rest |
| 4 · Site bring-up | `site-bringup` | underlay → overlay → servers → accept, gated at every layer |

See `Dev_Guide.md` if you want the exact command each stage runs.

### The daily greenfield run

`nvcm-greenfield` also runs **by itself every day at 06:00 IST** (cron `30 0 * * *`, UTC), on top of the
manual trigger. A scheduled run has no form to fill in, so it takes:

- the lab from `SCHEDULE_LAB` (blank → `DEFAULT_LAB`) and the branch from `SCHEDULE_POC_BRANCH` (blank →
  `POC_DEFAULT_BRANCH` → `main`);
- every other input at its default: `stages=all`, `blueprint_source=generate`, `tenants=3-11,84-100`;
- and it always powers the instance off at the end.

> **Set `SCHEDULE_POC_BRANCH` before relying on the daily run** — e.g. `prototype_fixes`. Left blank, the
> daily run tests `POC_DEFAULT_BRANCH`, or `main` if that isn't set either — not the branch you're working on.
> The run title shows which branch and lab it picked (`nvcm-greenfield · <lab> · <branch> · all · daily`).

Its run title ends in `· daily`. GitHub starts scheduled runs late when it is busy — often 5–30 minutes. If a
manual run is still using the same lab at 06:00, the daily run queues behind it, as any run would. Schedules
only fire from the workflow file on the default branch (`main`), and GitHub pauses them after 60 days without
any activity in the repository.

## Running brownfield

**Actions → nvcm-brownfield → Run workflow**

| Input | Default | |
|---|---|---|
| `lab` | *(blank)* | which OCI lab to run on — the name of a GitHub Environment set up as in [One-time setup](#one-time-setup). Blank uses the `DEFAULT_LAB` repository variable. Runs on different labs go in parallel; a run on a lab that is busy queues behind it |
| `poc_branch` | *(blank)* | the `rafay_nvcm_poc` branch to clone and run — blank uses the `POC_DEFAULT_BRANCH` repository variable, falling back to `main` if that isn't set either |
| `stages` | `bf-discover,bf-blueprint-generate` | stops **before** any write — see "The review gate" below. `all` or a comma list, same convention as greenfield |
| `discover_mode` | `virtual` | `virtual` = the simulated VMs already on this lab host (via `virsh`); `real` = physical switches, needs `seed` |
| `seed` | *(empty)* | `real` mode only — management IPs/hostnames to discover, one per line |
| `site` | `blr-dc01` | the discovered site's name |
| `location` | *(empty)* | blank carries `policy_from`'s own location chain |
| `device_type` | `Cumulus VX` | as modeled in Nautobot |
| `policy_from` | `stc/blueprint_stc.yaml` | reference blueprint to carry `tenant_policy`/supernets from — **a running switch can't reveal design policy**; blank leaves `TODO(confirm)` markers for a genuinely new DC |
| `tenants` | `3-11,84-100` | passed to `provision_site.sh --tenants` at the `bf-adopt` stage |
| `shutdown` | ✔ | untick to leave the instance up for debugging |

### The review gate — read this before onboarding a real DC

`rafay_nvcm_poc`'s own `bf-onboard.sh up` pauses for a human to approve the discovered blueprint before any
SoT write. This repo runs the same pattern across **two separate workflow runs**, because a CI job has no
terminal to pause in:

1. **Run 1** — default `stages=bf-discover,bf-blueprint-generate`. Nothing is written to Nautobot or to any switch.
   The `bf-blueprint-generate` stage prints the full generated blueprint into its own log (and, since logs are
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
  powered off afterward (unless you unticked `shutdown`) and a report is still produced — a failure
  never leaves the lab running or the run unreported.
- Results land in three places every run:
  - The **Summary** tab on the run itself — the pass/fail stage table and, for each stage that failed, its
    last 100 lines in a collapsible **Logs** section (`boot.log`'s, if the run died before any stage). The
    full `workflow.log` is in the `run-report` artifact.
  - Downloadable **artifacts** (`logs-*`, `run-report`) on the run page, for 30–90 days.
  - A permanent commit under `logs/<Mon-YYYY>/<DD-Mon-YYYY>/<time>Z-<lab>-run<id>.<attempt>-<STATUS>/` in this
    repo (e.g. `logs/Oct-2026/04-Oct-2026/220415Z-run36606934354.1-FAILED/`) — the durable record,
    including the brownfield blueprint you need to review before `bf-adopt`.
- A **failed** run (either workflow, manual or daily) also sends an **email** to `MAIL_TO` (see step 6 of
  setup): which stage failed, on which lab and branch, the stage table, the failed stage's last 60 lines, and
  `workflow.log` plus that phase's `diagnostics-*.txt` attached (`boot.log` if it died before any stage; a
  file over 5 MB is attached gzipped). Passed and cancelled runs send nothing.
- Only one run (of either workflow) is ever active against the lab at a time — a second trigger queues
  behind it rather than clashing.

## The weekly report

Every **Monday at 09:00 IST** the `weekly-report` workflow summarizes the last 7 days of greenfield and
brownfield runs and mails it to `MAIL_TO` (the same mail setup as failure mails — step 6 of setup). The same
report is on that run's **Summary** tab, so it's readable even before mail is set up. It shows:

- runs, passed / failed / cancelled and the pass rate, per workflow;
- the daily greenfield run's week, day by day;
- where runs failed — the stage that stopped each failed run, most frequent first;
- each stage's average and longest duration (passed stages only);
- every run: when, who, lab, branch, result, failed stage, duration and a link.

For a different window, **Actions → weekly-report → Run workflow** and set `days`. A run that was cancelled
early or died before committing its logs still counts, but shows no lab, branch or stage.

If something goes wrong and you're not sure why, that run's `workflow.log` is the first place to look —
every stage is in it, in order, each ending in a `STAGE STATUS:` line (search for `STAGE STATUS: FAILED`); `Dev_Guide.md` has the internals if you need to go deeper.
