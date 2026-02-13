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
  }
});
