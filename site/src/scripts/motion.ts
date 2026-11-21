import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { SplitText } from 'gsap/SplitText';
import { ScrambleTextPlugin } from 'gsap/ScrambleTextPlugin';
import { DrawSVGPlugin } from 'gsap/DrawSVGPlugin';
import Lenis from 'lenis';

gsap.registerPlugin(ScrollTrigger, SplitText, ScrambleTextPlugin, DrawSVGPlugin);

const $ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) => root.querySelector<T>(sel);
const $$ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) => Array.from(root.querySelectorAll<T>(sel));
const clamp01 = gsap.utils.clamp(0, 1);
const GLYPHS = '01<>/_$#{}[]~';
const HEX = '0123456789abcdef';
const finePointer = window.matchMedia('(hover: hover) and (pointer: fine)').matches;

function start() {
  const mm = gsap.matchMedia();

  mm.add('(prefers-reduced-motion: reduce)', () => {
    $('.intro')?.remove();
  });

  mm.add('(prefers-reduced-motion: no-preference)', () => {
    const lenis = new Lenis({ lerp: 0.1, anchors: { offset: -80 } });
    lenis.on('scroll', ScrollTrigger.update);
    const raf = (time: number) => lenis.raf(time * 1000);
    gsap.ticker.add(raf);
    gsap.ticker.lagSmoothing(0);

    const stopField = glyphField();
    intro(lenis);
    chrome();
    hero();
    marquee();
    headings();
    stats();
    security();
    reveals();
    pointerEffects();
    phones();
    codeBlock();
    downloadTitle();

    return () => {
      gsap.ticker.remove(raf);
      lenis.destroy();
      stopField();
    };
  });

  // Pinned scenes need room; below 1000px the same content is a plain column.
  mm.add('(prefers-reduced-motion: no-preference) and (min-width: 1000px)', () => {
    showcase();
    gallery();
  });
  mm.add('(prefers-reduced-motion: no-preference) and (max-width: 999px)', () => {
    $$('.feature').forEach((el) => {
      gsap.from(el.children, {
        y: 46, autoAlpha: 0, duration: 0.9, ease: 'power3.out', stagger: 0.07,
        scrollTrigger: { trigger: el, start: 'top 82%' },
      });
    });
  });

  window.addEventListener('load', () => ScrollTrigger.refresh());
}

/* ---------- intro + hero entrance ---------- */
function intro(lenis: Lenis) {
  const overlay = $('.intro');
  const heroSplits = $$('.hero [data-split]').map((el) =>
    el.closest('.accent') ? { chars: [el] } : SplitText.create(el, { type: 'chars' }),
  );
  const chars = heroSplits.flatMap((s) => s.chars as Element[]);

  gsap.set(chars, { yPercent: 118, rotate: 6, transformOrigin: '0% 100%' });
  gsap.set(['.hero .eyebrow', '.hero-sub', '.hero-cta > *', '.scroll-hint'], { autoAlpha: 0, y: 26 });
  gsap.set('.hero-window', { autoAlpha: 0, y: 140, rotateX: 34, scale: 0.86, transformPerspective: 1800 });
  gsap.set('.nav', { xPercent: -50, yPercent: -180 });

  const tl = gsap.timeline({ defaults: { ease: 'power4.out' } });
  if (overlay) {
    lenis.stop();
    window.scrollTo(0, 0);
    const word = $('.intro-word', overlay)!;
    tl.from($('.mark-bg', overlay), { scale: 0, rotate: -90, transformOrigin: '50% 50%', duration: 0.8, ease: 'back.out(1.6)' })
      .from($$('.mark-line', overlay), { drawSVG: '0%', duration: 0.7, stagger: 0.12, ease: 'power2.inOut' }, '-=0.35')
      .to(word, { duration: 0.9, scrambleText: { text: 'atermius', chars: GLYPHS, speed: 0.5 } }, '<')
      .to($('.mark-caret', overlay), { autoAlpha: 0, repeat: 3, yoyo: true, duration: 0.11, ease: 'none' })
      .to(overlay, { clipPath: 'inset(0% 0% 100% 0%)', duration: 0.9, ease: 'power4.inOut' })
      .add(() => { overlay.remove(); lenis.start(); })
      .addLabel('in', '-=0.55');
  } else {
    tl.addLabel('in', 0);
  }

  tl.to(chars, { yPercent: 0, rotate: 0, duration: 1.15, stagger: { each: 0.022, from: 'start' } }, 'in')
    .to('.nav', { yPercent: 0, duration: 1 }, 'in+=0.2')
    .to('.hero .eyebrow', { autoAlpha: 1, y: 0, duration: 0.8 }, 'in+=0.15')
    .to('.hero .eyebrow', { duration: 1.1, scrambleText: { text: '{original}', chars: GLYPHS, speed: 0.6 } }, '<')
    .to('.hero-sub', { autoAlpha: 1, y: 0, duration: 0.9 }, 'in+=0.5')
    .to('.hero-cta > *', { autoAlpha: 1, y: 0, duration: 0.8, stagger: 0.09 }, 'in+=0.62')
    .to('.hero-window', { autoAlpha: 1, y: 0, rotateX: 16, scale: 0.94, duration: 1.6, ease: 'expo.out' }, 'in+=0.45')
    .to('.scroll-hint', { autoAlpha: 1, y: 0, duration: 0.8 }, 'in+=1.1');
}

