/// Reports the first resolved startup page ('anon', 'workspace' or
/// 'locked') to the browser splash loader (web/splash-loader.js).
///
/// Native builds have no browser splash, so the call is a no-op there.
void reportSplashAuthResolution(String page) {}

/// Reports the AppShell-first-frame 'atermius:ready' signal to the browser
/// splash loader. Native builds have no browser splash, so it is a no-op.
void reportSplashReady() {}
