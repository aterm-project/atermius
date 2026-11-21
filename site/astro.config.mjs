import { defineConfig } from 'astro/config';

// Served by GitHub Pages at https://aterm-project.github.io/atermius/.
// Override with SITE_URL / SITE_BASE when hosting somewhere else.
export default defineConfig({
  site: process.env.SITE_URL ?? 'https://aterm-project.github.io',
  base: process.env.SITE_BASE ?? '/atermius',
  trailingSlash: 'always',
  build: { assets: 'assets' },
});