function hero() {
  const win = $('.hero-window');
  if (!win) return;
  // The window lies back at first and stands up as it scrolls into the middle of the screen.
  gsap.fromTo(win,
    { rotateX: 16, scale: 0.94 },
    {
      rotateX: 0, scale: 1, ease: 'none', immediateRender: false,
      scrollTrigger: { trigger: '.hero-stage', start: 'top 78%', end: 'top 12%', scrub: 0.6 },
    });
  gsap.to('.hero-copy', {
    yPercent: -14, autoAlpha: 0.25, ease: 'none',
    scrollTrigger: { trigger: '.hero', start: 'top top', end: '55% top', scrub: true },
  });

  if (finePointer) {
    const ry = gsap.quickTo(win, 'rotateY', { duration: 0.9, ease: 'power3.out' });
    const stage = $('.hero-stage')!;
    stage.addEventListener('pointermove', (e) => {
      const r = win.getBoundingClientRect();
      const px = (e.clientX - r.left) / r.width;
      const py = (e.clientY - r.top) / r.height;
      ry((px - 0.5) * 7);
      win.style.setProperty('--mx', `${px * 100}%`);
      win.style.setProperty('--my', `${py * 100}%`);
    });
    stage.addEventListener('pointerleave', () => ry(0));
  }
}

/* ---------- page chrome: progress bar, nav, glows ---------- */
function chrome() {
  gsap.to('.progress i', { scaleX: 1, ease: 'none', scrollTrigger: { start: 0, end: 'max', scrub: 0.3 } });

  const nav = $('.nav')!;
  let hidden = false;
  ScrollTrigger.create({
    start: 200, end: 'max',
    onUpdate: (self) => {
      const hide = self.direction === 1 && self.scroll() > 600;
      if (hide === hidden) return;
      hidden = hide;
      gsap.to(nav, { yPercent: hide ? -180 : 0, duration: 0.5, ease: 'power3.out', overwrite: 'auto' });
    },
  });

  gsap.to('.glow-a', { yPercent: 55, xPercent: 22, ease: 'none', scrollTrigger: { start: 0, end: 'max', scrub: 1.2 } });
  gsap.to('.glow-b', { yPercent: -70, xPercent: -30, ease: 'none', scrollTrigger: { start: 0, end: 'max', scrub: 1.6 } });
  gsap.to('.glow', { scale: 1.18, duration: 7, ease: 'sine.inOut', repeat: -1, yoyo: true, stagger: 2 });
}

