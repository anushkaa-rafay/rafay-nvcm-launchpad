// build.mjs — assemble the publishable site into _site/ (what the Pages workflow uploads): the page, its
// stylesheet and src/ only — never tests, scripts or package files. No bundling: the browser loads ES
// modules as-is.
import { cp, rm, mkdir, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const out = `${root}_site`;
await rm(out, { recursive: true, force: true });
await mkdir(out);
for (const f of ['index.html', 'styles.css']) await cp(`${root}${f}`, `${out}/${f}`);
await cp(`${root}src`, `${out}/src`, { recursive: true });
console.log(`built ${out}:`, (await readdir(out, { recursive: true })).sort().join(', '));
