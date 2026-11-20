'use strict';
// Atermius Web cache worker.
//
// Keeps one complete copy of the static Web bundle per build in Cache
// Storage, so a second visit starts from the cache, and lets a newer build be
// downloaded in the background while the open page keeps running the old
// one. It never reloads or navigates a page and never switches builds on its
// own: the page asks for `prepare` (download), and only the user's confirmed
// reload sends `activate`.
//
// Only files listed in the build's `atermius-cache-manifest.json` are ever
// stored, each checked against its SHA-256 from that manifest, so two builds
// are never mixed and no API answer, guest page or other dynamic response
// can end up in the cache.

const CACHE_PREFIX = 'atermius-web-build-';
const META_CACHE = 'atermius-web-meta';
const MANIFEST_FILE = 'atermius-cache-manifest.json';
const SCOPE = self.registration.scope; // ends with '/'
const SCOPE_PATH = new URL(SCOPE).pathname;
const STATE_KEY = SCOPE + '__atermius/state';
const MANIFEST_KEY = SCOPE + '__atermius/manifest';
const COMPLETE_KEY = SCOPE + '__atermius/complete';

// Server-side routes and guest pages: always the network.
const NETWORK_ONLY = /^(?:api|relay|desktop|collaboration|gateway|health|s)\/|^join\/?$/;
// Listed in the manifest but only stored once this browser actually asks
// for them (each browser loads one of several renderer variants).
const LAZY = /^canvaskit\//;
// Never stored.
const SKIP = /(?:\.map|\.dart|\.symbols)$|^flutter_service_worker\.js$|^atermius-sw\.js$|^atermius-cache-manifest\.json$/;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

// --- state -----------------------------------------------------------------

let stateMemo = null;
const manifestMemo = new Map();
// Build each open page runs (it tells us on start). Lost when the worker is
// restarted; requests of an unknown page use the active build.
const clientBuilds = new Map();

async function readState() {
  if (stateMemo) return stateMemo;
  const meta = await caches.open(META_CACHE);
  const stored = await meta.match(STATE_KEY);
  let state = { active: null, previous: null };
  if (stored) {
    try {
      const value = await stored.json();
      state = { active: value.active || null, previous: value.previous || null };
    } catch (_) {}
  }
  stateMemo = state;
  return state;
}

async function writeState(state) {
  stateMemo = state;
  const meta = await caches.open(META_CACHE);
  await meta.put(STATE_KEY, new Response(JSON.stringify(state), {
    headers: { 'content-type': 'application/json' },
  }));
}

async function buildManifest(buildId) {
  if (manifestMemo.has(buildId)) return manifestMemo.get(buildId);
  if (!(await caches.has(CACHE_PREFIX + buildId))) return null;
  const cache = await caches.open(CACHE_PREFIX + buildId);
  const stored = await cache.match(MANIFEST_KEY);
  if (!stored) return null;
  try {
    const files = (await stored.json()).files;
    manifestMemo.set(buildId, files);
    return files;
  } catch (_) {
    return null;
  }
}

async function buildComplete(buildId) {
  if (!(await caches.has(CACHE_PREFIX + buildId))) return false;
  const cache = await caches.open(CACHE_PREFIX + buildId);
  return Boolean(await cache.match(COMPLETE_KEY));
}

function validBuildId(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value);
}

async function sha256Hex(buffer) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', buffer));
  let out = '';
  for (const byte of digest) out += byte.toString(16).padStart(2, '0');
  return out;
}

/// Downloads [path] of the bundle the server has now and stores it in
/// [cache] only if it is byte-for-byte the file the manifest names.
async function fetchVerified(cache, path, expectedHash) {
  const response = await fetch(SCOPE + path, {
    cache: 'no-store',
    credentials: 'same-origin',
    redirect: 'error',
  });
  if (!response.ok || response.status !== 200) {
    throw new Error('fetch ' + response.status);
  }
  const body = await response.arrayBuffer();
  if ((await sha256Hex(body)) !== expectedHash) return { response: new Response(body, response), stored: false };
  const headers = new Headers(response.headers);
  // The body is stored decoded.
  headers.delete('content-encoding');
  headers.delete('content-length');
  const init = { status: 200, statusText: 'OK', headers };
  await cache.put(SCOPE + path, new Response(body, init));
  return { response: new Response(body, init), stored: true };
}

// --- serving ---------------------------------------------------------------

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  // Update probes and the downloads above must see the server.
  if (request.cache === 'no-store') return;
  if (request.headers.has('range')) return;
  if (!request.url.startsWith(SCOPE)) return;
  const url = new URL(request.url);
  const relative = url.pathname.slice(SCOPE_PATH.length);
  if (NETWORK_ONLY.test(relative)) return;
  event.respondWith(serve(event, request, relative));
});

async function serve(event, request, relative) {
  try {
    const state = await readState();
    const buildId = (request.mode !== 'navigate' && clientBuilds.get(event.clientId)) ||
      state.active;
    if (!buildId) return fetch(request);
    const files = await buildManifest(buildId);
    if (!files) return fetch(request);
    let path = relative === '' ? 'index.html' : relative;
    if (request.mode === 'navigate' && !(path in files)) {
      // Client-side routes (/admin/…) are the application page.
      if (/\.[A-Za-z0-9]{1,8}$/.test(path)) return fetch(request);
      path = 'index.html';
    }
    const expected = files[path];
    if (!expected || SKIP.test(path)) return fetch(request);
    const cache = await caches.open(CACHE_PREFIX + buildId);
    const hit = await cache.match(SCOPE + path);
    if (hit) return hit;
    if (request.mode === 'navigate') return fetch(request);
    const fetched = await fetchVerified(cache, path, expected);
    return fetched.response;
  } catch (_) {
    return fetch(request);
  }
}

