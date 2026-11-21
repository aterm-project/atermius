// These colors are available before Flutter paints its first frame. The table
// is checked against AppPalette.resolve by web_startup_palette_test.dart.
(() => {
  const palettes = {
    "dark": {
      "emerald": ["#0b0f10", "#ecf3f2", "#4fd8c4", "#ffb55e"],
      "ocean": ["#0c0e11", "#eef2f6", "#90c2ff", "#ffb55e"],
      "violet": ["#0e0e11", "#f2f0f6", "#caadff", "#ffb55e"],
      "rose": ["#110d0e", "#f6eff1", "#ff9cbc", "#ffb55e"],
      "amber": ["#100e0b", "#f4f1ec", "#f1b249", "#ffb55e"],
      "graphite": ["#0d0e10", "#eff1f4", "#b8bfc8", "#ffb55e"]
    },
    "light": {
      "emerald": ["#ffffff", "#14211f", "#0c6b5e", "#9e4b00"],
      "ocean": ["#ffffff", "#181f27", "#2c5e94", "#9e4b00"],
      "violet": ["#ffffff", "#1f1c26", "#644d90", "#9e4b00"],
      "rose": ["#ffffff", "#261a1e", "#89405b", "#9e4b00"],
      "amber": ["#ffffff", "#231d14", "#7b530c", "#9e4b00"],
      "graphite": ["#ffffff", "#1b1e22", "#585d62", "#9e4b00"]
    }
  };

  const root = document.documentElement;
  const meta = document.getElementById('atermius-theme-color');
  const systemDark = window.matchMedia('(prefers-color-scheme: dark)');
  let preference = '';
  try {
    preference = localStorage.getItem('atermius.app-theme.v1') || '';
  } catch (_) {
    // Browser storage can be unavailable in a private or embedded session.
  }

  function apply() {
    const record = preference.length <= 16 ? preference.toLowerCase() : '';
    const colon = record.indexOf(':');
    const mode = (colon < 0 ? record : record.slice(0, colon)).trim();
    // Same default scheme as defaultAppAccent in app_theme.dart.
    const accent = colon < 0 ? 'ocean' : record.slice(colon + 1).trim();
    const light = mode === 'light' || (mode === 'system' && !systemDark.matches);
    const scheme = light ? palettes.light : palettes.dark;
    const [background, text, progress, warning] =
      Object.prototype.hasOwnProperty.call(scheme, accent) ? scheme[accent] : scheme.ocean;
    root.style.colorScheme = light ? 'light' : 'dark';
    root.style.setProperty('--app-background', background);
    root.style.setProperty('--app-text', text);
    root.style.setProperty('--app-progress', progress);
    root.style.setProperty('--app-warning', warning);
    meta.content = background;
  }

  window.addEventListener('atermius:app-theme', (event) => {
    if (typeof event.detail !== 'string') return;
    preference = event.detail;
    apply();
  });
  systemDark.addEventListener('change', apply);
  apply();
})();
