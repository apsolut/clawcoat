# What you can re-skin — the ClawCoat anatomy

Every part of the Claude Code screen that ClawCoat can touch, named the way you'd
point at it ("the banner", "the bottom bar"), then mapped to its command and its
key in `~/.clawcoat/clawcoat.json`. Everything applies **live** — edit or run the
command, the next repaint picks it up. No reinstall, no restart (voice: next turn).

## The screen, labeled

```text
┌────────────────────────────────────────────────────────────┐
│   ▄█████▄    Claude Code v2.x                              │ ← ① Banner logo
│  █████████   Umbrella Corporation                          │ ← ② Org line
│      █       Mythos (5M context) preview                   │ ← ③ Model label
│                                                            │
│   14:02 · main* · ~/project · dose 37m                     │ ← ④ Header board
├────────────────────────────────────────────────────────────┤
│  > make the tests pass                                     │
│    …transcript…                                            │
│  ⠹ Mutating… (esc to interrupt)                            │ ← ⑤ Spinner
│                                                            │
│  ☣ ▌                                                       │ ← ⑥ Prompt glyph
├────────────────────────────────────────────────────────────┤
│  Opus 5 │ ctx 42% │ 5h ▰▰▱ │ main* │ 14:02                 │ ← ⑦ Bottom bar
└────────────────────────────────────────────────────────────┘
    ⑧ Brand color — tints ①–⑦ everywhere Claude paints its accent
    ⑨ Background — the wash behind it all
    ⑩ Voice — changes how Claude *talks*, not how it looks
```

## The map

| # | You'd call it | Command (`claude theme …`) | JSON key | Values |
|---|---|---|---|---|
| ① | **Banner logo** — the art in the launch box | `logo umbrella\|skull\|ap\|frog` | `logo` | `frog` = the default art; `off` resets |
| ② | **Org line** — company name in the banner | `org "Umbrella Corporation"` | `org` | any text, `off` |
| ③ | **Model label** — the model name shown | `label "Mythos (5M context)"` | `label`, `labelModel` | any text; `labelModel` limits the rename to models matching it; `off` restores the real name |
| ④ | **Header board** — info row under the banner | `widget clock,git,cwd,date,dose` | `widget` | any mix of `clock` `git` `cwd` `date` `dose`; `off` |
| ⑤ | **Spinner** — the "Thinking…" line | `spinner umbrella\|cyber\|chaos` (words) · `spin dots\|line\|arc\|…` (glyph) | `spinner`, `spin` | word packs: `umbrella` (Containing…, Mutating…), `cyber` (Decrypting…, Jacking-in…), `chaos` (Yeeting…, Manifesting…); glyphs: `dots` `dots2` `dots3` `dots8` `line` `arc` `star2` `circleHalves` `circleQuarters` `toggle` `toggle4` `pipe` `sand` `layer` |
| ⑥ | **Prompt glyph** — the symbol before your cursor | `prompt ☣` | `prompt` | any glyph, `off` |
| ⑦ | **Bottom bar** — the statusline (footer) | `bar model,effort,ctx,5h,git,clock` | `bar`, `barSep` | parts: `model` `effort` `ctx` `5h` `git` `cwd` `clock` `pomo` `brand` `status` `sweep` + hive readouts `contain` `tvirus` `pwr`; `pomo` is a repeating pomodoro countdown (`pomoMins`, default 30); `barSep` sets the divider character; `barLabels` renames any part's label (`{"contain":"CNTX"}`, `""` hides it) |
| ⑧ | **Brand color** — the accent everywhere | `theme clawcoat\|yellow\|violet\|gruvbox\|dracula\|biohazard\|neon` | `theme`, `palettes` | plus motion: `animate none\|breathe\|pulse\|wave\|rainbow\|neon\|strobe\|fire\|ocean [speed]` (`animate`, `speed`) and auto-color: `reactive off\|project\|clock\|danger\|model\|git\|dose` (`reactive`) |
| ⑨ | **Background** | `bg 0c0c0c` | `bg` | hex, `off` |
| ⑩ | **Voice** — Claude's persona (tone only) | `voice umbrella\|noir\|pirate\|butler\|hacker\|zen` or `voice "your own persona"` | `voice` | tone-guarded: flavors phrasing, never judgment or safety; applies from the next turn |

