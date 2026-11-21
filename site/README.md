# Atermius site

The introduction page served at <https://aterm-project.github.io/atermius/> (English) and
<https://aterm-project.github.io/atermius/zh/> (Chinese). A static [Astro](https://astro.build) site;
the motion is [GSAP](https://gsap.com) (ScrollTrigger, SplitText, ScrambleText, DrawSVG) with
[Lenis](https://lenis.darkroom.engineering) smooth scrolling.

```bash
cd site
npm ci
npm run dev        # http://localhost:4321/atermius/
npm run build      # static output in dist/
./deploy.sh        # build and publish dist/ to the gh-pages branch
```

Node 20 or later. `SITE_URL` and `SITE_BASE` override the address the site is built for
(defaults: `https://aterm-project.github.io` and `/atermius`).

## Layout

| Path | Contents |
| --- | --- |
| `src/i18n.ts` | All text of both languages, and the caption of every screenshot |
| `src/components/Landing.astro` | The page; `src/pages/` only picks the language |
| `src/scripts/motion.ts` | Every animation. With `prefers-reduced-motion` nothing is animated and the page is plain |
| `src/styles/global.css` | Styles |
| `src/assets/shots/` | Screenshots; Astro converts them to WebP in several widths at build time |

## Screenshots

Every image in `src/assets/shots/` is an unedited screenshot of the browser build of Atermius, driven
by Playwright against a disposable local server and a throwaway OpenSSH account. Host names, the
account and the terminal output in them are made up for the pictures. A section whose screenshot is
missing is left out of the page, and a screenshot only appears in the gallery once it has a caption in
`shotCaptions`.

Publishing is done from a developer machine with `./deploy.sh`; there is no workflow for it.
