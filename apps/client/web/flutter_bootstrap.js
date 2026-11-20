{{flutter_js}}
{{flutter_build_config}}

// Flutter's generated legacy worker activates immediately and navigates every
// open page. Keep this build identifier as a template token so deployed clients
// can discover a new static bundle without registering that worker.
globalThis.atermiusWebBuildId = {{flutter_service_worker_version}};
globalThis.atermiusProbeWebBuild = async () => {
  const probeUrl = new URL('flutter_bootstrap.js', document.baseURI);
  probeUrl.searchParams.set('atermius_update_probe', String(Date.now()));
  const response = await fetch(probeUrl, {
    cache: 'no-store',
    credentials: 'same-origin',
  });
  if (!response.ok) throw new Error('Web bundle probe failed');
  const source = await response.text();
  const match = source.match(
    /globalThis\.atermiusWebBuildId\s*=\s*['"]([A-Za-z0-9_-]{1,64})['"]/
  );
  if (!match) throw new Error('Web bundle identifier missing');
  return match[1];
};
globalThis.atermiusReloadWebApp = () => window.location.reload();

// --- Persistent bundle cache (atermius-sw.js) --------------------------------
// The cache worker keeps a complete, verified copy of each build. This page
// asks it to store the build it runs (so the next visit starts from the
// cache), to download a newer build in the background, and (only from the
// user's confirmed reload) to switch to that build. Without service worker
// support, on an insecure origin or with a bundle that has no cache manifest
// everything below reports 'unsupported' and the page behaves as before.
const atermiusCacheWorkerUrl = 'atermius-sw.js';
let atermiusCacheRegistration = null;

function atermiusCacheSupported() {
  if (!('serviceWorker' in navigator) || !window.isSecureContext) return false;
  // Guest share and join pages stay uncached.
  const base = new URL(document.baseURI).pathname;
  const relative = window.location.pathname.startsWith(base)
    ? window.location.pathname.slice(base.length) : '';
  return !/^(?:s\/|join\/?$)/.test(relative);
}

async function atermiusCacheWorker() {
  if (!atermiusCacheSupported()) return null;
  if (!atermiusCacheRegistration) {
    atermiusCacheRegistration = navigator.serviceWorker
      .register(new URL(atermiusCacheWorkerUrl, document.baseURI), {
        scope: new URL('./', document.baseURI).pathname,
        updateViaCache: 'none',
      })
      .catch(() => null);
  }
  const registration = await atermiusCacheRegistration;
  if (!registration) return null;
  const waitForActive = (worker) => new Promise((resolve) => {
    if (!worker) return resolve(null);
    if (worker.state === 'activated') return resolve(worker);
    const timer = setTimeout(() => resolve(null), 30000);
    worker.addEventListener('statechange', () => {
      if (worker.state === 'activated') {
        clearTimeout(timer);
        resolve(worker);
      } else if (worker.state === 'redundant') {
        clearTimeout(timer);
        resolve(null);
      }
    });
  });
  return registration.active ||
    waitForActive(registration.installing || registration.waiting);
}

function atermiusCacheCall(worker, message, timeoutMs, onProgress) {
  return new Promise((resolve, reject) => {
    const channel = new MessageChannel();
    // A browser may stop an idle or long-running worker; do not wait forever.
    let timer = setTimeout(() => reject(new Error('cache worker timeout')), timeoutMs);
    channel.port1.onmessage = (event) => {
      const data = event.data || {};
      if (data.progress) {
        clearTimeout(timer);
        timer = setTimeout(() => reject(new Error('cache worker timeout')), timeoutMs);
        onProgress?.(data);
        return;
      }
      clearTimeout(timer);
      channel.port1.close();
      if (data.ok) resolve(data); else reject(new Error(data.error || 'cache worker error'));
    };
    worker.postMessage(message, [channel.port2]);
  });
}

// Resolves 'ready' once the complete build is stored, or 'unsupported'.
// Rejects when the download did not finish (retry later).
globalThis.atermiusPrepareWebBuild = async (buildId) => {
  const worker = await atermiusCacheWorker();
  if (!worker) return 'unsupported';
  const result = await atermiusCacheCall(worker, {
    type: 'prepare',
    buildId: String(buildId),
    adopt: String(buildId) === String(globalThis.atermiusWebBuildId),
  }, 300000);
  return result.state === 'ready' ? 'ready' : 'unsupported';
};

// Makes the next page load start from the prepared build. If that cannot be
// done the cache is dropped instead, so the reload fetches the server's
// build rather than showing the old one again.
globalThis.atermiusActivateWebBuild = async (buildId) => {
  const worker = await atermiusCacheWorker();
  if (!worker) return;
  try {
    await atermiusCacheCall(worker, { type: 'activate', buildId: String(buildId) }, 15000);
  } catch (_) {
    try {
      await atermiusCacheCall(worker, { type: 'reset' }, 15000);
    } catch (_) {}
  }
};

async function atermiusStartBundleCache() {
  try {
    const worker = await atermiusCacheWorker();
    if (!worker) return;
    await atermiusCacheCall(worker, {
      type: 'hello',
      buildId: String(globalThis.atermiusWebBuildId),
    }, 15000);
    // Ask the browser not to evict the stored bundle under storage pressure.
    try {
      await navigator.storage?.persist?.();
    } catch (_) {}
    await globalThis.atermiusPrepareWebBuild(globalThis.atermiusWebBuildId);
  } catch (_) {
    // Best effort: the page keeps working from the network.
  }
}

// A stored bundle that cannot start must not lock the user out: drop the
// cache once and load from the server.
async function atermiusRecoverFromCachedBundleFailure() {
  const key = 'atermius.bundle-cache-recovery.v1';
  try {
    if (!navigator.serviceWorker?.controller) return false;
    if (sessionStorage.getItem(key)) return false;
    sessionStorage.setItem(key, '1');
    await atermiusCacheCall(navigator.serviceWorker.controller, { type: 'reset' }, 15000);
    window.location.reload();
    return true;
  } catch (_) {
    return false;
  }
}

function isFlutterLegacyWorker(worker) {
  if (!worker) return false;
  try {
    return new URL(worker.scriptURL).pathname.endsWith('/flutter_service_worker.js');
  } catch (_) {
    return false;
  }
}

function showLegacyWorkerMigrationNotice() {
  const container = document.createElement('main');
  container.setAttribute('role', 'alert');
  const title = document.createElement('h1');
  title.textContent = 'Finish retiring the older offline cache';
  const message = document.createElement('p');
  message.textContent =
    'Close other Atermius tabs, then reload this page. The Web app will start after the old cache releases control.';
  const reload = document.createElement('button');
  reload.type = 'button';
  reload.textContent = 'Reload page';
  reload.addEventListener('click', () => window.location.reload());
  container.append(title, message, reload);
  document.body.replaceChildren(container);
}

async function removeFlutterLegacyWorker() {
  if (!('serviceWorker' in navigator)) return false;
  const registrations = await navigator.serviceWorker.getRegistrations();
  const currentUrl = new URL(window.location.href);
  const legacy = registrations.filter((registration) => {
    const scopeUrl = new URL(registration.scope);
    const scopePath = scopeUrl.pathname;
    const descendantPrefix = scopePath.endsWith('/') ? scopePath : `${scopePath}/`;
    const workers = [registration.active, registration.waiting, registration.installing]
      .filter(Boolean);
    const coversCurrentApp = scopeUrl.origin === currentUrl.origin &&
      (currentUrl.pathname === scopePath ||
        currentUrl.pathname.startsWith(descendantPrefix));
    return coversCurrentApp && workers.some(isFlutterLegacyWorker);
  });

  try {
    if (legacy.length > 0) {
      await Promise.all(legacy.map((registration) => registration.unregister()));
      if ('caches' in window) {
        const flutterCache = await caches.open('flutter-app-cache');
        const legacyScopes = legacy.map((registration) =>
          new URL(registration.scope).pathname,
        );
        const currentBundleResource = (relativePath) =>
          /^(?:index\.html|flutter_bootstrap\.js|flutter\.js|flutter_service_worker\.js|main\.dart\.(?:js|mjs|wasm)|version\.json|manifest\.json|favicon\.(?:ico|png))$/.test(relativePath) ||
          /^(?:assets|canvaskit|fonts|icons)\//.test(relativePath);
        for (const request of await flutterCache.keys()) {
          const requestUrl = new URL(request.url);
          if (requestUrl.origin !== currentUrl.origin) continue;
          const belongsToCurrentApp = legacyScopes.some((scopePath) => {
            const prefix = scopePath.endsWith('/') ? scopePath : `${scopePath}/`;
            if (!requestUrl.pathname.startsWith(prefix)) return false;
            return currentBundleResource(requestUrl.pathname.slice(prefix.length));
          });
          if (belongsToCurrentApp) await flutterCache.delete(request);
        }
      }
    }
  } catch (_) {
    showLegacyWorkerMigrationNotice();
    return true;
  }

  const controllerIsLegacy = isFlutterLegacyWorker(navigator.serviceWorker.controller);
  if (!controllerIsLegacy) {
    try {
      sessionStorage.removeItem('atermius.flutter-sw-migration.v1');
    } catch (_) {}
    return false;
  }

  // This migration runs before Flutter creates terminal sessions. Browsers can
  // keep an unregistered worker as the current document's controller until a
  // navigation. Retry that startup navigation twice, then wait for the user
  // instead of launching Flutter under a stale worker or entering a reload loop.
  const migrationKey = 'atermius.flutter-sw-migration.v1';
  let attempts;
  try {
    attempts = Number(sessionStorage.getItem(migrationKey) || '0');
  } catch (_) {
    showLegacyWorkerMigrationNotice();
    return true;
  }
  if (Number.isInteger(attempts) && attempts < 2) {
    try {
      sessionStorage.setItem(migrationKey, String(attempts + 1));
    } catch (_) {
      showLegacyWorkerMigrationNotice();
      return true;
    }
    window.location.reload();
    return true;
  }
  showLegacyWorkerMigrationNotice();
  return true;
}

async function loadAtermiusFlutter() {
  try {
    if (await removeFlutterLegacyWorker()) return;
  } catch (_) {
    if (isFlutterLegacyWorker(navigator.serviceWorker?.controller)) {
      showLegacyWorkerMigrationNotice();
      return;
    }
  }
  const splash = globalThis.atermiusSplash;
  // Kick off the background preload of the Termius layout static resources
  // only after the legacy service-worker migration had its chance to reload,
  // so the old worker cannot answer these fetches from a stale cache.
  splash?.startBackgroundPreload?.();
  // The loader adds the app bundle as a script tag and never reports it when
  // that tag fails to load: the page stayed on "Starting Atermius…" for
  // good. Script load errors do not bubble, so listen in the capture phase.
  window.addEventListener('error', (event) => {
    const target = event.target;
    if (target instanceof HTMLScriptElement &&
        /\/main\.dart\.(?:js|mjs)(?:\?|$)/.test(target.src)) {
      console.error('Atermius app bundle failed to load');
      atermiusRecoverFromCachedBundleFailure().then((recovering) => {
        if (!recovering) splash?.fail?.('bundle-load');
      });
    }
  }, true);
  const config = {
    // Bundle CanvasKit and fallback fonts locally under the same-origin CSP.
    canvasKitBaseUrl: 'canvaskit/',
    fontFallbackBaseUrl: 'fonts/',
  };
  try {
    await _flutter.loader.load({
      config,
      // Flutter 3.47's loader only offers this hook: drive the engine
      // explicitly and tell the splash controller when the app is running.
      onEntrypointLoaded: async (initializer) => {
        const runner = await initializer.initializeEngine(config);
        splash?.onFlutterRunning?.();
        await runner.runApp();
        try {
          sessionStorage.removeItem('atermius.bundle-cache-recovery.v1');
        } catch (_) {}
        // Store this build for the next visit once the app is up, so the
        // download does not compete with the first start.
        setTimeout(atermiusStartBundleCache, 3000);
      },
      // Omitting serviceWorkerSettings disables Flutter's force-activate worker.
    });
  } catch (error) {
    console.error('Atermius Flutter startup failed:', error);
    if (!(await atermiusRecoverFromCachedBundleFailure())) {
      splash?.fail?.('flutter-load');
    }
  }
}

loadAtermiusFlutter();
