// app.js — wiring: state, data loading, filters, rendering. API access lives in github.js, every number in
// metrics.js, every piece of markup in components.js / charts.js.
import { CONFIG, repoUrl, actionsUrl } from './config.js';
import { fetchRuns, fetchWorkflows } from './github.js';
import { RANGES, rangeStart, filterRuns, kpis, activity, distribution, actors, chartGroup, classify, formatRelative } from './metrics.js';
import { kpiCards, legend, distributionView, runsTable, banner, esc } from './components.js';
import { renderActivity, activityTable, tooltipHtml } from './charts.js';

const $ = id => document.getElementById(id);
const TOKEN_KEY = 'nvcm-dash-token';
const store = {   // storage can throw (private mode, blocked site data) — the page must work without it
  get(s, k) { try { return s.getItem(k); } catch { return null; } },
  set(s, k, v) { try { v == null ? s.removeItem(k) : s.setItem(k, v); } catch { /* unavailable: per-tab memory only */ } },
};

const state = {
  token: store.get(sessionStorage, TOKEN_KEY),   // the VIEWER's own token, this tab only — never logged or sent elsewhere
  range: '7d', workflowId: null, actor: null,
  data: null,        // { runs, workflows, coveredSince, fetchedAt, complete, reason, totalCount, error }
  loading: false, error: null, needsToken: false,
  shown: CONFIG.tableStep,
  controller: null,
};

// ── URL ⇄ filters (shareable links; no token in the URL, ever) ───────────────────────────────────────────
function readUrl() {
  const p = new URLSearchParams(location.search);
  if (p.get('range') in RANGES) state.range = p.get('range');
  const wf = Number(p.get('workflow')); if (Number.isInteger(wf) && wf > 0) state.workflowId = wf;
  if (p.get('actor')) state.actor = p.get('actor');
}
function writeUrl() {
  const p = new URLSearchParams();
  if (state.range !== '7d') p.set('range', state.range);
  if (state.workflowId) p.set('workflow', state.workflowId);
  if (state.actor) p.set('actor', state.actor);
  history.replaceState(null, '', `${location.pathname}${p.toString() ? `?${p}` : ''}${location.hash}`);
}

// ── loading ──────────────────────────────────────────────────────────────────────────────────────────────
/** Fetch the selected range — unless the loaded data already covers it (narrowing filters locally). */
async function load({ force = false } = {}) {
  const since = rangeStart(state.range);
  const covered = state.data && (state.data.coveredSince == null || (since && since >= state.data.coveredSince));
  if (!force && covered && state.data.complete) { render(); return; }

  state.controller?.abort();
  const controller = state.controller = new AbortController();
  state.loading = true; state.error = null; render();
  const base = { owner: CONFIG.owner, repo: CONFIG.repo, token: state.token, signal: controller.signal };
  try {
    const [workflows, res] = await Promise.all([
      state.data?.workflows && !force ? state.data.workflows : fetchWorkflows(base),
      fetchRuns({ ...base, since, pageSize: CONFIG.pageSize, maxPages: CONFIG.maxPages,
                  onProgress: ({ loaded, totalCount }) => { $('progress').textContent = `Loading runs… ${loaded}${totalCount != null ? ` of ${totalCount}` : ''}`; } }),
    ]);
    if (controller !== state.controller) return;   // superseded by a newer load
    state.data = { ...res, workflows, coveredSince: since, fetchedAt: new Date() };
    state.needsToken = false;
  } catch (e) {
    if (e?.name === 'AbortError' || controller !== state.controller) return;
    state.error = e;
    // a private repo answers 404 to anyone without access — that's "connect", not a failure
    state.needsToken = !state.token && (e.kind === 'not_found' || e.kind === 'auth');
    if (state.token && e.kind === 'auth' && e.status === 401) { setToken(null); state.needsToken = true; }
  } finally {
    if (controller === state.controller) { state.loading = false; state.controller = null; $('progress').textContent = ''; render(); }
  }
}

function setToken(t) {
  state.token = t || null;
  store.set(sessionStorage, TOKEN_KEY, state.token);
  state.data = null;   // data loaded under another identity must not linger
}

// ── rendering ────────────────────────────────────────────────────────────────────────────────────────────
function selection() {
  const d = state.data;
  if (!d) return null;
  const since = rangeStart(state.range);
  const inRange = filterRuns(d.runs, { since });
  const byWorkflow = filterRuns(inRange, { workflowId: state.workflowId });
  const runs = filterRuns(byWorkflow, { actor: state.actor });
  return { since, inRange, byWorkflow, runs };
}

