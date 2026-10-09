// build.mjs — assemble the publishable site: the page, its stylesheet and src/ only — never tests, scripts or
// package files. No bundling: the browser loads ES modules as-is. The repository the page reports on is
// written into <out>/src/config.js (scripts/repo.mjs).
//
//   node scripts/build.mjs          → dashboard/_site/  (scratch preview; git-ignored)
//   node scripts/build.mjs ../docs  → <repo>/docs/      (committed; GitHub Pages "Deploy from a branch" serves it)
//
// The output folder is deleted and rewritten, so only those two targets are accepted.
import { cp, rm, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { repository, fillConfig } from './repo.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const targets = { _site: resolve(root, '_site'), '../docs': resolve(root, '..', 'docs') };
const arg = process.argv[2] ?? '_site';
const out = targets[arg.replace(/\/+$/, '')];
if (!out) { console.error(`build.mjs: output must be one of ${Object.keys(targets).join(', ')} (got ${arg})`); process.exit(2); }

const repo = repository();
await rm(out, { recursive: true, force: true });
await mkdir(out);
for (const f of ['index.html', 'styles.css']) await cp(`${root}${f}`, `${out}/${f}`);
await cp(`${root}src`, `${out}/src`, { recursive: true });
await writeFile(`${out}/src/config.js`, fillConfig(await readFile(`${root}src/config.js`, 'utf8'), repo));
await writeFile(`${out}/.nojekyll`, '');   // branch-deployed Pages: serve the files as-is, no Jekyll pass
console.log(`built ${out} for ${repo}:`, (await readdir(out, { recursive: true })).sort().join(', '));