/* ---------- platform marquee: speed and lean follow the scroll ---------- */
function marquee() {
  const track = $('[data-marquee]');
  if (!track) return;
  const loop = gsap.to(track, { xPercent: -100 / 3, duration: 26, ease: 'none', repeat: -1 });
  const skew = gsap.quickTo(track, 'skewX', { duration: 0.5, ease: 'power3.out' });
  const settle = gsap.delayedCall(0.25, () => {
    gsap.to(loop, { timeScale: Math.sign(loop.timeScale()) || 1, duration: 0.9, overwrite: true });
    skew(0);
  }).pause();
  ScrollTrigger.create({
    start: 0, end: 'max',
    onUpdate: (self) => {
      const v = self.getVelocity();
      const dir = v < 0 ? -1 : 1;
      gsap.to(loop, { timeScale: dir * (1 + Math.min(Math.abs(v) / 280, 7)), duration: 0.25, overwrite: true });
      skew(gsap.utils.clamp(-14, 14, v / -160));
      settle.restart(true);
    },
  });
}

/* ---------- section headings ---------- */
function headings() {
  $$('[data-reveal-words]').forEach((el) => {
    SplitText.create(el, {
      type: 'lines', mask: 'lines', autoSplit: true,
      onSplit: (self) =>
        gsap.from(self.lines, {
          yPercent: 112, rotate: 3, transformOrigin: '0% 100%', duration: 1.15, ease: 'power4.out', stagger: 0.11,
          scrollTrigger: { trigger: el, start: 'top 86%' },
        }),
    });
  });

  $$('[data-scramble]').forEach((el) => {
    if (el.closest('.hero')) return;
    gsap.from(el, { autoAlpha: 0, duration: 0.4, scrollTrigger: { trigger: el, start: 'top 90%' } });
    gsap.to(el, {
      duration: 1.2, scrambleText: { text: '{original}', chars: GLYPHS, speed: 0.6 },
      scrollTrigger: { trigger: el, start: 'top 90%' },
    });
  });
}

/* ---------- pinned feature showcase ---------- */
function showcase() {
  const pin = $('.showcase-pin');
  const texts = $$('.showcase-texts .feature');
  const stages = $$('.stage-window');
  const rail = $$('.showcase-rail li i');
  if (!pin || texts.length < 2 || stages.length !== texts.length) return;
  const n = texts.length;

  gsap.set(texts.slice(1), { autoAlpha: 0 });
  gsap.set(stages, { transformPerspective: 1600 });
  gsap.set(stages.slice(1), { clipPath: 'inset(100% 0% 0% 0%)' });

  const tl = gsap.timeline({
    defaults: { ease: 'power2.inOut' },
    scrollTrigger: {
      trigger: pin, start: 'top top', end: () => `+=${window.innerHeight * n * 0.95}`,
      pin: true, scrub: 0.7, anticipatePin: 1, invalidateOnRefresh: true,
      onUpdate: (self) => rail.forEach((el, i) => el.style.setProperty('--p', String(clamp01(self.progress * n - i)))),
    },
  });

  gsap.from(stages[0], {
    y: 120, rotateX: 18, autoAlpha: 0, duration: 1.2, ease: 'expo.out',
    scrollTrigger: { trigger: pin, start: 'top 65%' },
  });
  gsap.from(texts[0].children, {
    y: 40, autoAlpha: 0, duration: 0.9, ease: 'power3.out', stagger: 0.08,
    scrollTrigger: { trigger: pin, start: 'top 60%' },
  });

  tl.to({}, { duration: 0.45 });
  for (let i = 1; i < n; i++) {
    const at = `step${i}`;
    tl.addLabel(at)
      .to(texts[i - 1].children, { y: -46, autoAlpha: 0, duration: 0.4, stagger: 0.03, ease: 'power2.in' }, at)
      .set(texts[i - 1], { autoAlpha: 0 })
      .set(texts[i], { autoAlpha: 1 })
      .from(texts[i].children, { y: 56, autoAlpha: 0, duration: 0.5, stagger: 0.05, ease: 'power3.out' })
      .to(stages[i - 1], { scale: 0.9, yPercent: -5, rotateX: 8, filter: 'brightness(0.4)', duration: 0.95 }, at)
      .fromTo(stages[i],
        { clipPath: 'inset(100% 0% 0% 0%)', yPercent: 10, rotateX: -10 },
        { clipPath: 'inset(0% 0% 0% 0%)', yPercent: 0, rotateX: 0, duration: 0.95 }, at)
      .to({}, { duration: 0.5 });
  }
}

