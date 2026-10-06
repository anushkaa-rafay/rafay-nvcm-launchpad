#!/usr/bin/env bash
#
# commit-logs.sh — file a run report under logs/<Mon-YYYY>/<DD-Mon-YYYY>/ on this repo's current branch and push.
#
#   commit-logs.sh <report_dir>
#
# Layout:  logs/<Mon-YYYY>/<DD-Mon-YYYY>/<HHMMSS>Z-run<id>.<attempt>-<STATUS>/
#            {workflow.log,boot.log,diagnostics-<job>.txt,status.tsv,summary.json,summary.md}
# e.g.     logs/Oct-2026/04-Oct-2026/220415Z-run36606934354.1-FAILED/   (path built by lp_run_dir, scripts/lib-log.sh)
# Dated by the run's START (summary.json .run.started), so a run crossing midnight files under its start day.
# Logs over GZIP_OVER_MB are gzipped in the commit (GitHub rejects files > 100 MB); the workflow artifact
# always keeps them raw. This script is the one seam to replace when logs move to external storage.
#
set -euo pipefail
# shellcheck source=scripts/lib-log.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-log.sh"
REPORT="$1"
GZIP_OVER_MB="${GZIP_OVER_MB:-20}"
dest="$(lp_run_dir "$REPORT/summary.json")"

mkdir -p "$dest"
cp -r "$REPORT"/. "$dest/"
find "$dest" -type f -size +"${GZIP_OVER_MB}"M -exec gzip -9 {} \;

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$dest"
git commit -q -m "logs: run $(jq -r '"\(.run.id) \(.oci.lab // "?") \(.poc.branch) \(.status)"' "$REPORT/summary.json")"

branch="$(git rev-parse --abbrev-ref HEAD)"
for i in 1 2 3 4 5; do
  git push -q origin "HEAD:$branch" && { echo "committed $dest"; exit 0; }
  echo "push rejected (attempt $i) — rebasing onto origin/$branch"
  git pull -q --rebase origin "$branch"
  sleep $((i*5))
done
echo "::error::could not push logs after 5 attempts (branch protection on $branch?)"; exit 1
