/**
 * Post-build script: converts root-relative paths in HTML files to relative paths
 * so the site works when opened directly via file:// protocol.
 */
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join, relative, dirname } from 'node:path';

const DIST = new URL('../dist/', import.meta.url).pathname;

async function getHtmlFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true, recursive: true });
  return entries
    .filter(e => e.isFile() && e.name.endsWith('.html'))
    .map(e => join(e.parentPath || e.path, e.name));
}

async function main() {
  const files = await getHtmlFiles(DIST);

  for (const file of files) {
    let html = await readFile(file, 'utf-8');
    const depth = relative(DIST, dirname(file));
    const prefix = depth ? depth.split('/').map(() => '..').join('/') + '/' : './';

    // Replace root-relative href and src attributes (but not protocol URLs or # anchors)
    html = html.replace(/(href|src|content)="\/(?!\/)/g, `$1="${prefix}`);

    await writeFile(file, html, 'utf-8');
  }

  console.log(`Converted ${files.length} HTML files to relative paths.`);
}

main();
