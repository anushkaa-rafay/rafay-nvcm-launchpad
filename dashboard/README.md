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
| `src/config.js` | Repository owner/name and limits. **Never put a credential here**: this file is published |
| `test/*.test.mjs` | `node:test` unit tests with fixtures shaped like real API responses |
| `scripts/serve.mjs`, `scripts/build.mjs` | Zero-dependency local server; assembles `_site/` for Pages |

Every number on the page comes from one filtered list of runs, so the KPIs, both charts and the table can't
disagree with each other.

## Data source

The data comes live from the GitHub REST API, fetched in the viewer's browser:

- `GET /repos/ramakrishna-rafay/rafay_nvcm_launchpad/actions/runs?per_page=100&created=>=<range start>`:
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

This repository is **private**, which shapes the whole design:

- GitHub Pages serves static files and can't keep a secret, so **the published site contains no token and
  no run data**. It's only the code that draws the page.
- Each viewer connects with **their own** GitHub token. GitHub checks repository access on every API call,
  so someone without access to this repo sees nothing, and nobody sees more than they could already see on
  github.com. No shared or long-lived token is created for the dashboard.
- Recommended token: a **fine-grained personal access token** limited to *only this repository*, with
  permission **Actions: Read-only** (Metadata: Read-only is added automatically), and a short expiry.
  Nothing broader is needed.
- **Collaborators:** this repository is owned by a *personal* account (`ramakrishna-rafay`). A fine-grained
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
- If the repository is ever made public, the page also works with no token at all (60 requests/hour per IP).

## Local development

Needs Node ≥ 20. Nothing to install.

```bash
cd dashboard
npm start        # http://localhost:8080 — paste your token in the Connect panel
npm test         # unit tests (TZ=UTC, fixed timestamps — independent of the real clock)
npm run build    # writes _site/ (what Pages publishes)
```

ES modules don't load from `file://`, so open the page through `npm start` (or any static server), not by
double-clicking `index.html`.

## Deployment (GitHub Pages)

`.github/workflows/dashboard.yml` is separate from the NVCM/OCI workflows: no OCI, no SSH, no secrets, and its
own concurrency group.

- **Every PR and push** touching `dashboard/` runs the tests and the build. It also checks that the
  published files contain only page code and nothing token-shaped.
- **Publishing** runs on `main` only, once the repository owner opts in.

One-time setup by a repository **admin**:

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.** Do this only if Pages isn't
   already used for something else; the workflow never enables or overwrites a Pages setup
   (`configure-pages` with `enablement: false`).
2. **Settings → Secrets and variables → Actions → Variables → New repository variable**:
   `DASHBOARD_PAGES` = `true`.
3. **Actions → dashboard → Run workflow** on `main`, or push a change under `dashboard/`. The deploy job
   prints the site URL, normally `https://ramakrishna-rafay.github.io/rafay_nvcm_launchpad/`.

Things to know:

- **Plan:** Pages for a *private* repository needs GitHub Pro, Team or Enterprise. On plans other than
  Enterprise Cloud the Pages site is **publicly reachable**. That's acceptable here because the page holds
  no data, but it does reveal that the repository exists, and its name. Enterprise Cloud can restrict
  Pages to organization members (Settings → Pages → Visibility).
- Until step 2 is done, the deploy job shows as **skipped** (grey), not failed. Once enabled, a failure
  shows red in Actions like any other job.
- No Pages? Run it locally (`npm start`) or serve `_site/` from any internal static host. Nothing in the
  page depends on GitHub Pages.

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
| "Connect to GitHub" panel on first load | Expected: the repo is private and this tab has no token |
| "Repository not accessible" with a token | A fine-grained token must list *this* repository under "Repository access", with Actions: Read-only. Organization-owned repos may need an admin to approve the token |
| "Access denied", then asked to reconnect | Token expired or revoked (401). Create a new one |
| "Rate limited" | Wait until the reset time shown, or turn off auto-refresh in idle tabs |
| "Partial data" banner | 1,000-run cap, `maxPages`, or an error mid-load. The banner says which. Retry, or narrow the date range |
| Blank page locally | Opened via `file://`. Use `npm start` |
| Deploy job skipped | `DASHBOARD_PAGES` variable isn't `true` (by design until Pages is set up) |
| Deploy fails at "Pages must already be configured" | Pages Source isn't set to GitHub Actions (setup step 1), or the plan doesn't support Pages for private repos |
