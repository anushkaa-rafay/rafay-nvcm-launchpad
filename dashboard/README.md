# NVCM Launchpad · Workflow Operations dashboard

A read-only view of this repository's GitHub Actions runs: how often each workflow runs, who triggers it,
success/failure rates, durations, and the run history. Every row links straight to the run on GitHub. The
dashboard **complements** the Actions tab; it doesn't replace it.

```
┌ header: NVCM Launchpad · Workflow Operations · last updated · auto-refresh · Refresh · theme
├ filters: date range (24 h / 7 d / 30 d / all) · workflow · triggered by        ← kept in the URL, shareable
├ KPIs: Total runs · Successful (+ success rate) · Failed · Avg duration
├ Run activity (stacked columns per hour / 6 h / day / week)  │  Workflow distribution (runs per workflow)
└ Recent runs (newest first, 25 at a time, rows open the GitHub run) · View all runs →
```

## Architecture

A static page: plain HTML + CSS + native ES modules. No framework, no bundler, no chart library, no runtime
dependencies.

| File | Role |
|---|---|
| `src/github.js` | Read-only GitHub REST client. Follows every `Link: rel="next"` page, dedupes by run id, typed errors (auth / not found / rate limit / network / http), returns **partial** results instead of dropping them |
| `src/metrics.js` | Pure functions: status classification, filters, KPIs, time buckets, per-workflow counts, formatting. No DOM, no network |
| `src/components.js` | Markup for KPI cards, status badges, the runs table, distribution rows, banners. Escapes every API string |
| `src/charts.js` | The Run Activity chart as plain SVG, with hover/keyboard tooltips and a table view |
| `src/app.js` | State, filters ⇄ URL, loading/refresh, token handling, rendering |
| `src/config.js` | Limits, and a `__GITHUB_REPOSITORY__` placeholder for the repository. **Never put a credential here**: this file is published |
| `scripts/repo.mjs` | Picks the repository at build/serve time: `DASHBOARD_REPOSITORY` → `GITHUB_REPOSITORY` → the checkout's `origin` |
| `test/*.test.mjs` | `node:test` unit tests with fixtures shaped like real API responses |
| `scripts/serve.mjs`, `scripts/build.mjs` | Zero-dependency local server; builds the page into `docs/` (`npm run pages`) for Pages |

Every number on the page comes from one filtered list of runs, so the KPIs, both charts and the table can't
disagree with each other.

## Data source

The data comes live from the GitHub REST API, fetched in the viewer's browser:

- `GET /repos/{owner}/{repo}/actions/runs?per_page=100&created=>=<range start>`:
  all pages. "All time" omits `created`.
- `GET /repos/…/actions/workflows`: names the workflows. Workflows with no runs in the selection still
  show up as zero rows.

How the numbers are computed:

