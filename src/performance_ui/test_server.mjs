// Loopback check of the desktop UI server: every resource the page references
// must be served with the right MIME type on a chosen port. This is what caught
// the missing pcm.css whitelist entry (F14) — the page loaded, the stylesheet
// 404'd, and nobody noticed because the page still "worked".
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const port = 18000 + Math.floor(Math.random() * 1000);
let child;
let base;

before(async () => {
  child = spawn(process.execPath, [join(here, 'server.mjs')], {
    cwd: here, env: { ...process.env, XIANCHU_UI_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe']
  });
  base = `http://127.0.0.1:${port}`;
  // wait for listen without a fixed sleep loop
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server did not start')), 8000);
    child.stdout.on('data', chunk => {
      if (String(chunk).includes('Performance UI')) { clearTimeout(timer); resolve(); }
    });
    child.on('exit', code => { clearTimeout(timer); reject(new Error(`server exited ${code}`)); });
  });
});

after(() => { if (child) child.kill(); });

describe('desktop UI server', () => {
  it('identifies the expected package without claiming the programmed hardware identity',async()=>{
    const response=await fetch(`${base}/release-info.json`);
    assert.equal(response.status,200);assert.match(response.headers.get('content-type'),/application\/json/);
    const info=await response.json();
    // The server must serve this checkout's identity, including after an update.
    assert.deepEqual(info,JSON.parse(readFileSync(join(here,'release-info.json'),'utf8')));
    assert.ok(Number.isInteger(info.usability_revision)&&info.usability_revision>=1);
    assert.equal(info.actual_hardware_identity_verified,false);
  });
  it('serves the page and every asset it references', async () => {
    const page = await fetch(`${base}/`);
    assert.equal(page.status, 200);
    assert.match(page.headers.get('content-type'), /text\/html/);
    const html = await page.text();
    const references = [...html.matchAll(/(?:href|src)="\.\/([^"]+)"/g)].map(m => m[1]);
    assert.ok(references.includes('evidence.css'), 'the latest dashboard must include its status styles');
    for (const name of references) {
      const response = await fetch(`${base}/${name}`);
      assert.equal(response.status, 200, `asset ${name} must be served`);
      const type = response.headers.get('content-type');
      if (name.endsWith('.css')) assert.match(type, /text\/css/);
      if (name.endsWith('.mjs')) assert.match(type, /javascript/);
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    }
  });

  it('serves the modules with no caching so a fix is never masked', async () => {
    for (const name of ['app.mjs', 'protocol.mjs', 'music.mjs', 'wire_capture.mjs', 'evidence.mjs']) {
      const response = await fetch(`${base}/${name}`);
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('cache-control'), 'no-store');
    }
  });

  it('answers 404 for anything else and never serves files outside the whitelist', async () => {
    for (const path of ['/server.mjs', '/../package.json', '/etc/passwd', '/nope']) {
      const response = await fetch(`${base}${path}`);
      assert.equal(response.status, 404, `${path} must not be served`);
    }
  });

  it('the served index does not claim hardware evidence', async () => {
    const html = readFileSync(join(here, 'index.html'), 'utf8');
    assert.match(html, /演示数据/);
    assert.match(html, /不代表 FPGA 实测|非硬件/);
  });
});
