## NVCM e2e — ❌ FAILED

| | |
|---|---|
| Branch | `nvcm_1.3.1_migrate_test` @ `ef48bd64a75e` |
| Failed stage | blueprint-verify |
| Run | [43280870192#1](https://github.com/anushkaa-rafay/rafay-nvcm-launchpad/actions/runs/43280870192) · workflow_dispatch by anushkaa-rafay |
| Started / finished (UTC) | 2026-11-12T18:32:36Z → 2026-11-12T18:58:28Z |
| Lab | `aa-nvcm-vlab-2` |
| Instance | `ocid1.instance.oc1.phx.anyhqljtymbj47qcnihbser2eeavbrhapajtjkn4lba3vs5y7agurdo77djq` @ 129.146.175.81 · already running before: false · power-off job: skipped |

| # | Stage | Phase | Result | rc | Duration |
|---|---|---|---|---|---|
| 1 | host-prep | platform | ✅ passed | 0 | 0m 22s |
| 2 | platform-nvcm-install | platform | ✅ passed | 0 | 13m 12s |
| 3 | platform-rafay-install | platform | ✅ passed | 0 | 4m 17s |
| 4 | platform-verify | platform | ✅ passed | 0 | 1m 6s |
| 5 | blueprint-generate | blueprint | ✅ passed | 0 | 0m 23s |
| 6 | blueprint-verify | blueprint | ❌ failed | 1 | 0m 22s |
| 7 | substrate | substrate | ⚪ skipped |  |  |
| 8 | site-bringup | bringup | ⚪ skipped |  |  |