| Metric | Definition |
|---|---|
| Total runs | Runs **created** in the range (`created_at`, the field GitHub's `created` filter uses) matching the workflow/user filters, including in-progress runs. A re-run counts on the day the run was first created; the table's "Started" shows when the latest attempt actually ran |
| Successful | `conclusion == success` |
| Failed | `conclusion == failure`. Timed-out and startup failures are shown separately on the card ("+N timed out / startup failure") and never counted as successful |
| Success rate | successful ÷ (completed runs − skipped runs). Shows "—" when there's nothing to rate |
| Avg duration | Mean of `updated_at − run_started_at` over **completed, non-skipped** runs. This is wall-clock time for the latest attempt |
| Triggered by | `triggering_actor` (the person who re-ran it), else `actor` |
| Chart colours | green = success · red = failure, timed out, startup failure · amber = in progress or queued · grey = cancelled, skipped, other |

Filtering by workflow or user happens in the browser on runs already loaded, so it costs no API calls.
Changing to a *narrower* date range also reuses loaded data. Only a wider range or Refresh calls the API.

**Unavailable is never shown as zero.** Before data loads, or after an error, the KPIs show "—" and say
why. A partial load shows a banner saying how many runs were counted.

### Refresh

- **Refresh** reloads the current date range and updates "Last updated".
- **Auto-refresh** (on by default, toggle in the header, remembered per browser) reloads every 5 minutes,
  but only while the tab is visible and never on top of a load already in progress. It also catches up when
  you return to the tab. Change the interval with `autoRefreshMs` in `src/config.js`.

## Authentication and security

Which repository the page reports on is decided when it's built, never hardcoded: the repository the
dashboard workflow runs in (`GITHUB_REPOSITORY`), unless the repository variable `DASHBOARD_REPOSITORY`
(`owner/repo`) names another one. Locally, `npm start` / `npm run build` use `DASHBOARD_REPOSITORY` or
`GITHUB_REPOSITORY` from the environment, else this checkout's `origin` remote.

- **Public repository:** the page loads with no token. Anonymous calls share a limit of 60 requests/hour per
  network (IP); when it runs out, the "Rate limited" banner offers **Connect a token**.
- **Private repository:** every viewer needs a token, as below.

Either way:

- GitHub Pages serves static files and can't keep a secret, so **the published site contains no token and
  no run data**. It's only the code that draws the page.
- Each viewer connects with **their own** GitHub token. GitHub checks repository access on every API call,
  so someone without access to this repo sees nothing, and nobody sees more than they could already see on
  github.com. No shared or long-lived token is created for the dashboard.
- Recommended token: a **fine-grained personal access token** limited to *only this repository*, with
  permission **Actions: Read-only** (Metadata: Read-only is added automatically), and a short expiry.
  Nothing broader is needed.
- **Collaborators:** when the repository is owned by a *personal* account, a fine-grained
  token can only target repositories owned by its own account or by an organization the user belongs to,
  so only the owner can create one for it. Collaborators need a **classic** token with the `repo` scope.
  That scope is broad (read *and write* to every repository the user can access), so give it a short expiry,
  use it only for this page, and revoke it when you're done. Moving the repository into a GitHub
  organization would let everyone use the narrow fine-grained token instead.
- The token is kept in that tab's `sessionStorage`. It's sent only to `api.github.com` (as
  `Authorization: Bearer …`), is never written to the URL or the console, is dropped when the tab closes or
  on **Disconnect**, and is cleared automatically if GitHub rejects it (401).
- API strings such as branch, workflow and user names are HTML-escaped before rendering. Only `http(s)`
  links are allowed in `href`s. The page sends `no-referrer`.

## This branch

The `dashboard` branch holds **only** the dashboard; the NVCM automation lives on `main`. The two branches
have separate histories: never merge one into the other (Git refuses unless forced, because they share no
history). The page reports on the repository's Actions runs whichever branch they ran on.

```
.github/workflows/dashboard.yml   tests + "docs/ is current" check on every push/PR to this branch
dashboard/                        the source: page, styles, src/, tests, build/serve scripts
docs/                             the built page — what GitHub Pages serves (generated: never edit by hand)
```

## Local development

Needs Node ≥ 20. Nothing to install.

```bash
git switch dashboard && git pull
cd dashboard
npm test         # unit tests (TZ=UTC, fixed timestamps — independent of the real clock)
npm start        # http://localhost:8080, reporting on this checkout's origin repo
npm run pages    # rebuilds <repo>/docs/ — exactly what Pages serves
npm run build    # optional scratch preview in _site/ (git-ignored)
```

ES modules don't load from `file://`, so open the page through `npm start` (or any static server), not by
double-clicking `index.html`.

**Which repository it reports on** is set by the build, never hardcoded: `DASHBOARD_REPOSITORY`
(`owner/repo`) if set in the environment, else this checkout's `origin` remote. In `dashboard.yml` it's the
repository variable `DASHBOARD_REPOSITORY`, else the repository the workflow runs in.

## Deployment (GitHub Pages, from this branch)

Pages serves `docs/` straight from this branch: Settings → Pages → **Deploy from a branch** → `dashboard`,
`/docs`. No workflow of ours deploys anything. GitHub runs its own "pages build and deployment" job whenever
a push changes `docs/`. The site holds only page code — no run data and no token — so new workflow runs
never need a redeploy.

### 1. Build and check locally

Run `npm test`, `npm start` and `npm run pages` as above. The page must show the repository name in the
header, filled KPI cards and recent runs. "Repository not accessible" means the repository name is wrong or,
for a private repo, the token can't see it.

### 2. Commit and push `docs/`

```bash
cd ..                                   # repo root
git add dashboard docs
git commit -m "dashboard: <what changed>"
git push origin dashboard
```

`docs/` must be rebuilt and committed together with any change under `dashboard/`: Pages serves whatever is
committed there. `dashboard.yml` enforces it — every push and PR to this branch rebuilds and fails with
*"docs/ is out of date"* if the result differs from the commit.

### 3. One-time Pages setup (repository admin)

1. **Settings → Pages → Build and deployment → Source: Deploy from a branch.**
2. **Branch:** `dashboard`, folder **`/docs`** → **Save**. Push `docs/` first (step 2): the folder must
   already exist on the branch to be selectable.
3. Wait for the **pages build and deployment** run in the Actions tab to go green (about a minute). The site
   is at `https://<owner>.github.io/<repo>/`; Settings → Pages shows the link.
4. Open it and run the same check as step 1. Pages tells browsers to cache for up to 10 minutes: if you see
   an old version (or what was there before), hard-refresh (Cmd/Ctrl + Shift + R) or use a private window.

No secrets are involved. **Plan:** Pages is free for a *public* repository. A *private* one needs GitHub
Pro, Team or Enterprise, and outside Enterprise Cloud the site is **publicly reachable**. That's acceptable
because it holds no data, but it does reveal the repository's name. No Pages at all? Copy `docs/` to any
static host; nothing in the page depends on GitHub Pages.

### 4. Keeping it up to date

| Change | What to do |
|---|---|
| Code under `dashboard/` changed | `npm run pages`, commit `dashboard/` and `docs/` together, push. Pages redeploys by itself |
| New workflow runs (NVCM, lint…) | nothing — the page reads runs live (Refresh, or auto-refresh every 5 min) |
| Report on another repository | `DASHBOARD_REPOSITORY=owner/repo npm run pages`, commit, push. Also set the repository variable `DASHBOARD_REPOSITORY` to the same value, or the `docs/` check in `dashboard.yml` fails |
| Take the site down | Settings → Pages → **Unpublish site** (or Source: None) |

## Limitations

- **1,000-run cap.** GitHub returns at most 1,000 runs for a date-filtered query (`created`). If a range
  has more, the page shows a "Partial data" banner and counts the newest 1,000. "All time" uses the
  unfiltered listing and loads at most `maxPages × 100` (3,000) runs, with the same banner when it stops.
- **Retention.** Runs deleted by hand or removed under the repository's retention settings are gone from
  the API. The dashboard can't show history that GitHub no longer returns.
- **Durations** are wall-clock from the start of the latest attempt to completion (`updated_at`). They
  include queue time inside the run and are approximate for re-runs. Exact billed timing would need one
  `/runs/{id}/timing` call per run, which isn't done.
- **Rate limit:** 5,000 requests/hour per token. A 30-day load is usually 1–3 requests, and auto-refresh
  is about 12–36 requests/hour.

### Optional: history beyond the API (designed, not built)

For analytics that outlive GitHub's run history, record each run when it finishes:

1. Add a small workflow on `workflow_run: { workflows: [nvcm-greenfield, nvcm-brownfield, lint], types: [completed] }`
   with `actions: read`, `contents: write`.
2. It appends the run's fields (id, workflow, actor, event, branch, conclusion, timestamps) as one JSON line to
   `dashboard-data/runs-YYYY-MM.jsonl` on a dedicated branch, so it doesn't add noise to `main`.
3. The dashboard reads those files through the contents API, using the viewer's token as now, and merges
   them with live data, deduping by run id.

The NVCM workflows already keep a durable per-run record: `logs/<Mon-YYYY>/<DD-Mon-YYYY>/<run>/summary.json`
(per-stage results). That's the natural source for stage-level analytics later.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Connect to GitHub" panel on first load | Expected for a private repo: this tab has no token. On a public repo it means the repository name is wrong — check `DASHBOARD_REPOSITORY` |
| "Repository not accessible" with a token | A fine-grained token must list *this* repository under "Repository access", with Actions: Read-only. Organization-owned repos may need an admin to approve the token |
| "Access denied", then asked to reconnect | Token expired or revoked (401). Create a new one |
| "Rate limited" | Wait until the reset time shown, or turn off auto-refresh in idle tabs |
| "Partial data" banner | 1,000-run cap, `maxPages`, or an error mid-load. The banner says which. Retry, or narrow the date range |
| Blank page locally | Opened via `file://`. Use `npm start` |
| `dashboard.yml`: "docs/ is out of date" | Run `npm run pages` in `dashboard/` and commit `docs/` |
| `/docs` not offered in Settings → Pages | `docs/` isn't on the `dashboard` branch yet. Push it, then reload the settings page |
| Site shows an old page (or the README) | Browser cache (up to 10 min): hard-refresh. Else the "pages build and deployment" run hasn't finished, or Source isn't `dashboard` + `/docs` |
