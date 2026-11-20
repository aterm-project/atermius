/*
 * WEB-BUNDLE-CACHE: the repository's actual Web bootstrap and cache worker
 * (apps/client/web/atermius-sw.js) on a secure HTTPS origin with a small
 * fixture bundle whose build the test changes on the server.
 *
 * Checks: a second load is answered from the cache (also while the server
 * refuses every static file), dynamic routes are never cached, a newer build
 * is downloaded in the background while reloads keep the old build, only an
 * explicit activation switches builds, and a bundle that changes during the
 * download or has no manifest is not stored.
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const WEB = path.join(ROOT, 'apps/client/web');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function bundle(buildId, { manifest = true } = {}) {
  const bootstrap = fs.readFileSync(path.join(WEB, 'flutter_bootstrap.js'), 'utf8')
    .replace('{{flutter_js}}',
      'globalThis._flutter = { loader: { async load(options) {' +
      ' const script = document.createElement("script"); script.src = "main.dart.js";' +
      ' await new Promise((resolve, reject) => { script.onload = resolve; script.onerror = reject; document.body.append(script); });' +
      ' await options.onEntrypointLoaded({ initializeEngine: async () => ({ runApp: async () => { globalThis.__appStarted = true; } }) });' +
      ' } } };')
    .replace('{{flutter_build_config}}', 'globalThis._flutter.buildConfig = {};')
    .replace('{{flutter_service_worker_version}}', JSON.stringify(buildId));
  assertThat(!bootstrap.includes('{{flutter_'), 'bootstrap template tokens were not replaced');
  const files = new Map([
    ['index.html', '<!doctype html><html><head><meta charset="utf-8"><base href="/app/"></head><body>' +
      `<p id="build">${buildId}</p><script src="flutter_bootstrap.js"></script></body></html>`],
    ['flutter_bootstrap.js', bootstrap],
    ['atermius-sw.js', fs.readFileSync(path.join(WEB, 'atermius-sw.js'), 'utf8')],
    ['main.dart.js', `globalThis.__mainBuild = ${JSON.stringify(buildId)};`],
    ['assets/shared.bin', 'same-in-every-build'],
    ['assets/data.json', JSON.stringify({ build: buildId })],
    ['canvaskit/chromium/canvaskit.js', `// renderer of ${buildId}`],
    ['main.dart.js.map', '{}'],
  ]);
  if (manifest) {
    const hashes = {};
    for (const [name, body] of [...files].sort()) {
      hashes[name] = crypto.createHash('sha256').update(body).digest('hex');
    }
    files.set('atermius-cache-manifest.json',
      JSON.stringify({ version: 1, build_id: buildId, files: hashes }));
  }
  return files;
}

const TYPES = { html: 'text/html; charset=utf-8', js: 'text/javascript; charset=utf-8',
  json: 'application/json', bin: 'application/octet-stream', map: 'application/json' };

async function main() {
  let browser;
  let server;
  let tempRoot;
  let stage = 'setup';
  const hits = new Map();
  const state = { files: bundle('build-a'), refuseStatic: false, hold: null, corrupt: null };
  const count = (name) => hits.get(name) || 0;

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-bundle-cache-'));
    const keyPath = path.join(tempRoot, 'https.key');
    const certPath = path.join(tempRoot, 'https.crt');
    const ssl = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', keyPath, '-out', certPath, '-days', '1', '-subj', '/CN=127.0.0.1',
      '-addext', 'subjectAltName=IP:127.0.0.1'], { stdio: 'ignore', timeout: 15000 });
    assertThat(ssl.status === 0, 'temporary HTTPS certificate generation failed');

    server = https.createServer({ key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) },
      async (request, response) => {
        const pathname = new URL(request.url, 'https://127.0.0.1').pathname;
        if (!pathname.startsWith('/app/')) return response.writeHead(404).end();
        let name = pathname.slice('/app/'.length);
        if (name === 'api/ping') {
          hits.set(name, count(name) + 1);
          response.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
          return response.end(JSON.stringify({ n: count(name) }));
        }
        // Like deploy/nginx.conf: unknown routes are the application page.
        if (name === '' || (!state.files.has(name) && !/\.[a-z0-9]+$/i.test(name))) name = 'index.html';
        hits.set(name, count(name) + 1);
        if (state.refuseStatic) return response.writeHead(503).end();
        if (state.hold && state.hold.name === name) await state.hold.promise;
        let body = state.files.get(name);
        if (body === undefined) return response.writeHead(404, { 'Cache-Control': 'no-cache' }).end();
        if (state.corrupt === name) body += '/* changed by a later deploy */';
        response.writeHead(200, {
          'Content-Type': TYPES[name.split('.').pop()] || 'application/octet-stream',
          'Cache-Control': 'no-cache',
        });
        response.end(body);
      });
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const app = `https://127.0.0.1:${server.address().port}/app/`;

    const launchOptions = { headless: true, args: ['--ignore-certificate-errors'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    const context = await browser.newContext({ ignoreHTTPSErrors: true, serviceWorkers: 'allow' });
    const page = await context.newPage();
    const started = () => page.waitForFunction(() => globalThis.__appStarted === true, { timeout: 15000 });
    const pageBuild = () => page.evaluate(() => ({
      id: String(globalThis.atermiusWebBuildId),
      main: globalThis.__mainBuild,
      html: document.getElementById('build').textContent,
    }));
    const stored = (buildId) => page.evaluate(async (id) => {
      if (!(await caches.has('atermius-web-build-' + id))) return null;
      const cache = await caches.open('atermius-web-build-' + id);
      const keys = (await cache.keys()).map((request) => new URL(request.url).pathname.slice('/app/'.length));
      return { keys, complete: keys.includes('__atermius/complete') };
    }, buildId);
    const waitStored = async (buildId) => {
      for (let i = 0; i < 200; i++) {
        const value = await stored(buildId);
        if (value?.complete) return value;
        await page.waitForTimeout(100);
      }
      throw new Error(`build ${buildId} was not stored`);
    };

    stage = 'first visit stores the running build';
    await page.goto(app, { waitUntil: 'load' });
    await started();
    const first = await waitStored('build-a');
    for (const name of ['index.html', 'flutter_bootstrap.js', 'main.dart.js', 'assets/shared.bin', 'assets/data.json']) {
      assertThat(first.keys.includes(name), `first visit did not store ${name}`);
    }
    for (const name of ['main.dart.js.map', 'atermius-sw.js', 'atermius-cache-manifest.json', 'canvaskit/chromium/canvaskit.js', 'api/ping']) {
      assertThat(!first.keys.includes(name), `first visit stored ${name}`);
    }

    stage = 'second load comes from the cache';
    const before = { main: count('main.dart.js'), index: count('index.html'), bootstrap: count('flutter_bootstrap.js') };
    await page.reload({ waitUntil: 'load' });
    await started();
    assertThat(count('main.dart.js') === before.main && count('index.html') === before.index &&
      count('flutter_bootstrap.js') === before.bootstrap, 'the second load asked the server for the bundle');
    assertThat((await pageBuild()).main === 'build-a', 'the second load did not run the stored build');

    stage = 'the stored build starts while the server refuses static files';
    state.refuseStatic = true;
    await page.goto(app + 'admin/users', { waitUntil: 'load' });
    await started();
    assertThat((await pageBuild()).html === 'build-a', 'a client-side route was not answered from the cache');
    state.refuseStatic = false;
    await page.goto(app, { waitUntil: 'load' });
    await started();

    stage = 'dynamic routes and lazily used files';
    const pings = await page.evaluate(async () => [
      (await (await fetch('api/ping')).json()).n,
      (await (await fetch('api/ping')).json()).n,
    ]);
    assertThat(pings[1] === pings[0] + 1, 'an API answer was served from the cache');
    await page.evaluate(async () => (await fetch('canvaskit/chromium/canvaskit.js')).text());
    assertThat((await stored('build-a')).keys.includes('canvaskit/chromium/canvaskit.js'),
      'a renderer file this browser used was not kept');
    const rendererHits = count('canvaskit/chromium/canvaskit.js');
    await page.evaluate(async () => (await fetch('canvaskit/chromium/canvaskit.js')).text());
    assertThat(count('canvaskit/chromium/canvaskit.js') === rendererHits, 'the kept renderer file was downloaded again');

    stage = 'a newer build downloads in the background; reloads keep the old one';
    state.files = bundle('build-b');
    assertThat(await page.evaluate(() => globalThis.atermiusProbeWebBuild()) === 'build-b',
      'the update probe did not reach the server');
    let release;
    state.hold = { name: 'main.dart.js', promise: new Promise((resolve) => { release = resolve; }) };
    const sharedHits = count('assets/shared.bin');
    await page.evaluate(() => {
      globalThis.__prepare = globalThis.atermiusPrepareWebBuild('build-b')
        .then((value) => { globalThis.__prepared = value; }, (error) => { globalThis.__prepared = 'error:' + error.message; });
    });
    await page.waitForTimeout(700);
    assertThat(await page.evaluate(() => globalThis.__prepared) === undefined,
      'the new build was reported ready before its download finished');
    await page.reload({ waitUntil: 'load' });
    await started();
    let running = await pageBuild();
    assertThat(running.id === 'build-a' && running.main === 'build-a' && running.html === 'build-a',
      `a reload during the download left the old build: ${JSON.stringify(running)}`);
    release();
    state.hold = null;
    // The reloaded page asks again; the worker joins or resumes the download.
    assertThat(await page.evaluate(() => globalThis.atermiusPrepareWebBuild('build-b')) === 'ready',
      'the new build was not stored');
    const second = await stored('build-b');
    assertThat(second?.complete && second.keys.includes('canvaskit/chromium/canvaskit.js'),
      'the new build lacks the renderer file this browser uses');
    assertThat(count('assets/shared.bin') === sharedHits, 'an unchanged file was downloaded again');

    stage = 'still the old build until the user confirms';
    await page.reload({ waitUntil: 'load' });
    await started();
    running = await pageBuild();
    assertThat(running.id === 'build-a' && running.main === 'build-a',
      'a prepared build was applied without confirmation');

    stage = 'activation and reload switch to the new build from the cache';
    const mainHits = count('main.dart.js');
    await page.evaluate(() => globalThis.atermiusActivateWebBuild('build-b'));
    await page.reload({ waitUntil: 'load' });
    await started();
    running = await pageBuild();
    assertThat(running.id === 'build-b' && running.main === 'build-b' && running.html === 'build-b',
      `activation did not switch builds: ${JSON.stringify(running)}`);
    assertThat(count('main.dart.js') === mainHits, 'the activated build was downloaded again on reload');
    assertThat((await page.evaluate(async () => (await (await fetch('assets/data.json')).json()).build)) === 'build-b',
      'the new page received a file of the old build');

    stage = 'a bundle that changes during the download is not stored';
    state.files = bundle('build-c');
    state.corrupt = 'main.dart.js';
    const failed = await page.evaluate(() => globalThis.atermiusPrepareWebBuild('build-c')
      .then((value) => value, (error) => 'error:' + error.message));
    assertThat(String(failed).startsWith('error:'), `a changed bundle was accepted: ${failed}`);
    assertThat(!(await stored('build-c'))?.complete, 'a changed bundle was marked complete');
    state.corrupt = null;
    const mismatch = await page.evaluate(() => globalThis.atermiusPrepareWebBuild('build-x')
      .then((value) => value, (error) => 'error:' + error.message));
    assertThat(String(mismatch).startsWith('error:'), 'a build the server does not serve was accepted');
    await page.reload({ waitUntil: 'load' });
    await started();
    assertThat((await pageBuild()).main === 'build-b', 'a failed download disturbed the build in use');

    stage = 'a bundle without a manifest is simply not cached';
    state.files = bundle('build-d', { manifest: false });
    assertThat(await page.evaluate(() => globalThis.atermiusPrepareWebBuild('build-d')) === 'unsupported',
      'a bundle without a manifest was not reported as unsupported');
    // Activation of something that was never stored drops the cache, so the
    // reload shows the server's build instead of the old one again.
    await page.evaluate(() => globalThis.atermiusActivateWebBuild('build-d'));
    await page.reload({ waitUntil: 'load' });
    await started();
    running = await pageBuild();
    assertThat(running.id === 'build-d' && running.main === 'build-d',
      `the reload did not reach the server's build: ${JSON.stringify(running)}`);

    stage = 'guest pages register nothing new and bypass the cache';
    state.files = bundle('build-e');
    const guest = await context.newPage();
    const guestIndexHits = count('index.html');
    await guest.goto(app + 's/some-link', { waitUntil: 'load' });
    assertThat(count('index.html') === guestIndexHits + 1, 'a guest page was answered from the cache');

    console.log('WEB-BUNDLE-CACHE: passed');
  } catch (error) {
    console.error(`WEB-BUNDLE-CACHE failed at: ${stage}`);
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    await browser?.close().catch(() => {});
    if (server?.listening) {
      await new Promise((resolve) => { server.close(resolve); server.closeAllConnections?.(); });
    }
    if (tempRoot) fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

main();
