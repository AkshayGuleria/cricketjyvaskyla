# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Official website for Jyväskylä Cricket Club (JCC), a Finnish sports association founded in 2009. Astro 7 static site, deployed to Netlify at https://cricketjyvaskyla.com.

(An older jQuery/XHTML version of this site existed before the rewrite in `776b41c`. Any instruction elsewhere about `js/header.js`, LavaLamp, `document.write()`, or ISO-8859-1 refers to that dead site.)

## Architecture

### Stack

- Astro 7, `output: 'static'`, no server runtime (requires Node >=22.12)
- Plain CSS with custom properties — no Tailwind, no CSS framework
- PhotoSwipe 5 for the gallery lightbox
- TypeScript in `.astro` frontmatter (`@astrojs/check`)
- `@astrojs/sitemap` — new pages are picked up automatically, no manual sitemap edits

### Layout composition

Every page follows the same shape:

```astro
---
import BaseLayout from '../layouts/BaseLayout.astro';
import Header from '../components/Header.astro';
import Footer from '../components/Footer.astro';
---
<BaseLayout title="..." description="...">
  <Header slot="header" />
  <div class="container">
    ...page content...
  </div>
  <Footer slot="footer" />
</BaseLayout>
```

`BaseLayout.astro` owns `<head>`: title, description, canonical, OG/Twitter tags, favicons, Google Fonts, and the `SportsOrganization` JSON-LD block. It exposes named slots `header` and `footer` plus the default slot for page content. Props: `title` (required), `description`, `ogImage`, `noindex`.

### Styling

- `src/styles/global.css` — design tokens (`--color-*`, `--space-*`, `--font-size-*`, `--radius-*`, `--shadow-*`) plus a small set of global classes: `.container`, `.reveal` / `.reveal-delay-1..4`, `.visually-hidden`, `.sr-only`.
- Everything else lives in each file's scoped `<style>` block.
- Palette is "Nordic Cricket Editorial": deep navy `--color-primary`, terracotta `--color-accent`, warm cream surfaces, gold accents. Always use the tokens, never raw hex.
- Presentational classes like `.page-hero`, `.info-card`, `.card-accent`, `.section-label`, `.cta-band`, `.btn-accent` are **deliberately duplicated per page** because Astro scopes styles. When building a new page, copy these blocks from the closest existing page (`join_us.astro` is the best template for a content page) rather than inventing new ones or hoisting them into `global.css`.

### Data

- `src/data/members.json` — `{ executive: [{name, role, email}], players: [{name, role}] }`, rendered through `MemberCard.astro`.
- `src/data/gallery.json` — `{ albums: [{id, title, description, date, location, coverImage, images[]}], note }`, rendered through `Gallery.astro`. Image entries need `width`/`height` for PhotoSwipe.
- Fixtures are **not** in JSON — the fixture list is an inline array in `src/pages/fixtures.astro`.

## Development

```bash
npm install
npm run dev      # http://localhost:4321
npm run build    # astro build + scripts/make-relative-paths.mjs → dist/
npm run preview
```

There is no test suite and no linter. Verification is `npm run build` (must complete with no errors) plus manual checks — see `TESTING.md` for the checklist.

CI (`.github/workflows/ci.yml`) runs on PRs to `master`: `npm ci`, `npm audit --audit-level=critical`, `npm run build`.

## Conventions and Gotchas

### CRLF line endings

Most `.astro` files, `CLAUDE.md`, and `TESTING.md` use **CRLF**. There is no `.gitattributes`. Editing tools that rewrite a file wholesale can silently convert it to LF and produce a diff touching every line. After editing, check `git diff --stat` — if a file shows hundreds of changed lines for a one-line edit, the endings were flipped; restore with `perl -pi -e 's/\r?\n/\r\n/' <file>`. (`src/pages/index.astro` and `README.md` are LF.)

### Always write root-relative links in source

Write `/juniors/`, not `../juniors/`. The post-build script `scripts/make-relative-paths.mjs` rewrites every root-relative `href`/`src`/`content` in `dist/**/*.html` into a path relative to that file's depth, so the built site also works over `file://`. Hand-written relative paths defeat it.

### Do not drop the CSS target pin

`astro.config.mjs` pins `vite.build.cssTarget` to `['safari15', 'chrome100', 'firefox100']`. Without it, the default target emits media range syntax (`@media (width <= 640px)`), which Safari only supports from 16.4 - every responsive rule would be ignored on iOS 15 and early iOS 16.

### Trailing slashes

`astro.config.mjs` sets `trailingSlash: 'always'`. Internal links must end with `/` (`/members/`, not `/members`).

### Adding a page

1. Create `src/pages/<name>.astro` following the layout composition above.
2. Add an entry to the `navItems` array in `src/components/Header.astro`. `isActive()` handles highlighting via `startsWith`, so no other change is needed.
3. Add a link to the relevant column in `src/components/Footer.astro` (Navigate or Resources).
4. Sitemap is automatic. `netlify.toml` redirects exist only to map legacy `*.html` URLs from the pre-Astro site — a new page needs one only if an old URL pointed at it.
5. The desktop nav row is near capacity; adding items may need spacing tightened at the 1024–1279px band in `Header.astro`.

### Text

Files are UTF-8, so literal `ä`/`ö` are fine and are what `title`/`description` props use. In markup body text the existing pages lean on HTML entities (`&auml;`, `&mdash;`, `&euro;`) — match whichever the surrounding file already does. Entities do **not** work inside `.astro` attribute values or expressions, which are escaped as text.

### Assets

- Images and PDFs are static files under `public/` (`public/images/`, `public/pdfs/{agms,by-laws,smviikko2024}/`), referenced as `/images/...` and `/pdfs/...`. There is no `src/assets/` pipeline in use.
- `dist/` and `.astro/` are generated; both are gitignored.

## Deployment

Netlify builds `npm run build` and publishes `dist/` on push to `master` (Node 22 — Astro 7 requires >=22.12). `netlify.toml` also sets security headers and long cache lifetimes for `/assets/*`, `/images/*`, and `/pdfs/*`. See `DEPLOYMENT.md`.
