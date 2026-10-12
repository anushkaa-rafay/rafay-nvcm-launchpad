#!/usr/bin/env bash
#
# selftest.sh — every offline check of this repo in one command, no OCI / SSH / GitHub needed:
#   bash -n → shellcheck → both catalogues' stage-selection logic → tests/logging.sh
#
#   tests/selftest.sh       # exit 0 iff every check passed (needs bash ≥ 4; see Dev_Guide.md for the container)
#
# There is no push/PR workflow running this — run it before pushing a change to any script, catalogue or
# workflow. actionlint is separate (it's a container): see Dev_Guide.md → "Validating a change locally".
#
set -euo pipefail
trap 'echo "FAIL: tests/selftest.sh:$LINENO: $BASH_COMMAND"' ERR
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== bash -n (syntax) on every script"
fail=0
while IFS= read -r -d '' f; do bash -n "$f" || fail=1; done < <(find scripts remote config tests -name '*.sh' -print0)
[ $fail -eq 0 ]

echo "=== shellcheck (warning and above)"
if command -v shellcheck >/dev/null; then
  shellcheck -x --severity=warning scripts/*.sh remote/*.sh config/*.sh tests/*.sh
else
  echo "shellcheck not installed — skipped"
fi

echo "=== stage-selection — greenfield catalogue"
export LAUNCHPAD_CATALOGUE=config/stages-greenfield.sh
scripts/run-stages.sh validate all
scripts/run-stages.sh validate host-prep,blueprint-generate
# an unknown stage name must be rejected — `!` would skip -e on a regression here, so check explicitly
scripts/run-stages.sh validate not-a-stage 2>/dev/null && { echo "FAIL: validate accepted an unknown stage name"; exit 1; }
[ "$(scripts/run-stages.sh plan platform all | tr '\n' ,)" = "host-prep,nvcm-install,rafay-install,platform-verify," ]
[ "$(scripts/run-stages.sh plan blueprint all | tr '\n' ,)" = "blueprint-generate,blueprint-verify," ]
[ "$(scripts/run-stages.sh plan substrate all)" = "substrate" ]
[ "$(scripts/run-stages.sh plan bringup all)" = "site-bringup" ]
[ -z "$(scripts/run-stages.sh plan bringup blueprint-generate,substrate)" ]   # an earlier-phase-only selection plans nothing for bringup

echo "=== stage-selection — brownfield catalogue"
export LAUNCHPAD_CATALOGUE=config/stages-brownfield.sh
scripts/run-stages.sh validate all
scripts/run-stages.sh validate bf-discover,bf-blueprint-generate
scripts/run-stages.sh validate not-a-stage 2>/dev/null && { echo "FAIL: validate accepted an unknown stage name"; exit 1; }
[ "$(scripts/run-stages.sh plan platform all | tr '\n' ,)" = "host-prep,nvcm-install,rafay-install,platform-verify," ]
# the review-gate default (bf-discover,bf-blueprint-generate) must plan NOTHING for bringup — see
# config/stages-brownfield.sh's header. A regression here would silently skip the safety stop.
[ -z "$(scripts/run-stages.sh plan bringup bf-discover,bf-blueprint-generate)" ]
[ "$(scripts/run-stages.sh plan bringup bf-adopt)" = "bf-adopt" ]     # the resume run (stages=bf-adopt) must still find it

echo "=== log layout — run-stages → build-report → commit-logs against a fake lab"
tests/logging.sh

echo "all self-tests passed"