/* ---------- counters ---------- */
function stats() {
  $$('[data-count]').forEach((el) => {
    const target = Number(el.dataset.count);
    const state = { v: 0 };
    gsap.to(state, {
      v: target, duration: target > 1000 ? 2.4 : 1.4, ease: 'power3.out',
      onUpdate: () => { el.textContent = Math.round(state.v).toLocaleString('en-US'); },
      scrollTrigger: { trigger: el, start: 'top 88%' },
    });
  });
  gsap.from('.stat', {
    y: 50, autoAlpha: 0, duration: 0.9, ease: 'power3.out', stagger: 0.1,
    scrollTrigger: { trigger: '.stats', start: 'top 85%' },
  });
}

/* ---------- security: plaintext on the devices, ciphertext on the server ---------- */
function security() {
  const wire = $('.wire');
  if (!wire) return;
  const hex = (len: number) => Array.from({ length: len }, () => HEX[(Math.random() * 16) | 0]).join('');
  const serverLines = $$('[data-cipher-line]', wire);
  const otherLines = $$('.wire-other .pre span', wire);
  const plain = otherLines.map((el) => el.textContent ?? '');

  gsap.set($$('.wire-node', wire), { autoAlpha: 0, y: 50 });
  gsap.set($$('.wire-link', wire), { autoAlpha: 0 });
  otherLines.forEach((el) => { el.textContent = hex((el.textContent ?? '').trimEnd().length); });

  const tl = gsap.timeline({ scrollTrigger: { trigger: wire, start: 'top 72%' }, defaults: { ease: 'power3.out' } });
  tl.to('.wire-device', { autoAlpha: 1, y: 0, duration: 0.8 })
    .to($$('.wire-link', wire)[0], { autoAlpha: 1, duration: 0.5 }, '-=0.3')
    .to('.wire-server', { autoAlpha: 1, y: 0, duration: 0.8 }, '-=0.3');
  serverLines.forEach((el, i) => {
    const len = (el.textContent ?? '').trimEnd().length;
    tl.to(el, { duration: 0.9, scrambleText: { text: hex(len), chars: HEX, speed: 0.9 } }, `-=${i ? 0.75 : 0.2}`);
  });
  tl.to($$('.wire-link', wire)[1], { autoAlpha: 1, duration: 0.5 }, '-=0.4')
    .to('.wire-other', { autoAlpha: 1, y: 0, duration: 0.8 }, '-=0.3');
  otherLines.forEach((el, i) => {
    tl.to(el, { duration: 1, scrambleText: { text: plain[i].trimEnd(), chars: HEX, speed: 0.7 } }, `-=${i ? 0.8 : 0.3}`);
  });
  // The server never settles on readable text: its lines keep changing.
  tl.add(() => {
    serverLines.forEach((el, i) => {
      const len = (el.textContent ?? '').trimEnd().length;
      const again = () => gsap.to(el, {
        duration: 0.8, delay: 1.6 + i * 0.35 + Math.random(),
        scrambleText: { text: hex(len), chars: HEX, speed: 1 }, onComplete: again,
      });
      again();
    });
  });

  $$('.wire-path', wire).forEach((path) => {
    gsap.to(path, { strokeDashoffset: -40, duration: 1.4, ease: 'none', repeat: -1 });
  });
  $$('.wire-packet', wire).forEach((el, i) => {
    gsap.fromTo(el, { xPercent: -160, autoAlpha: 0 }, {
      keyframes: [
        { xPercent: -110, autoAlpha: 1, duration: 0.5 },
        { xPercent: 10, duration: 1.6, ease: 'none' },
        { xPercent: 60, autoAlpha: 0, duration: 0.5 },
      ],
      repeat: -1, repeatDelay: 0.4, delay: i * 1.3,
    });
  });
}

