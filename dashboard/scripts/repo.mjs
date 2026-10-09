// repo.mjs — which repository the page reports on, decided when the page is built or served, never hardcoded:
// DASHBOARD_REPOSITORY (the repository variable of that name, to point the page at another repo) →
// GITHUB_REPOSITORY (set by Actions: the repo the workflow runs in) → this checkout's `origin` (local dev).
import { execFileSync } from 'node:child_process';

export const PLACEHOLDER = '__GITHUB_REPOSITORY__';
const SHAPE = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/;

export function repository(env = process.env) {
  let r = env.DASHBOARD_REPOSITORY || env.GITHUB_REPOSITORY;
  if (!r) {
    try {
      const url = execFileSync('git', ['remote', 'get-url', 'origin'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
      r = url.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/)?.[1];
    } catch { /* not a git checkout */ }
  }
  if (!r || !SHAPE.test(r)) throw new Error(`no repository to report on (got ${JSON.stringify(r ?? null)}) — set DASHBOARD_REPOSITORY=owner/repo`);
  return r;
}

/** config.js source with the placeholder filled in; fails if the placeholder is missing. */
export function fillConfig(src, repo) {
  if (!src.includes(PLACEHOLDER)) throw new Error(`src/config.js has no ${PLACEHOLDER} placeholder`);
  return src.replaceAll(PLACEHOLDER, repo);
}
