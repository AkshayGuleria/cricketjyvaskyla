// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  output: 'static', // this is the default, but explicit is nice
  site: 'https://cricketjyvaskyla.com',
  trailingSlash: 'always',
  integrations: [sitemap()],
  image: {
    domains: ['cricketjyvaskyla.com']
  },
  build: {
    inlineStylesheets: 'auto'
  },
  vite: {
    build: {
      // Astro 7's default CSS target emits media range syntax
      // (`@media (width <= 640px)`), which Safari only understands from
      // 16.4. Pin an older target so responsive rules keep the
      // `max-width` form and still apply on iOS 15 / early iOS 16.
      cssTarget: ['safari15', 'chrome100', 'firefox100']
    }
  }
});