/* ---------- generic reveals ---------- */
function reveals() {
  $$('[data-reveal]').forEach((el) => {
    gsap.from(el, {
      y: 34, autoAlpha: 0, duration: 0.95, ease: 'power3.out',
      scrollTrigger: { trigger: el, start: 'top 90%' },
    });
  });
  gsap.set('[data-batch]', { autoAlpha: 0, y: 60, rotateX: -12, transformPerspective: 900, transformOrigin: '50% 100%' });
  ScrollTrigger.batch('[data-batch]', {
    start: 'top 90%', once: true,
    onEnter: (els) => gsap.to(els, { autoAlpha: 1, y: 0, rotateX: 0, duration: 1, ease: 'power3.out', stagger: 0.09, overwrite: true }),
  });
}

/* ---------- pointer: magnetic buttons, card spotlight and tilt ---------- */
function pointerEffects() {
  if (!finePointer) return;
  $$('[data-magnetic]').forEach((el) => {
    const x = gsap.quickTo(el, 'x', { duration: 0.5, ease: 'power3.out' });
    const y = gsap.quickTo(el, 'y', { duration: 0.5, ease: 'power3.out' });
    el.addEventListener('pointermove', (e) => {
      const r = el.getBoundingClientRect();
      x((e.clientX - r.left - r.width / 2) * 0.28);
      y((e.clientY - r.top - r.height / 2) * 0.42);
    });
    el.addEventListener('pointerleave', () => {
      gsap.to(el, { x: 0, y: 0, duration: 0.9, ease: 'elastic.out(1, 0.4)', overwrite: true });
    });
  });

  $$('[data-spot]').forEach((el) => {
    const rx = gsap.quickTo(el, 'rotationX', { duration: 0.6, ease: 'power3.out' });
    const ry = gsap.quickTo(el, 'rotationY', { duration: 0.6, ease: 'power3.out' });
    el.addEventListener('pointermove', (e) => {
      const r = el.getBoundingClientRect();
      const px = (e.clientX - r.left) / r.width;
      const py = (e.clientY - r.top) / r.height;
      el.style.setProperty('--mx', `${px * 100}%`);
      el.style.setProperty('--my', `${py * 100}%`);
      rx((0.5 - py) * 7);
      ry((px - 0.5) * 7);
    });
    el.addEventListener('pointerleave', () => { rx(0); ry(0); });
  });
}

/* ---------- horizontal gallery ---------- */
function gallery() {
  const pin = $('.gallery-pin');
  const track = $('.gallery-track');
  if (!pin || !track) return;
  const distance = () => Math.max(0, track.scrollWidth - window.innerWidth);
  const scroll = gsap.to(track, {
    x: () => -distance(), ease: 'none',
    scrollTrigger: {
      trigger: pin, start: 'center center', end: () => `+=${distance()}`,
      pin: true, scrub: 0.8, anticipatePin: 1, invalidateOnRefresh: true,
    },
  });
  $$('.gallery-item', track).forEach((item) => {
    gsap.fromTo(item, { scale: 0.86, autoAlpha: 0.35 }, {
      scale: 1, autoAlpha: 1, ease: 'none',
      scrollTrigger: { trigger: item, containerAnimation: scroll, start: 'left 96%', end: 'left 52%', scrub: true },
    });
  });
}

/* ---------- phones ---------- */
function phones() {
  const list = $$('.phone');
  if (!list.length) return;
  list.forEach((el, i) => {
    gsap.fromTo(el,
      { y: i % 2 ? -50 : 90, rotateY: i % 2 ? 16 : -16, rotateZ: i % 2 ? 3 : -3, transformPerspective: 1400 },
      {
        y: i % 2 ? 70 : -70, rotateY: i % 2 ? 5 : -5, rotateZ: 0, ease: 'none',
        scrollTrigger: { trigger: '.mobile', start: 'top bottom', end: 'bottom top', scrub: 0.8 },
      });
  });
}

