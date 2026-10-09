// serve.mjs — zero-dependency static server for local development: `npm start` → http://localhost:8080
// (ES modules don't load from file://). Serves this directory only, read-only.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { repository, fillConfig } from './repo.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const port = Number(process.env.PORT) || 8080;
const repo = repository();
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^([/\\])+/, '');
  const file = join(root, path === '' ? 'index.html' : path);
  if (!file.startsWith(root) || file.includes(`${sep}node_modules${sep}`)) { res.writeHead(403).end(); return; }
  try {
    let body = await readFile(file);
    if (file === join(root, 'src', 'config.js')) body = fillConfig(body.toString('utf8'), repo);
    res.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' }).end(body);
  } catch { res.writeHead(404).end('not found'); }
}).listen(port, '127.0.0.1', () => console.log(`NVCM dashboard for ${repo} → http://localhost:${port}`));
