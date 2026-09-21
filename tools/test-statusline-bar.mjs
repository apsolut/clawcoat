// Functional tests for the statusline part system (cfg.bar).
//
//   node tools/test-statusline-bar.mjs
//
// Extracts $StatuslineSource straight out of install.ps1 and runs it against a
// fake HOME, so it tests the shipping text and can never read (or disturb) the
// developer's live ~/.clawcoat config.
import { writeFileSync, mkdirSync, rmSync } from 'fs';
import { execFileSync } from 'child_process';
import { join } from 'path';
import { extractTo } from './extract-herestring.mjs';

const NODE = process.execPath;
const SCRATCH = extractTo(['StatuslineSource']);
// Teardown on exit, not at the end of the file: an assertion that throws would
// otherwise skip cleanup and leak a temp dir on every failing run.
process.on('exit', () => { try { rmSync(SCRATCH, { recursive: true, force: true }); } catch {} });
const SL = join(SCRATCH, 'StatuslineSource.js');
const HOME = join(SCRATCH, 't-home');
const CFG = join(HOME, '.clawcoat', 'clawcoat.json');

let pass = 0, fail = 0;
const check = (name, cond, detail) => {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}${detail !== undefined ? ` — ${JSON.stringify(detail)}` : ''}`); }
};

mkdirSync(join(HOME, '.clawcoat'), { recursive: true });

const SESSION = {
  model: { display_name: 'Claude Opus 5' },
  effort: { level: 'high' },
  context_window: { used_percentage: 34 },
  rate_limits: { five_hour: { used_percentage: 28 } },
  workspace: { current_dir: process.cwd() },
};

function render(cfg, session = SESSION) {
  if (cfg === null) rmSync(CFG, { force: true });
  else writeFileSync(CFG, JSON.stringify(cfg, null, 2));
  return execFileSync(NODE, [SL], {
    input: JSON.stringify(session),
    encoding: 'utf8',
    env: { ...process.env, HOME, USERPROFILE: HOME },
  });
}
// strip ANSI so assertions read the text, not the escape soup
const plain = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

console.log('\nstatusline parts\n');

// ---- defaults / backwards compatibility ----
let o = plain(render({ theme: 'biohazard' }));
check('unset bar keeps the original layout', o.includes('Claude Opus 5') && o.includes('ctx 34%') && o.includes('5h 28%'), o);
check('  default separator is ·', o.includes(' · '), o);
check('  no hive parts leak in', !o.includes('T-VIRUS') && !o.includes('CONTAIN'), o);

o = plain(render(null));
check('missing config still renders', o.includes('Claude Opus 5'), o);

// ---- hive parts ----
const HIVE = {
  theme: 'biohazard', org: 'Umbrella  Hive·B7', barSep: '│',
  bar: ['brand', 'contain', 'tvirus', 'pwr', 'model', 'status', 'sweep', 'clock'],
};
o = plain(render(HIVE));
check('brand uses org, uppercased', o.includes('█ UMBRELLA  HIVE·B7'), o);
check('contain = 100 - ctx', o.includes('CONTAIN') && / 66%/.test(o), o);
check('  contain draws a meter', /[█░]{10}/.test(o), o);
check('tvirus = ctx used', o.includes('T-VIRUS 34%'), o);
check('pwr = 5h reserve remaining (not used)', o.includes('PWR 72%'), o);
check('status SECURE at 66% integrity', o.includes('SECURE'), o);
check('custom separator applied', o.includes(' │ '), o);
check('sweep renders a glyph', /[◜◝◞◟]/.test(o), o);

// ---- the bar genuinely degrades ----
const at = (used) => plain(render(HIVE, { ...SESSION, context_window: { used_percentage: used } }));
check('ctx 10%  -> SECURE', at(10).includes('SECURE'));
check('ctx 50%  -> ELEVATED', at(50).includes('ELEVATED'));
check('ctx 80%  -> BREACH', at(80).includes('BREACH'));
check('  breach dot is one of ⬤/○', /[⬤○] BREACH/.test(at(80)), at(80));

// ---- graceful degradation on missing metrics ----
o = plain(render(HIVE, { model: { display_name: 'X' } }));
check('no metrics -> hive parts skipped, not NaN', !/NaN|undefined|null/.test(o), o);
check('  brand + model still render', o.includes('UMBRELLA') && o.includes('X'), o);
check('  no dangling separators', !/│\s*│/.test(o) && !o.trim().endsWith('│'), o);

// ---- label precedence ----
o = plain(render({ ...HIVE, label: 'RED QUEEN' }));
check('cfg.label wins over display_name', o.includes('RED QUEEN') && !o.includes('Claude Opus 5'), o);

// ---- accent comes from the live palette, not a hardcoded table ----
const withPal = { theme: 'custom', palettes: { custom: { claude: 'rgb(1,2,3)' } }, bar: ['model'] };
check('accent read from cfg.palettes', render(withPal).includes('38;2;1;2;3m'), render(withPal));
const unknown = { theme: 'nope-not-a-theme', bar: ['model'] };
check('unknown theme falls back, does not crash', plain(render(unknown)).includes('Claude Opus 5'));

// ---- unknown parts ignored ----
o = plain(render({ ...HIVE, bar: ['model', 'not-a-part', 'clock'] }));
check('unknown part is skipped silently', o.includes('Claude Opus 5') && !o.includes('not-a-part'), o);

// ---- string form accepted ----
o = plain(render({ theme: 'biohazard', bar: 'tvirus,pwr' }));
check('bar accepts a comma string', o.includes('T-VIRUS') && o.includes('PWR'), o);

// ---- empty bar falls back to default rather than a blank line ----
o = plain(render({ theme: 'biohazard', bar: [] }));
check('empty bar -> default, not blank', o.includes('Claude Opus 5'), o);

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
