// build.mjs — assemble the publishable site into _site/ (what the Pages workflow uploads): the page, its
// stylesheet and src/ only — never tests, scripts or package files. No bundling: the browser loads ES
// modules as-is. The repository the page reports on is written into _site/src/config.js (scripts/repo.mjs).
import { cp, rm, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { repository, fillConfig } from './repo.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const out = `${root}_site`;
await rm(out, { recursive: true, force: true });
await mkdir(out);
for (const f of ['index.html', 'styles.css']) await cp(`${root}${f}`, `${out}/${f}`);
await cp(`${root}src`, `${out}/src`, { recursive: true });
const repo = repository();
await writeFile(`${out}/src/config.js`, fillConfig(await readFile(`${root}src/config.js`, 'utf8'), repo));
console.log(`built ${out} for ${repo}:`, (await readdir(out, { recursive: true })).sort().join(', '));
