## NVCM e2e — ❌ FAILED

| | |
|---|---|
| Branch | `nvcm-1.3.1-migrate` @ `4267d9daa1af` |
| Failed stage | site-bringup |
| Run | [42967707629#3](https://github.com/anushkaa-rafay/rafay-nvcm-launchpad/actions/runs/42967707629) · workflow_dispatch by anushkaa-rafay |
| Started / finished (UTC) | 2026-11-11T07:21:34Z → 2026-11-11T09:45:32Z |
| Lab | `aa-nvcm-vlab-3` |
| Instance | `ocid1.instance.oc1.phx.anyhqljtymbj47qcaul6h6ecttryb7xqlveo6c3iamf7qjkodvoomi5oh6ca` @ 161.153.2.57 · already running before: true · power-off job: success |

| # | Stage | Phase | Result | rc | Duration |
|---|---|---|---|---|---|
| 1 | host-prep | platform | ✅ passed | 0 | 2m 10s |
| 2 | platform-nvcm-install | platform | ✅ passed | 0 | 16m 3s |
| 3 | platform-rafay-install | platform | ✅ passed | 0 | 4m 17s |
| 4 | platform-verify | platform | ✅ passed | 0 | 1m 6s |
| 5 | blueprint-generate | blueprint | ✅ passed | 0 | 0m 44s |
| 6 | blueprint-verify | blueprint | ✅ passed | 0 | 0m 24s |
| 7 | substrate | substrate | ✅ passed | 0 | 4m 12s |
| 8 | site-bringup | bringup | ❌ failed | 1 | 107m 50s |
