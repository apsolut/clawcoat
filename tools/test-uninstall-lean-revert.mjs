// Tests for $LeanUndoScript — the revert of the global-settings mutations that
// older ClawCoat versions applied as "lean mode".
//
// Lean mode is REMOVED. There is no apply path any more, which is exactly why
// this suite still matters: anyone who ran an older ClawCoat still carries those
// edits, so both `-Uninstall` and every fresh install run the undo. The fixture
// below is a settings.json as an old install would have left it.
//
//   node tools/test-uninstall-lean-revert.mjs
import { writeFileSync, readFileSync, rmSync } from 'fs';
import { execFileSync } from 'child_process';
import { join } from 'path';
import { extractTo } from './extract-herestring.mjs';

const SCRATCH = extractTo(['LeanUndoScript']);
// Teardown on exit, not at the end of the file: an assertion that throws would
// otherwise skip cleanup and leak a temp dir on every failing run.
process.on('exit', () => { try { rmSync(SCRATCH, { recursive: true, force: true }); } catch {} });
const NODE = process.execPath;
const P = join(SCRATCH, 'settings.json');

let pass = 0, fail = 0;
const check = (n, c, d) => {
  if (c) { pass++; console.log(`  ok   ${n}`); }
  else { fail++; console.log(`  FAIL ${n}${d !== undefined ? ` — ${JSON.stringify(d)}` : ''}`); }
};
const undo = () =>
  execFileSync(NODE, ['-e', readFileSync(join(SCRATCH, 'LeanUndoScript.js'), 'utf8'), P], { encoding: 'utf8' }).trim();
const read = () => JSON.parse(readFileSync(P, 'utf8'));
const seed = (o) => writeFileSync(P, JSON.stringify(o, null, 2) + '\n');

console.log('\nlean revert (removed feature, migration path)\n');

// A realistic user config that must survive untouched.
const USER = {
  model: 'claude-opus-5',
  env: { FOO: 'bar' },
  hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 'x' }] }] },
  permissions: { allow: ['Bash(npm:*)', 'Read'], deny: ['MyOwnDenial'] },
};

const BASE_DENY = ['DesignSync', 'NotebookEdit', 'PushNotification', 'RemoteTrigger', 'CronCreate', 'CronDelete', 'CronList'];
const MAX_DENY = ['EnterPlanMode', 'ExitPlanMode', 'SendMessage', 'ScheduleWakeup', 'AskUserQuestion', 'ReportFindings'];

// settings.json exactly as an older ClawCoat ("lean on") would have left it
const leaned = (max) => ({
  ...USER,
  disableWorkflows: true,
  disableRemoteControl: true,
  disableClaudeAiConnectors: true,
  disableArtifact: true,
  ...(max ? { disableBundledSkills: true } : {}),
  permissions: { ...USER.permissions, deny: [...USER.permissions.deny, ...BASE_DENY, ...(max ? MAX_DENY : [])] },
});

seed(leaned(false));
check('undo reports lean-reverted', undo() === 'lean-reverted');
const after = read();
check('  disable* flags all gone', !['disableWorkflows', 'disableRemoteControl', 'disableClaudeAiConnectors', 'disableArtifact', 'disableBundledSkills'].some((k) => k in after));
check('  our deny entries gone', !after.permissions.deny.some((d) => d !== 'MyOwnDenial'), after.permissions.deny);
check("  the user's own deny survives", after.permissions.deny.includes('MyOwnDenial'));
check('  model / env / hooks / allow untouched',
  after.model === USER.model && after.env.FOO === 'bar' &&
  after.hooks.SessionStart.length === 1 && after.permissions.allow.length === 2, after);

// a "lean max" install left more behind; undo must clear those too
seed(leaned(true));
check('undo clears max-mode additions too',
  undo() === 'lean-reverted' &&
  !('disableBundledSkills' in read()) && !read().permissions.deny.includes('AskUserQuestion'));

// idempotent, and silent when there is nothing to do — this is the common case
// now, since fresh installs never write these in the first place
seed(USER);
check('undo on a never-leaned config is a no-op', undo() === '');
check('  file still intact', read().model === 'claude-opus-5');
check('  running twice stays a no-op', undo() === '' && read().permissions.deny.length === 1);

// never clobber what we cannot parse (the bug this whole pass came from)
const CORRUPT = '{ "permissions": { "allow": ["Bash"] },\n}';
writeFileSync(P, CORRUPT);
check('corrupt settings -> reports unparseable', undo() === 'unparseable');
check('  file byte-for-byte untouched', readFileSync(P, 'utf8') === CORRUPT);

// a missing settings.json is not an error
rmSync(P, { force: true });
check('missing settings -> silent no-op', undo() === '');

console.log(`\n  ${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
