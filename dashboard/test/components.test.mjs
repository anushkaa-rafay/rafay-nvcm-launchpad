import { test } from 'node:test';
import assert from 'node:assert/strict';
import { esc, safeUrl, statusBadge, kpiCards, runsTable, distributionView } from '../src/components.js';
import { kpis } from '../src/metrics.js';
import { niceTicks } from '../src/charts.js';
import { run, NOW } from './fixtures.mjs';

test('API strings are escaped — a branch name cannot inject markup', () => {
  const evil = run({ branch: '<img src=x onerror=alert(1)>', name: '"><script>x</script>', actor: '<b>me</b>' });
  const html = runsTable([evil], { now: NOW }) + distributionView([{ id: 1, name: evil.name, total: 1, success: 1, failure: 0, active: 0, other: 0 }], { repoUrl: 'https://github.com/o/r' });
  assert.ok(!html.includes('<img src=x'));
  assert.ok(!html.includes('<script>'));
  assert.ok(!html.includes('<b>me</b>'));
  assert.equal(esc(`<a href="x">'&`), '&lt;a href=&quot;x&quot;&gt;&#39;&amp;');
});

test('only http(s) URLs become links', () => {
  assert.equal(safeUrl('javascript:alert(1)'), '#');
  assert.equal(safeUrl('not a url'), '#');
  assert.equal(safeUrl('https://github.com/x'), 'https://github.com/x');
});

test('status badges: distinct class + label per state', () => {
  const b = c => statusBadge(run(c));
  assert.match(b({ conclusion: 'success' }), /class="badge success".*Success/s);
  assert.match(b({ conclusion: 'failure' }), /class="badge failure".*Failure/s);
  assert.match(b({ conclusion: 'timed_out' }), /class="badge failure".*Timed out/s);
  assert.match(b({ status: 'in_progress' }), /class="badge active".*In progress/s);
  assert.match(b({ conclusion: 'cancelled' }), /class="badge other".*Cancelled/s);
  assert.match(b({ conclusion: 'skipped' }), /class="badge other".*Skipped/s);
});

test('KPI cards: unavailable data shows "—", never a 0', () => {
  const html = kpiCards(null);
  assert.equal((html.match(/>—</g) ?? []).length, 4);
  assert.ok(!/class="value">0</.test(html));
  assert.match(kpiCards(null, { loading: true }), /Loading…/);
  // a genuine zero is a 0
  assert.match(kpiCards(kpis([])), /class="value">0</);
});

test('runs table: each row links to its GitHub run; empty state', () => {
  const r = run();
  const html = runsTable([r], { now: NOW });
  assert.ok(html.includes(`data-href="${r.html_url}"`));
  assert.ok(html.includes(`href="${r.html_url}"`));
  assert.match(html, /3m/);
  assert.match(runsTable([], { now: NOW }), /No runs match/);
  assert.match(runsTable([run({ status: 'in_progress', started: '2026-10-05T11:00:00Z' })], { now: NOW }), /1h.*running/s);
});

test('niceTicks: integer axis that covers the max', () => {
  assert.deepEqual(niceTicks(0), [0, 1]);
  assert.deepEqual(niceTicks(3), [0, 1, 2, 3]);
  const t = niceTicks(37); assert.ok(t.at(-1) >= 37 && t.every(Number.isInteger) && t.length <= 6);
});