Extras that aren't on the screen map:

| You'd call it | Command | JSON keys | What it does |
|---|---|---|---|
| **Dose meter** | `dose` · `dose reset` · `dose <minutes>` | `doseLimit`, `doseIdleReset` | time-at-desk counter for the ④/⑦ `dose` part; warns at 75%, nags past the limit; being away `doseIdleReset` min clears it |
| **Presets** — one command, whole outfit | `preset umbrella-corp\|hive\|cyberpunk\|vaporwave\|ghibli\|party` · `preset save <name>` · `preset <name> --keep-color` | `userPresets` | a preset sets several of the keys above at once; `save` snapshots your current look; `--keep-color` applies everything but ⑧ |
| **Panic button** | `theme reset` | — | back to stock ClawCoat: default palette, everything else off |

### What each built-in preset sets

| preset | the outfit |
|---|---|
| `umbrella-corp` | biohazard palette · skull logo · label "Mythos (5M context) preview" · org "Umbrella Corporation" · umbrella spinner · pulse animation · reactive `dose` · ☣ prompt · widget `dose,clock` · umbrella voice |
| `hive` | biohazard palette · umbrella logo · org "Umbrella  Hive·B7" · umbrella spinner · pulse · ☣ prompt · umbrella voice · widget `clock` · bar `brand,contain,tvirus,pwr,model,status,clock,sweep` with `│` separator — sets no label on purpose |
| `cyberpunk` | neon palette · frog logo · cyber spinner · neon animation ×1.5 |
| `vaporwave` | violet palette · frog logo · chaos spinner · wave animation ×0.8 |
| `ghibli` | clawcoat palette · frog logo · breathe animation ×0.7 |
| `party` | neon palette · skull logo · chaos spinner · rainbow ×3 · ✨ prompt · widget `clock` |

A preset clears the surfaces it dresses before applying, so switching presets
never leaves half an old outfit behind; `preset save <name>` snapshots your
current config as a new one.

## The file itself

`~/.clawcoat/clawcoat.json` — every command above is just an edit to this file,
and editing it by hand (`claude theme edit`) works just as well:

```jsonc
{
  "theme": "biohazard",            // ⑧ which palette (see "palettes" to add your own)
  "animate": "pulse",              // ⑧ motion mode
  "speed": 1,                      // ⑧ motion speed multiplier
  "reactive": "dose",              // ⑧ auto-color driver (overrides theme when active)
  "bg": "#0c0c0c",                 // ⑨ background
  "logo": "skull",                 // ① banner art
  "org": "Umbrella Corporation",   // ② org line
  "label": "Mythos (5M context)",  // ③ shown model name…
  "labelModel": "opus",            // ③ …but only for models matching this
  "widget": ["dose", "clock"],     // ④ header board parts, in order
  "spinner": "umbrella",           // ⑤ thinking words
  "spin": "dots2",                 // ⑤ thinking glyph
  "prompt": "☣",                   // ⑥ prompt glyph
  "bar": ["brand", "contain", "tvirus", "pwr", "model", "status", "clock", "sweep"],
  "barSep": "│",                   // ⑦ bottom bar parts + divider
  "barLabels": {"contain":"CNTX"}, // ⑦ rename a part's label; "" hides it, value stays
  "voice": "umbrella",             // ⑩ persona (preset name or your own text)
  "doseLimit": 60,                 // dose: minutes before the ☢ nag
  "doseIdleReset": 10,             // dose: minutes away that reset the clock (pomo uses it too)
  "pomoMins": 30,                  // ⑦ pomo part: countdown block length in minutes
  "pomoChime": true,               // ⑦ two rising beeps when a block completes (default on)
  "pomoChimeCmd": ""               // ⑦ optional: replace the beep with any shell command

}
```

Delete a key to return that surface to default. A malformed file never breaks
anything — the engine falls back to the baked-in defaults until it parses again.

`claude theme` with no arguments prints the current state of all of this;
`claude theme list` shows the palettes.
