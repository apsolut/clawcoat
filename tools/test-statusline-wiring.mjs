// Functional tests for the statusline settings.json wiring.
//
//   node tools/test-statusline-wiring.mjs
//
// Extracts the helpers straight out of install.ps1 into a temp dir, so they are
// tested as they ship and nothing is written next to the repo.
import { writeFileSync, readFileSync, rmSync } from 'fs';
import { execFileSync } from 'child_process';
import { join } from 'path';
import { extractTo } from './extract-herestring.mjs';

const SCRATCH = extractTo(['slWireScript', 'SlUnhookScript']);
// Teardown on exit, not at the end of the file: an assertion that throws would
// otherwise skip cleanup and leak a temp dir on every failing run.
process.on('exit', () => { try { rmSync(SCRATCH, { recursive: true, force: true }); } catch {} });

const NODE = process.execPath;
const SCRIPT = 'C:\\Users\\testuser\\.clawcoat\\statusline.js';
// Derived, not hardcoded — the wiring writes forward-slash paths, and the test
// must not assume any particular machine's node location.
const fwd = (s) => s.replace(/\\/g, '/');
const WANT = `"${fwd(NODE)}" "${fwd(SCRIPT)}"`;
const P = join(SCRATCH, 't-settings.json');

let pass = 0, fail = 0;
const check = (name, cond, detail) => {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`); }
};

// install.ps1 runs these as `node -e <source> <args>`, which makes argv[1] the
// first user arg rather than a script path. Invoke the same way or the tests
// exercise a different argv shape than production does.
function run(script, ...args) {
  const src = readFileSync(join(SCRATCH, script), 'utf8');
  return execFileSync(NODE, ['-e', src, P, ...args], { encoding: 'utf8' }).trim();
}
const wire = () => run('slWireScript.js', NODE, SCRIPT);
const read = () => JSON.parse(readFileSync(P, 'utf8'));
const seed = (o) => writeFileSync(P, JSON.stringify(o, null, 2) + '\n');

console.log('\nstatusline wiring\n');

// 1. empty settings -> claims the slot
seed({ foo: 1 });
check('empty settings -> wired', wire() === 'wired');
check('  command is correct', read().statusLine.command === WANT, read().statusLine?.command);
check('  type is command', read().statusLine.type === 'command');
check('  unrelated keys survive', read().foo === 1);

// 2. idempotent
check('re-run -> ok (no rewrite)', wire() === 'ok');

// 3. stale but same-dir (node moved) -> repaired
seed({ statusLine: { type: 'command', command: '"C:/old/node.exe" "C:/Users/testuser/.clawcoat/statusline.js"' } });
check('stale node path -> repaired', wire() === 'repaired');
check('  node path updated', read().statusLine.command === WANT);

// 4. a hand-rolled statusline is never stolen
const foreign = { type: 'command', command: 'starship prompt' };
seed({ statusLine: { ...foreign } });
check('foreign statusLine -> foreign', wire() === 'foreign');
check('  left untouched', read().statusLine.command === 'starship prompt');

// 5. backslash paths escape correctly through JSON.stringify
seed({});
const bsNode = 'C:\\Program Files\\nodejs\\node.exe';
const out = run('slWireScript.js', bsNode, SCRIPT);
check('backslash + space path -> wired', out === 'wired');
check('  round-trips as valid JSON', (() => { try { read(); return true; } catch { return false; } })());
check('  no raw backslashes in command', !read().statusLine.command.includes('\\'), read().statusLine?.command);

// 6. An unparseable settings.json must be LEFT ALONE. Writing over it would
//    destroy every permission / hook / env var / model pin the user has, because
//    of one trailing comma. This test previously asserted the opposite and locked
//    the data-loss in; caught in review.
const CORRUPT = '{\n  "permissions": { "allow": ["Bash(npm:*)"] },\n  "model": "claude-opus-5",\n}';
writeFileSync(P, CORRUPT);
check('corrupt settings -> reports unparseable', wire() === 'unparseable');
check('  file is byte-for-byte untouched', readFileSync(P, 'utf8') === CORRUPT);

// an absent file is still fine to create
rmSync(P, { force: true });
check('absent settings -> wired from scratch', wire() === 'wired');
check('  created valid JSON', read().statusLine.command === WANT);

// an empty file is treated as absent, not as corruption
writeFileSync(P, '   ');
check('empty settings -> wired', wire() === 'wired');

// 7. unhook (used by -StatuslineOff) removes ours
seed({ keep: true }); wire();
run('SlUnhookScript.js');
check('unhook removes our statusLine', read().statusLine === undefined);
check('  other keys survive', read().keep === true);

// 8. unhook leaves a foreign bar alone
seed({ statusLine: { ...foreign } });
run('SlUnhookScript.js');
check('unhook spares foreign statusLine', read().statusLine?.command === 'starship prompt');

// 9. the same script backs -Uninstall, and reports what it did
seed({}); wire();
check('uninstall remover reports unhooked', run('SlUnhookScript.js') === 'unhooked');
check('  statusLine gone', read().statusLine === undefined);
seed({ statusLine: { ...foreign } });
check('unhook silent on foreign', run('SlUnhookScript.js') === '');
check('  foreign survives uninstall', read().statusLine?.command === 'starship prompt');

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
