// Silent-loading splash controller for the Flutter Web entry layer.
//
// Runs synchronously before flutter_bootstrap.js so every later hook can
// reach `window.atermiusSplash`. Responsibilities:
//   1. Present the animated "Starting Atermius…" startup state (vendored
//      GSAP at web/gsap/; CSS breathing fallback when GSAP or motion is out).
//   2. Read the stored-session hint from localStorage as a fast pre-check,
//      then rely on the Dart bridge event 'atermius:auth-resolved'
//      (detail 'anon' | 'workspace' | 'locked') as the authoritative signal.
//   3. Preload the Termius layout static resources in the background
//      (bounded concurrency, timeout) and drive the thin top progress bar.
//   4. Release rules:
//        - login page ('anon'): splash steps aside immediately; the thin bar
//          stays over the login page until the preload settles.
//        - console ('workspace' | 'locked'): the GSAP animation keeps running
//          until the preload settles, then the splash fades out.
//      A first-frame fallback releases the splash even if the Dart bridge is
//      absent (guest pages, older bundles).
//
// No inline event handlers (strict CSP 'self').
(function () {
  "use strict";

  var PRELOAD_RESOURCES = [
    { path: "assets/AssetManifest.bin.json" },
    { path: "assets/FontManifest.json" },
    // The bundle layout for pubspec fonts is under "assets/assets/…" today;
    // the bare variants are optional probes so either layout counts.
    { path: "assets/assets/fonts/atermius_icons.ttf", optional: true },
    { path: "assets/fonts/atermius_icons.ttf", optional: true },
    { path: "assets/assets/fonts/MaterialIcons-Regular.otf", optional: true },
    { path: "assets/fonts/MaterialIcons-Regular.otf", optional: true },
    { path: "sqlite3.wasm" },
    { path: "drift_worker.js" },
    { path: "version.json" },
    { path: "manifest.json", optional: true },
  ];
  var PRELOAD_CONCURRENCY = 4;
  var PRELOAD_TIMEOUT_MS = 30000;
  var FALLBACK_RELEASE_MS = 20000;

  var splashEl = document.getElementById("atermius-splash");
  // The splash covers the page before the app's own right-click handling
  // exists; keep the browser menu off it too.
  if (splashEl) {
    splashEl.addEventListener("contextmenu", function (event) {
      event.preventDefault();
    });
  }
  var wordmarkEl = document.getElementById("atermius-wordmark");
  var progressEl = document.getElementById("atermius-progress");
  var fillEl = document.getElementById("atermius-progress-fill");

  var reducedMotion = false;
  try {
    reducedMotion =
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch (_) {
    reducedMotion = false;
  }

  var state = {
    likelyLoggedIn: false,
    authResolved: null, // 'anon' | 'workspace' | 'locked'
    flutterRunning: false,
    firstFrame: false,
    resourcesSettled: false,
    resourcesOk: false,
    released: false,
    failed: null,
  };

  var resourcesDone = 0;
  var resourcesTotal = 0;
  var failures = [];
  var gsapTimeline = null;

  // --- login pre-check (hint only) -------------------------------------
  // Session snapshots are persisted through flutter_secure_storage (web):
  // localStorage keys look like
  //   secure_storage.atermius.v1.<url-encoded-origin-ns>.session.<user>.<device>
  // Their presence means a session was stored for this browser; the Dart
  // bridge event later corrects the guess (expired sessions land on login).
  function readLoginHint() {
    try {
      var storage = window.localStorage;
      if (!storage) return false;
      for (var i = 0; i < storage.length; i += 1) {
        var key = storage.key(i) || "";
        if (
          key.indexOf("atermius.v1.") !== -1 &&
          key.indexOf(".session.") !== -1
        ) {
          return true;
        }
      }
    } catch (_) {
      // Access errors (private mode, blocked storage) stay "unknown".
    }
    return false;
  }
  state.likelyLoggedIn = readLoginHint();

  // --- animated wordmark ------------------------------------------------
  function splitWordmark() {
    if (!wordmarkEl) return;
    var text = wordmarkEl.textContent || "Starting Atermius…";
    wordmarkEl.textContent = "";
    for (var i = 0; i < text.length; i += 1) {
      var span = document.createElement("span");
      var ch = text.charAt(i);
      if (ch === " ") {
        span.innerHTML = "&nbsp;";
      } else {
        span.textContent = ch;
      }
      wordmarkEl.appendChild(span);
    }
  }

  function startAnimation() {
    if (!wordmarkEl) return;
    if (reducedMotion) return; // static text by design
    var chars = wordmarkEl.querySelectorAll("span");
    if (window.gsap && typeof window.gsap.fromTo === "function") {
      gsapTimeline = window.gsap.fromTo(
        chars,
        { autoAlpha: 0.25, y: 6 },
        {
          autoAlpha: 1,
          y: 0,
          duration: 0.9,
          ease: "sine.inOut",
          stagger: { each: 0.05, from: "start" },
          repeat: -1,
          yoyo: true,
          repeatDelay: 0.35,
        }
      );
    } else {
      // GSAP missing (failed to load): keep a pure-CSS breathing loop.
      wordmarkEl.classList.add("atermius-wordmark-pulse");
    }
  }

  function stopAnimation() {
    if (gsapTimeline) {
      gsapTimeline.kill();
      gsapTimeline = null;
    }
    if (wordmarkEl) wordmarkEl.classList.remove("atermius-wordmark-pulse");
  }

  // --- progress bar -------------------------------------------------------
  function updateProgress() {
    if (!fillEl || resourcesTotal === 0) return;
    var pct = Math.round((resourcesDone / resourcesTotal) * 100);
    fillEl.style.width = Math.max(4, pct) + "%";
  }

  function markResourceDone(entry, ok) {
    resourcesDone += 1;
    if (!ok && entry && !entry.optional) failures.push(entry.path);
    updateProgress();
    if (resourcesDone >= resourcesTotal) settleResources();
  }

  function preloadOne(entry) {
    var url = new URL(entry.path, document.baseURI).href;
    var timeoutId = null;
    var timedOut = false;
    var raced = new Promise(function (resolve, reject) {
      timeoutId = window.setTimeout(function () {
        timedOut = true;
        reject(new Error("preload-timeout"));
      }, PRELOAD_TIMEOUT_MS);
      fetch(url, { cache: "default", credentials: "same-origin" })
        .then(function (response) {
          if (!response.ok) {
            throw new Error("preload-http-" + response.status);
          }
          return response.arrayBuffer();
        })
        .then(function () {
          resolve();
        })
        .catch(reject);
    });
    return raced.then(
      function () {
        if (timeoutId) window.clearTimeout(timeoutId);
        if (timedOut) markResourceDone(entry, false);
        else markResourceDone(entry, true);
      },
      function () {
        if (timeoutId) window.clearTimeout(timeoutId);
        markResourceDone(entry, false);
      }
    );
  }

  function trackSodiumScript() {
    // sodium.js is already on the page as an async script tag; join its
    // result instead of fetching a second copy.
    var scripts = document.getElementsByTagName("script");
    for (var i = 0; i < scripts.length; i += 1) {
      var src = scripts[i].getAttribute("src") || "";
      if (src.indexOf("sodium.js") !== -1) {
        var sodium = scripts[i];
        resourcesTotal += 1;
        if (sodium.complete || sodium.readyState === "complete") {
          // Already loaded before the controller attached its listeners.
          markResourceDone({ path: "sodium.js" }, true);
          return;
        }
        sodium.addEventListener(
          "load",
          function () {
            markResourceDone({ path: "sodium.js" }, true);
          },
          { once: true }
        );
        sodium.addEventListener(
          "error",
          function () {
            markResourceDone({ path: "sodium.js" }, false);
          },
          { once: true }
        );
        return;
      }
    }
  }

  var resourcesResolve = null;
  var resourcesPromise = new Promise(function (resolve) {
    resourcesResolve = resolve;
  });

  function settleResources() {
    if (state.resourcesSettled) return;
    state.resourcesSettled = true;
    state.resourcesOk = failures.length === 0;
    if (progressEl) {
      fillEl && (fillEl.style.width = "100%");
      progressEl.classList.add("is-done");
      if (!state.resourcesOk) progressEl.classList.add("is-failed");
    }
    resourcesResolve({ ok: state.resourcesOk, failures: failures.slice() });
    maybeRelease();
  }

  function startBackgroundPreload() {
    if (state.preloadStarted) return resourcesPromise;
    state.preloadStarted = true;

    var queue = PRELOAD_RESOURCES.slice();
    resourcesTotal = queue.length;
    trackSodiumScript();
    if (progressEl) progressEl.classList.add("is-active");
    updateProgress();

    var active = 0;
    function pump() {
      while (active < PRELOAD_CONCURRENCY && queue.length > 0) {
        var entry = queue.shift();
        active += 1;
        preloadOne(entry).then(function () {
          active -= 1;
          if (
            queue.length === 0 &&
            active === 0 &&
            resourcesDone >= resourcesTotal
          ) {
            settleResources();
          }
          pump();
        });
      }
      if (queue.length === 0 && active === 0 && resourcesDone >= resourcesTotal) {
        settleResources();
      }
    }
    pump();
    window.setTimeout(settleResources, PRELOAD_TIMEOUT_MS + 5000);
    return resourcesPromise;
  }

  // --- release ------------------------------------------------------------
  function releaseSplash() {
    if (state.released) return;
    state.released = true;
    stopAnimation();
    if (!splashEl) return;
    if (
      window.gsap &&
      !reducedMotion &&
      typeof window.gsap.to === "function"
    ) {
      window.gsap.to(splashEl, {
        autoAlpha: 0,
        y: -10,
        duration: 0.45,
        ease: "power2.out",
        onComplete: function () {
          if (splashEl.parentNode) splashEl.parentNode.removeChild(splashEl);
        },
      });
    } else {
      splashEl.classList.add("atermius-splash-hide");
      window.setTimeout(function () {
        if (splashEl.parentNode) splashEl.parentNode.removeChild(splashEl);
      }, reducedMotion ? 0 : 500);
    }
  }

  function maybeRelease() {
    if (state.released || state.failed) return;
    var resolved = state.authResolved;
    if (resolved === "anon") {
      releaseSplash();
      return;
    }
    if ((resolved === "workspace" || resolved === "locked") && state.resourcesSettled) {
      releaseSplash();
      return;
    }
    if (resolved === null && state.firstFrame && state.resourcesSettled) {
      // No Dart bridge (guest pages / older bundle): first frame plus a
      // settled preload is the best available release signal.
      releaseSplash();
    }
  }

  function applyFailure(code) {
    if (state.released) return;
    state.failed = code || "startup";
    stopAnimation();
    if (wordmarkEl) {
      wordmarkEl.textContent = "Atermius could not start. Reloading…";
    }
    window.setTimeout(function () {
      window.location.reload();
    }, 1500);
  }

  // --- wiring -------------------------------------------------------------
  splitWordmark();
  startAnimation();

  window.addEventListener("atermius:auth-resolved", function (event) {
    var detail = event && event.detail;
    if (detail !== "anon" && detail !== "workspace" && detail !== "locked") {
      return;
    }
    state.authResolved = detail;
    maybeRelease();
  });

  window.addEventListener("flutter-first-frame", function () {
    state.firstFrame = true;
    maybeRelease();
  });

  // If the bridge never arrives (e.g. the app stalls before its first real
  // page), never hold the splash forever.
  window.setTimeout(function () {
    if (state.authResolved === null && !state.released) {
      state.firstFrame = true;
      if (state.resourcesSettled) releaseSplash();
    }
  }, FALLBACK_RELEASE_MS);

  window.atermiusSplash = {
    state: state,
    likelyLoggedIn: function () {
      return state.likelyLoggedIn;
    },
    whenResourcesSettled: function () {
      return resourcesPromise;
    },
    startBackgroundPreload: startBackgroundPreload,
    onFlutterRunning: function () {
      state.flutterRunning = true;
    },
    notifyAuthResolved: function (detail) {
      state.authResolved = detail;
      maybeRelease();
    },
    fail: applyFailure,
  };
})();
