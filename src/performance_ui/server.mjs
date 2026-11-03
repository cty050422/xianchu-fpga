import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {gatewayUrl} from '../tools/service_config.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8' };
const files = new Map([
  ['/', 'index.html'], ['/index.html', 'index.html'], ['/style.css', 'style.css'],
  ['/diagnostics.css', 'diagnostics.css'], ['/studio.css', 'studio.css'], ['/studio.mjs', 'studio.mjs'],
  ['/evidence.css', 'evidence.css'], ['/app.mjs', 'app.mjs'],
  ['/protocol.mjs', 'protocol.mjs'], ['/music.mjs', 'music.mjs'],
  ['/wire_capture.mjs', 'wire_capture.mjs'], ['/evidence.mjs', 'evidence.mjs'],
  ['/release-info.json', 'release-info.json']
]);

// Software-service status panel: proxy the gateway health endpoints so the
// browser page never needs CORS or a direct cross-origin call. Read-only,
// non-secret, and honest — "not running" is a valid, displayed state.
const GATEWAY = gatewayUrl();
async function gatewayHealth() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2500);
  try {
    const res = await fetch(GATEWAY + '/assistant/v1/healthz', { signal: controller.signal });
    return { reachable: true, body: await res.json() };
  } catch (error) {
    return { reachable: false, error: error.name === 'AbortError' ? 'timeout' : String(error.cause?.code || error.message) };
  } finally { clearTimeout(timer); }
}

const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  if (pathname === '/services/status') {
    const gateway = await gatewayHealth();
    const body = JSON.stringify({
      gateway_url: GATEWAY,
      gateway,
      generated_at: new Date().toISOString()
    });
    response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    return response.end(body);
  }
  const name = files.get(pathname);
  if (!name) { response.writeHead(404); response.end('Not found'); return; }
  try {
    const content = await readFile(join(root, name));
    response.writeHead(200, { 'Content-Type': types[name.slice(name.lastIndexOf('.'))],
      'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    response.end(content);
  } catch {
    response.writeHead(500); response.end('Failed to read UI file');
  }
});
const port=Number(process.env.XIANCHU_UI_PORT || 8765);
server.listen(port, '127.0.0.1', () => {
  console.log(`Performance UI: http://127.0.0.1:${server.address().port}`);
  console.log(`Gateway probe target: ${GATEWAY} (/services/status)`);
  console.log('Open this URL in desktop Microsoft Edge or Google Chrome. Ctrl+C to stop.');
});
