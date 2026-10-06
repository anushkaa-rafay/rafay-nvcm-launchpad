// components.js — presentation only: turns already-computed data into HTML. Every value that came from the
// API (workflow / branch / actor names are user-controlled — a branch can be named <img onerror=…>) goes
// through esc(). Nothing here fetches or computes metrics.
import { CATEGORIES, chartGroup, classify, actorOf, startedAt, durationMs, elapsedMs,
         formatDuration, formatRelative, formatPercent } from './metrics.js';

export function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

/** only http(s) links from the API make it into an href */
export function safeUrl(u) {
  try { const x = new URL(u); return x.protocol === 'https:' || x.protocol === 'http:' ? x.href : '#'; } catch { return '#'; }
}

// chart groups: red covers failure + timed_out + startup_failure (the Failed KPI counts conclusion=failure only)
export const GROUP_LABEL = { success: 'Success', failure: 'Failed / timed out', active: 'In progress', other: 'Cancelled / skipped' };

// status icons — shape carries the state too, so colour is never the only cue
const ICON = {
  success: '<path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z"/>',
  failure: '<path d="M3.72 3.72a.75.75 0 0 1 1.06 0L8 6.94l3.22-3.22a.75.75 0 1 1 1.06 1.06L9.06 8l3.22 3.22a.75.75 0 1 1-1.06 1.06L8 9.06l-3.22 3.22a.75.75 0 0 1-1.06-1.06L6.94 8 3.72 4.78a.75.75 0 0 1 0-1.06Z"/>',
  active:  '<path d="M8 2a6 6 0 1 0 6 6h-1.5A4.5 4.5 0 1 1 8 3.5V2Z"/>',
  other:   '<path d="M8 1.5a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13Zm0 1.5a5 5 0 0 0-3.9 8.1l7-7A5 5 0 0 0 8 3Zm3.9 1.9-7 7A5 5 0 0 0 11.9 4.9Z"/>',
};
const icon = g => `<svg aria-hidden="true" viewBox="0 0 16 16" width="12" height="12" fill="currentColor">${ICON[g]}</svg>`;

export function statusBadge(run) {
  const cat = classify(run), g = chartGroup(cat);
  return `<span class="badge ${g}">${icon(g)}${esc(CATEGORIES[cat].label)}</span>`;
}

// ── KPI cards ────────────────────────────────────────────────────────────────────────────────────────────
function card(title, value, note, dot) {
  const na = value == null;
  return `<article class="kpi">
    <h3>${dot ? `<span class="dot ${dot}" aria-hidden="true"></span>` : ''}${esc(title)}</h3>
    <div class="value${na ? ' na' : ''}">${na ? '—' : esc(value)}</div>
    <div class="note">${note}</div>
  </article>`;
}

/** k = kpis(...) result, or null while nothing is loaded ("unavailable" — never shown as 0). */
export function kpiCards(k, { loading = false } = {}) {
  if (!k) {
    const why = loading ? 'Loading…' : 'Unavailable';
    return [card('Total runs', null, why), card('Successful', null, why, 'success'),
            card('Failed', null, why, 'failure'), card('Avg duration', null, why)].join('');
  }
  const totalNote = [k.completed && `${k.completed} completed`, k.active && `${k.active} in progress`]
    .filter(Boolean).join(' · ') || 'no runs in this selection';
  const extra = [k.otherFailures && `+${k.otherFailures} timed out / startup failure`, k.cancelled && `${k.cancelled} cancelled`]
    .filter(Boolean).join(' · ');
  return [
    card('Total runs', k.total, esc(totalNote)),
    card('Successful', k.success, k.successRate == null ? 'no finished runs to rate' : `${formatPercent(k.successRate)} success rate`, 'success'),
    card('Failed', k.failure, esc(extra || (k.completed ? 'conclusion: failure' : '—')), 'failure'),
    card('Avg duration', k.avgDurationMs == null ? null : formatDuration(k.avgDurationMs),
         k.durationSamples ? `over ${k.durationSamples} completed run${k.durationSamples === 1 ? '' : 's'}` : 'no completed runs'),
  ].join('');
}

// ── legend (counts are part of the label, so it also serves as a summary) ─────────────────────────────────
export function legend(counts) {
  return ['success', 'failure', 'active', 'other']
    .map(g => `<span><i class="dot ${g}" aria-hidden="true"></i>${GROUP_LABEL[g]} <b>${counts[g] ?? 0}</b></span>`).join('');
}

