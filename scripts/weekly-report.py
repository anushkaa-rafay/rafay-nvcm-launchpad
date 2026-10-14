#!/usr/bin/env python3
"""weekly-report.py — the last N days of greenfield/brownfield runs, as a mail and a step summary.

  scripts/weekly-report.py [--days 7] [--out weekly] [--mail]     # from the repo root (it reads logs/)

Runs come from the GitHub Actions API (so a cancelled run, or one that died before committing its logs,
still counts); each run's stage detail comes from its committed logs/…/run<id>.<attempt>-*/summary.json.
Writes <out>/report.md (for $GITHUB_STEP_SUMMARY) and <out>/report.html; --mail sends the HTML to MAIL_TO
(see scripts/lplib.py — with MAIL_TO unset it sends nothing). Env: GITHUB_REPOSITORY (else the git origin),
GITHUB_TOKEN (optional for a public repo; anonymous calls are limited to 60 an hour).
"""
import argparse
import datetime as dt
import glob
import html
import json
import os
import re
import subprocess
import sys
import urllib.request
from collections import Counter, defaultdict

import lplib

WORKFLOWS = ["nvcm-greenfield.yml", "nvcm-brownfield.yml"]

ap = argparse.ArgumentParser()
ap.add_argument("--days", type=int, default=7)
ap.add_argument("--out", default="weekly")
ap.add_argument("--mail", action="store_true")
args = ap.parse_args()

repo = os.environ.get("GITHUB_REPOSITORY")
if not repo:
    url = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(\.git)?$", url)
    repo = m.group(1) if m else lplib.fail("GITHUB_REPOSITORY not set and no GitHub origin to infer it from")
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
since = now - dt.timedelta(days=args.days)


