## NVCM e2e — ❌ FAILED

| | |
|---|---|
| Branch | `nvcm_1.3.1_migrate_test` @ `ef48bd64a75e` |
| Failed stage | site-bringup |
| Run | [43357913408#1](https://github.com/anushkaa-rafay/rafay-nvcm-launchpad/actions/runs/43357913408) · workflow_dispatch by anushkaa-rafay |
| Started / finished (UTC) | 2026-11-13T03:17:14Z → 2026-11-13T03:40:57Z |
| Lab | `aa-nvcm-vlab-2` |
| Instance | `ocid1.instance.oc1.phx.anyhqljtymbj47qcnihbser2eeavbrhapajtjkn4lba3vs5y7agurdo77djq` @ 129.146.175.81 · already running before: false · power-off job: skipped |

| # | Stage | Phase | Result | rc | Duration |
|---|---|---|---|---|---|
| 1 | host-prep | platform | ⚪ not-selected |  |  |
| 2 | platform-nvcm-install | platform | ⚪ not-selected |  |  |
| 3 | platform-rafay-install | platform | ⚪ not-selected |  |  |
| 4 | platform-verify | platform | ⚪ not-selected |  |  |
| 5 | blueprint-generate | blueprint | ✅ passed | 0 | 0m 23s |
| 6 | blueprint-verify | blueprint | ✅ passed | 0 | 0m 23s |
| 7 | substrate | substrate | ✅ passed | 0 | 2m 54s |
| 8 | site-bringup | bringup | ❌ failed | 1 | 15m 5s |
