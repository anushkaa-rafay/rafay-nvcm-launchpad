// github.js — read-only GitHub REST client for the dashboard. No DOM. `fetchImpl` is injectable for tests.
//
// The token (if any) is the VIEWER's own, passed in per call — this module never stores, logs or embeds it.
// GitHub enforces repository access on every request, so a viewer only ever sees what their own account
// can already see on github.com.

const API = 'https://api.github.com';

/** kind: 'auth' | 'not_found' | 'rate_limit' | 'network' | 'http' */
export class GitHubError extends Error {
  constructor(kind, message, { status = null, resetAt = null } = {}) {
    super(message);
    this.name = 'GitHubError';
    this.kind = kind; this.status = status; this.resetAt = resetAt;
  }
}

function headers(token) {
  const h = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
  if (token) h.Authorization = `Bearer ${token}`;
  return h;
}

/** rel="next" target of a Link header, or null. */
export function nextLink(link) {
  if (!link) return null;
  for (const part of link.split(',')) {
    const m = part.match(/<([^>]+)>\s*;\s*rel="next"/);
    if (m) return m[1];
  }
  return null;
}

async function request(url, { token, fetchImpl, signal }) {
  let res;
  try {
    res = await fetchImpl(url, { headers: headers(token), signal });
  } catch (e) {
    if (e?.name === 'AbortError') throw e;
    throw new GitHubError('network', 'Could not reach api.github.com — check your connection.');
  }
  const remaining = res.headers.get('x-ratelimit-remaining');
  const reset = res.headers.get('x-ratelimit-reset');
  const resetAt = reset ? new Date(Number(reset) * 1000) : null;
  if (res.ok) {
    let body;
    try { body = await res.json(); } catch { throw new GitHubError('http', 'GitHub returned an unreadable response.', { status: res.status }); }
    return { body, link: res.headers.get('link'), rateLimit: remaining == null ? null : { remaining: Number(remaining), resetAt } };
  }
  if (res.status === 401) throw new GitHubError('auth', 'GitHub rejected the token (expired or revoked).', { status: 401 });
  if (res.status === 404) throw new GitHubError('not_found', 'Repository not found — it is private and this browser has no token with access to it, or the name is wrong.', { status: 404 });
  if ((res.status === 403 || res.status === 429) && (remaining === '0' || res.headers.get('retry-after'))) {
    const retry = res.headers.get('retry-after');
    throw new GitHubError('rate_limit', 'GitHub API rate limit reached.',
      { status: res.status, resetAt: retry ? new Date(Date.now() + Number(retry) * 1000) : resetAt });
  }
  if (res.status === 403) throw new GitHubError('auth', 'The token lacks permission to read Actions on this repository.', { status: 403 });
  throw new GitHubError('http', `GitHub API error ${res.status}.`, { status: res.status });
}

/**
 * All workflow runs created since `since` (null = all), newest first, following every Link rel="next"
 * page up to `maxPages`. Never throws away what it already has: an error after the first page returns the
 * runs loaded so far with complete=false and the error, so the UI can show partial data honestly.
 *
 * GitHub caps a FILTERED runs search (here: `created`) at 1,000 results; unfiltered listing is not capped
 * but is bounded by maxPages here. Either cap sets complete=false with reason 'capped'.
 *
 * → { runs, totalCount, complete, reason: null|'capped'|'error', error, rateLimit }
 */
export async function fetchRuns({ owner, repo, token = null, since = null, pageSize = 100, maxPages = 30,
                                  fetchImpl = globalThis.fetch.bind(globalThis), signal, onProgress } = {}) {
  const q = new URLSearchParams({ per_page: String(pageSize) });
  if (since) q.set('created', `>=${since.toISOString().replace(/\.\d{3}Z$/, 'Z')}`);
  let url = `${API}/repos/${owner}/${repo}/actions/runs?${q}`;
  const byId = new Map();     // pages can shift while new runs start — dedupe by run id
  let totalCount = null, pages = 0, rateLimit = null;
  while (url) {
    let page;
    try {
      page = await request(url, { token, fetchImpl, signal });
    } catch (e) {
      if (pages === 0 || e?.name === 'AbortError') throw e;
      return { runs: [...byId.values()], totalCount, complete: false, reason: 'error', error: e, rateLimit };
    }
    pages++;
    rateLimit = page.rateLimit ?? rateLimit;
    totalCount ??= page.body.total_count ?? null;
    for (const r of page.body.workflow_runs ?? []) byId.set(r.id, r);
    onProgress?.({ loaded: byId.size, totalCount });
    url = nextLink(page.link);
    if (url && pages >= maxPages) break;
  }
  const runs = [...byId.values()];
  const capped = url != null || (totalCount != null && runs.length < totalCount && (since != null && totalCount > 1000));
  return { runs, totalCount, complete: !capped, reason: capped ? 'capped' : null, error: null, rateLimit };
}

/** Every workflow defined in the repo (id, name, path, state). */
export async function fetchWorkflows({ owner, repo, token = null, fetchImpl = globalThis.fetch.bind(globalThis), signal } = {}) {
  let url = `${API}/repos/${owner}/${repo}/actions/workflows?per_page=100`;
  const out = [];
  while (url) {
    const page = await request(url, { token, fetchImpl, signal });
    for (const w of page.body.workflows ?? []) out.push({ id: w.id, name: w.name, path: w.path, state: w.state });
    url = nextLink(page.link);
  }
  return out;
}
