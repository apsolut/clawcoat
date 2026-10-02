// Functional tests for the statusline part system (cfg.bar).
//
//   node tools/test-statusline-bar.mjs
//
// Extracts $StatuslineSource straight out of install.ps1 and runs it against a
// fake HOME, so it tests the shipping text and can never read (or disturb) the
// developer's live ~/.clawcoat config.
import { writeFileSync, mkdirSync, rmSync, readFileSync, existsSync } from 'fs';
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

// ---- barLabels: per-part label overrides ----
o = plain(render({ ...HIVE, barLabels: { contain: 'CNTX', tvirus: 'VIRAL' } }));
check('barLabels renames contain -> CNTX', o.includes('CNTX') && !o.includes('CONTAIN'), o);
check('  and tvirus -> VIRAL', o.includes('VIRAL 34%') && !o.includes('T-VIRUS'), o);
o = plain(render({ ...HIVE, barLabels: { pwr: '' } }));
check('empty barLabel hides the label, keeps the value', !o.includes('PWR') && o.includes('72%'), o);
o = plain(render({ ...HIVE, barLabels: { pwr: 42 } }));
check('non-string barLabel ignored, default kept', o.includes('PWR 72%'), o);

// ---- pomo: repeating pomodoro countdown ----
const DOSE = join(HOME, '.clawcoat', '.dose');
const now = Date.now();

// fresh sitting that started 10 minutes ago -> 30m default leaves ~20m
writeFileSync(DOSE, JSON.stringify({ start: now - 10 * 60000, last: now }));
o = plain(render({ theme: 'biohazard', bar: ['pomo'] }));
check('pomo renders MM:SS', /POMO \d{2}:\d{2}/.test(o), o);
check('  default 30m anchored to dose start (10m in -> ~20m left)', /POMO (19:[0-5]\d|20:00)/.test(o), o);

// custom length: pomoMins 5, two minutes in -> ~3m left
writeFileSync(DOSE, JSON.stringify({ start: now - 2 * 60000, last: now }));
o = plain(render({ theme: 'biohazard', bar: ['pomo'], pomoMins: 5 }));
check('pomoMins respected (5m, 2m in -> ~3m left)', /POMO (02:[0-5]\d|03:00)/.test(o), o);

// stale sitting (idle longer than doseIdleReset) -> midnight anchor fallback
writeFileSync(DOSE, JSON.stringify({ start: now - 90 * 60000, last: now - 60 * 60000 }));
o = plain(render({ theme: 'biohazard', bar: ['pomo'] }));
{
  const midnight = new Date(); midnight.setHours(0, 0, 0, 0);
  const left = 30 * 60000 - ((Date.now() - midnight.getTime()) % (30 * 60000));
  const mm = Math.floor(left / 60000);
  const m = /POMO (\d{2}):/.exec(o);
  // modular distance: 00:xx and 30:00 are one tick apart across a block boundary
  const d = m ? Math.abs(+m[1] - mm) : 99;
  check('stale dose -> midnight-anchored blocks', m && Math.min(d, 30 - d) <= 1, o);
}

// no .dose at all -> still renders, never NaN
rmSync(DOSE, { force: true });
o = plain(render({ theme: 'biohazard', bar: ['pomo'] }));
check('missing .dose still renders, no NaN', /POMO \d{2}:\d{2}/.test(o) && !/NaN/.test(o), o);

// corrupt .dose -> fallback, no crash
writeFileSync(DOSE, '{not json');
o = plain(render({ theme: 'biohazard', bar: ['pomo'] }));
check('corrupt .dose -> fallback, no crash', /POMO \d{2}:\d{2}/.test(o), o);
rmSync(DOSE, { force: true });

// ---- pomo chime: one chime per completed block ----
const POMOF = join(HOME, '.clawcoat', '.pomo');
const MARKER = join(HOME, '.clawcoat', 'chimed');
// the chime command writes a marker instead of beeping, so the suite stays silent
const CHIME_CFG = { theme: 'biohazard', bar: ['pomo'], pomoMins: 5,
  pomoChimeCmd: 'node -e "require(\'fs\').writeFileSync(process.env.CHIME_MARKER,\'x\')"' };
// a cold cmd+node spawn on Windows can take several seconds — poll generously
const chimed = async () => {
  for (let i = 0; i < 100; i++) {
    if (existsSync(MARKER)) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
};
// negative checks: give a would-be chime a moment to land, then assert silence
const quiet = async () => { await new Promise((r) => setTimeout(r, 1200)); return !existsSync(MARKER); };
process.env.CHIME_MARKER = MARKER;

// first paint of a sitting: records the block, no chime
rmSync(POMOF, { force: true }); rmSync(MARKER, { force: true });
let anchor = Date.now() - 2 * 60000;               // 2m into block 0
writeFileSync(DOSE, JSON.stringify({ start: anchor, last: Date.now() }));
render(CHIME_CFG);
check('first paint writes .pomo, block 0', existsSync(POMOF) && JSON.parse(readFileSync(POMOF, 'utf8')).block === 0, existsSync(POMOF) && readFileSync(POMOF, 'utf8'));
check('  and does not chime', await quiet(), 'marker exists');

// fresh rollover (boundary 30s ago, previous block on record) -> chime
rmSync(MARKER, { force: true });
anchor = Date.now() - (5 * 60000 + 30000);          // 30s into block 1
writeFileSync(DOSE, JSON.stringify({ start: anchor, last: Date.now() }));
writeFileSync(POMOF, JSON.stringify({ anchor, block: 0 }));
render(CHIME_CFG);
check('fresh rollover chimes', await chimed(), 'no marker within 10s');
check('  and advances .pomo to block 1', JSON.parse(readFileSync(POMOF, 'utf8')).block === 1, readFileSync(POMOF, 'utf8'));

// repaint in the same block -> no second chime
rmSync(MARKER, { force: true });
render(CHIME_CFG);
check('same block repaint does not re-chime', await quiet(), 'marker exists');

// stale rollover (boundary crossed 3m ago) -> state advances silently
rmSync(MARKER, { force: true });
anchor = Date.now() - (5 * 60000 + 3 * 60000);      // 3m into block 1
writeFileSync(DOSE, JSON.stringify({ start: anchor, last: Date.now() }));
writeFileSync(POMOF, JSON.stringify({ anchor, block: 0 }));
render(CHIME_CFG);
check('stale rollover stays silent', await quiet(), 'marker exists');
check('  but still advances .pomo', JSON.parse(readFileSync(POMOF, 'utf8')).block === 1, readFileSync(POMOF, 'utf8'));

// pomoChime: false -> chime machinery fully off, no state file
rmSync(POMOF, { force: true }); rmSync(MARKER, { force: true });
render({ ...CHIME_CFG, pomoChime: false });
check('pomoChime:false writes no state, no chime', !existsSync(POMOF) && !existsSync(MARKER));
rmSync(DOSE, { force: true });

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
