# Contributing to ClawCoat

ClawCoat is GPL-3.0 (see [`LICENSE`](LICENSE) and the *Attribution and license*
section of the README). By contributing you agree your changes ship under it.

**Stack:** PowerShell 7 (`install.ps1`), JavaScript embedded inside it as
here-strings, Node >= 18 for the tests. Windows-only. Requires Bun and ripgrep.

## The one thing to know

`install.ps1` is the **single source of truth**. The Bun wrapper, the Node patcher,
the statusline and three settings-mutation helpers do not exist as separate source
files — they are PowerShell here-strings inside it:

| variable | becomes |
|---|---|
| `$wrapperCode` | `~/.clawcoat/cli.cjs` — the theme engine, runs under Bun |
| `$patcherCode` | the patch engine that rewrites brand tokens into getters |
| `$StatuslineSource` | `~/.clawcoat/statusline.js` |
| `$slWireScript`, `$SlUnhookScript`, `$LeanUndoScript` | `settings.json` mutations |

**Editing `~/.clawcoat/` is a deployment, not a fix.** The next install silently
reverts it. Change the here-string, then redeploy.

Test embedded scripts **as-written by extracting them**, never by retyping a copy —
`tools/extract-herestring.mjs` exists for exactly this, and both suites self-extract.

## Before you open a PR

```bash
# 1. parse-check the installer (always, after any edit)
pwsh -NoProfile -Command '$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "./install.ps1").Path,[ref]$t,[ref]$e)|Out-Null; if($e){$e|%{$_.Message}}else{"PARSE OK"}'

# 2. syntax-check every embedded script
for v in wrapperCode patcherCode StatuslineSource; do
  node tools/extract-herestring.mjs install.ps1 $v /tmp/$v.js && node --check /tmp/$v.js
done

# 3. run the suites (no setup — each extracts what it needs into a temp dir)
for t in tools/test-*.mjs; do node "$t" || break; done

# 4. are the patch hooks still matching the current bundle?
sh tools/doctor.sh
```

`install.ps1` is **CRLF with a UTF-8 BOM**. Several editors and tools silently
normalise it to LF, which turns a three-line change into a 3,000-line diff. Check
before you commit:

```bash
node -e 'const s=require("fs").readFileSync("install.ps1","utf8");console.log("CRLF:",(s.match(/\r\n/g)||[]).length,"bareLF:",(s.match(/(?<!\r)\n/g)||[]).length,"BOM:",s.charCodeAt(0)===0xFEFF)'
```

## Rules that exist because something broke

- **Anchor patch regexes on distinctive content, never on minified identifiers.**
  Those are regenerated every Claude Code release. `hmc=!q.IS_DEMO` silently stopped
  matching in 2.1.240 and took the entire header widget with it. When a hook drifts,
  `sh tools/prettify.sh` unminifies the bundle so you can find the new shape.
- **Anything that writes `~/.claude/settings.json` must distinguish "missing" from
  "unparseable".** Missing → start from `{}`. Present but unparseable → bail and warn.
  Writing over it destroys the user's permissions, hooks, env vars and model pin
  because of one trailing comma. Every writer follows this; keep it that way.
- **On any corrupt/hostile-input path, assert on what SURVIVES** — the file bytes
  unchanged — never merely on the return value. A test once asserted a data-loss bug
  as correct behaviour, which is why that bug shipped.
- **Don't add `unique: true` to a patch without dry-running it.** Several patches
  legitimately match 2–4 times (light/dark variants); `unique` turns those into hard
  failures.
- **The bundle uses `using` declarations** (TC39 explicit resource management).
  **Bun parses them; Node does not.** Any syntax check against `cli.original.cjs` must
  run under Bun — `node --check` is a false negative that would block every install.
- **`$ErrorActionPreference = "Stop"` is script-wide**, so `& node … 2>&1` dies on the
  first byte Node writes to stderr. Use the `Invoke-Native` helper; never call
  node/bun bare.
- **Embedded helpers run as `node -e <src> <args>`**, which makes `argv[1]` the first
  user arg, not a script path. Test them the same way or you exercise a different argv
  shape than production.

## Running the installer is not a dry run

`pwsh ./install.ps1` downloads ~100MB and rewrites `~/.clawcoat` and your `claude`
launcher. It is not a way to "check" a change. Test the logic in isolation; use
`tools/doctor.sh` to inspect an existing install.

## Not tracked

`tools/cli.pretty.js` and `tools/system-prompts-*/` are derived from Anthropic's `cli`
binary. They are regenerable with `tools/prettify.sh`, git history is permanent, and
none of it is ours to redistribute. Keep them out.

Linter handles code style — don't hand-enforce it in review.
