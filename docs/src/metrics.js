// metrics.js — pure functions over GitHub workflow-run records (GET /repos/{o}/{r}/actions/runs items).
// No DOM, no network: everything the KPI cards, charts and table show is computed here, from the same
// filtered list, so the sections can never disagree with each other.

const HOUR = 3600e3, DAY = 24 * HOUR;

export const RANGES = {
  '24h': { label: 'Last 24 hours', ms: DAY },
  '7d':  { label: 'Last 7 days',   ms: 7 * DAY },
  '30d': { label: 'Last 30 days',  ms: 30 * DAY },
  all:   { label: 'All time',      ms: null },
};

/** Start of a date range as a Date, or null for "all time". */
export function rangeStart(range, now = new Date()) {
  const r = RANGES[range];
  if (!r) throw new Error(`unknown range ${range}`);
  return r.ms == null ? null : new Date(now.getTime() - r.ms);
}

// One category per run. KPI semantics follow GitHub's own conclusions literally: "Successful" is
// conclusion=success and "Failed" is conclusion=failure — timed_out / startup_failure are failures of a
// different kind and are counted separately, never folded into either.
export const CATEGORIES = {
  success:     { label: 'Success' },
  failure:     { label: 'Failure' },
  timed_out:   { label: 'Timed out' },
  startup_failure: { label: 'Startup failure' },
  cancelled:   { label: 'Cancelled' },
  skipped:     { label: 'Skipped' },
  in_progress: { label: 'In progress' },
  queued:      { label: 'Queued' },
  other:       { label: 'Other' },
};

export function classify(run) {
  if (run.status !== 'completed') return run.status === 'in_progress' ? 'in_progress' : 'queued';   // queued / waiting / requested / pending
  const c = run.conclusion;
  return c in CATEGORIES && c !== 'in_progress' && c !== 'queued' && c !== 'other' ? c : 'other';  // neutral, action_required, stale, null…
}

/** The four groups the charts colour by. */
export function chartGroup(category) {
  if (category === 'success') return 'success';
  if (category === 'failure' || category === 'timed_out' || category === 'startup_failure') return 'failure';
  if (category === 'in_progress' || category === 'queued') return 'active';
  return 'other';
}

/** Who triggered the run: the re-runner for a re-run (triggering_actor), else the original actor. */
export function actorOf(run) {
  return run.triggering_actor?.login ?? run.actor?.login ?? null;
}

/** When the run (latest attempt) actually started executing — for display and newest-first ordering. */
export function startedAt(run) {
  return new Date(run.run_started_at ?? run.created_at);
}

/**
 * What date ranges and time buckets use: created_at, the same field GitHub's `created` query filters on.
 * A re-run keeps its original created_at, so it counts on the day the run was first created — using
 * run_started_at here would make a narrow window silently drop re-runs that a wider fetch returned.
 */
export function createdAt(run) {
  return new Date(run.created_at ?? run.run_started_at);
}

/**
 * Wall-clock duration of a COMPLETED run: run_started_at → updated_at (GitHub sets updated_at when the run
 * finishes). null when the run isn't completed or a timestamp is missing. Approximate for re-runs, where
 * run_started_at is the latest attempt's start.
 */
export function durationMs(run) {
  if (run.status !== 'completed' || !run.run_started_at || !run.updated_at) return null;
  const d = Date.parse(run.updated_at) - Date.parse(run.run_started_at);
  return Number.isFinite(d) && d >= 0 ? d : null;
}

/** Elapsed time of a run still going, for the table. */
export function elapsedMs(run, now = new Date()) {
  if (run.status === 'completed' || !run.run_started_at) return null;
  return Math.max(0, now.getTime() - Date.parse(run.run_started_at));
}

/** Filters: { since: Date|null, workflowId: number|null, actor: string|null }. Newest first. */
export function filterRuns(runs, { since = null, workflowId = null, actor = null } = {}) {
  return runs
    .filter(r => (since == null || createdAt(r) >= since)
              && (workflowId == null || r.workflow_id === workflowId)
              && (actor == null || actorOf(r) === actor))
    .sort((a, b) => startedAt(b) - startedAt(a));
}

export function kpis(runs) {
  const n = {}; for (const k of Object.keys(CATEGORIES)) n[k] = 0;
  let durSum = 0, durCount = 0;
  for (const r of runs) {
    const c = classify(r); n[c]++;
    const d = c === 'skipped' ? null : durationMs(r);   // a skipped run never executed — not a 0s sample
    if (d != null) { durSum += d; durCount++; }
  }
  const active = n.in_progress + n.queued;
  const completed = runs.length - active;
  const rated = completed - n.skipped;                    // finished runs that actually executed
  return {
    total: runs.length,
    success: n.success,
    failure: n.failure,
    otherFailures: n.timed_out + n.startup_failure,
    cancelled: n.cancelled,
    skipped: n.skipped,
    active,
    completed,
    successRate: rated > 0 ? n.success / rated : null,    // null = nothing to rate, not 0%
    avgDurationMs: durCount > 0 ? durSum / durCount : null,
    durationSamples: durCount,
    byCategory: n,
  };
}

