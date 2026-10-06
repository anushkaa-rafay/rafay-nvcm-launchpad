#!/usr/bin/env bash
#
# logging.sh — self-test of the run-report log layout, no OCI / SSH / GitHub needed:
#   run-stages.sh run  (against a fake `ssh lab`)  →  build-report.sh  →  commit-logs.sh (into a scratch repo)
#
#   tests/logging.sh        # exit 0 iff every check passed
#
# The fake host serves each stage's log + exit code from fixtures; dates come from a fixed summary.json
# .run.started, so nothing here depends on the real clock.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export LAUNCHPAD_CATALOGUE=config/stages-greenfield.sh LAB_POLL_SECS=0 GITHUB_OUTPUT=/dev/null
KEY=1-1
fails=0
ok(){ if "$@"; then echo "  ok   $DESC"; else echo "  FAIL $DESC"; fails=$((fails+1)); fi; }

# ── the fake lab host ───────────────────────────────────────────────────────────────────────────────────────
# ssh lab "<cmd>" runs <cmd> in $FAKE_HOME. agent.sh there: start copies fixtures/<stage>.log into the run dir
# (output arrives in two halves across polls, to exercise the incremental pull); status reports `running`
# until the stage's .rc fixture exists; a stage with no .rc fixture runs forever (the cancellation case).
mkdir -p "$T/bin" "$T/home/launchpad"
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
shift; cd "$FAKE_HOME" && bash -c "$*"
EOF
cat > "$T/home/launchpad/agent.sh" <<'EOF'
#!/usr/bin/env bash
run="$FAKE_HOME/launchpad/runs/$2"; fx="$FIXTURES/$3"
case "$1" in
  start)  mkdir -p "$run"; head -n 2 "$fx.log" > "$run/$3.log"; echo "[agent] started $3 (pid 4242, timeout $4m)" ;;
  status) if [ ! -f "$run/$3.polled" ]; then : > "$run/$3.polled"; tail -n +3 "$fx.log" >> "$run/$3.log"; echo running
          elif [ -f "$fx.rc" ]; then echo "done $(cat "$fx.rc")"; else echo running; fi ;;
  diag)   echo '===== $ uptime'; echo 'fake diag output' ;;
esac
EOF
chmod +x "$T/bin/ssh" "$T/home/launchpad/agent.sh"
export PATH="$T/bin:$PATH" FAKE_HOME="$T/home"

fixture(){   # fixture <stage> <rc|-> : 4 output lines (stdout + stderr text), unique per stage
  printf '[launchpad] stage=%s started\nout-%s line 1\nout-%s line 2\nerr-%s Traceback (most recent call last):' "$1" "$1" "$1" "$1" > "$FIXTURES/$1.log"
  [ "$2" = - ] || echo "$2" > "$FIXTURES/$1.rc"
}

# run one scenario: scenario <name> <rc per greenfield stage, '-' = never exits> <phases to run>
scenario(){
  local name="$1" rcs="$2"; shift 2
  export FIXTURES="$T/$name/fixtures"; mkdir -p "$FIXTURES" "$T/$name/collected/logs-boot"
  rm -rf "$T/home/launchpad/runs"
  local i=0 s; for s in host-prep platform-install-1 platform-install-2 verify-platform blueprint substrate dc-bringup; do
    i=$((i+1)); fixture "$s" "$(cut -d, -f$i <<< "$rcs")"
  done
  printf 'POC_BRANCH=main\nPOC_SHA=0123456789abcdef\nSTARTED_AT=2026-10-04T22:04:15Z\n' > "$T/$name/collected/logs-boot/meta.env"
  [ -z "${LAB_META:-}" ] || cat "$LAB_META" >> "$T/$name/collected/logs-boot/meta.env"
  echo "boot-log-line" > "$T/$name/collected/logs-boot/boot.log"
  local p; for p in "$@"; do
    # a phase that never exits is the cancelled job: the runner kills it mid-stage, like GitHub does
    if [[ "$rcs" == *-* ]] && [ "$p" = "${CANCEL_PHASE:-}" ]; then
      timeout 3 "$ROOT/scripts/run-stages.sh" run "$p" "$KEY" all "$T/$name/collected/logs-$p" > "$T/$name/run-$p.out" 2>&1 || true
    else
      "$ROOT/scripts/run-stages.sh" run "$p" "$KEY" all "$T/$name/collected/logs-$p" > "$T/$name/run-$p.out" 2>&1 || echo $? > "$T/$name/run-$p.rc"
    fi
  done
  RUN_ID=36606934354 RUN_ATTEMPT=1 "$ROOT/scripts/build-report.sh" "$T/$name/collected" "$T/$name/report" > /dev/null
}

