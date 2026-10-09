// Test fixtures shaped like GET /repos/{o}/{r}/actions/runs items (only the fields the dashboard reads).
// Fixed timestamps — no test depends on the real clock.
export const NOW = new Date('2026-10-05T12:00:00Z');

let seq = 1000;
export function run({ workflow = 1, name = 'nvcm-greenfield', status = 'completed', conclusion = 'success',
                      started = '2026-10-05T10:00:00Z', minutes = 3, actor = 'alice', trigger = null, event = 'workflow_dispatch',
                      branch = 'main', attempt = 1 } = {}) {
  const id = seq++;
  const s = new Date(started);
  return {
    id, run_number: id - 900, run_attempt: attempt, name, workflow_id: workflow, path: `.github/workflows/${name}.yml`,
    event, head_branch: branch, status, conclusion: status === 'completed' ? conclusion : null,
    created_at: started, run_started_at: started,
    updated_at: new Date(s.getTime() + minutes * 60e3).toISOString(),
    actor: { login: actor, avatar_url: `https://avatars.githubusercontent.com/u/1?v=4` },
    triggering_actor: { login: trigger ?? actor, avatar_url: `https://avatars.githubusercontent.com/u/2?v=4` },
    html_url: `https://github.com/ramakrishna-rafay/rafay_nvcm_launchpad/actions/runs/${id}`,
  };
}

/**
 * A fake fetch serving `runs` in pages of `pageSize` with real-style Link headers.
 * opts.failOnPage: return `failWith` for that page (1-based); opts.calls collects requested URLs.
 */
export function fakeFetch(runs, { pageSize = 2, failOnPage = null, failWith = { status: 500 }, calls = [], totalCount = runs.length } = {}) {
  return async (url, init) => {
    calls.push({ url, init });
    const u = new URL(url);
    if (u.pathname.endsWith('/actions/workflows')) {
      return response(200, { total_count: 2, workflows: [
        { id: 1, name: 'nvcm-greenfield', path: '.github/workflows/nvcm-greenfield.yml', state: 'active' },
        { id: 2, name: 'lint', path: '.github/workflows/ci.yml', state: 'active' },
        { id: 3, name: 'nvcm-brownfield', path: '.github/workflows/nvcm-brownfield.yml', state: 'active' } ] });
    }
    const page = Number(u.searchParams.get('page') ?? 1);
    if (page === failOnPage) return response(failWith.status, { message: 'boom' }, failWith.headers ?? {});
    const items = runs.slice((page - 1) * pageSize, page * pageSize);
    const headers = {};
    if (page * pageSize < runs.length) {
      const next = new URL(url); next.searchParams.set('page', String(page + 1));
      headers.link = `<${next}>; rel="next", <${next}>; rel="last"`;
    }
    headers['x-ratelimit-remaining'] = '4999';
    return response(200, { total_count: totalCount, workflow_runs: items }, headers);
  };
}

export function response(status, body, headers = {}) {
  const h = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { ok: status >= 200 && status < 300, status, headers: { get: k => h.get(k.toLowerCase()) ?? null }, json: async () => body };
}