// --- commands from the page ------------------------------------------------

const preparing = new Map();

async function prepare(buildId, report) {
  const response = await fetch(SCOPE + MANIFEST_FILE, {
    cache: 'no-store',
    credentials: 'same-origin',
    redirect: 'error',
  });
  if (response.status === 404) return { ok: true, state: 'unsupported' };
  if (!response.ok) throw new Error('manifest ' + response.status);
  let manifest;
  try {
    manifest = await response.json();
  } catch (_) {
    // A server that answers unknown paths with the application page: this
    // bundle was built without a cache manifest.
    return { ok: true, state: 'unsupported' };
  }
  const files = manifest && manifest.files;
  if (!manifest || manifest.version !== 1 || !files || typeof files !== 'object') {
    throw new Error('manifest format');
  }
  // The server is serving another build than the page asked for (a deploy
  // is in progress, or it moved on again): nothing to store under this name.
  if (manifest.build_id !== buildId) throw new Error('build changed');

  const state = await readState();
  const cache = await caches.open(CACHE_PREFIX + buildId);
  const wanted = [];
  let reuse = null;
  if (state.active && state.active !== buildId && (await caches.has(CACHE_PREFIX + state.active))) {
    reuse = await caches.open(CACHE_PREFIX + state.active);
  }
  const reuseFiles = reuse ? (await buildManifest(state.active)) || {} : {};
  for (const path of Object.keys(files)) {
    if (SKIP.test(path) || NETWORK_ONLY.test(path)) continue;
    if (LAZY.test(path)) {
      // Keep the renderer files this browser already uses.
      if (!reuse || !(await reuse.match(SCOPE + path))) continue;
    }
    wanted.push(path);
  }
  let done = 0;
  let cursor = 0;
  const total = wanted.length;
  async function worker() {
    while (cursor < wanted.length) {
      const path = wanted[cursor++];
      if (!(await cache.match(SCOPE + path))) {
        const same = reuse && reuseFiles[path] === files[path]
          ? await reuse.match(SCOPE + path) : null;
        if (same) {
          // Unchanged since the build in use: copy instead of downloading.
          await cache.put(SCOPE + path, same);
        } else {
          const fetched = await fetchVerified(cache, path, files[path]);
          if (!fetched.stored) throw new Error('build changed');
        }
      }
      done++;
      if (done % 20 === 0 || done === total) report({ progress: true, done, total });
    }
  }
  await Promise.all(Array.from({ length: 6 }, worker));
  await cache.put(MANIFEST_KEY, new Response(JSON.stringify({ files }), {
    headers: { 'content-type': 'application/json' },
  }));
  await cache.put(COMPLETE_KEY, new Response('1'));
  manifestMemo.set(buildId, files);
  return { ok: true, state: 'ready' };
}

async function prune() {
  const state = await readState();
  const keep = new Set([state.active, state.previous].filter(Boolean).map((id) => CACHE_PREFIX + id));
  for (const id of preparing.keys()) keep.add(CACHE_PREFIX + id);
  for (const name of await caches.keys()) {
    if (name.startsWith(CACHE_PREFIX) && !keep.has(name)) {
      await caches.delete(name);
      manifestMemo.delete(name.slice(CACHE_PREFIX.length));
    }
  }
}

async function activate(buildId) {
  if (!(await buildComplete(buildId))) throw new Error('not prepared');
  const state = await readState();
  if (state.active !== buildId) {
    await writeState({ active: buildId, previous: state.active });
  }
  await prune();
  return { ok: true };
}

async function reset() {
  stateMemo = { active: null, previous: null };
  manifestMemo.clear();
  clientBuilds.clear();
  for (const name of await caches.keys()) {
    if (name.startsWith(CACHE_PREFIX) || name === META_CACHE) await caches.delete(name);
  }
  return { ok: true };
}

self.addEventListener('message', (event) => {
  const data = event.data || {};
  const port = event.ports && event.ports[0];
  const reply = (value) => { try { port && port.postMessage(value); } catch (_) {} };
  const sourceId = event.source && event.source.id;
  let work;
  switch (data.type) {
    case 'hello':
      if (sourceId && validBuildId(data.buildId)) clientBuilds.set(sourceId, data.buildId);
      work = readState().then((state) => ({ ok: true, active: state.active }));
      break;
    case 'prepare': {
      if (!validBuildId(data.buildId)) {
        work = Promise.reject(new Error('build id'));
        break;
      }
      let running = preparing.get(data.buildId);
      if (!running) {
        running = prepare(data.buildId, reply)
          .finally(() => preparing.delete(data.buildId));
        preparing.set(data.buildId, running);
      }
      work = running.then(async (result) => {
        // The asking page already runs this build (first visit, or a build
        // loaded from the network): serve it from the cache from now on.
        if (result.state === 'ready' && data.adopt === true) {
          const state = await readState();
          if (state.active !== data.buildId) {
            await writeState({ active: data.buildId, previous: state.active });
            await prune();
          }
        }
        return result;
      });
      break;
    }
    case 'activate':
      work = validBuildId(data.buildId)
        ? activate(data.buildId) : Promise.reject(new Error('build id'));
      break;
    case 'reset':
      work = reset();
      break;
    default:
      return;
  }
  event.waitUntil(work.then(reply, (error) => reply({ ok: false, error: String(error && error.message || error) })));
});
