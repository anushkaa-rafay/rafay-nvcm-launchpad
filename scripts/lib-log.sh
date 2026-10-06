# shellcheck shell=bash
#
# lib-log.sh — the run report's log format and location, in one place. Sourced by:
#   * run-stages.sh   — writes each phase job's stages, in order, into <out>/workflow.log as they run;
#   * build-report.sh — stitches every phase's workflow.log into the run's ONE workflow.log;
#   * commit-logs.sh  — files the report under logs/<Mon-YYYY>/<DD-Mon-YYYY>/<run dir>/.
#
# workflow.log section per catalogue stage (stage output itself is copied verbatim, never re-prefixed):
#   ============================================================
#   STAGE 06: substrate (phase: site)
#   ============================================================
#
#   [2026-10-04 22:04:16 UTC] INFO  Starting stage substrate (timeout 120m, run key 36606934354-1)
#   <stdout + stderr of the stage, exactly as the host wrote it>
#   [2026-10-04 22:04:38 UTC] ERROR Stage substrate failed (rc=1, 22s)
#
#   ------------------------------------------------------------
#   STAGE STATUS: FAILED
#   ------------------------------------------------------------

LP_RULE_STAGE="============================================================"
LP_RULE_STATUS="------------------------------------------------------------"

lp_line(){ printf '[%s] %-5s %s\n' "$(date -u '+%F %T UTC')" "$1" "$2"; }   # lp_line INFO|ERROR <message>

# the header's title line — also what build-report.sh greps a phase log for to tell "started" from "never reached"
lp_stage_title(){ printf 'STAGE %02d: %s (phase: %s)' "$1" "$2" "$3"; }

lp_stage_header(){ printf '%s\n%s\n%s\n\n' "$LP_RULE_STAGE" "$(lp_stage_title "$1" "$2" "$3")" "$LP_RULE_STAGE"; }

# <result> as status.tsv spells it (passed, failed, timed-out, lost-contact, skipped, not-selected, interrupted)
lp_stage_footer(){ printf '\n%s\nSTAGE STATUS: %s\n%s\n\n\n' "$LP_RULE_STATUS" "$(tr '[:lower:]' '[:upper:]' <<< "$1")" "$LP_RULE_STATUS"; }

# a whole section for a stage that never ran: lp_stage_stub <idx> <name> <phase> <result>
lp_stage_stub(){
  local why="not run — an earlier stage or phase did not pass"
  [ "$4" = not-selected ] && why="not in this run's stage selection"
  lp_stage_header "$1" "$2" "$3"; lp_line INFO "Stage $2 $why"; lp_stage_footer "$4"
}

# the committed run dir for a report: logs/<Mon-YYYY>/<DD-Mon-YYYY>/<HHMMSS>Z-<lab>-run<id>.<attempt>-<STATUS>
# (no "<lab>-" part for a report without .oci.lab). Dated by the run's START (summary.json .run.started), so a
# run crossing midnight files under its start day. LC_ALL=C: %b must be the English month on any runner locale.
lp_run_dir(){
  local s="$1" started lab
  started="$(jq -r '.run.started // empty' "$s")"; started="${started:-$(date -u +%FT%TZ)}"
  lab="$(jq -r '.oci.lab // empty' "$s")"
  printf 'logs/%s-%srun%s.%s-%s\n' "$(LC_ALL=C date -u -d "$started" +%b-%Y/%d-%b-%Y/%H%M%SZ)" "${lab:+$lab-}" \
      "$(jq -r '.run.id' "$s")" "$(jq -r '.run.attempt' "$s")" "$(jq -r '.status' "$s")"
}
