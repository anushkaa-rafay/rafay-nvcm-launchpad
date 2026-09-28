#!/usr/bin/env bash
#
# commit-logs.sh — file a run report under logs/YYYY/MM/DD/ on this repo's current branch and push.
#
#   commit-logs.sh <report_dir>
#
# Layout:  logs/<yyyy>/<mm>/<dd>/<HHMMSS>Z-run<id>.<attempt>-<STATUS>/{summary.md,summary.json,status.tsv,*.log}
# Dated by the run's START (summary.json .run.started), so a run crossing midnight files under its start day.
# Logs over GZIP_OVER_MB are gzipped in the commit (GitHub rejects files > 100 MB); the workflow artifact
# always keeps them raw. This script is the one seam to replace when logs move to external storage.
#
set -euo pipefail
REPORT="$1"
GZIP_OVER_MB="${GZIP_OVER_MB:-20}"
started="$(jq -r '.run.started // empty' "$REPORT/summary.json")"; started="${started:-$(date -u +%FT%TZ)}"
dest="logs/$(date -u -d "$started" +%Y/%m/%d)/$(date -u -d "$started" +%H%M%S)Z-run$(jq -r '.run.id' "$REPORT/summary.json").$(jq -r '.run.attempt' "$REPORT/summary.json")-$(jq -r '.status' "$REPORT/summary.json")"

mkdir -p "$dest"
cp -r "$REPORT"/. "$dest/"
find "$dest" -type f -size +"${GZIP_OVER_MB}"M -exec gzip -9 {} \;

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$dest"
git commit -q -m "logs: run $(jq -r '"\(.run.id) \(.poc.branch) \(.status)"' "$REPORT/summary.json")"

branch="$(git rev-parse --abbrev-ref HEAD)"
for i in 1 2 3 4 5; do
  git push -q origin "HEAD:$branch" && { echo "committed $dest"; exit 0; }
  echo "push rejected (attempt $i) — rebasing onto origin/$branch"
  git pull -q --rebase origin "$branch"
  sleep $((i*5))
done
echo "::error::could not push logs after 5 attempts (branch protection on $branch?)"; exit 1
