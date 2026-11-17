import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool _authResolutionReported = false;
bool _readyReported = false;

/// Dispatches the one-shot `atermius:auth-resolved` CustomEvent that
/// web/splash-loader.js uses to release the silent-loading splash:
/// 'anon' steps the splash aside immediately (login page + thin preload
/// bar), while 'workspace'/'locked' keep the animated splash until the
/// background preload of the layout static resources has settled.
void reportSplashAuthResolution(String page) {
  if (_authResolutionReported) return;
  _authResolutionReported = true;
  final event = web.CustomEvent(
    'atermius:auth-resolved',
    web.CustomEventInit(detail: page.toJS),
  );
  // Let the resolved page paint one frame before the splash fades away.
  web.window.requestAnimationFrame(
    ((double _) => web.window.dispatchEvent(event)).toJS,
  );
}

/// Dispatches the one-shot `atermius:ready` CustomEvent once the unlocked
/// AppShell has painted its first frame, so the splash hands over to a live
/// console instead of a blank canvas. web/splash-loader.js treats this event
/// as optional and releases on a short grace period when it never arrives.
void reportSplashReady() {
  if (_readyReported) return;
  _readyReported = true;
  web.window.dispatchEvent(
    web.CustomEvent('atermius:ready', web.CustomEventInit()),
  );
}
