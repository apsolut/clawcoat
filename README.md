# ClawCoat — a live theming engine for Claude Code

> **Built on [clawgod](https://github.com/0Chencc/clawgod)** by 0Chencc, and licensed
> **GPL-3.0** because of it. ClawCoat keeps clawgod's binary fetch/extract/wrapper/repatch
> pipeline and throws the rest away. See [Attribution and license](#attribution-and-license).

A single `install.ps1` that recolors the official Claude Code UI (logo, window
border + title, section labels like *Tips for getting started* / *Recent
activity*, and the shimmer) — and then lets you **change the colors live, from a
JSON file or a `claude theme` command, without reinstalling.**

![How ClawCoat works: install.ps1 patches the bundle's static brand colours into
getter functions, which re-read ~/.clawcoat/clawcoat.json on every paint — so editing
the config retints the running UI without reinstalling.](docs/how-it-works.png)

## What it touches — and what it deliberately doesn't

It patches the Claude Code binary on your machine. Install does exactly three things:

- creates `~/.clawcoat/` (patched bundle, a clean backup, your config)
- repoints the `claude` launcher at the patched copy
- sets `statusLine` in `~/.claude/settings.json` (skipped if you already have one)

`.\install.ps1 -Uninstall` reverses all three. If a patch ever produces invalid JS on a
future Claude build, the wrapper restores the clean backup and boots Claude unthemed —
you can't brick `claude` with this.

**It is only a theming engine.** Every one of the 33 patches changes a colour, a glyph or
a label. ClawCoat does not:

- unlock features, remove restrictions, or alter what Claude Code is allowed to do
- disable any of your tools, or touch `permissions` in your settings
- route your session anywhere except Anthropic — no proxy, no alternate provider
- read your API keys, or any credential belonging to another tool
- hijack `claude update`, or phone home

Two inherited clawgod features that broke those rules — **"lean mode"** (wrote `disable*`
flags and `permissions.deny` entries into your global settings on every install) and the
**OpenAI/Grok provider proxy** — were removed. If you ran an older ClawCoat, the current
installer reverts those settings and deletes the leftover files for you.

## Prerequisites

Official **Claude Code** installed, plus **Node.js >= 18**, **Bun**, **ripgrep**.

## Install

```powershell
# use pwsh (7+), NOT powershell — Windows PowerShell 5.1 can't parse the script
cd <this folder>
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1                 # default: clawcoat (cornflower)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Theme yellow   # start on yellow (or violet)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall      # restore vanilla claude
```

## Live theming — the wow part

Once installed, no reinstall is ever needed to recolor:

```
claude theme                     # show current theme + animation
claude theme list                # clawcoat · yellow · violet · gruvbox · dracula
claude theme dracula             # switch palette (takes effect on next render)
claude theme animate rainbow     # animate the logo (8 modes, see below)
claude theme animate pulse 2     # optional speed multiplier
claude theme animate breathe 0.5 # slow breathing pulse
claude theme reset               # back to clawcoat, animation off
claude theme edit                # prints the JSON path so you can hand-edit colors
```

Everything reads from **`~/.clawcoat/clawcoat.json`**, re-read whenever the
file changes. Edit that file directly and the new colors apply on the next
screen paint — the logo pulses/recolors while Claude is working.

### How live reload works (and its honest limit)

Each brand color in Claude's binary is rewritten into a **getter** that calls a
theme engine at read time. If Claude reads the token per-render (spinner, active
logo), changes appear **live in the running session**. If a given screen reads a
token only once at startup, that spot updates on the next launch. Either way the
color is always correct — never broken.

### Rename the model in the header (`claude theme label`)

The welcome line ("Opus 5 (1M context) with … reasoning · Claude Max ·") builds
its **model-name** from Claude's `pae()` display function (`display_name +
" (1M context)"`), rendered as an Ink `<Text>`. This hooks `pae()` (and `dA()`,
used elsewhere) so the model name is whatever you want:

```
claude theme label "Mythos (5M context) preview"   # header model name -> your text
claude theme label                                  # show current
claude theme label off                              # restore the real model name
```

Optional scoping via `labelModel` in the JSON (e.g. `"labelModel": "opus"` only
relabels Opus models; the picker keeps real names for the rest).

**Honest limits:**
- It replaces the **model-name** portion. The trailing " with <effort> reasoning
  · <subscription> ·" is rendered as separate Ink siblings and still follows your
  text (so you'll see "Mythos (5M context) preview with … · Claude Max ·"). Because
  your label is longer, the reasoning part truncates harder. Dropping that tail is
  a further patch (the reasoning + subscription render sites).
- It's a **display relabel only** — the real model is unchanged; anyone reading
  your screen sees "Mythos" while it's actually Opus.
- `pae()`/`dA()` also feed the model picker and some prompts, so an unscoped label
  shows there too — use `labelModel` to scope, or leave it.

## Reactive logo — the logo as a live indicator (unique)

Normally a theme is a fixed color. `claude theme reactive <driver>` makes the
**logo + brand color a live readout of session state** — something no other
Claude client does. It composes with animation (the driver picks the base
color, the animation modulates it).

| driver    | the logo shows…                                                        |
|-----------|------------------------------------------------------------------------|
| `off`     | your normal palette color (default)                                    |
| `project` | a unique color hashed from the current repo path — every project gets its own stable accent, so you can tell at a glance which project's Claude you're in |
| `danger`  | flares **red** whenever you launched with `--dangerously-skip-permissions` (or bypass) — an always-on "you're armed" cue; normal color otherwise |
| `model`   | accent by the active model: Opus = gold, Sonnet = cyan, Haiku = green, Fable = magenta (reads `--model` / `ANTHROPIC_MODEL`) |
| `clock`   | circadian — warm & bright at midday, cool & dim at night              |
| `git`     | warns when you're on `main`/`master` (orange) or have an uncommitted dirty tree (amber); normal otherwise |
| `dose`    | amber once you've been at the desk past 75% of your limit, **red** past it — stand up (see *Dose meter* below) |

```
claude theme reactive project     # per-repo identity color
claude theme reactive danger      # red when running with skip-permissions
claude theme reactive model       # gold on Opus, cyan on Sonnet
claude theme reactive off         # back to a static palette
```

Drivers that don't apply right now (e.g. `danger` when not armed, `model` on an
unknown model, `git` outside a repo) simply fall back to your palette color, so
it's always safe. `git` reads the repo state with a 3-second cache to stay fast.

### Dose meter — stand up every hour (`☢`)

A widget part that reads out how long you've been at the desk, and a matching
reactive driver that turns the logo amber then red as you pass your limit.

```
claude theme widget dose,git,clock   # put ☢ on the header board
claude theme reactive dose           # logo flares as the dose climbs
claude theme dose                    # show current dose
claude theme dose reset              # you stood up — restart the clock
claude theme dose 45                 # change the limit (default 60m)
claude theme dose idle 15            # change the away-threshold (default 10m)
```

| board shows | when |
|-------------|------|
| `☢ 42m` | normal |
| `☢ 51m` + amber logo | past 75% of your limit |
| `☢ DOSE LIMIT` + red logo | past the limit, until you move |

**How it knows you stood up.** It doesn't — nothing inside a CLI can detect
presence. It *infers* it: the wrapper only paints while someone is actually
driving Claude, so a gap between paints longer than `doseIdleReset` (default
10 minutes) means you were away from the keyboard, and the clock restarts.

**Honest limits:**
- The reading updates **on the next paint**, not on a timer. Sit reading a long
  output for 90 minutes and the warning appears when you next interact — which is
  the first moment you could act on it anyway.
- A long unattended task with no renders reads as "away" and clears the clock. It
  fails toward **under-nagging**, deliberately.
- It's a footer readout and a color, never a popup — a modal in a terminal UI would
  wedge the render loop.
- State lives in `~/.clawcoat/.dose`, not `clawcoat.json` (writing per-paint into
  the main config would thrash the hot-reload cache). It's shared across concurrent
  sessions on purpose: the dose belongs to you, not to a terminal window.

The `umbrella-corp` preset turns this on by default.

### Animation modes

`claude theme animate <mode> [speed]` — the logo/brand color animates while
Claude renders (during a spinner it's continuous; idle screens update on the
next paint). Speed is an optional multiplier (e.g. `2` = twice as fast).

| mode      | look                                                        | theme-aware |
|-----------|-------------------------------------------------------------|-------------|
| `none`    | static palette color (default)                              | —           |
| `breathe` | gentle in/out lightness swell on your theme's hue           | yes         |
| `pulse`   | sharper heartbeat pulse on your theme's hue                 | yes         |
| `wave`    | hue drifts back and forth around your theme's color         | yes         |
| `rainbow` | full smooth hue cycle through the spectrum                  | no          |
| `neon`    | fast, high-saturation hue cycle                             | no          |
| `strobe`  | alternates bright/dim of your theme color (~2/sec)          | yes         |
| `fire`    | flickering red→orange→yellow                                | no          |
| `ocean`   | slow blue/teal/cyan drift                                   | no          |

Theme-aware modes derive from whatever palette you're on, so `breathe` on
`dracula` breathes purple, on `gruvbox` breathes gold. Turn it off with
`claude theme animate none`.

**Self-heal:** if a patch ever produces invalid JS on some future Claude build,
the wrapper catches it, restores the clean backup, and boots Claude unthemed
rather than failing. You can't brick `claude` with this.

## The palette — "color all things how we want"

Themes live in one place: the `palettes` block of `clawcoat.json` (seeded
from `_CLAW_BAKED` in the wrapper). Each theme has slots:

| slot                  | what it colors                                   |
|-----------------------|--------------------------------------------------|
| `clawd_body`          | the frog logo body                               |
| `claude`              | brand color (title, border, labels) — dark theme |
| `claudeLight`         | same, on the light terminal theme                |
| `claudeShimmer`       | the shimmer pulse (dark)                          |
| `claudeShimmerLight`  | shimmer on light theme                            |
| `briefLabelClaude`    | the *Tips / Recent activity* section labels      |
| `ansi`                | fallback for 16-color terminals (no truecolor)   |

Add your own theme: drop a new object into `palettes` in the JSON, then
`claude theme <yourname>`. Want the logo, border, and labels to be *different*
colors? They're `clawd_body`, `claude`, and `briefLabelClaude` — give each its
own value.

Built-in palettes: `clawcoat` (cornflower #6495ed), `yellow` (#facc15),
`violet` (#8b5cf6), `gruvbox`, `dracula`.

## Not yet included (needs a one-time binary read)

- **Spatial gradient** across the frog (per-row color) and **swapping the frog
  for a custom mascot** need the *logo-render* code in the extracted
  `cli.original.cjs`, which isn't in this repo. Temporal animation (8 modes:
  breathe/pulse/wave/rainbow/neon/strobe/fire/ocean) is shipped; spatial
  gradient + custom art are the next pass once we inspect the real logo renderer.

## Statusline — the persistent bottom bar

Separate from the header banner. Claude Code runs an external command and pipes it a
session JSON on stdin; the installer writes that script to `~/.clawcoat/statusline.js`
and points `statusLine` in `~/.claude/settings.json` at it.

```
Mythos (5M context) preview · high · ctx 12% · 5h 31% · main✳ · 02:08
```

It's a list of **parts** you choose:

```
claude theme bar                       # what's on it now + every available part
claude theme bar model,ctx,git,clock   # pick your own
claude theme bar default               # back to the layout above
```

| plain part | notes |
|------|-------|
| `model` | your `claude theme label` if set, else the real `display_name` |
| `effort` | reasoning effort level, when the session reports one |
| `ctx` | context window used — green, amber past 65%, red past 85% |
| `5h` | 5-hour plan usage — amber past 60%, red past 85% |
| `git` | branch, with a red `✳` when the tree is dirty |
| `cwd` | current directory name |
| `clock` | local `HH:MM` |

The accent colour is read from your live palette, so the bar re-themes with
everything else — including custom palettes you add yourself.

### THE HIVE — the same metrics in costume (`claude theme preset hive`)

```
█ UMBRELLA  HIVE·B7 │ CONTAIN ███████░░░  66% │ T-VIRUS 34% │ PWR 72% │ Mythos │ ⬤ SECURE │ 02:49 │ ◞
```

| costume part | actually |
|------|-------|
| `brand` | your `claude theme org`, uppercased, in palette colour |
| `contain` | `100 - context used`, as a draining meter |
| `tvirus` | context window used — rises as you talk |
| `pwr` | 5-hour reserve **remaining** (not consumed) |
| `status` | `SECURE` → `ELEVATED` → `BREACH`, derived from containment; only the breach alarm blinks |
| `sweep` | a scanner glyph that turns on every repaint |

None of it is decoration — every readout is a real session metric with a
different name, so the bar genuinely degrades over a long session. That is the
whole point: it's an honest gauge that happens to look like a bioweapons lab.

Mix the families freely — `claude theme bar brand,contain,git,clock` is fine.
`preset hive` also sets `barSep` to `│`; the default separator is `·`.

The `hive` preset deliberately sets no `label`, so it dresses the bar and the
chrome and leaves whatever model name you already chose alone.

```
.\install.ps1 -StatuslineOff    # unhook it (the flag survives re-installs)
.\install.ps1 -StatuslineOn     # put it back
```

If you already have your own `statusLine` configured, the installer detects it, leaves
it alone, and prints the command to wire ours up by hand instead.

> **Why this lives in the installer.** The bar is not part of the patched bundle — it
> is an external file plus a path in someone else's config. When a `statusLine` command
> cannot be executed, Claude Code paints an empty bar and reports nothing, so a stale
> path is invisible. The `apsolut-theme` → ClawCoat rename broke exactly that way. The
> installer now owns both links, and repairs a stale pointer on the next run.

## Upgrading from `apsolut-theme`

This project was called **apsolut-theme** before it was named ClawCoat. Everything
moved: the install dir, the config file, the launcher alias, and the default palette.

| was | is now |
|-----|--------|
| `~/.apsolut-theme/` | `~/.clawcoat/` |
| `apsolut-theme.json` | `clawcoat.json` |
| `apsolut` alias (`apsolut theme …`) | `clawcoat` (`clawcoat theme …`) |
| `apsolut` palette (cornflower) | `clawcoat` palette (same `#6495ed`) |
| `APSOLUT_THEME`, `APSOLUT_VERSION` | `CLAWCOAT_*` (the `*_LEAN_*` vars are gone with lean mode) |
| `statusLine` in `~/.claude/settings.json` | repointed at `~/.clawcoat/statusline.js` |

**You don't have to do any of it by hand.** Just re-run the installer — it detects
`~/.apsolut-theme`, moves the whole state dir to `~/.clawcoat`, renames the config,
rewrites `"theme": "apsolut"` to `"clawcoat"` inside it so your settings survive, and
deletes the stale `apsolut` alias:

```
→ found legacy ~/.apsolut-theme
→ migrating to ~/.clawcoat
→ config migrated → clawcoat.json (palette 'apsolut' → 'clawcoat')
→ removed stale 'apsolut' alias (use 'clawcoat' now)
```

If both `~/.apsolut-theme` and `~/.clawcoat` somehow exist, the installer keeps its
hands off the legacy dir and uses `~/.clawcoat` — delete the old one yourself once
you've confirmed everything works.

## Notes

- Installs into the dedicated `~/.clawcoat` dir (separate from any clawgod install); installing
  it repoints the `claude` launcher (reversible with `-Uninstall`).
- Windows-only (`install.sh` for macOS/Linux is not included here).
- `claude update` is **not** hijacked; re-run the script after Claude updates.

## Repo layout

The installer is the product: `install.ps1` is a single self-contained script that
carries the wrapper, the patcher, and the statusline as embedded here-strings.

| path | what |
|------|------|
| `install.ps1` | **source of truth** — everything ships from here; carries its own GPL-3 notice |
| `LICENSE` | GPL-3.0, inherited from clawgod — see *Attribution and license* |
| `tools/prettify.sh` | Biome unminify recipe: turns Claude's bundle into readable JS |
| `tools/doctor.sh` | health check for an existing install |
| `tools/extract-herestring.mjs` | pulls an embedded script out of `install.ps1` so it can be tested as-written |
| `tools/test-statusline-*.mjs` | regression suites for the statusline + its settings wiring |
| `CONTRIBUTING.md` | the here-string rule, the checks to run, and the rules that exist because something broke |
| `docs/how-it-works.png` | the diagram at the top of this README |

`tools/cli.pretty.js` and `tools/system-prompts-*/` are **not tracked**: both are
derived from Anthropic's `cli` binary and regenerable with `tools/prettify.sh`.

### Running the tests

No setup — each suite extracts what it needs from `install.ps1` into a temp dir,
so it tests the text that actually ships and leaves nothing behind.

```bash
for t in tools/test-*.mjs; do node "$t" || break; done
```

| suite | covers |
|---|---|
| `test-statusline-bar.mjs` | the bar's part system, thresholds, missing-metric degradation |
| `test-statusline-wiring.mjs` | `settings.json` wiring, stale-path repair, refusing to clobber |
| `test-uninstall-lean-revert.mjs` | the lean-mode revert: cleans up what old versions wrote, never clobbers a corrupt settings.json |
| `test-patcher-backup.mjs` | the clean backup tracks the installed version |

## Health checks

`sh tools/doctor.sh` dry-runs the patcher against your installed bundle and reports
which hooks still match — run it after a Claude Code update to spot drift. When a hook
drifts, `sh tools/prettify.sh` unminifies the bundle so you can find the new shape.

Patterns anchor on **distinctive content**, never on minified identifiers: those are
regenerated every release. `hmc=!q.IS_DEMO` silently stopped matching in 2.1.240 and
took the whole header widget with it; the pattern now captures those names instead.

## Attribution and license

ClawCoat is a derivative work of **[clawgod](https://github.com/0Chencc/clawgod)**
by 0Chencc and the clawgod contributors, which is licensed **GPL-3.0**. ClawCoat is
therefore also **GPL-3.0** — see [`LICENSE`](LICENSE). That covers the whole work,
including the parts written for ClawCoat.

**Retained from clawgod:** the binary fetch / extract / wrapper / repatch pipeline —
pulling the platform tarball from npm, extracting `cli.js` and the native modules from
the Bun binary, running the patched bundle under a wrapper, and re-patching on version
drift. It is the load-bearing half of `install.ps1`.

**Changed in ClawCoat (2026):**

- The patch set was reduced to one plumbing patch plus brand-token **getter injection**.
  None of clawgod's feature-unlock or restriction-removal patches are carried over.
- **Removed clawgod's OpenAI-compatible provider proxy** — an Anthropic↔OpenAI translating
  server that routed sessions to Grok or any OpenAI endpoint, read an API key from
  `~/.grok/user-settings.json`, and set `CLAUDE_CODE_ATTRIBUTION_HEADER=0`.
- **Removed clawgod's "lean mode"** — it wrote four `disable*` flags and up to thirteen
  `permissions.deny` entries into the user's global `~/.claude/settings.json` on every
  install. Install now *reverts* those edits instead, for anyone upgrading.
- Added the live theme engine: palettes, 8 animation modes, reactive drivers, the dose
  meter, the header widget, the `claude theme` command surface and the model relabel hook.
- Added the statusline (`~/.clawcoat/statusline.js`) and its `settings.json` wiring.

The same notice and change summary are at the top of `install.ps1`, which matters because
that file is distributed on its own — detached from this README — whenever someone installs
via a one-liner.

**Not covered by this license:** Claude Code itself. ClawCoat patches a copy of Anthropic's
binary on your own machine and redistributes none of it. `tools/cli.pretty.js` and
`tools/system-prompts-*/` are derived from that binary and are deliberately untracked.