stage_order(){ grep -oE '^STAGE [0-9]{2}: [a-z0-9-]+' "$1" | paste -sd, -; }
status_order(){ grep -oE '^STAGE STATUS: [A-Z-]+' "$1" | cut -d' ' -f3 | paste -sd, -; }
ALL="STAGE 01: host-prep,STAGE 02: platform-install-1,STAGE 03: platform-install-2,STAGE 04: verify-platform,STAGE 05: blueprint,STAGE 06: substrate,STAGE 07: dc-bringup"

# ── 1. all stages pass ──────────────────────────────────────────────────────────────────────────────────
echo "scenario: all stages pass"
RESULT_BOOT=success RESULT_PLATFORM=success RESULT_SITE=success RESULT_BRINGUP=success \
  scenario pass 0,0,0,0,0,0,0 platform site bringup
R="$T/pass/report"
DESC="report holds exactly workflow.log + boot.log + status.tsv + summary.{json,md}"
ok [ "$(cd "$R" && ls | paste -sd, -)" = "boot.log,status.tsv,summary.json,summary.md,workflow.log" ]
DESC="no per-stage NN-<stage>.log anywhere — report or phase artifacts"
ok [ -z "$(find "$T/pass" -name '[0-9][0-9]-*.log')" ]
DESC="one workflow.log per phase artifact"; ok [ "$(find "$T/pass/collected" -name workflow.log | wc -l)" -eq 3 ]
DESC="every stage has a header, in catalogue order"; ok [ "$(stage_order "$R/workflow.log")" = "$ALL" ]
DESC="every stage's footer says PASSED"; ok [ "$(status_order "$R/workflow.log")" = "PASSED,PASSED,PASSED,PASSED,PASSED,PASSED,PASSED" ]
DESC="all 28 output lines present (incl. those pulled on a later poll, and stderr text)"
ok [ "$(grep -cE '^(\[launchpad\] stage=|out-|err-)' "$R/workflow.log")" -eq 28 ]
DESC="no output line duplicated"; ok [ -z "$(grep -E '^(out-|err-)' "$R/workflow.log" | sort | uniq -d)" ]
DESC="stage output lands inside its own section"
ok awk '/^STAGE 05:/{s=1} /^STAGE 06:/{s=0} s&&/out-blueprint line 2/{f=1} END{exit !f}' "$R/workflow.log"
DESC="run-level status recorded in workflow.log"; ok grep -qx 'WORKFLOW STATUS: PASSED' "$R/workflow.log"
DESC="summary.json status PASSED"; ok [ "$(jq -r .status "$R/summary.json")" = PASSED ]

# ── 2. a stage fails (substrate, rc=1) — the bringup phase job is skipped ──────────────────────
echo "scenario: substrate fails"
RESULT_BOOT=success RESULT_PLATFORM=success RESULT_SITE=failure RESULT_BRINGUP=skipped \
  scenario fail 0,0,0,0,0,1,0 platform site
