// charts.js — the Run Activity chart as plain SVG (no chart library: one stacked-column chart doesn't earn
// a dependency). Stacked columns per time bucket — success / failed / in progress / other — on one integer
// y-axis, with a hover/keyboard tooltip per bucket. Presentation only; buckets come from metrics.activity().
import { esc, GROUP_LABEL } from './components.js';

const GROUPS = ['success', 'failure', 'active', 'other'];   // bottom → top

/** 0..max in ≤ 5 integer ticks */
export function niceTicks(max) {
  if (max <= 0) return [0, 1];
  const raw = max / 4, mag = 10 ** Math.floor(Math.log10(raw));
  const step = Math.max(1, [1, 2, 5, 10].map(m => m * mag).find(s => s >= raw));
  const top = Math.ceil(max / step) * step;
  const out = []; for (let v = 0; v <= top; v += step) out.push(v);
  return out;
}

export function bucketLabel(start, step, { long = false } = {}) {
  const o = { hour: { hour: '2-digit', minute: '2-digit' }, hour6: { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' },
              day: { month: 'short', day: 'numeric' }, week: { month: 'short', day: 'numeric' }, month: { month: 'short', year: 'numeric' } }[step];
  if (long && step === 'hour') return start.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  if (long && step === 'week') return `Week of ${start.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}`;
  return start.toLocaleString(undefined, o);
}

export function tooltipHtml(title, counts) {
  const rows = GROUPS.map(g => `<div class="r"><span><i class="dot ${g}"></i>${GROUP_LABEL[g]}</span><b>${counts[g] ?? 0}</b></div>`).join('');
  return `<div class="t">${esc(title)}</div>${rows}`;
}

/**
 * Render into `el`. `act` = metrics.activity() result. `tip` = { show(html, x, y), hide() }.
 * Returns nothing; re-call on resize / data change.
 */
export function renderActivity(el, act, tip) {
  const { buckets, step } = act;
  if (!buckets.length || buckets.every(b => b.total === 0)) {
    el.innerHTML = '<div class="empty">No runs in this period.</div>';
    return;
  }
  const W = Math.max(280, el.clientWidth || 600), H = 220;
  const m = { t: 8, r: 8, b: 26, l: 34 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const ticks = niceTicks(Math.max(...buckets.map(b => b.total)));
  const top = ticks[ticks.length - 1];
  const y = v => m.t + ih - (v / top) * ih;
  const band = iw / buckets.length;
  const bw = Math.max(1, Math.min(28, band * 0.72));

  // y grid + labels
  let s = `<g class="axis">${ticks.map(v => `<line class="gridline" x1="${m.l}" x2="${W - m.r}" y1="${y(v)}" y2="${y(v)}"/>
    <text x="${m.l - 6}" y="${y(v) + 3.5}" text-anchor="end">${v}</text>`).join('')}</g>`;

  // stacked columns: 1px surface gap between segments, rounded data-end on the top segment only
  s += '<g>';
  buckets.forEach((b, i) => {
    let acc = 0;
    const x = m.l + i * band + (band - bw) / 2;
    const present = GROUPS.filter(g => b[g] > 0);
    present.forEach((g, k) => {
      const y0 = y(acc), y1 = y(acc + b[g]); acc += b[g];
      const h = Math.max(0, y0 - y1 - (k > 0 ? 1 : 0));
      const isTop = k === present.length - 1, r = Math.min(3, bw / 2, h);
      s += isTop && r > 0
        ? `<path class="seg-${g}" d="M${x},${y0 - (k > 0 ? 1 : 0)}V${y1 + r}Q${x},${y1} ${x + r},${y1}H${x + bw - r}Q${x + bw},${y1} ${x + bw},${y1 + r}V${y0 - (k > 0 ? 1 : 0)}Z"/>`
        : `<rect class="seg-${g}" x="${x}" y="${y1}" width="${bw}" height="${h}"/>`;
    });
  });
  s += `</g><line class="baseline" x1="${m.l}" x2="${W - m.r}" y1="${y(0)}" y2="${y(0)}"/>`;

  // x labels: ≤ ~7, evenly spaced, never overlapping
  const every = Math.max(1, Math.ceil(buckets.length / Math.max(2, Math.floor(iw / 90))));
  s += `<g class="axis">${buckets.map((b, i) => i % every ? '' :
    `<text x="${m.l + i * band + band / 2}" y="${H - 8}" text-anchor="middle">${esc(bucketLabel(b.start, step))}</text>`).join('')}</g>`;

  // full-height hit targets (bigger than the marks)
  s += `<g>${buckets.map((b, i) => `<rect class="hit" data-i="${i}" x="${m.l + i * band}" y="${m.t}" width="${band}" height="${ih}"/>`).join('')}</g>`;

  const total = buckets.reduce((a, b) => a + b.total, 0);
  el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" height="${H}" tabindex="0" role="img"
    aria-label="Run activity: ${total} runs across ${buckets.length} ${esc(act.stepLabel)} buckets. Use arrow keys to step through buckets.">${s}</svg>`;

  const svg = el.querySelector('svg');
  const hits = [...svg.querySelectorAll('.hit')];
  let cur = -1;
  const show = (i, cx, cy) => {
    hits[cur]?.classList.remove('on'); cur = i; hits[i].classList.add('on');
    const b = buckets[i];
    tip.show(tooltipHtml(bucketLabel(b.start, step, { long: true }) + (b.total ? ` · ${b.total} run${b.total === 1 ? '' : 's'}` : ' · no runs'), b), cx, cy);
  };
  const hide = () => { hits[cur]?.classList.remove('on'); cur = -1; tip.hide(); };
  svg.addEventListener('pointermove', e => { const i = e.target.dataset?.i; if (i != null) show(Number(i), e.clientX, e.clientY); });
  svg.addEventListener('pointerleave', hide);
  svg.addEventListener('blur', hide);
  svg.addEventListener('keydown', e => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight' && e.key !== 'Home' && e.key !== 'End') { if (e.key === 'Escape') hide(); return; }
    e.preventDefault();
    let i = cur < 0 ? buckets.length - 1 : cur;
    if (e.key === 'ArrowLeft') i = Math.max(0, i - 1);
    if (e.key === 'ArrowRight') i = Math.min(buckets.length - 1, i + 1);
    if (e.key === 'Home') i = 0;
    if (e.key === 'End') i = buckets.length - 1;
    const r = hits[i].getBoundingClientRect();
    show(i, r.left + r.width / 2, r.top + 24);
  });
}

/** Text alternative: only buckets with runs. */
export function activityTable(act) {
  const rows = act.buckets.filter(b => b.total);
  if (!rows.length) return '<p class="muted">No runs in this period.</p>';
  return `<div class="table-wrap"><table><thead><tr><th scope="col">${esc(act.stepLabel[0].toUpperCase() + act.stepLabel.slice(1))}</th>
    ${GROUPS.map(g => `<th scope="col" class="num">${GROUP_LABEL[g]}</th>`).join('')}<th scope="col" class="num">Total</th></tr></thead><tbody>
    ${rows.map(b => `<tr><td>${esc(bucketLabel(b.start, act.step, { long: true }))}</td>${GROUPS.map(g => `<td class="num">${b[g]}</td>`).join('')}<td class="num">${b.total}</td></tr>`).join('')}
    </tbody></table></div>`;
}