/* ---------- self-host commands type themselves ---------- */
function codeBlock() {
  const block = $('[data-code]');
  if (!block) return;
  const lines = $$('.code-line', block);
  gsap.set(lines, { autoAlpha: 0 });
  const tl = gsap.timeline({ scrollTrigger: { trigger: block, start: 'top 72%' } });
  tl.from(block, { y: 60, autoAlpha: 0, duration: 0.9, ease: 'power3.out' });
  lines.forEach((line) => {
    const text = $('span', line)!;
    const steps = Math.max(12, Math.round((text.textContent ?? '').length / 2));
    tl.set(line, { autoAlpha: 1 })
      .fromTo(text, { clipPath: 'inset(0% 100% 0% 0%)' },
        { clipPath: 'inset(0% 0% 0% 0%)', duration: Math.min(1.3, steps * 0.03), ease: `steps(${steps})` })
      .to({}, { duration: 0.18 });
  });
}

/* ---------- closing title is scrubbed in letter by letter ---------- */
function downloadTitle() {
  const title = $('.download-title');
  if (!title) return;
  const parts = $$('[data-split-scroll]', title).flatMap((el) =>
    el.closest('.accent') ? [el as Element] : (SplitText.create(el, { type: 'chars' }).chars as Element[]),
  );
  gsap.from(parts, {
    yPercent: 120, rotate: 8, transformOrigin: '0% 100%', ease: 'power2.out', stagger: 0.06,
    scrollTrigger: { trigger: title, start: 'top 92%', end: 'top 38%', scrub: 0.7 },
  });
}

/* ---------- background glyph field ---------- */
function glyphField() {
  const canvas = $<HTMLCanvasElement>('.field');
  const ctx = canvas?.getContext('2d');
  if (!canvas || !ctx) return () => {};
  const STEP = 36;
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  let w = 0, h = 0, cols = 0, rows = 0;
  let cells: { g: string; seed: number }[] = [];
  const pointer = { x: -9999, y: -9999 };
  const eased = { x: -9999, y: -9999 };

  const resize = () => {
    w = window.innerWidth; h = window.innerHeight;
    canvas.width = w * dpr; canvas.height = h * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = '12px "JetBrains Mono Variable", ui-monospace, monospace';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    cols = Math.ceil(w / STEP) + 1; rows = Math.ceil(h / STEP) + 2;
    cells = Array.from({ length: cols * rows }, () => ({ g: GLYPHS[(Math.random() * GLYPHS.length) | 0], seed: Math.random() }));
  };
  const onMove = (e: PointerEvent) => { pointer.x = e.clientX; pointer.y = e.clientY; };

  let frame = 0;
  const draw = (time: number) => {
    if (document.hidden) return;
    frame++;
    eased.x += (pointer.x - eased.x) * 0.12;
    eased.y += (pointer.y - eased.y) * 0.12;
    const shift = (window.scrollY * 0.12) % STEP;
    ctx.clearRect(0, 0, w, h);
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const cell = cells[r * cols + c];
        const x = c * STEP + STEP / 2;
        const y = r * STEP - shift;
        // A slow diagonal wave plus a pool of light under the pointer.
        const wave = Math.sin((c + r) * 0.42 - time * 0.9 + cell.seed * 1.4) * 0.5 + 0.5;
        const d = Math.hypot(x - eased.x, y - eased.y);
        const near = Math.max(0, 1 - d / 240);
        const a = 0.035 + wave * wave * 0.1 + near * near * 0.75;
        if (near > 0.25 && (frame + ((cell.seed * 60) | 0)) % 9 === 0) cell.g = GLYPHS[(Math.random() * GLYPHS.length) | 0];
        ctx.fillStyle = near > 0.05 ? `rgba(140, 240, 205, ${a})` : `rgba(130, 156, 255, ${a})`;
        ctx.fillText(cell.g, x, y);
      }
    }
  };

  resize();
  window.addEventListener('resize', resize);
  window.addEventListener('pointermove', onMove, { passive: true });
  gsap.ticker.add(draw);
  return () => {
    gsap.ticker.remove(draw);
    window.removeEventListener('resize', resize);
    window.removeEventListener('pointermove', onMove);
  };
}

if (document.fonts?.ready) document.fonts.ready.then(start);
else start();