// ── Workflow distribution ────────────────────────────────────────────────────────────────────────────────
export function distributionView(rows, { repoUrl, selectedId = null }) {
  if (!rows.length) return '<div class="empty">No workflows found.</div>';
  const max = Math.max(1, ...rows.map(r => r.total));
  const items = rows.map(r => {
    const file = r.path ? r.path.split('/').pop() : null;
    const href = file ? `${repoUrl}/actions/workflows/${encodeURIComponent(file)}` : `${repoUrl}/actions`;
    const segs = ['success', 'failure', 'active', 'other'].filter(g => r[g] > 0)
      .map(g => `<span class="seg-bg ${g}" style="width:${(r[g] / max) * 100}%;background:var(--${g === 'success' ? 'ok' : g === 'failure' ? 'bad' : g})"></span>`).join('');
    const breakdown = ['success', 'failure', 'active', 'other'].map(g => `${GROUP_LABEL[g]}: ${r[g]}`).join(', ');
    return `<div class="dist-row" data-id="${esc(r.id)}" data-tip="${esc(JSON.stringify({ t: r.name, success: r.success, failure: r.failure, active: r.active, other: r.other }))}"
              ${selectedId === r.id ? 'aria-current="true"' : ''}>
      <a class="dist-name${r.total ? '' : ' zero'}" href="${esc(href)}" target="_blank" rel="noopener" title="${esc(r.name)}${r.path ? ` (${esc(r.path)})` : ''}">${esc(r.name)}</a>
      <span class="dist-count" aria-label="${r.total} runs">${r.total}</span>
      <div class="dist-bar" role="img" aria-label="${esc(r.name)}: ${esc(breakdown)}">${segs}</div>
    </div>`;
  }).join('');
  const zero = rows.filter(r => !r.total).length;
  return `<div class="dist">${items}</div>${zero ? `<p class="dist-foot muted">${zero} workflow${zero === 1 ? ' has' : 's have'} no runs in this selection.</p>` : ''}`;
}

// ── Recent runs ──────────────────────────────────────────────────────────────────────────────────────────
export function runsTable(runs, { now = new Date() } = {}) {
  if (!runs.length) return '<div class="empty">No runs match these filters.</div>';
  const rows = runs.map(r => {
    const url = safeUrl(r.html_url), who = actorOf(r);
    const avatar = (r.triggering_actor ?? r.actor)?.avatar_url;
    const start = startedAt(r);
    const d = durationMs(r), el = elapsedMs(r, now);
    const dur = d != null ? formatDuration(d) : el != null ? `${formatDuration(el)} <small class="muted">running</small>` : '—';
    const attempt = r.run_attempt > 1 ? ` <span class="muted">· attempt ${esc(r.run_attempt)}</span>` : '';
    return `<tr class="run" data-href="${esc(url)}">
      <td><a href="${esc(url)}" target="_blank" rel="noopener">#${esc(r.run_number)}</a>${attempt}<span class="id">${esc(r.id)}</span></td>
      <td class="wf" title="${esc(r.name)}">${esc(r.name)}</td>
      <td><span class="who">${avatar ? `<img src="${esc(safeUrl(avatar))}&s=40" alt="" loading="lazy">` : ''}${esc(who ?? '—')}</span></td>
      <td>${esc(r.event)}</td>
      <td>${r.head_branch ? `<span class="branch" title="${esc(r.head_branch)}">${esc(r.head_branch)}</span>` : '—'}</td>
      <td class="when"><time datetime="${esc(start.toISOString())}">${esc(start.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }))}</time><small>${esc(formatRelative(start, now))}</small></td>
      <td class="num">${dur}</td>
      <td>${statusBadge(r)}</td>
    </tr>`;
  }).join('');
  return `<table>
    <caption class="skip">Workflow runs, newest first. Each row opens the run on GitHub.</caption>
    <thead><tr><th scope="col">Run</th><th scope="col">Workflow</th><th scope="col">Triggered by</th><th scope="col">Event</th>
      <th scope="col">Branch</th><th scope="col">Started</th><th scope="col" class="num">Duration</th><th scope="col">Status</th></tr></thead>
    <tbody>${rows}</tbody></table>`;
}

/** banner({kind:'error'|'warn', title, text, action?:{id,label}}) */
export function banner({ kind, title, text, action }) {
  return `<div class="banner ${kind}" role="${kind === 'error' ? 'alert' : 'status'}">
    <div><strong>${esc(title)}</strong> ${esc(text)}</div>
    ${action ? `<button type="button" class="btn" data-action="${esc(action.id)}">${esc(action.label)}</button>` : ''}
  </div>`;
}
