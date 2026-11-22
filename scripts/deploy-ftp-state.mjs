// Keeps `lftp mirror --only-newer` from re-uploading the whole site after
// every build. Astro rewrites every file in dist/ (including copies of
// public/), so every file looks newer than the remote copy.
//
// After a successful deploy, `save` records each file's SHA-256 and mtime.
// Before the next deploy, `restore` gives every file whose content is
// unchanged its recorded mtime back, so only files that really changed look
// newer than the server's copy.
//
// Before a live upload, `prune` drops every record entry whose content differs
// from dist/ (or whose file is gone). If that upload then fails half way, the
// record no longer vouches for files the server may now hold in a newer
// version, so the next deploy compares them again instead of skipping them.
//
// Before a live --full upload, which re-sends every file, `clear` deletes the
// record: a --full run cut off part way can leave any file incomplete on the
// server, so no entry may survive it.
//
// Usage:
//   node scripts/deploy-ftp-state.mjs restore <distDir> <manifest.json>
//   node scripts/deploy-ftp-state.mjs prune   <distDir> <manifest.json>
//   node scripts/deploy-ftp-state.mjs clear   <distDir> <manifest.json>
//   node scripts/deploy-ftp-state.mjs save    <distDir> <manifest.json>

import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';

const [cmd, distDir, manifestPath] = process.argv.slice(2);
if (!['restore', 'prune', 'clear', 'save'].includes(cmd) || !distDir || !manifestPath) {
  console.error('usage: deploy-ftp-state.mjs restore|prune|clear|save <distDir> <manifest.json>');
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

// Returns the recorded files, or null when there is no readable record.
function readManifest() {
  try {
    return JSON.parse(readFileSync(manifestPath, 'utf8')).files ?? {};
  } catch {
    return null;
  }
}

function writeManifest(files) {
  mkdirSync(dirname(manifestPath), { recursive: true });
  const tmp = `${manifestPath}.tmp`;
  writeFileSync(tmp, JSON.stringify({ savedAt: new Date().toISOString(), files }, null, 1));
  renameSync(tmp, manifestPath);
}

if (cmd === 'clear') {
  rmSync(manifestPath, { force: true });
} else if (cmd === 'prune') {
  const manifest = readManifest();
  if (manifest === null) process.exit(0);
  const files = {};
  for (const file of walk(distDir)) {
    const prev = manifest[key(file)];
    if (prev && prev.sha256 === sha256(file)) files[key(file)] = prev;
  }
  writeManifest(files);
} else if (cmd === 'restore') {
  const manifest = readManifest();
  if (manifest === null) {
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
  writeManifest(files);
}
