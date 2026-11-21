// Keeps `lftp mirror --only-newer` from re-uploading the whole site after
// every build. Astro rewrites every file in dist/ (including copies of
// public/), so every file looks newer than the remote copy.
//
// After a successful deploy, `save` records each file's SHA-256 and mtime.
// Before the next deploy, `restore` gives every file whose content is
// unchanged its recorded mtime back, so only files that really changed look
// newer than the server's copy.
//
// Usage:
//   node scripts/deploy-ftp-state.mjs restore <distDir> <manifest.json>
//   node scripts/deploy-ftp-state.mjs save    <distDir> <manifest.json>

import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, renameSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';

const [cmd, distDir, manifestPath] = process.argv.slice(2);
if (!['restore', 'save'].includes(cmd) || !distDir || !manifestPath) {
  console.error('usage: deploy-ftp-state.mjs restore|save <distDir> <manifest.json>');
  process.exit(2);
}

function* walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (entry.isFile()) yield full;
  }
}

const sha256 = (file) => createHash('sha256').update(readFileSync(file)).digest('hex');
const key = (file) => relative(distDir, file).split(sep).join('/');

if (cmd === 'restore') {
  let manifest = {};
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8')).files ?? {};
  } catch {
    console.log('No previous deploy recorded: every file will be uploaded.');
    process.exit(0);
  }
  let kept = 0;
  let changed = 0;
  for (const file of walk(distDir)) {
    const prev = manifest[key(file)];
    if (prev && prev.sha256 === sha256(file)) {
      const t = new Date(prev.mtimeMs);
      utimesSync(file, t, t);
      kept++;
    } else {
      changed++;
    }
  }
  console.log(`${kept} file(s) unchanged since last deploy, ${changed} new or changed.`);
} else {
  const files = {};
  for (const file of walk(distDir)) {
    files[key(file)] = { sha256: sha256(file), mtimeMs: Math.floor(statSync(file).mtimeMs / 1000) * 1000 };
  }
  mkdirSync(dirname(manifestPath), { recursive: true });
  const tmp = `${manifestPath}.tmp`;
  writeFileSync(tmp, JSON.stringify({ savedAt: new Date().toISOString(), files }, null, 1));
  renameSync(tmp, manifestPath);
}
