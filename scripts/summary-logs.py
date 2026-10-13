#!/usr/bin/env python3
"""summary-logs.py — the logs part of a run's Summary tab, printed as markdown.

  scripts/summary-logs.py <report_dir> >> "$GITHUB_STEP_SUMMARY"      # after summary.md, in the report job

For every stage that didn't pass (failed, timed-out, lost-contact, interrupted) a collapsible section with
the last 100 lines of its workflow.log section; boot.log's tail when the run died before any stage. Then
where the full logs are. Lines are capped at 400 characters: GitHub truncates a step summary over 1 MiB.
"""
import json
import os
import sys

import lplib

TAIL_LINES, MAX_LINE = 100, 400
NOT_FAILED = {"passed", "skipped", "not-selected"}

if len(sys.argv) != 2:
    lplib.fail("usage: summary-logs.py <report_dir>")
rep = sys.argv[1]
try:
    s = json.load(open(os.path.join(rep, "summary.json"), encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(0)   # build-report.sh didn't get far enough; summary.md already says what it could


def block(title, lines, total):
    lines = [l if len(l) <= MAX_LINE else l[:MAX_LINE] + " …" for l in lines]
    shown = "last %d of %d lines" % (len(lines), total) if total > len(lines) else "%d lines" % len(lines)
    print("<details><summary>%s — %s</summary>\n\n~~~~~~text\n%s\n~~~~~~\n\n</details>\n"
          % (title, shown, "\n".join(lines) or "(no output captured)"))


failed = [x for x in s.get("stages", []) if x.get("result") not in NOT_FAILED]
if failed or s.get("status") == "FAILED":
    print("### Logs\n")
for x in failed:
    section = lplib.stage_section(os.path.join(rep, "workflow.log"), x["name"])
    block("❌ <b>%s</b> (%s, rc %s)" % (x["name"], x["result"], x.get("rc") or "—"), section[-TAIL_LINES:], len(section))
if not failed and s.get("status") == "FAILED":
    boot = lplib.tail(os.path.join(rep, "boot.log"), 10**6)
    block("❌ <b>%s</b> — boot.log" % (s.get("failed_stage") or "boot"), boot[-TAIL_LINES:], len(boot))

print("Full logs: **workflow.log** (every stage, in order) and **diagnostics-*.txt** are in this run's "
      "**run-report** artifact below, and committed to this repo under `logs/`.")