function renderFilters(sel) {
  const r = $('f-range');
  if (!r.options.length) r.innerHTML = Object.entries(RANGES).map(([k, v]) => `<option value="${k}">${esc(v.label)}</option>`).join('');
  r.value = state.range;

  const wfs = new Map((state.data?.workflows ?? []).map(w => [w.id, w.name]));
  for (const run of state.data?.runs ?? []) if (!wfs.has(run.workflow_id)) wfs.set(run.workflow_id, run.name);
  if (state.workflowId && !wfs.has(state.workflowId)) wfs.set(state.workflowId, `workflow ${state.workflowId}`);
  $('f-workflow').innerHTML = '<option value="">All workflows</option>' +
    [...wfs].sort((a, b) => a[1].localeCompare(b[1])).map(([id, n]) => `<option value="${id}">${esc(n)}</option>`).join('');
  $('f-workflow').value = state.workflowId ?? '';

  // users: everyone who triggered something in the date range + workflow selection (so a pick can't dead-end)
  const users = sel ? actors(sel.byWorkflow) : [];
  if (state.actor && !users.includes(state.actor)) users.unshift(state.actor);
  $('f-actor').innerHTML = '<option value="">All users</option>' + users.map(u => `<option>${esc(u)}</option>`).join('');
  $('f-actor').value = state.actor ?? '';

  for (const id of ['f-range', 'f-workflow', 'f-actor']) $(id).disabled = state.needsToken;
}

function renderBanners() {
  const out = [], e = state.error, d = state.data;
  if (e && !state.needsToken) {
    const title = { auth: 'Access denied.', not_found: 'Repository not accessible.', rate_limit: 'Rate limited.', network: 'Network error.', http: 'GitHub API error.' }[e.kind] ?? 'Error.';
    let text = e.message;
    if (e.kind === 'rate_limit' && e.resetAt) text += ` It resets at ${e.resetAt.toLocaleTimeString()}.`;
    if (e.kind === 'not_found' && state.token) text = 'This token cannot see the repository. A fine-grained token must list this repository and grant Actions: Read-only.';
    if (d) text += ' Showing the data from the last successful load.';
    // a public repo loads without a token until the shared 60/hour anonymous limit runs out — offer one then
    const action = e.kind === 'rate_limit' && !state.token ? { id: 'connect', label: 'Connect a token' } : { id: 'retry', label: 'Retry' };
    out.push(banner({ kind: 'error', title, text, action }));
  }
  if (d && !d.complete) {
    const n = d.runs.length;
    const text = d.reason === 'capped'
      ? (d.totalCount > 1000 && d.coveredSince
          ? `GitHub returns at most 1,000 runs per date-filtered query; this range has ${d.totalCount}. Metrics cover the newest ${n}.`
          : `Loaded the newest ${n} of ${d.totalCount ?? 'more'} runs (dashboard limit ${CONFIG.maxPages * CONFIG.pageSize}). Older runs are not counted.`)
      : `Loading stopped after ${n} of ${d.totalCount ?? '?'} runs (${d.error?.message ?? 'error'}). Metrics cover the loaded runs only.`;
    out.push(banner({ kind: 'warn', title: 'Partial data.', text, action: d.reason === 'error' ? { id: 'retry', label: 'Retry' } : null }));
  }
  $('banners').innerHTML = out.join('');
}

let lastSel = null;
function render() {
  const sel = selection(); lastSel = sel;
  $('connect').hidden = !state.needsToken;
  $('account').hidden = !state.token;
  $('account').textContent = 'Disconnect';
  const rb = $('refresh'); rb.disabled = state.loading || state.needsToken; rb.classList.toggle('loading', state.loading);
  rb.querySelector('span').textContent = state.loading ? 'Refreshing…' : 'Refresh';
  renderUpdated();
  renderFilters(sel);
  renderBanners();

  // KPIs: "—" (unavailable) until real data exists — never a fake 0
  $('kpis').innerHTML = kpiCards(sel ? kpis(sel.runs) : null, { loading: state.loading });

  const loadingOnly = state.loading && !sel;
  if (!sel) {
    const msg = state.needsToken ? 'Connect to GitHub to load runs.' : state.error ? 'Data unavailable.' : '';
    for (const id of ['activity', 'distribution', 'runs-table']) $(id).innerHTML = loadingOnly ? '<div class="skeleton"></div>' : `<div class="empty">${esc(msg)}</div>`;
    $('act-legend').innerHTML = ''; $('act-table').innerHTML = ''; $('runs-sub').textContent = ''; $('more').hidden = true;
    return;
  }

  // Run activity
  const act = activity(sel.runs, sel.since);
  const counts = { success: 0, failure: 0, active: 0, other: 0 };
  for (const r of sel.runs) counts[chartGroup(classify(r))]++;
  $('act-legend').innerHTML = legend(counts);
  $('act-sub').textContent = `Runs created per ${act.stepLabel} · ${RANGES[state.range].label.toLowerCase()}`;
  renderActivity($('activity'), act, tip);
  $('act-table').innerHTML = activityTable(act);

  // Workflow distribution follows every filter; with no workflow picked, workflows with zero runs in the
  // selection still get a row, so "never ran" is visible rather than missing.
  $('distribution').innerHTML = distributionView(distribution(sel.runs, state.workflowId ? state.data.workflows.filter(w => w.id === state.workflowId) : state.data.workflows),
                                                 { repoUrl, selectedId: state.workflowId });

  // Recent runs
  const shown = sel.runs.slice(0, state.shown);
  $('runs-table').innerHTML = runsTable(shown);
  $('runs-sub').textContent = sel.runs.length ? `Showing ${shown.length} of ${sel.runs.length}, newest first` : '';
  $('more').hidden = shown.length >= sel.runs.length;
  $('more').textContent = `Show ${Math.min(CONFIG.tableStep, sel.runs.length - shown.length)} more`;
}

