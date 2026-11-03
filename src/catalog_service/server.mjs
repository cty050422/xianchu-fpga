// Local catalog service: the /catalog/v1/* surface extracted from
// assistant_gateway/server.mjs, with no voice/ASR/TTS/chat routes.
// Reuses the reviewed catalog compiler and the device-token session auth.
// Pairing and renew keep the /assistant/v1/* paths the phone already speaks,
// so the miniprogram client and its tests stay source-compatible.
// Default port 8893 (src/tools/service_config.mjs); override: XIANCHU_CATALOG_PORT.
import { createServer } from 'node:http';
import { createServiceAuth } from '../assistant_gateway/service_auth.mjs';
import { createCatalog } from '../assistant_gateway/catalog.mjs';

const VERSION = 'XC-CATALOG-20261031';
const PORT = Number(process.env.XIANCHU_CATALOG_PORT ?? 8893);
const HOST=process.env.XIANCHU_CATALOG_HOST || '0.0.0.0';
if(!Number.isInteger(PORT)||PORT<0||PORT>65535)throw Error('INVALID_CATALOG_PORT');
const MAX_BODY_BYTES = 4096;

function json(response, status, body) {
  const text = JSON.stringify(body);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store'
  });
  response.end(text);
}

async function readBody(request, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) {
      const error = new Error('BODY_TOO_LARGE');
      error.code = 'BODY_TOO_LARGE';
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

const env = process.env;
// Pairing code comes from the environment only; an absent code means open access,
// exactly like the gateway's behavior with no pairing configured.
const serviceAuth = createServiceAuth({
  legacyToken: env.XIANCHU_SERVICE_TOKEN || '',
  pairingCode: env.XIANCHU_PAIRING_CODE || ''
});
const authorized = request => serviceAuth.authorized(request.headers['x-device-token']);
const catalog = createCatalog({});

const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  const path = url.pathname;
  try {
    if (path === '/catalog/v1/healthz' && request.method === 'GET') {
      return json(response, 200, {
        service: 'catalog', version: VERSION, songs: catalog.size, ready: true,
        auth: serviceAuth.status(),
        note: '局域网曲库服务；未公网部署'
      });
    }
    if (path === '/catalog/v1/songs' && request.method === 'GET') {
      return json(response, 200, catalog.list({
        page: url.searchParams.get('page') || undefined,
        pageSize: url.searchParams.get('pageSize') || undefined,
        q: url.searchParams.get('q') || undefined,
        difficulty: url.searchParams.get('difficulty') || undefined,
        maxDifficulty: url.searchParams.get('maxDifficulty') || undefined,
        tag: url.searchParams.get('tag') || undefined,
        bpmMin: url.searchParams.get('bpmMin') || undefined,
        bpmMax: url.searchParams.get('bpmMax') || undefined,
        sort: url.searchParams.get('sort') || undefined
      }));
    }
    const songDetailMatch = path.match(/^\/catalog\/v1\/songs\/([a-z0-9-]+)$/);
    if (songDetailMatch && request.method === 'GET') {
      const detail = catalog.detail(songDetailMatch[1]);
      if (!detail) return json(response, 404, { error: 'NO_SUCH_SONG' });
      const etag = `"${detail.contentHash}"`;
      if (request.headers['if-none-match'] === etag) {
        response.writeHead(304, { ETag: etag });
        return response.end();
      }
      const text = JSON.stringify(detail);
      response.writeHead(200, {
        'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        ETag: etag, 'Content-Length': Buffer.byteLength(text)
      });
      return response.end(text);
    }
    const songCompileMatch = path.match(/^\/catalog\/v1\/songs\/([a-z0-9-]+)\/compile$/);
    if (songCompileMatch && request.method === 'GET') {
      const result = catalog.compileSong(songCompileMatch[1], {
        bpm: url.searchParams.get('bpm') || undefined,
        deviceSupportsCustomNotes: url.searchParams.get('customNotes') || undefined
      });
      if (!result) return json(response, 404, { error: 'NO_SUCH_SONG' });
      return json(response, 200, result);
    }
    if (path === '/assistant/v1/session/renew' && request.method === 'POST') {
      try { return json(response, 200, serviceAuth.renew(request.headers['x-device-token'])); }
      catch (error) { return json(response, 401, { error: error.code || 'SESSION_EXPIRED_OR_RESTARTED' }); }
    }
    if (path === '/assistant/v1/pair' && request.method === 'POST') {
      try {
        const body = JSON.parse((await readBody(request, 1024)).toString('utf8'));
        return json(response, 200, serviceAuth.pair(body.code));
      } catch (error) {
        const status = { PAIR_NOT_ENABLED: 404, PAIR_CODE_EXPIRED: 410, PAIR_LOCKED: 429,
          PAIR_CLIENT_LIMIT: 429, PAIR_CODE_INVALID: 401 }[error.code] || 400;
        return json(response, status, { error: error.code || 'PAIR_REQUEST_FORMAT' });
      }
    }
    return json(response, 404, { error: 'NO_SUCH_ROUTE' });
  } catch (error) {
    if (error.code === 'BODY_TOO_LARGE') return json(response, 413, { error: 'BODY_TOO_LARGE' });
    return json(response, 500, { error: 'CATALOG_INTERNAL' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`${VERSION} listening on http://${HOST}:${server.address().port} (${catalog.size} songs)`);
});
export {server};
