/// Reports the first resolved startup page ('anon', 'workspace' or
/// 'locked') to the browser splash loader (web/splash-loader.js).
///
/// Native builds have no browser splash, so the call is a no-op there.
void reportSplashAuthResolution(String page) {}
