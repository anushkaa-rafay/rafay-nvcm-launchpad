#!/usr/bin/env python3
"""failure-mail.py — mail a FAILED run's report: what failed, the failed stage's last lines, the logs attached.

  scripts/failure-mail.py <report_dir>        # the dir build-report.sh wrote; run by the report job on FAILED

Reads <report_dir>/summary.json (the report's stable contract) and attaches workflow.log plus the failed
phase's diagnostics (boot.log when the run died before any stage). Recipients and SMTP come from the
environment — see scripts/lplib.py. With MAIL_TO unset it sends nothing and exits 0.
"""
import glob
import html
import json
import os
import subprocess
import sys

import lplib

TAIL_LINES = 60

if len(sys.argv) != 2:
    lplib.fail("usage: failure-mail.py <report_dir>")
rep = sys.argv[1]
try:
    s = json.load(open(os.path.join(rep, "summary.json"), encoding="utf-8"))
except (OSError, ValueError) as e:
    lplib.fail("no usable summary.json in %s: %s" % (rep, e))
if not lplib.mail_configured():
    sys.exit(0)

workflow = os.environ.get("GITHUB_WORKFLOW") or "NVCM run"
run, poc, oci = s.get("run", {}), s.get("poc", {}), s.get("oci", {})
failed = s.get("failed_stage") or "unknown"
stage = next((x for x in s.get("stages", []) if x["name"] == failed), None)
e = html.escape

# the failed stage's own output; a run that died before any stage (lab / boot) has only boot.log
if stage:
    lines = lplib.stage_section(os.path.join(rep, "workflow.log"), failed)[-TAIL_LINES:]
    files = [os.path.join(rep, "workflow.log")] + sorted(glob.glob(os.path.join(rep, "diagnostics-%s.txt" % stage["phase"])))
    where = "stage <b>%s</b> (phase %s)" % (e(failed), e(stage["phase"]))
else:
    lines = lplib.tail(os.path.join(rep, "boot.log"), TAIL_LINES)
    files = [os.path.join(rep, f) for f in ("boot.log", "workflow.log")]
    where = "<b>%s</b>" % e(failed)

icon = {"passed": "✅", "skipped": "⚪", "not-selected": "⚪"}
rows = "".join(
    "<tr><td>%d</td><td>%s</td><td>%s</td><td>%s %s</td><td>%s</td></tr>" % (
        x["index"], e(x["name"]), e(x["phase"]), icon.get(x["result"], "❌"), e(x["result"]),
        "" if x.get("seconds") is None else "%dm %02ds" % divmod(x["seconds"], 60))
    for x in s.get("stages", []))
# this run's folder under logs/, named exactly as commit-logs.sh files it (lp_run_dir, scripts/lib-log.sh)
run_dir = subprocess.run(["bash", "-c", '. "$1/lib-log.sh" && lp_run_dir "$2"', "_", os.path.dirname(os.path.abspath(__file__)),
                          os.path.join(rep, "summary.json")], capture_output=True, text=True).stdout.strip()
links = [(n, u) for n, u in (("Run logs folder", lplib.logs_url(run_dir) if run_dir else lplib.logs_url()),
                             ("Dashboard", lplib.dashboard_url())) if u]
td = 'style="padding:2px 10px 2px 0;vertical-align:top"'
facts = [
    ("Failed at", where),
    ("Branch", "<code>%s</code> @ <code>%s</code>" % (e(poc.get("branch", "?")), e((poc.get("sha") or "?")[:12]))),
    ("Lab", "<code>%s</code>" % e(oci.get("lab") or "?")),
    ("Run", '<a href="%s">%s #%s</a> · %s by %s' % (e(run.get("url", "")), e(run.get("id", "")), e(run.get("attempt", "")),
                                                   e(run.get("trigger", "")), e(run.get("actor", "")))),
    ("Started → finished (UTC)", "%s → %s" % (e(run.get("started") or "?"), e(run.get("finished") or "?"))),
] + [(n, '<a href="%s">%s</a>' % (e(u), e(u))) for n, u in links]
body = """<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:14px">
<h2 style="margin:0 0 8px">❌ %s failed</h2>
<table>%s</table>
<h3 style="margin:16px 0 4px">Stages</h3>
<table style="border-collapse:collapse" cellpadding="3"><tr><th align=left>#</th><th align=left>Stage</th><th align=left>Phase</th>
<th align=left>Result</th><th align=left>Duration</th></tr>%s</table>
<h3 style="margin:16px 0 4px">Last %d lines of %s</h3>
<pre style="background:#f6f8fa;padding:8px;font-size:12px;white-space:pre-wrap">%s</pre>
<p>Attached: %s. The full report is also in the run's <i>run-report</i> artifact and committed under <code>logs/</code> (the folder linked above).</p>
</div>""" % (e(workflow), "".join("<tr><td %s>%s</td><td>%s</td></tr>" % (td, k, v) for k, v in facts), rows,
             len(lines), "the stage" if stage else "boot.log", e("\n".join(lines)) or "(no output captured)",
             ", ".join(e(os.path.basename(f)) for f in files if os.path.isfile(f)) or "nothing (no log files were produced)")

subject = "[NVCM] ❌ %s FAILED at %s · %s · %s · run %s#%s" % (
    workflow, failed.split(" ")[0], oci.get("lab") or "?", poc.get("branch") or "?", run.get("id", "?"), run.get("attempt", "?"))
lplib.send_mail(subject, body, files)