R="$T/fail/report"
DESC="run-stages.sh exits 1 for the failed phase"; ok [ "$(cat "$T/fail/run-site.rc")" = 1 ]
DESC="diagnostics + every supporting artifact still produced"
ok [ "$(cd "$R" && ls | paste -sd, -)" = "boot.log,diagnostics-site.txt,status.tsv,summary.json,summary.md,workflow.log" ]
DESC="all 7 stage headers in order, incl. the never-run bringup phase"; ok [ "$(stage_order "$R/workflow.log")" = "$ALL" ]
DESC="statuses: 5 passed, substrate FAILED, dc-bringup SKIPPED"
ok [ "$(status_order "$R/workflow.log")" = "PASSED,PASSED,PASSED,PASSED,PASSED,FAILED,SKIPPED" ]
DESC="failed stage's error output kept"; ok grep -q '^err-substrate Traceback' "$R/workflow.log"
DESC="failed stage's rc logged"; ok grep -qE '\] ERROR Stage substrate failed \(rc=1, [0-9]+s\)' "$R/workflow.log"
DESC="WORKFLOW STATUS names the failed stage"; ok grep -qx 'WORKFLOW STATUS: FAILED (failed stage: substrate)' "$R/workflow.log"
DESC="status.tsv unchanged in shape: substrate failed rc=1"; ok [ "$(awk -F'\t' '$2=="substrate"{print $4"/"$5}' "$R/status.tsv")" = failed/1 ]

# ── 3. cancelled mid-stage (blueprint never exits; the site job is killed) ────────────────────────────────
echo "scenario: cancelled during blueprint"
CANCEL_PHASE=site RESULT_BOOT=success RESULT_PLATFORM=success RESULT_SITE=cancelled RESULT_BRINGUP=cancelled \
  scenario cancel 0,0,0,0,-,0,0 platform site
R="$T/cancel/report"
DESC="all 7 stage headers in order"; ok [ "$(stage_order "$R/workflow.log")" = "$ALL" ]
DESC="blueprint INTERRUPTED (not SKIPPED), later stages SKIPPED"
ok [ "$(status_order "$R/workflow.log")" = "PASSED,PASSED,PASSED,PASSED,INTERRUPTED,SKIPPED,SKIPPED" ]
DESC="output pulled before the cancel is kept"; ok grep -q '^out-blueprint line 2' "$R/workflow.log"
DESC="status.tsv: blueprint interrupted"; ok [ "$(awk -F'\t' '$2=="blueprint"{print $4}' "$R/status.tsv")" = interrupted ]
# build-report.sh's existing rule (unchanged here): an interrupted stage is the failed stage → FAILED
DESC="summary.json: FAILED at blueprint"; ok [ "$(jq -r '.status+"/"+.failed_stage' "$R/summary.json")" = FAILED/blueprint ]
DESC="WORKFLOW STATUS: FAILED at blueprint"; ok grep -qx 'WORKFLOW STATUS: FAILED (failed stage: blueprint)' "$R/workflow.log"

# ── 4. boot failed — no phase ran at all ─────────────────────────────────────────────────────────────────
echo "scenario: boot failed"
RESULT_BOOT=failure RESULT_PLATFORM=skipped RESULT_SITE=skipped RESULT_BRINGUP=skipped scenario boot 0,0,0,0,0,0,0
R="$T/boot/report"
DESC="workflow.log still lists every stage"; ok [ "$(stage_order "$R/workflow.log")" = "$ALL" ]
DESC="all SKIPPED"; ok [ "$(status_order "$R/workflow.log")" = "SKIPPED,SKIPPED,SKIPPED,SKIPPED,SKIPPED,SKIPPED,SKIPPED" ]

# ── 4b. unknown lab — the lab job failed, so boot and every phase were skipped ───────────────────────────────
echo "scenario: unknown lab"
LAB=no-such-lab RESULT_LAB=failure RESULT_BOOT=skipped RESULT_PLATFORM=skipped RESULT_SITE=skipped RESULT_BRINGUP=skipped \
  scenario nolab 0,0,0,0,0,0,0
R="$T/nolab/report"
DESC="summary.json: FAILED at the lab, naming it (not PASSED, though every job after it was only skipped)"
ok [ "$(jq -r '.status+"/"+.failed_stage' "$R/summary.json")" = "FAILED/lab (no such GitHub Environment: 'no-such-lab')" ]
DESC="summary.json .oci.lab falls back to the requested lab"; ok [ "$(jq -r .oci.lab "$R/summary.json")" = no-such-lab ]

