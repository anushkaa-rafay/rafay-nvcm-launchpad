import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classify, chartGroup, kpis, filterRuns, rangeStart, activity, distribution, actors, actorOf,
         durationMs, elapsedMs, formatDuration, formatRelative, formatPercent, pickStep } from '../src/metrics.js';
import { run, NOW } from './fixtures.mjs';

test('classify: every status/conclusion lands in exactly one category', () => {
  assert.equal(classify(run({ conclusion: 'success' })), 'success');
  assert.equal(classify(run({ conclusion: 'failure' })), 'failure');
  assert.equal(classify(run({ conclusion: 'timed_out' })), 'timed_out');
  assert.equal(classify(run({ conclusion: 'startup_failure' })), 'startup_failure');
  assert.equal(classify(run({ conclusion: 'cancelled' })), 'cancelled');
  assert.equal(classify(run({ conclusion: 'skipped' })), 'skipped');
  assert.equal(classify(run({ conclusion: 'neutral' })), 'other');
  assert.equal(classify(run({ conclusion: 'action_required' })), 'other');
  assert.equal(classify(run({ status: 'in_progress' })), 'in_progress');
  for (const s of ['queued', 'waiting', 'requested', 'pending']) assert.equal(classify(run({ status: s })), 'queued');
});

test('chartGroup: failure-like conclusions are red, active amber, the rest neutral', () => {
  assert.deepEqual(['success', 'failure', 'timed_out', 'startup_failure', 'in_progress', 'queued', 'cancelled', 'skipped', 'other'].map(chartGroup),
    ['success', 'failure', 'failure', 'failure', 'active', 'active', 'other', 'other', 'other']);
});

test('kpis: Successful/Failed count only success/failure; nothing else leaks in', () => {
  const k = kpis([
    run({ conclusion: 'success', minutes: 2 }), run({ conclusion: 'success', minutes: 4 }),
    run({ conclusion: 'failure', minutes: 6 }), run({ conclusion: 'timed_out', minutes: 10 }),
    run({ conclusion: 'cancelled', minutes: 1 }), run({ conclusion: 'skipped', minutes: 0 }),
    run({ status: 'in_progress' }), run({ status: 'queued' }),
  ]);
  assert.equal(k.total, 8);
  assert.equal(k.success, 2);
  assert.equal(k.failure, 1);
  assert.equal(k.otherFailures, 1);
  assert.equal(k.cancelled, 1);
  assert.equal(k.skipped, 1);
  assert.equal(k.active, 2);
  assert.equal(k.completed, 6);
  // rate over finished runs that executed: 2 / (6 completed - 1 skipped)
  assert.equal(k.successRate, 2 / 5);
  // average over completed, non-skipped runs: (2+4+6+10+1)/5 min
  assert.equal(k.durationSamples, 5);
  assert.equal(k.avgDurationMs, (23 / 5) * 60e3);
});

test('kpis: empty selection is zero runs with null (not 0) rate and duration', () => {
  const k = kpis([]);
  assert.equal(k.total, 0);
  assert.equal(k.successRate, null);
  assert.equal(k.avgDurationMs, null);
});

test('durations come from real timestamps; unfinished runs have none', () => {
  assert.equal(durationMs(run({ minutes: 2.8 })), 168e3);
  assert.equal(durationMs(run({ status: 'in_progress' })), null);
  assert.equal(durationMs({ ...run(), run_started_at: null }), null);
  assert.equal(durationMs({ ...run(), updated_at: '2020-01-01T00:00:00Z' }), null);   // negative → unusable
  assert.equal(elapsedMs(run({ status: 'in_progress', started: '2026-10-05T11:30:00Z' }), NOW), 30 * 60e3);
});

test('filterRuns: date, workflow and actor filters compose; newest first', () => {
  const runs = [
    run({ started: '2026-10-05T09:00:00Z', workflow: 1, actor: 'alice' }),
    run({ started: '2026-10-05T11:00:00Z', workflow: 2, actor: 'bob' }),
    run({ started: '2026-10-01T09:00:00Z', workflow: 1, actor: 'bob' }),
    run({ started: '2026-09-01T09:00:00Z', workflow: 1, actor: 'alice' }),
  ];
  const day = filterRuns(runs, { since: rangeStart('24h', NOW) });
  assert.deepEqual(day.map(r => r.started ?? r.run_started_at), ['2026-10-05T11:00:00Z', '2026-10-05T09:00:00Z']);
  assert.equal(filterRuns(runs, { since: rangeStart('7d', NOW) }).length, 3);
  assert.equal(filterRuns(runs, { since: rangeStart('30d', NOW) }).length, 3);
  assert.equal(filterRuns(runs, {}).length, 4);
  assert.equal(filterRuns(runs, { workflowId: 1 }).length, 3);
  assert.equal(filterRuns(runs, { workflowId: 1, actor: 'bob' }).length, 1);
  assert.equal(filterRuns(runs, { since: rangeStart('24h', NOW), actor: 'bob', workflowId: 1 }).length, 0);
});

