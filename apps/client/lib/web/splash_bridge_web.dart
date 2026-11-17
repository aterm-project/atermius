import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool _authResolutionReported = false;

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
