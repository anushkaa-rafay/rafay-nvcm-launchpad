## NVCM e2e — ❌ FAILED

| | |
|---|---|
| Branch | `nvcm_1.3.1_migrate_test` @ `ef48bd64a75e` |
| Failed stage | blueprint-verify |
| Run | [43194653667#1](https://github.com/anushkaa-rafay/rafay-nvcm-launchpad/actions/runs/43194653667) · workflow_dispatch by anushkaa-rafay |
| Started / finished (UTC) | 2026-11-12T09:48:14Z → 2026-11-12T10:12:14Z |
| Lab | `aa-nvcm-vlab-2` |
| Instance | `ocid1.instance.oc1.phx.anyhqljtymbj47qcnihbser2eeavbrhapajtjkn4lba3vs5y7agurdo77djq` @ 129.146.175.81 · already running before: true · power-off job: skipped |

| # | Stage | Phase | Result | rc | Duration |
|---|---|---|---|---|---|
| 1 | host-prep | platform | ✅ passed | 0 | 0m 23s |
| 2 | platform-nvcm-install | platform | ✅ passed | 0 | 13m 20s |
| 3 | platform-rafay-install | platform | ✅ passed | 0 | 4m 21s |
| 4 | platform-verify | platform | ✅ passed | 0 | 1m 7s |
| 5 | blueprint-generate | blueprint | ✅ passed | 0 | 0m 23s |
| 6 | blueprint-verify | blueprint | ❌ failed | 127 | 0m 23s |
| 7 | substrate | substrate | ⚪ skipped |  |  |
| 8 | site-bringup | bringup | ⚪ skipped |  |  |
