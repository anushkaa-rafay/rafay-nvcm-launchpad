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
is the source of truth this mirrors), and this repo runs both as **two separate workflows**, sharing every
job/script except the stage catalogue, and sharing one concurrency group because both drive the same
physical OCI host.

|  | [`nvcm-greenfield.yml`](.github/workflows/nvcm-greenfield.yml) | [`nvcm-brownfield.yml`](.github/workflows/nvcm-brownfield.yml) |
|---|---|---|
| **When** | nothing to preserve — build a fabric from scratch | a fabric already exists and is running — learn from it |
| **Trust direction** | trusts the SoT — push freely, no running config to protect | trusts the switch — the running config is truth; nothing is written until proven |
| **Source of intent** | an Excel workbook (`stc/STCS-GPUaaS_Network-Schema_v0.3.xlsx`) | the live fabric itself, read over NVUE REST/SSH |
| **rafay_nvcm_poc flow it mirrors** | `onboarding/greenfield/greenfield_adoption_plan.md` | `onboarding/brownfield/brownfield_adoption_plan.md` (`bf-onboard.sh`) |
| **Writes before review?** | yes — it's a blank lab, nothing to protect | **no** — discover + blueprint are read-only; only `bf-adopt` writes |

Both land on the exact same downstream: `deploy_scripts/fabric/provision_site.sh`.

## Documentation

- **[User Guide](User_Guide.md)** — running a workflow: one-time setup (secrets/variables), the inputs for
  each flow, the brownfield review-gate pattern, and where results land. Start here if you just want to
  trigger a run.
- **[Dev Guide](Dev_Guide.md)** — architecture, what each of the four workflow files is actually for, the
  stage-catalogue system and how to add a stage, and how to validate a change locally without touching OCI.
  Start here if you're modifying this repo.
