// Pull a literal PowerShell here-string (@' ... '@) out of install.ps1, so the
// JavaScript embedded in the installer can be tested exactly as it ships rather
// than as a retyped copy that can drift.
//
// CLI:  node tools/extract-herestring.mjs install.ps1 StatuslineSource sl.js
// API:  import { extract, extractTo } from './extract-herestring.mjs'
import { readFileSync, writeFileSync, mkdtempSync } from 'fs';
import { fileURLToPath } from 'url';
import { tmpdir } from 'os';
import { join, dirname, resolve } from 'path';

const here = dirname(fileURLToPath(import.meta.url));
export const INSTALLER = resolve(here, '..', 'install.ps1');

export function extract(varName, installer = INSTALLER) {
  const code = readFileSync(installer, 'utf8');
  const m = code.match(new RegExp(`\\$${varName}\\s*=\\s*@'\\r?\\n([\\s\\S]*?)\\r?\\n'@`));
  if (!m) throw new Error(`here-string not found in ${installer}: $${varName}`);
  return m[1];
}

// Writes the named here-strings into a fresh temp dir and returns its path, so a
// test can run them without the caller having to pre-extract anything.
export function extractTo(varNames, installer = INSTALLER) {
  const dir = mkdtempSync(join(tmpdir(), 'clawcoat-'));
  for (const v of varNames) writeFileSync(join(dir, `${v}.js`), extract(v, installer));
  return dir;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const [src, varName, out] = process.argv.slice(2);
  if (!src || !varName || !out) {
    console.error('usage: extract-herestring.mjs <install.ps1> <VarName> <outFile>');
    process.exit(1);
  }
  const body = extract(varName, src);
  writeFileSync(out, body);
  console.log(`extracted $${varName} -> ${out} (${body.length} bytes)`);
}
