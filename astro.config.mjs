// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://cricketjyvaskyla.com',
  integrations: [sitemap()],
  image: {
    domains: ['cricketjyvaskyla.com']
  },
  build: {
    inlineStylesheets: 'auto'
  }
});
