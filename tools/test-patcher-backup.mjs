// Tests that the patcher's clean backup tracks the INSTALLED version rather than
// being created once and never refreshed. A stale backup is what let -NoUpgrade
// and the wrapper's syntax rescue silently downgrade Claude Code.
//
//   node tools/test-patcher-backup.mjs
import { writeFileSync, readFileSync, existsSync, mkdtempSync, rmSync } from 'fs';
import { execFileSync } from 'child_process';
import { join } from 'path';
import { tmpdir } from 'os';
import { extract } from './extract-herestring.mjs';

const NODE = process.execPath;
const DIR = mkdtempSync(join(tmpdir(), 'clawcoat-bak-'));
// Teardown on exit, not at the end of the file: an assertion that throws would
// otherwise skip cleanup and leak a temp dir on every failing run.
process.on('exit', () => { try { rmSync(DIR, { recursive: true, force: true }); } catch {} });
const PATCHER = join(DIR, 'patch.mjs');
const TARGET = join(DIR, 'cli.original.cjs');
const BACKUP = TARGET + '.bak';
const BACKUP_VER = BACKUP + '.version';

writeFileSync(PATCHER, extract('patcherCode').replaceAll('__CLAW_HEX__', '#6495ed'));

let pass = 0, fail = 0;
const check = (n, c, d) => {
  if (c) { pass++; console.log(`  ok   ${n}`); }
  else { fail++; console.log(`  FAIL ${n}${d !== undefined ? ` — ${JSON.stringify(d)}` : ''}`); }
};

// A minimal stand-in bundle carrying a version banner and one patchable token.
const bundle = (v) => `// Version: ${v}\nconst t={clawd_body:"rgb(215,119,87)"};\nmodule.exports=t;\n`;
// The patcher now exits non-zero when a run is not viable, so capture instead of
// throwing — several cases here deliberately exercise those exits.
const runPatcher = () => {
  try { return execFileSync(NODE, [PATCHER], { cwd: DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch (e) { return String(e.stdout || '') + String(e.stderr || ''); }
};

console.log('\npatcher: clean backup versioning\n');

// ---- first install ----
writeFileSync(TARGET, bundle('2.1.238'));
let out = runPatcher();
check('first run creates a backup', existsSync(BACKUP));
check('  stamped with the bundle version', readFileSync(BACKUP_VER, 'utf8').trim() === '2.1.238');
check('  backup holds the PRISTINE text', readFileSync(BACKUP, 'utf8') === bundle('2.1.238'));
check('  target was actually patched', readFileSync(TARGET, 'utf8').includes('__clawcoat'));
check('  reported the version', /Backup: .*2\.1\.238/.test(out), out.match(/Backup:.*/)?.[0]);

// ---- re-running on the SAME version must not capture the patched file ----
const bakBefore = readFileSync(BACKUP, 'utf8');
runPatcher();
check('re-run leaves the backup pristine', readFileSync(BACKUP, 'utf8') === bakBefore);
check('  backup still has no patch marker', !readFileSync(BACKUP, 'utf8').includes('__clawcoat'));

// ---- upgrade: this is the bug. A fresh extract replaces TARGET. ----
writeFileSync(TARGET, bundle('2.1.245'));
out = runPatcher();
check('upgrade REFRESHES the backup', readFileSync(BACKUP_VER, 'utf8').trim() === '2.1.245');
check('  backup is the new bundle, not the old one', readFileSync(BACKUP, 'utf8') === bundle('2.1.245'));
check('  restoring it would NOT downgrade', !readFileSync(BACKUP, 'utf8').includes('2.1.238'));

// ---- a fully patched target with no backup: 0 patches match, so the patcher
//      does nothing at all and must not invent a backup from patched text ----
rmSync(BACKUP, { force: true });
rmSync(BACKUP_VER, { force: true });
out = runPatcher();   // TARGET is still patched from the run above
check('fully patched target is not backed up as clean', !existsSync(BACKUP));
check('  and nothing was applied', /0 applied/.test(out), out.match(/Result:.*/)?.[0]);
check('  already-patched is NOT reported as failure', /already patched/.test(out) && !/every hook missed/.test(out), out.match(/already patched.*|every hook missed.*/)?.[0]);

// ---- partially patched: some patches DO match, so the write block runs. This
//      is the path where a naive `!existsSync(BACKUP)` would capture patched text
//      and permanently poison every restore. ----
writeFileSync(TARGET, `// Version: 2.1.245\nconst a=globalThis.__clawcoat?1:0;\nconst t={clawd_body:"rgb(215,119,87)"};\n`);
out = runPatcher();
check('partially patched target still not backed up', !existsSync(BACKUP));
check('  patcher warns restore paths are disabled', /no clean backup/.test(out), out.match(/no clean backup.*/)?.[0]);
check('  but it did apply the remaining patch', /[1-9]\d* applied/.test(out), out.match(/Result:.*/)?.[0]);

// A genuinely drifted bundle (unpatched, nothing matches) must exit non-zero so
// the installer can refuse rather than print "installed!" over a stock CLI.
writeFileSync(TARGET, ['// Version: 9.9.9', 'const nothing = 1;', ''].join('\n'));
const drift = runPatcher();
check('drifted bundle reports every hook missed', /every hook missed/.test(drift), drift.match(/XX.*/)?.[0]);
check('  and does not create a backup from it', !existsSync(BACKUP));

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