# ── 4c. the lab + its instance come from boot's meta.env (the report job runs outside the lab's Environment) ──
echo "scenario: lab recorded"
printf 'LAB=lab-2\nINSTANCE_ID=ocid1.instance.oc1..lab2\n' > "$T/lab-meta"
LAB_META="$T/lab-meta" RESULT_LAB=success RESULT_BOOT=success RESULT_PLATFORM=success RESULT_SITE=success RESULT_BRINGUP=success \
  scenario labrec 0,0,0,0,0,0,0 platform site bringup
R="$T/labrec/report"
DESC="summary.json .oci.lab/.oci.instance from meta.env"
ok [ "$(jq -r '.oci.lab+"/"+.oci.instance' "$R/summary.json")" = lab-2/ocid1.instance.oc1..lab2 ]
DESC="summary.md names the lab"; ok grep -q '^| Lab | `lab-2` |$' "$R/summary.md"
DESC="workflow.log header names the lab"; ok grep -q '^WORKFLOW RUN .* · lab lab-2 · ' "$R/workflow.log"

# ── 5. committed path: logs/<Mon-YYYY>/<DD-Mon-YYYY>/<HHMMSS>Z-[<lab>-]run<id>.<attempt>-<STATUS>/ ───────────────────
echo "scenario: commit-logs.sh"
# shellcheck source=scripts/lib-log.sh
. "$ROOT/scripts/lib-log.sh"
sj(){ jq -n --arg s "$1" --arg st "$2" --arg lab "${3:-}" '{status:$st, run:{id:"36606934354", attempt:"1", started:$s}, poc:{branch:"main"}}
       + (if $lab == "" then {} else {oci:{lab:$lab}} end)' > "$T/s.json"; }
sj 2026-10-04T22:04:15Z FAILED
DESC="Oct run → logs/Oct-2026/04-Oct-2026/220415Z-run36606934354.1-FAILED"
ok [ "$(lp_run_dir "$T/s.json")" = logs/Oct-2026/04-Oct-2026/220415Z-run36606934354.1-FAILED ]
sj 2026-09-01T09:46:26Z PASSED
DESC="zero-padded day: logs/Sep-2026/01-Sep-2026/094626Z-…-PASSED"
ok [ "$(lp_run_dir "$T/s.json")" = logs/Sep-2026/01-Sep-2026/094626Z-run36606934354.1-PASSED ]
sj 2026-10-04T22:04:15Z PASSED lab-2
DESC="lab in the run dir: …/220415Z-lab-2-run36606934354.1-PASSED"
ok [ "$(lp_run_dir "$T/s.json")" = logs/Oct-2026/04-Oct-2026/220415Z-lab-2-run36606934354.1-PASSED ]

git init -q --bare "$T/origin.git"; git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
( cd "$T/repo" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git push -q origin HEAD 2>/dev/null
  "$ROOT/scripts/commit-logs.sh" "$T/fail/report" > /dev/null )
D="$T/repo/logs/Oct-2026/04-Oct-2026/220415Z-run36606934354.1-FAILED"
DESC="commit-logs.sh files the report under Mon-YYYY/DD-Mon-YYYY with every artifact"
ok [ "$(cd "$D" 2>/dev/null && ls | paste -sd, -)" = "boot.log,diagnostics-site.txt,status.tsv,summary.json,summary.md,workflow.log" ]
DESC="no numeric logs/YYYY/MM/DD directories"; ok [ -z "$(find "$T/repo/logs" -type d -regex '.*/logs/[0-9]+.*')" ]
DESC="pushed to origin"; ok git -C "$T/origin.git" cat-file -e "HEAD:logs/Oct-2026/04-Oct-2026/220415Z-run36606934354.1-FAILED/workflow.log"

echo; [ "$fails" -eq 0 ] && echo "all logging checks passed" || { echo "$fails logging check(s) FAILED"; exit 1; }