function renderUpdated() {
  const at = state.data?.fetchedAt;
  $('updated').innerHTML = at
    ? `Last updated <time datetime="${at.toISOString()}" title="${esc(at.toLocaleString())}">${esc(at.toLocaleTimeString())}</time> · ${esc(formatRelative(at))}`
    : state.loading ? 'Loading…' : 'Not loaded yet';
}

// ── tooltip (shared by both charts) ──────────────────────────────────────────────────────────────────────
const tip = {
  show(html, x, y) {
    const t = $('tooltip'); t.innerHTML = html; t.hidden = false;
    const w = t.offsetWidth, h = t.offsetHeight, pad = 12;
    t.style.left = `${Math.min(window.innerWidth - w - 8, x + pad)}px`;
    t.style.top = `${y - h - pad < 8 ? y + pad : y - h - pad}px`;
  },
  hide() { $('tooltip').hidden = true; },
};

// ── events ───────────────────────────────────────────────────────────────────────────────────────────────
function bind() {
  $('repo-link').href = repoUrl; $('repo-link').textContent = `${CONFIG.owner}/${CONFIG.repo}`;
  $('all-runs').href = actionsUrl;

  $('f-range').addEventListener('change', e => { state.range = e.target.value; state.shown = CONFIG.tableStep; writeUrl(); load(); });
  $('f-workflow').addEventListener('change', e => { state.workflowId = e.target.value ? Number(e.target.value) : null; state.shown = CONFIG.tableStep; writeUrl(); render(); });
  $('f-actor').addEventListener('change', e => { state.actor = e.target.value || null; state.shown = CONFIG.tableStep; writeUrl(); render(); });
  $('refresh').addEventListener('click', () => load({ force: true }));
  $('more').addEventListener('click', () => { state.shown += CONFIG.tableStep; render(); });
  $('banners').addEventListener('click', e => {
    if (e.target.closest('[data-action="retry"]')) load({ force: true });
    if (e.target.closest('[data-action="connect"]')) { state.needsToken = true; render(); $('token').focus(); }
  });

  $('connect-form').addEventListener('submit', e => {
    e.preventDefault();
    const t = $('token').value.trim(); $('token').value = '';
    if (!t) return;
    setToken(t); state.error = null; load({ force: true });
  });
  $('account').addEventListener('click', () => { setToken(null); state.error = null; state.needsToken = true; render(); });

  $('theme').addEventListener('click', () => {
    const dark = document.documentElement.dataset.theme
      ? document.documentElement.dataset.theme === 'dark'
      : matchMedia('(prefers-color-scheme: dark)').matches;
    document.documentElement.dataset.theme = dark ? 'light' : 'dark';
    store.set(localStorage, 'nvcm-dash-theme', document.documentElement.dataset.theme);
  });

  // whole row opens the run (the run-number cell is the real, keyboard-focusable link)
  $('runs-table').addEventListener('click', e => {
    if (e.target.closest('a')) return;
    const tr = e.target.closest('tr[data-href]');
    if (tr && tr.dataset.href !== '#') window.open(tr.dataset.href, '_blank', 'noopener');
  });

  // distribution hover tooltip
  $('distribution').addEventListener('pointermove', e => {
    const row = e.target.closest('.dist-row');
    if (!row) return tip.hide();
    const d = JSON.parse(row.dataset.tip);
    tip.show(tooltipHtml(`${d.t} · ${d.success + d.failure + d.active + d.other} runs`, d), e.clientX, e.clientY);
  });
  $('distribution').addEventListener('pointerleave', () => tip.hide());

  // charts re-layout on width change
  let w = 0;
  new ResizeObserver(([entry]) => {
    const nw = Math.round(entry.contentRect.width);
    if (nw !== w) { w = nw; if (lastSel) renderActivity($('activity'), activity(lastSel.runs, lastSel.since), tip); }
  }).observe($('activity'));

  // auto-refresh: only while visible, never stacked on an in-flight load
  const auto = $('auto');
  auto.checked = store.get(localStorage, 'nvcm-dash-auto') !== 'off';
  auto.addEventListener('change', () => store.set(localStorage, 'nvcm-dash-auto', auto.checked ? 'on' : 'off'));
  const stale = () => !state.data || Date.now() - state.data.fetchedAt >= CONFIG.autoRefreshMs;
  const tick = () => { if (auto.checked && !document.hidden && !state.loading && !state.needsToken && stale()) load({ force: true }); };
  setInterval(tick, 30e3);
  setInterval(renderUpdated, 30e3);
  document.addEventListener('visibilitychange', tick);
}

readUrl();
bind();
load();
