import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { repository, fillConfig, PLACEHOLDER } from '../scripts/repo.mjs';

test('repository: DASHBOARD_REPOSITORY overrides GITHUB_REPOSITORY', () => {
  assert.equal(repository({ DASHBOARD_REPOSITORY: 'org/other', GITHUB_REPOSITORY: 'me/this' }), 'org/other');
  assert.equal(repository({ DASHBOARD_REPOSITORY: '', GITHUB_REPOSITORY: 'me/this-repo.x' }), 'me/this-repo.x');
});

test('repository: a malformed value is refused, not published', () => {
  assert.throws(() => repository({ GITHUB_REPOSITORY: 'no-slash' }), /DASHBOARD_REPOSITORY/);
  assert.throws(() => repository({ GITHUB_REPOSITORY: "a/b';alert(1)//" }), /DASHBOARD_REPOSITORY/);
});

test('fillConfig: the real config.js carries the placeholder and comes out pointed at the repo', async () => {
  const src = await readFile(new URL('../src/config.js', import.meta.url), 'utf8');
  const out = fillConfig(src, 'me/this');
  assert.ok(!out.includes(PLACEHOLDER));
  assert.match(out, /'me\/this'\.split\('\/'\)/);
  assert.throws(() => fillConfig('export const CONFIG = {}', 'me/this'), /placeholder/);
});