test('date range uses created_at like the API — a re-run of an old run stays on its creation day', () => {
  const rerun = { ...run({ started: '2026-09-25T09:00:00Z' }), run_started_at: '2026-10-05T11:00:00Z', run_attempt: 2 };
  assert.equal(filterRuns([rerun], { since: rangeStart('24h', NOW) }).length, 0);   // created 10 days ago
  assert.equal(filterRuns([rerun], { since: rangeStart('30d', NOW) }).length, 1);
  const a = activity([rerun], rangeStart('30d', NOW), NOW);
  assert.equal(a.buckets.find(b => b.total).start.toISOString(), '2026-09-25T00:00:00.000Z');
});

test('actor = the triggering actor (re-runs), falling back to the original actor', () => {
  assert.equal(actorOf(run({ actor: 'alice', trigger: 'carol' })), 'carol');
  assert.equal(actorOf({ ...run({ actor: 'alice' }), triggering_actor: null }), 'alice');
  assert.deepEqual(actors([run({ actor: 'bob' }), run({ actor: 'Alice' }), run({ actor: 'bob' })]), ['Alice', 'bob']);
});

test('rangeStart', () => {
  assert.equal(rangeStart('24h', NOW).toISOString(), '2026-10-04T12:00:00.000Z');
  assert.equal(rangeStart('7d', NOW).toISOString(), '2026-09-28T12:00:00.000Z');
  assert.equal(rangeStart('all', NOW), null);
  assert.throws(() => rangeStart('1y', NOW));
});

test('activity: hourly buckets for 24 h, every bucket present, counts add up', () => {
  const runs = [
    run({ started: '2026-10-05T10:05:00Z' }), run({ started: '2026-10-05T10:55:00Z', conclusion: 'failure' }),
    run({ started: '2026-10-05T11:10:00Z', status: 'in_progress' }), run({ started: '2026-10-04T13:00:00Z', conclusion: 'cancelled' }),
  ];
  const a = activity(runs, rangeStart('24h', NOW), NOW);
  assert.equal(a.step, 'hour');
  assert.equal(a.buckets.length, 25);   // 12:00 yesterday … 12:00 today, inclusive of the current hour
  const at = iso => a.buckets.find(b => b.start.toISOString() === iso);
  assert.deepEqual({ ...at('2026-10-05T10:00:00.000Z'), start: 0, end: 0 }, { start: 0, end: 0, success: 1, failure: 1, active: 0, other: 0, total: 2 });
  assert.equal(at('2026-10-05T11:00:00.000Z').active, 1);
  assert.equal(at('2026-10-04T13:00:00.000Z').other, 1);
  assert.equal(a.buckets.reduce((s, b) => s + b.total, 0), runs.length);
});

test('activity: bucket size follows the range', () => {
  assert.equal(activity([], rangeStart('7d', NOW), NOW).step, 'hour6');
  assert.equal(activity([], rangeStart('30d', NOW), NOW).step, 'day');
  assert.equal(activity([], rangeStart('30d', NOW), NOW).buckets.length, 31);
  assert.equal(pickStep(200 * 864e5), 'week');
  assert.equal(pickStep(3 * 365 * 864e5), 'month');
  // all time: spans from the oldest run
  const all = activity([run({ started: '2026-06-01T00:00:00Z' }), run({ started: '2026-10-05T00:00:00Z' })], null, NOW);
  assert.equal(all.step, 'week');
  assert.equal(all.buckets.reduce((s, b) => s + b.total, 0), 2);
  // empty all-time: no crash, no runs
  assert.equal(activity([], null, NOW).buckets.reduce((s, b) => s + b.total, 0), 0);
});

test('distribution: per-workflow totals, most-run first, zero rows for idle workflows', () => {
  const d = distribution(
    [run({ workflow: 2, name: 'lint' }), run({ workflow: 1 }), run({ workflow: 2, name: 'lint', conclusion: 'failure' })],
    [{ id: 1, name: 'nvcm-greenfield' }, { id: 2, name: 'lint' }, { id: 3, name: 'nvcm-brownfield' }]);
  assert.deepEqual(d.map(r => [r.name, r.total, r.success, r.failure]),
    [['lint', 2, 1, 1], ['nvcm-greenfield', 1, 1, 0], ['nvcm-brownfield', 0, 0, 0]]);
  // a run from a workflow missing from the list (deleted file) still counts
  assert.equal(distribution([run({ workflow: 9, name: 'old' })], []).at(0).name, 'old');
});

test('formatDuration', () => {
  assert.equal(formatDuration(null), '—');
  assert.equal(formatDuration(0), '0s');
  assert.equal(formatDuration(48e3), '48s');
  assert.equal(formatDuration(168e3), '2m 48s');
  assert.equal(formatDuration(120e3), '2m');
  assert.equal(formatDuration(3900e3), '1h 5m');
  assert.equal(formatDuration(7200e3), '2h');
  assert.equal(formatDuration(187_200e3), '2d 4h');
});

test('formatRelative / formatPercent', () => {
  assert.equal(formatRelative(new Date(NOW - 10e3), NOW), 'just now');
  assert.equal(formatRelative(new Date(NOW - 5 * 60e3), NOW), '5 min ago');
  assert.equal(formatRelative(new Date(NOW - 3 * 3600e3), NOW), '3 h ago');
  assert.equal(formatRelative(new Date(NOW - 864e5), NOW), '1 day ago');
  assert.equal(formatPercent(null), '—');
  assert.equal(formatPercent(1), '100%');
  assert.equal(formatPercent(2 / 3), '66.7%');
});
