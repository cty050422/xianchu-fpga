// Starts only the matching local dashboard. No serial, BLE or programming APIs.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {gatewayUrl} from './service_config.mjs';

export const sha = data => crypto.createHash('sha256').update(data).digest('hex');
export function uiRoot(root) {
  for (const relative of ['web/performance_ui', 'performance_ui']) {
    const dir = path.join(root, relative);
    if (fs.existsSync(path.join(dir, 'server.mjs')) && fs.existsSync(path.join(dir, 'index.html'))) return dir;
  }
  throw new Error('Dashboard files missing: expected web/performance_ui/server.mjs');
}
export async function matches(base, dir, expectedGateway) {
  try {
    // A server started before a UI update may have an older asset whitelist.
    // Matching index/app alone would silently reuse it even when new CSS is 404.
    const html = fs.readFileSync(path.join(dir,'index.html'),'utf8');
    const assets = new Set(['release-info.json', 'index.html', 'app.mjs', 'protocol.mjs', 'music.mjs',
      'wire_capture.mjs', 'evidence.mjs', 'style.css', 'diagnostics.css', 'evidence.css',
      ...Array.from(html.matchAll(/(?:href|src)="\.\/([^"?#]+)"/g),m=>m[1])]);
    for (const name of assets) {
      if (!path.resolve(dir,name).startsWith(path.resolve(dir)+path.sep)) return false;
      const response = await fetch(base + '/' + name, { signal: AbortSignal.timeout(1200), cache: 'no-store' });
      if (!response.ok || sha(Buffer.from(await response.arrayBuffer())) !== sha(fs.readFileSync(path.join(dir, name)))) return false;
    }
    if (expectedGateway) {
      const service = await fetch(base + '/services/status', {signal:AbortSignal.timeout(4000)});
      if (!service.ok || (await service.json()).gateway_url !== expectedGateway) return false;
    }
    return true;
  } catch { return false; }
}
function browser(url) {
  if (process.platform !== 'win32') { console.log('Open in desktop Edge/Chrome: ' + url); return; }
  const programs = [
    path.join(process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)', 'Microsoft/Edge/Application/msedge.exe'),
    path.join(process.env.ProgramFiles || 'C:/Program Files', 'Microsoft/Edge/Application/msedge.exe'),
    path.join(process.env.ProgramFiles || 'C:/Program Files', 'Google/Chrome/Application/chrome.exe'),
    path.join(process.env.LOCALAPPDATA || '', 'Google/Chrome/Application/chrome.exe')
  ];
  const exe = programs.find(p => fs.existsSync(p));
  if (!exe) { console.log('Open in desktop Edge/Chrome: ' + url); return; }
  const opened = spawn(exe, [url], { detached: true, windowsHide: true, stdio: 'ignore' });
  opened.on('error', error => console.error('Browser: ' + error.message + '; open ' + url + ' manually.'));
  opened.unref();
}
export async function startUi(root, { firstPort = 8765, noBrowser = false, checkOnly = false, expectedGateway = gatewayUrl() } = {}) {
  const dir = uiRoot(root);
  if (!Number.isInteger(firstPort) || firstPort < 1024 || firstPort > 65525) throw new Error('Invalid dashboard port');
  for (let port = firstPort; port < firstPort + 10; port++) {
    const url = 'http://127.0.0.1:' + port;
    if (await matches(url, dir, expectedGateway)) {
      console.log('MATCHING_UI_REUSED ' + url);
      if (!noBrowser) browser(url);
      return { url, reused: true, stop() {} };
    }
    const child = spawn(process.execPath, [path.join(dir, 'server.mjs')], {
      cwd: dir, env: { ...process.env, XIANCHU_UI_PORT: String(port), XIANCHU_GATEWAY_URL: expectedGateway }, windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    });
    const started = await new Promise((resolve, reject) => {
      let settled = false, output = '';
      const done = value => { if (!settled) { settled = true; clearTimeout(timer); resolve(value); } };
      const timer = setTimeout(() => { child.kill(); done({ error: 'Dashboard startup timed out' }); }, 6000);
      child.stdout.on('data', data => {
        output += data;
        if (output.includes('Performance UI: ')) done({ ready: true });
      });
      child.stderr.on('data', data => { output += data; });
      child.once('error', error => { if (!settled) { settled = true; clearTimeout(timer); reject(error); } });
      child.once('exit', () => done(output.includes('EADDRINUSE') ? { occupied: true } : { error: output || 'Dashboard exited' }));
    });
    if (started.occupied) continue; // Never terminate a different or older server.
    if (!started.ready) throw new Error(started.error);
    if (!await matches(url, dir, expectedGateway)) { child.kill(); throw new Error('Dashboard content does not match this package'); }
    const stop = () => { if (child.exitCode === null) child.kill(); };
    console.log('VERIFIED_UI_READY ' + url);
    let identity={};
    try { identity=JSON.parse(fs.readFileSync(path.join(dir,'release-info.json'),'utf8')); } catch {}
    console.log(`Expected package: ${identity.ui_package_id || 'development tree'} / FPGA ${identity.expected_fpga_sha256?.slice(0,8) || 'unspecified'}. This is not actual hardware identity.`);
    if (checkOnly) { stop(); console.log('PASS launcher HTTP/content check; no serial access'); }
    else {
      console.log('Keep this window open. Press Ctrl+C to stop this UI server.');
      if (!noBrowser) browser(url);
    }
    return { url, reused: false, child, stop };
  }
  throw new Error('Ports are occupied. No existing process was terminated.');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = path.resolve(process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
  try {
    const result = await startUi(root, { noBrowser: process.argv.includes('--no-browser'), checkOnly: process.argv.includes('--check'),
      firstPort: Number(process.env.XIANCHU_UI_PORT || 8765) });
    if (!result.reused && !process.argv.includes('--check')) {
      process.once('SIGINT', () => { result.stop(); process.exit(0); });
      process.once('SIGTERM', () => { result.stop(); process.exit(0); });
      process.once('exit', result.stop);
    }
  } catch (error) { console.error('UI_START_FAILED: ' + error.message); process.exitCode = 1; }
}