// ── time buckets ─────────────────────────────────────────────────────────────────────────────────────────
// Bucket boundaries are aligned to the viewer's local clock (hour / 6 h / midnight / Monday) and stepped
// with calendar arithmetic, so a DST change never shifts a day bucket.
const STEPS = {
  hour:  { label: 'hour',    floor: d => d.setMinutes(0, 0, 0),                                     next: d => d.setHours(d.getHours() + 1) },
  hour6: { label: '6 hours', floor: d => { d.setMinutes(0, 0, 0); d.setHours(d.getHours() - d.getHours() % 6); }, next: d => d.setHours(d.getHours() + 6) },
  day:   { label: 'day',     floor: d => d.setHours(0, 0, 0, 0),                                     next: d => d.setDate(d.getDate() + 1) },
  week:  { label: 'week',    floor: d => { d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - (d.getDay() + 6) % 7); }, next: d => d.setDate(d.getDate() + 7) },
  month: { label: 'month',   floor: d => { d.setHours(0, 0, 0, 0); d.setDate(1); },                 next: d => d.setMonth(d.getMonth() + 1) },
};

export function pickStep(spanMs) {
  if (spanMs <= 2 * DAY) return 'hour';
  if (spanMs <= 8 * DAY) return 'hour6';
  if (spanMs <= 120 * DAY) return 'day';
  if (spanMs <= 2 * 365 * DAY) return 'week';
  return 'month';
}

/**
 * Activity buckets covering [since, now] — for "all time", from the oldest run shown. Every bucket is
 * present, including empty ones, so gaps read as zero runs rather than vanishing.
 * Returns { step, buckets: [{ start, end, success, failure, active, other, total }] }.
 */
export function activity(runs, since, now = new Date()) {
  const from = since ?? (runs.length ? new Date(Math.min(...runs.map(r => createdAt(r).getTime()))) : now);
  const step = pickStep(now - from);
  const { floor, next } = STEPS[step];
  const buckets = [];
  const cur = new Date(from); floor(cur);
  while (cur <= now) {
    const start = new Date(cur); next(cur);
    buckets.push({ start, end: new Date(cur), success: 0, failure: 0, active: 0, other: 0, total: 0 });
  }
  for (const r of runs) {
    const t = createdAt(r);
    // binary search — "all time" can mean thousands of runs over hundreds of buckets
    let lo = 0, hi = buckets.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (t < buckets[mid].start) hi = mid - 1; else if (t >= buckets[mid].end) lo = mid + 1; else { lo = mid; break; }
    }
    const b = buckets[lo];
    if (!b || t < b.start || t >= b.end) continue;
    b[chartGroup(classify(r))]++; b.total++;
  }
  return { step, stepLabel: STEPS[step].label, buckets };
}

/**
 * Runs per workflow, most-run first. `workflows` (from GET /actions/workflows) adds the workflows with no
 * runs in the selection as zero rows, so "never ran" is visible rather than absent.
 */
export function distribution(runs, workflows = []) {
  const rows = new Map();
  for (const w of workflows) rows.set(w.id, { id: w.id, name: w.name, path: w.path, success: 0, failure: 0, active: 0, other: 0, total: 0 });
  for (const r of runs) {
    let row = rows.get(r.workflow_id);
    if (!row) rows.set(r.workflow_id, row = { id: r.workflow_id, name: r.name ?? `workflow ${r.workflow_id}`, path: r.path, success: 0, failure: 0, active: 0, other: 0, total: 0 });
    row[chartGroup(classify(r))]++; row.total++;
  }
  return [...rows.values()].sort((a, b) => b.total - a.total || a.name.localeCompare(b.name));
}

/** Distinct triggering actors, alphabetical. */
export function actors(runs) {
  return [...new Set(runs.map(actorOf).filter(Boolean))].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
}

// ── formatting ───────────────────────────────────────────────────────────────────────────────────────────
/** 48000 → "48s", 168000 → "2m 48s", 3_900_000 → "1h 5m", 187_200_000 → "2d 4h". null → "—". */
export function formatDuration(ms) {
  if (ms == null || !Number.isFinite(ms)) return '—';
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
  if (m < 60) return s % 60 ? `${m}m ${s % 60}s` : `${m}m`;
  if (h < 24) return m % 60 ? `${h}h ${m % 60}m` : `${h}h`;
  return h % 24 ? `${d}d ${h % 24}h` : `${d}d`;
}

/** "just now", "5 min ago", "3 h ago", "2 days ago" — falls back to a date past 30 days. */
export function formatRelative(date, now = new Date()) {
  const s = Math.round((now - date) / 1000);
  if (s < 45) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  const d = Math.round(s / 86400);
  if (d <= 30) return `${d} day${d === 1 ? '' : 's'} ago`;
  return date.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

export function formatPercent(x) {
  return x == null ? '—' : `${(x * 100).toFixed(x === 1 || x === 0 ? 0 : 1)}%`;
}