def api(path):
    req = urllib.request.Request("https://api.github.com" + path, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    if os.environ.get("GITHUB_TOKEN"):
        req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001 — any API failure ends the report with the reason
        lplib.fail("GitHub API %s: %s" % (path, e))


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def hm(seconds):
    if seconds is None:
        return ""
    h, m = divmod(int(seconds) // 60, 60)
    return "%dh %02dm" % (h, m) if h else "%dm %02ds" % divmod(int(seconds), 60)


# ── collect ──────────────────────────────────────────────────────────────────────────────────────────────
runs = []
for wf in WORKFLOWS:
    page = 1
    while True:
        r = api("/repos/%s/actions/workflows/%s/runs?per_page=100&page=%d&created=%%3E%%3D%s"
                % (repo, wf, page, since.strftime("%Y-%m-%dT%H:%M:%SZ")))
        for x in r.get("workflow_runs", []):
            x["_wf"] = wf.removesuffix(".yml")
            runs.append(x)
        if len(r.get("workflow_runs", [])) < 100:
            break
        page += 1

rows = []
for x in runs:
    hits = glob.glob("logs/*/*/*run%s.%s-*/summary.json" % (x["id"], x["run_attempt"]))
    s = json.load(open(hits[0], encoding="utf-8")) if hits else None
    if x["status"] != "completed":
        result = "RUNNING"
    elif s:
        result = s["status"]
    else:
        result = {"success": "PASSED", "failure": "FAILED", "timed_out": "FAILED", "startup_failure": "FAILED",
                  "cancelled": "CANCELLED", "skipped": "CANCELLED"}.get(x["conclusion"], (x["conclusion"] or "?").upper())
    if not s and x["conclusion"] == "startup_failure":
        s = {"failed_stage": "startup (GitHub could not start the run — a workflow file error)"}
    start, end = ts(x.get("run_started_at")), ts(x.get("updated_at"))
    rows.append({
        "workflow": x["_wf"], "id": x["id"], "attempt": x["run_attempt"], "url": x["html_url"],
        "trigger": "daily" if x["event"] == "schedule" else ("manual" if x["event"] == "workflow_dispatch" else x["event"]),
        "actor": (x.get("triggering_actor") or x.get("actor") or {}).get("login", ""),
        "started": start, "seconds": (end - start).total_seconds() if start and end and result != "RUNNING" else None,
        "result": result, "failed_stage": (s or {}).get("failed_stage") or "",
        "lab": ((s or {}).get("oci") or {}).get("lab", ""), "branch": ((s or {}).get("poc") or {}).get("branch", ""),
        "stages": (s or {}).get("stages", []), "logged": bool(hits),
    })
rows.sort(key=lambda r: r["started"] or now, reverse=True)
done = [r for r in rows if r["result"] != "RUNNING"]

# ── aggregate ────────────────────────────────────────────────────────────────────────────────────────────
def tally(rs):
    c = Counter(r["result"] for r in rs)
    decided = c["PASSED"] + c["FAILED"]
    return c, ("%d%%" % round(100 * c["PASSED"] / decided)) if decided else "—"


by_wf = [(wf, *tally([r for r in done if r["workflow"] == wf])) for wf in sorted({r["workflow"] for r in done})]
daily = [r for r in done if r["trigger"] == "daily"]
fail_stage = Counter(r["failed_stage"].split(" ")[0] for r in done if r["result"] == "FAILED" and r["failed_stage"])
dur, order = defaultdict(list), {}
for r in done:
    for st in r["stages"]:
        order.setdefault(st["name"], st["index"])   # catalogue position, to list stages in run order
        if st.get("result") == "passed" and st.get("seconds") is not None:
            dur[(r["workflow"], st["name"])].append(st["seconds"])

total, rate = tally(done)
period = "%s → %s (UTC)" % (since.strftime("%d %b %Y"), now.strftime("%d %b %Y"))
icon = {"PASSED": "✅", "FAILED": "❌", "CANCELLED": "⚪", "RUNNING": "⏳"}

# ── render: one table model → markdown and HTML ─────────────────────────────────────────────────────────
tables = []   # (title, header, rows, note)
tables.append(("By workflow", ["Workflow", "Runs", "Passed", "Failed", "Cancelled", "Pass rate"],
               [[wf, sum(c.values()), c["PASSED"], c["FAILED"], c["CANCELLED"], pr] for wf, c, pr in by_wf]
               or [["(no runs)", 0, 0, 0, 0, "—"]], ""))
if daily:
    dc, drate = tally(daily)
    tables.append(("Daily greenfield run", ["Date (UTC)", "Result", "Failed stage", "Duration"],
                   [[r["started"].strftime("%a %d %b"), "%s %s" % (icon.get(r["result"], "❔"), r["result"]),
                     r["failed_stage"] or "—", hm(r["seconds"])] for r in daily],
                   "%d of %d passed (%s)" % (dc["PASSED"], len(daily), drate)))
if fail_stage:
    tables.append(("Where runs failed", ["Stage", "Failures"], [[k, v] for k, v in fail_stage.most_common()], ""))
if dur:
    tables.append(("Stage durations (passed stages)", ["Workflow", "Stage", "Runs", "Average", "Longest"],
                   [[wf, st, len(v), hm(sum(v) / len(v)), hm(max(v))]
                    for (wf, st), v in sorted(dur.items(), key=lambda kv: (kv[0][0], order[kv[0][1]]))], ""))
tables.append(("All runs", ["Started (UTC)", "Workflow", "Trigger", "By", "Lab", "Branch", "Result", "Failed stage", "Duration", "Run"],
               [[r["started"].strftime("%a %d %b %H:%M") if r["started"] else "", r["workflow"], r["trigger"], r["actor"], r["lab"] or "—",
                 r["branch"] or "—", "%s %s" % (icon.get(r["result"], "❔"), r["result"]), r["failed_stage"] or "—", hm(r["seconds"]),
                 ("link", r["url"], "#%s.%s" % (r["id"], r["attempt"]))] for r in rows] or [["(no runs)"] + [""] * 9],
               "" if all(r["logged"] for r in done) else "Runs without committed logs (cancelled early, or died before the report job) show no lab, branch or stage."))

headline = "%d run%s · %d passed · %d failed · %d cancelled · pass rate %s" % (
    len(done), "" if len(done) == 1 else "s", total["PASSED"], total["FAILED"], total["CANCELLED"], rate)
running = len(rows) - len(done)


def md_cell(v):
    if isinstance(v, tuple):
        return "[%s](%s)" % (v[2], v[1])
    return str(v).replace("|", "\\|")


links = [(n, u) for n, u in (("Dashboard", lplib.dashboard_url()), ("Logs folder", lplib.logs_url())) if u]
md = ["## NVCM weekly report — %s" % period, "", "**%s**%s" % (headline, " · %d still running" % running if running else ""), ""]
md += [" · ".join("[%s](%s)" % l for l in links), ""] if links else []
for title, head, body, note in tables:
    md += ["### " + title, "", "| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    md += ["| " + " | ".join(md_cell(c) for c in row) + " |" for row in body]
    md += ([""] + [note] if note else []) + [""]

e = html.escape


def html_cell(v):
    if isinstance(v, tuple):
        return '<a href="%s">%s</a>' % (e(v[1]), e(v[2]))
    return e(str(v))


th = 'style="text-align:left;padding:4px 10px 4px 0;border-bottom:1px solid #d0d7de"'
td = 'style="padding:3px 10px 3px 0;border-bottom:1px solid #eaeef2;vertical-align:top;white-space:nowrap"'
parts = ['<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:14px">',
         "<h2 style=\"margin:0 0 4px\">NVCM weekly report</h2><div style=\"color:#57606a\">%s · %s</div>" % (e(period), e(repo)),
         "<p style=\"font-size:16px\"><b>%s</b>%s</p>" % (e(headline), e(" · %d still running" % running) if running else "")]
if links:
    parts.append("<p>%s</p>" % " · ".join('<a href="%s">%s</a>' % (e(u), e(n)) for n, u in links))
for title, head, body, note in tables:
    parts.append("<h3 style=\"margin:20px 0 6px\">%s</h3>" % e(title))
    parts.append("<table style=\"border-collapse:collapse\"><tr>%s</tr>%s</table>" % (
        "".join("<th %s>%s</th>" % (th, e(h)) for h in head),
        "".join("<tr>%s</tr>" % "".join("<td %s>%s</td>" % (td, html_cell(c)) for c in row) for row in body)))
    if note:
        parts.append("<p style=\"color:#57606a;font-size:12px\">%s</p>" % e(note))
parts.append("</div>")

os.makedirs(args.out, exist_ok=True)
open(os.path.join(args.out, "report.md"), "w", encoding="utf-8").write("\n".join(md))
open(os.path.join(args.out, "report.html"), "w", encoding="utf-8").write("\n".join(parts))
print(headline)
if args.mail and lplib.mail_configured():
    lplib.send_mail("[NVCM] Weekly report %s – %s · %s" % (since.strftime("%d %b"), now.strftime("%d %b"), headline),
                    "\n".join(parts))
