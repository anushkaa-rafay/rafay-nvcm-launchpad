import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchRuns, fetchWorkflows, nextLink, GitHubError } from '../src/github.js';
import { run, fakeFetch, response } from './fixtures.mjs';

const repo = { owner: 'ramakrishna-rafay', repo: 'rafay_nvcm_launchpad' };
const five = () => Array.from({ length: 5 }, (_, i) => run({ started: `2026-10-05T0${i}:00:00Z` }));

test('nextLink parses rel="next" only', () => {
  assert.equal(nextLink('<https://a/x?page=2>; rel="next", <https://a/x?page=9>; rel="last"'), 'https://a/x?page=2');
  assert.equal(nextLink('<https://a/x?page=1>; rel="prev"'), null);
  assert.equal(nextLink(null), null);
});

test('fetchRuns follows every page — never just the first', async () => {
  const calls = [];
  const res = await fetchRuns({ ...repo, fetchImpl: fakeFetch(five(), { pageSize: 2, calls }) });
  assert.equal(res.runs.length, 5);
  assert.equal(calls.length, 3);
  assert.equal(res.complete, true);
  assert.equal(res.totalCount, 5);
});

test('fetchRuns sends the date filter and auth header, and no token when there is none', async () => {
  const calls = [];
  await fetchRuns({ ...repo, token: 'tkn', since: new Date('2026-10-04T12:00:00.123Z'), fetchImpl: fakeFetch([], { calls }) });
  const u = new URL(calls[0].url);
  assert.equal(u.pathname, '/repos/ramakrishna-rafay/rafay_nvcm_launchpad/actions/runs');
  assert.equal(u.searchParams.get('created'), '>=2026-10-04T12:00:00Z');
  assert.equal(u.searchParams.get('per_page'), '100');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer tkn');
  calls.length = 0;
  await fetchRuns({ ...repo, fetchImpl: fakeFetch([], { calls }) });
  assert.equal(calls[0].init.headers.Authorization, undefined);
});

test('a failure after page 1 keeps what was loaded and says so (partial, not zero)', async () => {
  const res = await fetchRuns({ ...repo, fetchImpl: fakeFetch(five(), { pageSize: 2, failOnPage: 2 }) });
  assert.equal(res.runs.length, 2);
  assert.equal(res.complete, false);
  assert.equal(res.reason, 'error');
  assert.equal(res.error.kind, 'http');
});

test('maxPages caps the load and marks it incomplete', async () => {
  const res = await fetchRuns({ ...repo, maxPages: 2, fetchImpl: fakeFetch(five(), { pageSize: 2 }) });
  assert.equal(res.runs.length, 4);
  assert.equal(res.complete, false);
  assert.equal(res.reason, 'capped');
});

test("GitHub's 1,000-result cap on date-filtered queries is reported", async () => {
  const res = await fetchRuns({ ...repo, since: new Date('2026-01-01'), fetchImpl: fakeFetch(five(), { pageSize: 10, totalCount: 1500 }) });
  assert.equal(res.complete, false);
  assert.equal(res.reason, 'capped');
});

test('duplicate runs across shifting pages are counted once', async () => {
  const r = five();
  const res = await fetchRuns({ ...repo, fetchImpl: fakeFetch([r[0], r[1], r[1], r[2]], { pageSize: 2 }) });
  assert.equal(res.runs.length, 3);
});

test('errors on the first page are typed', async () => {
  const cases = [
    [{ status: 401 }, 'auth'],
    [{ status: 404 }, 'not_found'],
    [{ status: 403, headers: { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '1790000000' } }, 'rate_limit'],
    [{ status: 429, headers: { 'retry-after': '60' } }, 'rate_limit'],
    [{ status: 403 }, 'auth'],
    [{ status: 502 }, 'http'],
  ];
  for (const [failWith, kind] of cases) {
    await assert.rejects(fetchRuns({ ...repo, fetchImpl: fakeFetch(five(), { failOnPage: 1, failWith }) }),
      e => e instanceof GitHubError && e.kind === kind, `${failWith.status} → ${kind}`);
  }
  const e = await fetchRuns({ ...repo, fetchImpl: fakeFetch(five(), { failOnPage: 1, failWith: { status: 403, headers: { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '1790000000' } } }) }).catch(x => x);
  assert.equal(e.resetAt.toISOString(), new Date(1790000000 * 1000).toISOString());
});

test('network failure is typed; abort passes through untouched', async () => {
  await assert.rejects(fetchRuns({ ...repo, fetchImpl: async () => { throw new TypeError('Failed to fetch'); } }), e => e.kind === 'network');
  const abort = Object.assign(new Error('aborted'), { name: 'AbortError' });
  await assert.rejects(fetchRuns({ ...repo, fetchImpl: async () => { throw abort; } }), e => e === abort);
});

test('unreadable body is an http error, not a crash', async () => {
  const fetchImpl = async () => ({ ...response(200, null), json: async () => { throw new SyntaxError('bad json'); } });
  await assert.rejects(fetchRuns({ ...repo, fetchImpl }), e => e.kind === 'http');
});

test('fetchWorkflows lists id/name/path/state', async () => {
  const w = await fetchWorkflows({ ...repo, fetchImpl: fakeFetch([]) });
  assert.deepEqual(w.map(x => x.name), ['nvcm-greenfield', 'lint', 'nvcm-brownfield']);
  assert.deepEqual(Object.keys(w[0]), ['id', 'name', 'path', 'state']);
});
