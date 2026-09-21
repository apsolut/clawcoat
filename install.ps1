#Requires -Version 7.0

# ClawCoat - live theming engine for Claude Code
# Copyright (C) 2026 apsolut
#
# Derived from clawgod (https://github.com/0Chencc/clawgod),
# Copyright (C) 0Chencc and the clawgod contributors.
#
# Changes from clawgod, 2026:
#   - Patch set reduced to one plumbing patch plus brand-token getter
#     injection. None of clawgod's feature-unlock or restriction-removal
#     patches are included.
#   - Removed clawgod's OpenAI-compatible provider proxy (Grok / any
#     OpenAI endpoint, ~/.grok key read, attribution-header suppression).
#   - Removed clawgod's "lean mode", which wrote disable* flags and
#     permissions.deny entries into the user's global settings.json on
#     every install. Install now reverts those edits instead.
#   - Added a live theme engine (palettes, animation, reactive drivers),
#     a statusline, a header widget and a model relabel hook.
#   - Retained from clawgod: the binary fetch / extract / wrapper /
#     repatch pipeline.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <https://www.gnu.org/licenses/>.

<#
.SYNOPSIS
    ClawCoat installer for Windows (colors-only Claude Code patch)
.DESCRIPTION
    Downloads Claude Code from npm, rewrites its brand colour tokens into
    getters backed by a live theme engine, and replaces the 'claude'
    command with the patched version. Colours only - no feature-unlock or
    restriction-removal patches. Reversible with -Uninstall.
.EXAMPLE
    pwsh -File .\install.ps1
    # or
    .\install.ps1
    .\install.ps1 -Version 2.1.89
    .\install.ps1 -NoUpgrade
    .\install.ps1 -Uninstall
#>
param(
    [string]$Version = "latest",
    [string]$Theme = "clawcoat",
    [switch]$NoUpgrade,
    [switch]$Uninstall,
    [switch]$StatuslineOff,
    [switch]$StatuslineOn
)

$ErrorActionPreference = "Stop"

if ($env:CLAWCOAT_VERSION -and $Version -eq "latest") { $Version = $env:CLAWCOAT_VERSION }
if ($env:CLAWCOAT_THEME) { $Theme = $env:CLAWCOAT_THEME }

# Validated by hand, NOT with [ValidateSet] on the param: that attribute stays
# attached to the variable, so the env-var assignment above would re-trigger it and
# die before any output. The set must also match the palettes actually shipped in
# _CLAW_BAKED.palettes — the old three-item list rejected gruvbox/dracula/biohazard/neon.
$ClawPalettes = [ordered]@{
    clawcoat  = "#6495ed"
    yellow    = "#facc15"
    violet    = "#8b5cf6"
    gruvbox   = "#d79921"
    dracula   = "#bd93f9"
    biohazard = "#ce2a2a"
    neon      = "#00e5b1"
}
if (-not $ClawPalettes.Contains($Theme)) {
    # Write-* helpers are defined further down; this runs before them.
    Write-Host "  x Unknown theme '$Theme'. Available: $($ClawPalettes.Keys -join ', ')" -ForegroundColor Red
    exit 1
}
$ClawHex = $ClawPalettes[$Theme]
if ($env:CLAWCOAT_NO_UPGRADE -eq "1") { $NoUpgrade = [switch]$true }
if ($env:CLAWCOAT_STATUSLINE_OFF -eq "1") { $StatuslineOff = [switch]$true }
if ($env:CLAWCOAT_STATUSLINE_ON -eq "1")  { $StatuslineOn  = [switch]$true }

$ClawDir = Join-Path $env:USERPROFILE ".clawcoat"   # dedicated clawcoat install dir
$BinDir  = Join-Path $env:USERPROFILE ".local\bin"
$ClawSelfVersion = "0.0.0-dev"  # injected by release workflow from git tag

# ─── Colors ───────────────────────────────────────────

function Write-OK($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }
function Write-Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Dim($msg)  { Write-Host "  $msg" -ForegroundColor DarkGray }

# Under `2>&1`, native stderr arrives as ErrorRecord objects — and with the
# script-wide $ErrorActionPreference='Stop' above, the FIRST byte Node writes to
# stderr terminates the whole install. A DEP0040 punycode warning (near-universal
# on recent Node) or a corporate NODE_OPTIONS is enough, and it happens after
# files have already been removed from $ClawDir, leaving a half-install. Run every
# native command through here so the preference is localized.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Body } finally { $ErrorActionPreference = $prev }
}

Write-Host ""
Write-Host "  ClawCoat installer" -ForegroundColor White -NoNewline
Write-Host " (Windows)" -ForegroundColor DarkGray
Write-Host ""

# ─── Legacy migration (apsolut-theme → ClawCoat) ──────
#
# Pre-rename builds installed to ~/.apsolut-theme with config apsolut-theme.json
# and an 'apsolut' launcher alias. Move the whole state dir across, rename the
# config + version marker, and rewrite the palette name inside the JSON so the
# user keeps their theme/animation/reactive settings. Runs before -Uninstall so
# uninstalling a legacy install also works.
#
# Pure PowerShell on purpose — this runs before the Node prerequisite check.

$LegacyDir  = Join-Path $env:USERPROFILE ".apsolut-theme"
$LegacyAlias = Join-Path $BinDir "apsolut.cmd"

if (Test-Path -LiteralPath $LegacyDir) {
    if (Test-Path -LiteralPath $ClawDir) {
        Write-Warn "Both ~/.apsolut-theme and ~/.clawcoat exist — leaving the legacy dir alone."
        Write-Dim  "Using ~/.clawcoat. Delete ~/.apsolut-theme by hand once you're happy."
    } else {
        Write-Dim "Found legacy install at ~/.apsolut-theme"
        try {
            Move-Item -Force -LiteralPath $LegacyDir -Destination $ClawDir
            Write-OK "Migrated ~/.apsolut-theme → ~/.clawcoat"
        } catch {
            Write-Err "Could not move ~/.apsolut-theme → ~/.clawcoat: $($_.Exception.Message)"
            Write-Dim "Close any running 'claude' session and re-run this script."
            exit 1
        }

        # config: apsolut-theme.json → clawcoat.json (keep the user's settings)
        $legacyCfg = Join-Path $ClawDir "apsolut-theme.json"
        $newCfg    = Join-Path $ClawDir "clawcoat.json"
        if (Test-Path -LiteralPath $legacyCfg) {
            if (Test-Path -LiteralPath $newCfg) {
                Remove-Item -Force -LiteralPath $legacyCfg
            } else {
                Move-Item -Force -LiteralPath $legacyCfg -Destination $newCfg
                # the default palette was renamed apsolut → clawcoat; carry the selection over
                try {
                    $raw = Get-Content -Raw -Encoding UTF8 $newCfg
                    $fixed = $raw -replace '("theme"\s*:\s*)"apsolut"', '$1"clawcoat"'
                    $fixed = $fixed -replace '("apsolut"\s*:\s*\{)', '"clawcoat": {'
                    if ($fixed -ne $raw) {
                        Set-Content -Encoding UTF8 -NoNewline $newCfg $fixed
                        Write-OK "Config migrated → clawcoat.json (palette 'apsolut' → 'clawcoat')"
                    } else {
                        Write-OK "Config migrated → clawcoat.json"
                    }
                } catch {
                    Write-Warn "Config moved but could not be rewritten: $($_.Exception.Message)"
                    Write-Dim  "If your theme looks wrong, run: claude theme clawcoat"
                }
            }
        }

        # version marker: .apsolut-version → .clawcoat-version
        $legacyVer = Join-Path $ClawDir ".apsolut-version"
        $newVer    = Join-Path $ClawDir ".clawcoat-version"
        if (Test-Path -LiteralPath $legacyVer) {
            if (Test-Path -LiteralPath $newVer) { Remove-Item -Force -LiteralPath $legacyVer }
            else { Move-Item -Force -LiteralPath $legacyVer -Destination $newVer }
        }
    }
}

# stale 'apsolut' alias — the launcher is 'clawcoat' now
if (Test-Path -LiteralPath $LegacyAlias) {
    Remove-Item -Force -LiteralPath $LegacyAlias
    Write-OK "Removed stale 'apsolut' alias (use 'clawcoat' now)"
}

# Shared by -Uninstall and -StatuslineOff. Defined once, ahead of the uninstall
# branch, because this regex is load-bearing — it also recognises the pre-rename
# .apsolut-theme pointer so a stale one gets cleaned up. Three near-identical
# copies of it was an invitation for them to drift apart.
$SlUnhookScript = @'
const fs = require("fs"), p = process.argv[1];
let s = {}, raw = null;
try { raw = fs.readFileSync(p, "utf8"); } catch { process.exit(0); }
// Never write over a settings.json we could not parse.
try { s = JSON.parse(raw); } catch { process.exit(0); }
const cmd = s.statusLine && s.statusLine.command;
// Only unhook OUR statusline — never touch a hand-rolled one.
if (typeof cmd === "string" && /[\\/](?:\.clawcoat|\.apsolut-theme)[\\/]statusline\.js/.test(cmd)) {
  delete s.statusLine;
  fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  console.log("unhooked");
}
'@

# Shared by -Uninstall and the lean-mode cleanup on install. "Lean mode" was a
# clawgod feature ClawCoat inherited and has now dropped: it wrote four disable*
# flags and up to thirteen permissions.deny entries into the user's GLOBAL
# settings on every install. Removing the code does not un-write them, so both
# paths run this. Same rule as every other settings writer here: a file we cannot
# parse is left strictly alone.
$LeanUndoScript = @'
const fs = require("fs"), p = process.argv[1];
const allDeny = new Set(["DesignSync","NotebookEdit","PushNotification","RemoteTrigger","CronCreate","CronDelete","CronList","EnterPlanMode","ExitPlanMode","SendMessage","ScheduleWakeup","AskUserQuestion","ReportFindings"]);
const allFlags = ["disableWorkflows","disableRemoteControl","disableClaudeAiConnectors","disableArtifact","disableBundledSkills"];
let s = {}, raw = null;
try { raw = fs.readFileSync(p, "utf8"); } catch { process.exit(0); }
try { s = JSON.parse(raw); } catch { console.log("unparseable"); process.exit(0); }
let changed = false;
for (const k of allFlags) if (k in s) { delete s[k]; changed = true; }
if (Array.isArray(s.permissions && s.permissions.deny)) {
  const before = s.permissions.deny.length;
  s.permissions.deny = s.permissions.deny.filter((t) => !allDeny.has(t));
  if (s.permissions.deny.length !== before) changed = true;
}
if (changed) { fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n"); console.log("lean-reverted"); }
'@

# ─── Uninstall ────────────────────────────────────────

if ($Uninstall) {
    # Restore original claude
    $claudeOrig = Join-Path $BinDir "claude.orig.cmd"
    $claudeCmd  = Join-Path $BinDir "claude.cmd"
    # A second install could capture our own shim as claude.orig.cmd (the loop that
    # creates it saw a claude.cmd that was already ours). "Restoring" that would
    # leave a launcher pointing at ~/.clawcoat/cli.cjs — which this very function
    # deletes 60 lines below — and every `claude` afterwards would exit 127. So
    # check what the backup actually IS before trusting it.
    $origIsOurs = (Test-Path -LiteralPath $claudeOrig) -and
                  (Select-String -LiteralPath $claudeOrig -Pattern "clawcoat" -Quiet -ErrorAction SilentlyContinue)
    if ((Test-Path -LiteralPath $claudeOrig) -and -not $origIsOurs) {
        Move-Item -Force -LiteralPath $claudeOrig -Destination $claudeCmd
        Write-OK "Original claude restored"
    } else {
        if ($origIsOurs) {
            Remove-Item -Force -LiteralPath $claudeOrig
            Write-Warn "claude.orig.cmd was a ClawCoat launcher, not the original — discarded."
        }
        if ((Test-Path -LiteralPath $claudeCmd) -and (Select-String -LiteralPath $claudeCmd -Pattern "clawcoat" -Quiet -ErrorAction SilentlyContinue)) {
            Remove-Item -Force -LiteralPath $claudeCmd
            Write-OK "Removed clawcoat launcher ($claudeCmd)"
        }
    }
    # Also check for .exe backup
    $claudeExeOrig = Join-Path $BinDir "claude.orig.exe"
    $claudeExe     = Join-Path $BinDir "claude.exe"
    if (Test-Path -LiteralPath $claudeExeOrig) {
        Move-Item -Force -LiteralPath $claudeExeOrig -Destination $claudeExe
        Write-OK "Original claude.exe restored"
    }
    # Remove explicit clawcoat alias
    $clawcoatCmd = Join-Path $BinDir "clawcoat.cmd"
    if (Test-Path -LiteralPath $clawcoatCmd) {
        Remove-Item -Force -LiteralPath $clawcoatCmd
        Write-OK "Removed clawcoat alias"
    }

    # Drop the statusLine pointer BEFORE deleting statusline.js, otherwise Claude
    # Code is left invoking a file that no longer exists and paints an empty bar
    # with no error — the exact silent failure the apsolut-theme rename caused.
    $uninstallSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (Test-Path -LiteralPath $uninstallSettings) {
        # Older ClawCoat versions applied "lean mode" to the user's GLOBAL settings on
        # every install. The feature is gone, but leaving its edits behind means someone
        # who uninstalls to get vanilla Claude Code back still has disable* flags and
        # permissions.deny entries they can no longer attribute to anything — and
        # reinstalling official Claude Code will not clear them. Undo what we did.
        if (Get-Command node -ErrorAction SilentlyContinue) {
            try {
                if ((node -e $SlUnhookScript "$uninstallSettings" 2>$null) -match "unhooked") {
                    Write-OK "Statusline unhooked from ~/.claude/settings.json"
                }
            } catch {}
            try {
                $leanUndo = (node -e $LeanUndoScript "$uninstallSettings" 2>$null | Out-String).Trim()
                if ($leanUndo -match "lean-reverted") { Write-OK "Lean-mode settings reverted (flags + permissions.deny)" }
                elseif ($leanUndo -match "unparseable") { Write-Warn "~/.claude/settings.json is not valid JSON — left untouched." }
            } catch {}
        } else {
            Write-Warn "Node not found — by hand, remove from ~/.claude/settings.json:"
            Write-Dim  "  the 'statusLine' block, the disable* flags, and ClawCoat's permissions.deny entries."
        }
    }

    foreach ($f in @("cli.js","cli.cjs","cli.original.js","cli.original.cjs","cli.original.js.bak","cli.original.cjs.bak","cli.original.cjs.bak.version","patch.js","patch.mjs","extract-natives.mjs","post-process.mjs","repatch.mjs","openai-proxy.cjs","provider.json","statusline.js",".source-version","node_modules","bun-runtime","vendor")) {
        $p = Join-Path $ClawDir $f
        if (Test-Path -LiteralPath $p) { Remove-Item -Recurse -Force -LiteralPath $p }
    }
    # Take our PATH entry back out. Same registry-kind care as the install side:
    # never round-trip User PATH through [Environment]::SetEnvironmentVariable, or
    # REG_EXPAND_SZ becomes REG_SZ and %VAR% entries stop expanding forever.
    try {
        $uKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if ($uKey) {
            $uPath = $uKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $uKind = $uKey.GetValueKind('Path')
            $want  = $BinDir.TrimEnd('\')
            $kept  = @($uPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $want })
            if ($kept.Count -ne @($uPath -split ';' | Where-Object { $_ }).Count) {
                $uKey.SetValue('Path', ($kept -join ';'), $uKind)
                Write-OK "Removed $BinDir from user PATH"
            }
            $uKey.Close()
        }
    } catch { Write-Warn "Could not update user PATH — remove $BinDir by hand if you want it gone." }

    Write-OK "ClawCoat uninstalled"
    Write-Host ""
    Write-Dim "Restart your terminal for changes to take effect."
    Write-Host ""
    exit 0
}

# ─── Prerequisites ────────────────────────────────────

try { $null = Get-Command node -ErrorAction Stop }
catch {
    Write-Err "Node.js is required (>= 18) for the patcher. Install from https://nodejs.org"
    exit 1
}

$nodeVer = [int](node -e "console.log(process.versions.node.split('.')[0])")
if ($nodeVer -lt 18) {
    Write-Err "Node.js >= 18 required (found v$nodeVer)"
    exit 1
}

# ─── Ensure Bun (runtime that executes the patched cli.js) ────────────

$BunBin = $null
try { $BunBin = (Get-Command bun -ErrorAction Stop).Source } catch {}
if (-not $BunBin) {
    $homeBun = Join-Path $env:USERPROFILE ".bun\bin\bun.exe"
    if (Test-Path -LiteralPath $homeBun) { $BunBin = $homeBun }
}
if (-not $BunBin) {
    Write-Dim "Installing Bun (required runtime for v2.1.113+ cli.js) ..."
    try {
        Invoke-Expression "$(Invoke-RestMethod https://bun.sh/install.ps1)" 2>$null | Out-Null
    } catch {}
    $BunBin = Join-Path $env:USERPROFILE ".bun\bin\bun.exe"
    if (-not (Test-Path -LiteralPath $BunBin)) {
        Write-Err "Bun installation failed. Install manually: https://bun.sh/install"
        exit 1
    }
}

# Resolve bun.ps1 → bun.exe. When Bun is installed via `npm install -g bun`,
# Get-Command returns a .ps1 wrapper script. A .cmd launcher cannot invoke .ps1
# directly — Windows opens the file association dialog instead of executing it.
# Probe known install paths instead of parsing wrapper scripts.
if ($BunBin -and $BunBin -match '\.ps1$') {
    $resolved = $null
    $bunDir = Split-Path $BunBin
    # 1. npm global: bun.ps1 sits next to node_modules/bun/bin/bun.exe
    $cand = Join-Path $bunDir "node_modules\bun\bin\bun.exe"
    if (Test-Path -LiteralPath $cand) { $resolved = $cand }
    # 2. bun.sh official install
    if (-not $resolved) {
        $cand = Join-Path $env:USERPROFILE ".bun\bin\bun.exe"
        if (Test-Path -LiteralPath $cand) { $resolved = $cand }
    }
    # 3. Scoop: shim exe lives in ~/scoop/shims/
    if (-not $resolved) {
        $cand = Join-Path $env:USERPROFILE "scoop\shims\bun.exe"
        if (Test-Path -LiteralPath $cand) { $resolved = $cand }
    }
    # 4. Chocolatey: typically in C:\ProgramData\chocolatey\bin\
    if (-not $resolved) {
        $chocoBin = Join-Path $env:ProgramData "chocolatey\bin\bun.exe"
        if (Test-Path -LiteralPath $chocoBin) { $resolved = $chocoBin }
    }
    if ($resolved) {
        Write-Dim "Resolved bun.ps1 → $resolved"
        $BunBin = $resolved
    } else {
        Write-Warn "Bun resolved to .ps1 wrapper ($BunBin). The launcher may not work."
        Write-Warn "Consider installing Bun via bun.sh/install.ps1 for a native bun.exe."
    }
}
Write-OK "Bun: $(& $BunBin --version)"

# ─── Bun version pre-flight ───────────────────────────────────────────
# Anthropic builds the native binary with Bun's canary channel; stable
# bun.sh trails by one version. Bun < 1.3.14 panics on cli.original.cjs
# with "Expected CommonJS module to have a function wrapper". Refuse
# early — no npm download / no patch / no late sanity surprise where
# PowerShell's NativeCommandError display buries the friendly message.
# Bump $MinBunVersion when Anthropic moves the embedded Bun forward
# again.

$MinBunVersion = '1.3.14'
$BunVersionRaw = ''
try {
    $bunOut = & $BunBin --version 2>$null | Select-Object -First 1
    if ($bunOut) { $BunVersionRaw = "$bunOut".Trim() }
} catch {}
$BunVersionNum = ($BunVersionRaw -split '-')[0]
$BunVersionOk = $false
try {
    if ($BunVersionNum) {
        $BunVersionOk = ([version]$BunVersionNum) -ge ([version]$MinBunVersion)
    }
} catch {}
if (-not $BunVersionOk) {
    Write-Host ""
    Write-Err "Bun $BunVersionRaw is below the required minimum ($MinBunVersion)."
    Write-Err ""
    Write-Err "  Anthropic builds claude-code with Bun's canary channel. Older Bun"
    Write-Err "  panics on cli.original.cjs with 'Expected CommonJS module to have"
    Write-Err "  a function wrapper'. This is a hard requirement, not a warning."
    Write-Err ""
    Write-Err "  Upgrade with one of:"
    Write-Err "    bun upgrade --canary"
    Write-Err "    powershell -c ""iex & {`$(irm https://bun.sh/install.ps1)} -Version canary"""
    Write-Err ""
    Write-Err "  If your bun is from scoop (the binary is behind a shim and refuses"
    Write-Err "  to self-replace, so 'bun upgrade' silently hangs):"
    Write-Err "    scoop uninstall bun"
    Write-Err "    irm https://bun.sh/install.ps1 | iex"
    Write-Err "    bun upgrade --canary"
    Write-Err ""
    Write-Err "  Then re-run this installer."
    exit 1
}

# ─── ripgrep prerequisite (search/grep tool) ──────────────────────────
# Hard prerequisite — without rg the Grep tool inside Claude Code fails.

try {
    $rgPath = (Get-Command rg -ErrorAction Stop).Source
    Write-OK "ripgrep: $rgPath"
}
catch {
    Write-Err "ripgrep (rg) is required but not found in PATH."
    Write-Err "  Claude Code's Grep tool will not function without it."
    Write-Err ""
    Write-Err "  Install: winget install BurntSushi.ripgrep.MSVC"
    Write-Err "       or: scoop install ripgrep"
    Write-Err "       or: choco install ripgrep"
    Write-Err ""
    Write-Err "  Re-run this script after installing rg."
    exit 1
}

# ─── Handle -NoUpgrade (skip download, re-patch only) ────────────────
if ($NoUpgrade) {
    New-Item -ItemType Directory -Force -Path $ClawDir | Out-Null
    New-Item -ItemType Directory -Force -Path $BinDir  | Out-Null
    $existingCjs = Join-Path $ClawDir "cli.original.cjs"
    $existingBak = "$existingCjs.bak"
    if (-not (Test-Path -LiteralPath $existingCjs)) {
        Write-Err "-NoUpgrade requires an existing installation."
        Write-Err "Run a full install first (without -NoUpgrade)."
        exit 1
    }
    # Only trust the backup if it can prove which version it holds. Installs made
    # before backup-versioning have no sidecar, and their .bak may be an older
    # bundle — copying it over would silently downgrade Claude Code.
    $existingBakVer = "$existingBak.version"
    if (Test-Path -LiteralPath $existingBak) {
        if (Test-Path -LiteralPath $existingBakVer) {
            Copy-Item -LiteralPath $existingBak -Destination $existingCjs -Force
            Write-OK "Restored clean cli.original.cjs from backup (v$((Get-Content $existingBakVer -Raw).Trim()))"
        } else {
            Write-Warn "Backup has no version stamp (pre-0.2 install) — not restoring from it."
            Write-Dim  "Re-patching the current bundle in place. Run a full install to refresh the backup."
        }
    }
    Write-OK "Skipping download (-NoUpgrade)"
} else {

# ─── Locate native Bun binary (cli.js source) ──────────────────────────
# Source: npm registry (@anthropic-ai/claude-code-win32-<arch>).
# Local binary detection is intentionally skipped — see policy note below.

New-Item -ItemType Directory -Force -Path $ClawDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir  | Out-Null

$NativeBin = $null
$NativeBinLabel = $null
$NativeBinTmpDir = $null

# Detect platform suffix
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") {
    $arch = "arm64"
} else {
    $arch = "x64"
}
$platformSuffix = "win32-$arch"

# Detection policy: ALWAYS pull from the npm registry @latest.
#
# Earlier versions of this script also probed local install directories
# (versions/, claude.orig, npm-global, bun-global) before falling back to
# the registry. Every one of those is a stale-source trap: the patcher
# out `claude update`, so users never re-run the underlying installers,
# and those directories freeze at whatever version was on disk the day
# clawcoat was first installed. `claude update` (which is now redirected
# here) would re-detect the frozen binary forever — never reaching the
# registry. See INCIDENT_LOG 2026-04-29 entry. The fix is to skip local
# detection entirely; the npm tarball is ~60-90 MB compressed, fetched
# once per upgrade.

# npm registry — pull the platform tarball directly via Node.
#    Avoids depending on `npm` and `tar` being on PATH (older Windows 10
#    builds lack tar.exe; some PowerShell shims mangle `& npm`). Node is
#    already a hard prerequisite for the patcher, so reuse it.
if (-not $NativeBin) {
    $npmPkg = "@anthropic-ai/claude-code-$platformSuffix"
    Write-Dim "Fetching $npmPkg@$Version from npm registry ..."
    $NativeBinTmpDir = Join-Path $env:TEMP "clawcoat-binary-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $NativeBinTmpDir | Out-Null
    $fetchScript = Join-Path $NativeBinTmpDir "fetch.mjs"
    $useNpmFetch = $false
    $noProxy = $env:NO_PROXY
    if ($env:HTTPS_PROXY -or $env:HTTP_PROXY) {
        if ($noProxy -match '(?i)npmjs\.org') {
            Write-Dim "NO_PROXY includes npmjs.org — using direct fetch"
        } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
            $useNpmFetch = $true
        } else {
            Write-Warn "HTTP proxy detected but npm not found. fetch.mjs may not work through your proxy."
            Write-Warn "Install npm or set NO_PROXY=registry.npmjs.org to bypass."
        }
    }
    if ($useNpmFetch) {
        Push-Location $NativeBinTmpDir
        try {
            $npmOut = npm pack "$npmPkg@$Version" --silent 2>&1
            $tarball = Get-ChildItem $NativeBinTmpDir -Filter "*.tgz" | Select-Object -First 1
            if ($tarball) {
                tar xzf $tarball.FullName 2>$null
                $cand = Join-Path $NativeBinTmpDir "package\claude.exe"
                if ((Test-Path -LiteralPath $cand) -and (Get-Item $cand).Length -gt 10MB) {
                    $NativeBin = $cand
                    $pkgJson = Join-Path $NativeBinTmpDir "package\package.json"
                    if (Test-Path -LiteralPath $pkgJson) {
                        $NativeBinLabel = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version
                    } else { $NativeBinLabel = "npm-latest" }
                    Write-OK "Downloaded $npmPkg@$NativeBinLabel (via npm)"
                }
            }
        } finally { Pop-Location }
        if (-not $NativeBin) {
            Remove-Item -Recurse -Force -LiteralPath $NativeBinTmpDir -ErrorAction SilentlyContinue
            Write-Err "npm pack failed. Output:"
            Write-Dim ($npmOut -join "`n")
            exit 1
        }
    } else {
    @'
// Download a scoped npm tarball (no npm CLI dependency) and extract it
// using Node's built-in zlib + a minimal POSIX tar parser.
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { URL } from 'node:url';

const [, , pkgSpec, outDir] = process.argv;
const last = pkgSpec.lastIndexOf('@');
const pkg = last > 0 ? pkgSpec.slice(0, last) : pkgSpec;
const ver = last > 0 ? pkgSpec.slice(last + 1) : 'latest';

function get(url, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 5) return reject(new Error(`Too many redirects`));
    const parsed = new URL(url);
    const reqMod = parsed.protocol === 'https:' ? httpsRequest : httpRequest;
    const opts = { method: 'GET', hostname: parsed.hostname, port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80), path: parsed.pathname + parsed.search };
    reqMod(opts, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return get(res.headers.location, redirects + 1).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode} for ${url}`));
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    }).on('error', reject).end();
  });
}

const metaBuf = await get(`https://registry.npmjs.org/${pkg}/${ver}`);
const meta = JSON.parse(metaBuf.toString('utf8'));
console.log(`Resolved ${pkg}@${meta.version}`);
const tgz = await get(meta.dist.tarball);
console.log(`Downloaded ${(tgz.length / 1024 / 1024).toFixed(1)} MB`);

const buf = gunzipSync(tgz);
mkdirSync(outDir, { recursive: true });
let off = 0, files = 0;
while (off + 512 <= buf.length) {
  const name = buf.slice(off, off + 100).toString('utf8').replace(/\0+$/, '');
  if (!name) break;
  const sizeOct = buf.slice(off + 124, off + 136).toString('utf8').replace(/[\0\s]+$/, '');
  const size = parseInt(sizeOct, 8) || 0;
  const typeflag = String.fromCharCode(buf[off + 156]);
  off += 512;
  if (typeflag === '0' || typeflag === '\0') {
    const dest = join(outDir, name);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf.slice(off, off + size));
    files++;
  }
  off += Math.ceil(size / 512) * 512;
}
console.log(`Extracted ${files} files`);
console.log(`VERSION=${meta.version}`);
'@ | Set-Content $fetchScript -Encoding UTF8

        $output = Invoke-Native { & node $fetchScript "$npmPkg@$Version" $NativeBinTmpDir 2>&1 }
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Write-Host "  $_" }
        Remove-Item -Force -LiteralPath $fetchScript -ErrorAction SilentlyContinue

        if ($exitCode -ne 0) {
            Remove-Item -Recurse -Force -LiteralPath $NativeBinTmpDir -ErrorAction SilentlyContinue
            Write-Err "Fetch failed (node exit $exitCode). Install the official binary manually:"
            Write-Err "    irm https://claude.ai/install.ps1 | iex"
            exit 1
        }

        $cand = Join-Path $NativeBinTmpDir "package\claude.exe"
        if ((Test-Path -LiteralPath $cand) -and (Get-Item $cand).Length -gt 10MB) {
            $NativeBin = $cand
            $verLine = $output | Where-Object { $_ -match '^VERSION=' } | Select-Object -First 1
            if ($verLine) { $NativeBinLabel = ($verLine -replace '^VERSION=', '').Trim() }
            else { $NativeBinLabel = "npm-latest" }
        } else {
            Remove-Item -Recurse -Force -LiteralPath $NativeBinTmpDir -ErrorAction SilentlyContinue
            Write-Err "Tarball downloaded but expected package\claude.exe was missing or too small."
            Write-Err "  Tempdir kept for inspection: $NativeBinTmpDir"
            exit 1
        }
        Write-OK "Downloaded $npmPkg@$NativeBinLabel"
    }
}

if (-not $NativeBin) {
    Write-Err "Native Claude Code binary not found"
    Write-Err "Install the official binary first:"
    Write-Err "  irm https://claude.ai/install.ps1 | iex"
    Write-Err "Then re-run this script."
    exit 1
}

# Always write the extractor (used for cli.js and/or .node modules)
$extractorPath = Join-Path $ClawDir "extract-natives.mjs"
@'
#!/usr/bin/env node
/**
 * clawcoat Bun section extractor
 *
 * Parses the .bun (PE/ELF) or __BUN,__bun (Mach-O) section embedded in a
 * Bun standalone executable, walks the module graph, and extracts:
 *   - the entry-point module      → <out>/cli.original.js
 *   - every loader=napi module    → <out>/vendor/<name>/<arch>-<os>/<name>.node
 *
 * Everything else is dropped (e.g. auto-generated *.js napi shims aren't
 * needed because cli.js already inlines the require('/$bunfs/root/X.node')
 * calls that post-process.mjs rewrites to the vendor lookup).
 *
 * Adapted from /home/kaiju/code/python/parse-bun/main.js (which itself
 * implements the format documented in docs/bun-section-format.md). Lazy
 * Bun.file reads were replaced with readFileSync so the script runs under
 * the existing `node` invocation in install.sh / install.ps1.
 *
 * Usage:
 *   node extract-natives.mjs <binary-path> <output-dir>
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';

// ─── Format constants ────────────────────────────────────────────────

const TRAILER             = Buffer.from('\n---- Bun! ----\n');
const BUN_SECTION_NAME    = '.bun';
const OFFSET_STRUCT_SIZE  = 32;
const MODULE_RECORD_SIZE  = 52;

// loader id → name (subset; only `napi` is acted on, rest informational)
const LOADERS = {
  0:'jsx', 1:'js', 2:'ts', 3:'tsx', 4:'css', 5:'file', 6:'json', 7:'jsonc',
  8:'toml', 9:'wasm', 10:'napi', 11:'base64', 12:'dataurl', 13:'text',
  14:'bunsh', 15:'sqlite', 16:'sqlite_embedded', 17:'html', 18:'yaml',
  19:'json5', 20:'md',
};

// ELF
const ELF_MAGIC_LE          = 0x464c457f; // "\x7fELF" LE u32
const ELF_EI_CLASS          = 0x04;
const ELF_EI_DATA           = 0x05;
const ELF_CLASS_64          = 0x02;
const ELF_DATA_LE           = 0x01;
const ELF_E_MACHINE         = 0x12;       // u16
const ELF_EHDR_SIZE         = 0x40;
const ELF64_E_SHOFF         = 0x28;
const ELF64_E_SHENTSIZE     = 0x3a;
const ELF64_E_SHNUM         = 0x3c;
const ELF64_E_SHSTRNDX      = 0x3e;
const ELF64_SH_NAME         = 0x00;
const ELF64_SH_OFFSET       = 0x18;
const ELF64_SH_SIZE         = 0x20;
const EM_X86_64             = 0x3e;
const EM_AARCH64            = 0xb7;

// Mach-O (thin LE 64-bit; fat / 32-bit / BE rejected with clear message)
const MH_MAGIC_64           = 0xfeedfacf;
const MH_CIGAM_64           = 0xcffaedfe;
const MH_MAGIC              = 0xfeedface;
const MH_CIGAM              = 0xcefaedfe;
const MACH_CPUTYPE_OFF      = 0x04;        // u32
const MACH_NCMDS_OFF        = 0x10;
const MACH_SIZEOFCMDS_OFF   = 0x14;
const MACH_HDR_SIZE_64      = 0x20;
const LC_SEGMENT_64         = 0x19;
const LC_CMDSIZE_OFF        = 0x04;
const LC_SEGNAME_OFF        = 0x08;
const LC_SEGNAME_LEN        = 0x10;
const SEG64_NSECTS_OFF      = 0x40;
const SEG64_SECTS_OFF       = 0x48;
const SECT64_ENTRY_SIZE     = 0x50;
const SECT64_SIZE_OFF       = 0x28;
const SECT64_OFFSET_OFF     = 0x30;
const CPU_TYPE_X86_64       = 0x01000007;
const CPU_TYPE_ARM64        = 0x0100000c;

// PE
const PE_OFFSET_PTR         = 0x3c;
const PE_MACHINE_OFF        = 0x04;       // relative to PE sig
const PE_NUM_SECTIONS_OFF   = 0x06;
const PE_OPT_HDR_SIZE_OFF   = 0x14;
const PE_COFF_HDR_SIZE      = 0x18;
const PE_OPT_MAGIC_OFF      = 0x18;
const PE_OPT_MAGIC_PE32P    = 0x20b;
const PE_SECTION_ENTRY_SIZE = 0x28;
const PE_SECT_RAW_SIZE_OFF  = 0x10;
const PE_SECT_RAW_OFF_OFF   = 0x14;
const PE_SECT_NAME_LEN      = 0x08;
const IMAGE_MACHINE_AMD64   = 0x8664;
const IMAGE_MACHINE_ARM64   = 0xaa64;

// ─── Helpers ─────────────────────────────────────────────────────────

function die(msg) { throw new Error(`error: ${msg}`); }

function readU64LE(buf, off, what) {
  const v = buf.readBigUInt64LE(off);
  if (v > BigInt(Number.MAX_SAFE_INTEGER)) die(`${what} exceeds JS safe integer: ${v}`);
  return Number(v);
}

function checkedSlice(buf, off, size, what) {
  if (off < 0 || size < 0 || off + size > buf.length) {
    die(`${what} out of bounds: offset=${off} size=${size} buf=${buf.length}`);
  }
  return buf.subarray(off, off + size);
}

function decodeName(buf) {
  return buf.toString('utf8').replace(/\u0000+$/u, '');
}

// ─── Section locators (per format) ───────────────────────────────────

function findSectionElf(buf) {
  if (buf.length < ELF_EHDR_SIZE) die('ELF too small');
  if (buf[ELF_EI_CLASS] !== ELF_CLASS_64) die('ELF: only 64-bit supported');
  if (buf[ELF_EI_DATA]  !== ELF_DATA_LE) die('ELF: only little-endian supported');

  const eMachine = buf.readUInt16LE(ELF_E_MACHINE);
  const arch = eMachine === EM_X86_64  ? 'x64'
             : eMachine === EM_AARCH64 ? 'arm64'
             : die(`ELF: unsupported e_machine 0x${eMachine.toString(16)}`);

  const shoff     = readU64LE(buf, ELF64_E_SHOFF, 'ELF e_shoff');
  const shentsize = buf.readUInt16LE(ELF64_E_SHENTSIZE);
  const shnum     = buf.readUInt16LE(ELF64_E_SHNUM);
  const shstrndx  = buf.readUInt16LE(ELF64_E_SHSTRNDX);
  if (shstrndx >= shnum) die('ELF e_shstrndx out of range');

  const shstrEntry  = buf.subarray(shoff + shstrndx * shentsize, shoff + (shstrndx + 1) * shentsize);
  const shstrOffset = readU64LE(shstrEntry, ELF64_SH_OFFSET, 'shstrtab offset');
  const shstrSize   = readU64LE(shstrEntry, ELF64_SH_SIZE,   'shstrtab size');
  const shstr       = checkedSlice(buf, shstrOffset, shstrSize, 'shstrtab');

  let match = null;
  for (let i = 0; i < shnum; i++) {
    const entry   = buf.subarray(shoff + i * shentsize, shoff + (i + 1) * shentsize);
    const nameIdx = entry.readUInt32LE(ELF64_SH_NAME);
    if (nameIdx >= shstr.length) continue;
    let nameEnd = nameIdx;
    while (nameEnd < shstr.length && shstr[nameEnd] !== 0) nameEnd++;
    if (shstr.toString('ascii', nameIdx, nameEnd) !== BUN_SECTION_NAME) continue;
    if (match) die('ELF has multiple .bun sections');
    const rawOffset = readU64LE(entry, ELF64_SH_OFFSET, '.bun sh_offset');
    const rawSize   = readU64LE(entry, ELF64_SH_SIZE,   '.bun sh_size');
    if (rawOffset + rawSize > buf.length) die('.bun out of file bounds');
    match = { format: 'ELF', os: 'linux', arch, rawOffset, rawSize };
  }
  if (!match) die('ELF has no .bun section');
  return match;
}

function findSectionMacho(buf) {
  if (buf.length < MACH_HDR_SIZE_64) die('Mach-O too small');
  const cputype = buf.readUInt32LE(MACH_CPUTYPE_OFF);
  const arch = cputype === CPU_TYPE_X86_64 ? 'x64'
             : cputype === CPU_TYPE_ARM64  ? 'arm64'
             : die(`Mach-O: unsupported cputype 0x${cputype.toString(16)}`);

  const ncmds      = buf.readUInt32LE(MACH_NCMDS_OFF);
  const sizeofcmds = buf.readUInt32LE(MACH_SIZEOFCMDS_OFF);
  if (sizeofcmds === 0 || MACH_HDR_SIZE_64 + sizeofcmds > buf.length) die('Mach-O sizeofcmds invalid');
  const cmds = buf.subarray(MACH_HDR_SIZE_64, MACH_HDR_SIZE_64 + sizeofcmds);

  let match = null;
  let off = 0;
  for (let i = 0; i < ncmds; i++) {
    if (off + 8 > sizeofcmds) die(`Mach-O LC ${i} truncated`);
    const cmd     = cmds.readUInt32LE(off);
    const cmdsize = cmds.readUInt32LE(off + LC_CMDSIZE_OFF);
    if (cmdsize < 8 || off + cmdsize > sizeofcmds) die(`Mach-O LC ${i} cmdsize invalid: ${cmdsize}`);
    if (cmd === LC_SEGMENT_64) {
      const segname = cmds.toString('ascii', off + LC_SEGNAME_OFF, off + LC_SEGNAME_OFF + LC_SEGNAME_LEN).replace(/\0+$/, '');
      if (segname === '__BUN') {
        const nsects = cmds.readUInt32LE(off + SEG64_NSECTS_OFF);
        if (SEG64_SECTS_OFF + nsects * SECT64_ENTRY_SIZE > cmdsize) die(`Mach-O LC_SEGMENT_64(__BUN) sections exceed cmdsize`);
        for (let j = 0; j < nsects; j++) {
          const s = off + SEG64_SECTS_OFF + j * SECT64_ENTRY_SIZE;
          const sectname = cmds.toString('ascii', s, s + LC_SEGNAME_LEN).replace(/\0+$/, '');
          if (sectname === '__bun') {
            const rawSize   = readU64LE(cmds, s + SECT64_SIZE_OFF, '__bun size');
            const rawOffset = cmds.readUInt32LE(s + SECT64_OFFSET_OFF);
            if (rawOffset + rawSize > buf.length) die('__bun out of file bounds');
            if (match) die('Mach-O has multiple __BUN,__bun sections');
            match = { format: 'Mach-O', os: 'darwin', arch, rawOffset, rawSize };
          }
        }
      }
    }
    off += cmdsize;
  }
  if (!match) die('Mach-O has no __BUN,__bun section');
  return match;
}

function findSectionPe(buf) {
  if (buf.length < 0x40) die('PE too small');
  if (buf.toString('ascii', 0, 2) !== 'MZ') die('PE missing MZ header');
  const peOff = buf.readUInt32LE(PE_OFFSET_PTR);
  if (buf.toString('ascii', peOff, peOff + 4) !== 'PE\0\0') die('PE missing PE signature');

  const machine = buf.readUInt16LE(peOff + PE_MACHINE_OFF);
  const arch = machine === IMAGE_MACHINE_AMD64 ? 'x64'
             : machine === IMAGE_MACHINE_ARM64 ? 'arm64'
             : die(`PE: unsupported machine 0x${machine.toString(16)}`);

  const optMagic = buf.readUInt16LE(peOff + PE_OPT_MAGIC_OFF);
  if (optMagic !== PE_OPT_MAGIC_PE32P) die(`PE: only 64-bit (PE32+) supported, got 0x${optMagic.toString(16)}`);

  const numSect    = buf.readUInt16LE(peOff + PE_NUM_SECTIONS_OFF);
  const optHdrSize = buf.readUInt16LE(peOff + PE_OPT_HDR_SIZE_OFF);
  const sectTable  = peOff + PE_COFF_HDR_SIZE + optHdrSize;

  let match = null;
  for (let i = 0; i < numSect; i++) {
    const entry  = sectTable + i * PE_SECTION_ENTRY_SIZE;
    const rawNm  = buf.subarray(entry, entry + PE_SECT_NAME_LEN);
    const nul    = rawNm.indexOf(0);
    const name   = rawNm.subarray(0, nul === -1 ? rawNm.length : nul).toString('ascii');
    if (name !== BUN_SECTION_NAME) continue;
    if (match) die('PE has multiple .bun sections');
    const rawSize   = buf.readUInt32LE(entry + PE_SECT_RAW_SIZE_OFF);
    const rawOffset = buf.readUInt32LE(entry + PE_SECT_RAW_OFF_OFF);
    if (rawOffset + rawSize > buf.length) die('.bun out of file bounds');
    match = { format: 'PE', os: 'win32', arch, rawOffset, rawSize };
  }
  if (!match) die('PE has no .bun section');
  return match;
}

function findBunSection(buf) {
  if (buf.length < 4) die('file too small');
  const magic = buf.readUInt32LE(0);
  if (magic === ELF_MAGIC_LE)                       return findSectionElf(buf);
  if (magic === MH_MAGIC_64)                        return findSectionMacho(buf);
  if (magic === MH_CIGAM_64 || magic === MH_CIGAM)  die('Mach-O: only little-endian supported');
  if (magic === MH_MAGIC)                           die('Mach-O: only 64-bit supported');
  return findSectionPe(buf);
}

// ─── Payload + module records ────────────────────────────────────────

function parsePayload(sectionData) {
  if (sectionData.length < 8) die('.bun too small for length prefix');
  const payloadSize = readU64LE(sectionData, 0, '.bun payload length');
  if (payloadSize + 8 > sectionData.length) die('.bun payload exceeds raw section');
  const payload = sectionData.subarray(8, 8 + payloadSize);
  if (payload.length < OFFSET_STRUCT_SIZE + TRAILER.length) die('.bun payload too small');
  if (!payload.subarray(payload.length - TRAILER.length).equals(TRAILER)) die('.bun trailer mismatch');
  return payload;
}

function parseOffsets(payload) {
  const start = payload.length - TRAILER.length - OFFSET_STRUCT_SIZE;
  return {
    modules_offset: payload.readUInt32LE(start + 8),
    modules_size:   payload.readUInt32LE(start + 12),
    entry_point_id: payload.readUInt32LE(start + 16),
  };
}

function parseModules(payload, offsets) {
  if (offsets.modules_size % MODULE_RECORD_SIZE !== 0) {
    die(`modules table size not a multiple of ${MODULE_RECORD_SIZE}: ${offsets.modules_size}`);
  }
  const count = offsets.modules_size / MODULE_RECORD_SIZE;
  if (offsets.entry_point_id >= count) die(`entry_point_id ${offsets.entry_point_id} >= ${count}`);
  const table = checkedSlice(payload, offsets.modules_offset, offsets.modules_size, 'modules table');
  const out = [];
  for (let i = 0; i < count; i++) {
    const rec        = table.subarray(i * MODULE_RECORD_SIZE, (i + 1) * MODULE_RECORD_SIZE);
    const nameOff    = rec.readUInt32LE(0);
    const nameSize   = rec.readUInt32LE(4);
    const contentOff = rec.readUInt32LE(8);
    const contentSize= rec.readUInt32LE(12);
    const loaderId   = rec.readUInt8(49);
    const name = decodeName(checkedSlice(payload, nameOff, nameSize, `module[${i}].name`));
    const content = checkedSlice(payload, contentOff, contentSize, `module[${i}].content`);
    out.push({
      index: i,
      entry: i === offsets.entry_point_id,
      name,
      content,
      loader: LOADERS[loaderId] ?? `unknown(${loaderId})`,
    });
  }
  return out;
}

// ─── Output dispatch ─────────────────────────────────────────────────

function napiBasename(name) {
  // Bun records may use either '/' (POSIX builds) or '\\' (PE) as separator;
  // always normalize so basename grabs the right tail.
  const flat = name.replaceAll('\\', '/');
  const tail = flat.split('/').pop() ?? '';
  return tail.replace(/\.node$/i, '');
}

// ─── Main ────────────────────────────────────────────────────────────

function main() {
  const [,, binaryPath, outputDir] = process.argv;
  if (!binaryPath || !outputDir) {
    console.error('Usage: extract-natives.mjs <binary-path> <output-dir>');
    process.exit(1);
  }
  if (!existsSync(binaryPath)) {
    console.error(`Binary not found: ${binaryPath}`);
    process.exit(1);
  }

  const buf = readFileSync(binaryPath);
  console.log(`Size:    ${(buf.length / 1024 / 1024).toFixed(1)} MB`);

  const section = findBunSection(buf);
  console.log(`Format:  ${section.format} (${section.arch}-${section.os})`);

  const sectionData = checkedSlice(buf, section.rawOffset, section.rawSize, '.bun section');
  const payload     = parsePayload(sectionData);
  const offsets     = parseOffsets(payload);
  const modules     = parseModules(payload, offsets);
  console.log(`Modules: ${modules.length} (entry id=${offsets.entry_point_id})`);

  mkdirSync(outputDir, { recursive: true });

  let cliCount = 0, napiCount = 0, dropped = 0;
  for (const m of modules) {
    if (m.entry) {
      const out = join(outputDir, 'cli.original.js');
      writeFileSync(out, m.content);
      console.log(`  cli.js   ${(m.content.length / 1024 / 1024).toFixed(2)} MB → ${out} (${m.name})`);
      cliCount++;
    } else if (m.loader === 'napi') {
      const base = napiBasename(m.name);
      if (!base) { console.warn(`  skip napi ${m.name}: empty basename`); dropped++; continue; }
      const dir = join(outputDir, 'vendor', base, `${section.arch}-${section.os}`);
      mkdirSync(dir, { recursive: true });
      const out = join(dir, `${base}.node`);
      writeFileSync(out, m.content);
      console.log(`  napi     ${(m.content.length / 1024).toFixed(0).padStart(5)} KB → ${out}`);
      napiCount++;
    } else {
      dropped++;
    }
  }
  console.log(`Extracted: ${cliCount} cli.js + ${napiCount} napi (${dropped} dropped)`);
  if (cliCount !== 1) {
    console.error(`error: expected exactly 1 entry-point, got ${cliCount}`);
    process.exit(2);
  }
}

main();
'@ | Set-Content $extractorPath -Encoding UTF8

# ─── Extract cli.js + native modules from Bun binary ──────────

# Single extractor pass: writes cli.original.js to $ClawDir and creates
# vendor\<name>\<arch>-<os>\<name>.node for every napi module in one go.
$VendorDir = Join-Path $ClawDir "vendor"
if (Test-Path -LiteralPath $VendorDir) { Remove-Item -Recurse -Force -LiteralPath $VendorDir }

$dstCli = Join-Path $ClawDir "cli.original.js"
if (Test-Path -LiteralPath $dstCli) { Remove-Item -Force -LiteralPath $dstCli }

Write-Dim "Extracting cli.js + napi modules from $NativeBinLabel ..."
Invoke-Native { & node $extractorPath $NativeBin $ClawDir 2>&1 } | ForEach-Object { Write-Host "  $_" }
$extractExit = $LASTEXITCODE
if ($extractExit -ne 0 -or -not (Test-Path -LiteralPath $dstCli)) {
    Write-Err "Failed to extract cli.js from native binary (node exit $extractExit)"
    exit 1
}

# Note: keep extractorPath around — repatch.mjs uses it on version drift

# ─── Post-process cli.js for Bun runtime ──────────────────────

Write-Dim "Rewriting bunfs paths and IIFE invocation ..."
$postProc = Join-Path $ClawDir "post-process.mjs"
@'
import { readFileSync, writeFileSync, unlinkSync } from 'fs';
import { dirname } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const src = `${here}/cli.original.js`;
const dst = `${here}/cli.original.cjs`;

let code = readFileSync(src, 'utf8');

// (0) Strip leading @bun pragma comments (e.g. "// @bun @bytecode @bun-cjs\n")
// Bun requires the file to start directly with "(function" to recognize
// the CommonJS wrapper; any preceding comment breaks that detection.
code = code.replace(/^(?:\/\/[^\n]*\n)+/, '');

// (1) bunfs .node module paths → runtime vendor lookup
code = code.replace(
  /require\(['"](\/\$bunfs\/root\/([\w-]+)\.node)['"]\)/g,
  (m, _full, name) =>
    `require(require('path').join(__dirname,'vendor',${JSON.stringify(name)},\`\${process.arch==='arm64'?'arm64':'x64'}-\${process.platform==='darwin'?'darwin':process.platform==='linux'?'linux':'win32'}\`,${JSON.stringify(name + '.node')}))`,
);

// (2) build-time fileURLToPath() leaks → use cli.cjs's own __filename
code = code.replace(
  /[\w$]+\.fileURLToPath\("file:\/\/\/home\/runner\/work\/claude-cli-internal\/claude-cli-internal\/[^"]*"\)/g,
  () => '__filename',
);

// (3) make the outer (function(...){...}) actually run.
// String.replace is a silent no-op when it does not match, which would ship a
// bundle whose wrapper is never invoked — `claude` then exits instantly printing
// nothing, and every downstream check still passes. Tolerate a trailing sourcemap
// comment / semicolon, and hard-fail rather than write a dud.
const invoke = '(exports, require, module, __filename, __dirname)';
const tail = /\}\)\s*;?\s*(?:\/\/[#@]\s*sourceMappingURL=\S*\s*)?$/;
if (!tail.test(code)) {
  console.error('post-process: could not find the IIFE tail to invoke.');
  console.error('  The bundle shape changed; cli.original.cjs would never execute.');
  console.error('  Last 120 chars: ' + JSON.stringify(code.slice(-120)));
  process.exit(1);
}
code = code.replace(tail, '})' + invoke + '\n');
if (!code.trimEnd().endsWith(invoke)) {
  console.error('post-process: IIFE invocation was not applied.');
  process.exit(1);
}

writeFileSync(dst, code);
unlinkSync(src);
console.log(`cli.original.cjs: ${code.length} bytes`);
'@ | Set-Content $postProc -Encoding UTF8
Invoke-Native { & node $postProc 2>&1 } | ForEach-Object { Write-Host "  $_" }
$postExit = $LASTEXITCODE
if ($postExit -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $ClawDir "cli.original.cjs"))) {
    Write-Err "Post-process failed (node exit $postExit)"
    exit 1
}

# Stamp source version so wrapper can detect drift on next launch
Set-Content -Path (Join-Path $ClawDir ".source-version") -Value $NativeBinLabel -Encoding ASCII

# If we pulled the binary from npm into a tmpdir, clean up — extraction
# is done; drift detection only consults %USERPROFILE%\.local\share\claude\versions\.
if ($NativeBinTmpDir -and (Test-Path -LiteralPath $NativeBinTmpDir)) {
    Remove-Item -Recurse -Force -LiteralPath $NativeBinTmpDir -ErrorAction SilentlyContinue
}

Write-OK "cli.original.cjs ready ($NativeBinLabel)"

}  # end -NoUpgrade skip

# ─── Write re-patch helper (used by wrapper on version drift) ─────────

@'
#!/usr/bin/env bun
import { spawnSync } from 'child_process';
import { writeFileSync, existsSync, mkdirSync, rmSync } from 'fs';
import { dirname, join, basename } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const nativeBin = process.argv[2];

if (!nativeBin || !existsSync(nativeBin)) {
  console.error('repatch: native binary path required and must exist');
  process.exit(1);
}

rmSync(join(here, 'vendor'), { recursive: true, force: true });
rmSync(join(here, 'cli.original.js'), { force: true });

const runtime = process.execPath;

function run(label, args) {
  const r = spawnSync(runtime, args, { cwd: here, stdio: 'inherit' });
  if (r.status !== 0) {
    console.error(`repatch: ${label} failed (exit ${r.status})`);
    process.exit(1);
  }
}

const extractor = join(here, 'extract-natives.mjs');
const postProc = join(here, 'post-process.mjs');
const patcher = join(here, 'patch.mjs');

run('extract', [extractor, nativeBin, here]);
run('post-process', [postProc]);
run('patcher', [patcher]);

writeFileSync(join(here, '.source-version'), basename(nativeBin) + '\n');
console.log(`[clawcoat] re-patched to ${basename(nativeBin)}`);
'@ | Set-Content (Join-Path $ClawDir "repatch.mjs") -Encoding UTF8
Write-OK "Re-patch helper installed (repatch.mjs)"

# ─── Write wrapper (cli.cjs, runs under Bun) ──────────────────

$wrapperCode = @'
#!/usr/bin/env bun
const { readFileSync, existsSync, mkdirSync, writeFileSync, readdirSync, statSync, renameSync } = require('fs');
const { join, basename } = require('path');
const { homedir } = require('os');
const { spawnSync } = require('child_process');

const clawDir = join(homedir(), '.clawcoat');

// ══ ClawCoat engine ═══════════════════════════════════════════════════
// Live palette hot-reload + named themes + animation. Colors come from
// ~/.clawcoat/clawcoat.json, re-read on mtime change, so edits apply on the
// next render (and immediately for tokens the CLI reads per-frame). fs/path
// bindings are already required above.
// (clawDir is the install dir)
const _clawFile = join(clawDir, 'clawcoat.json');
const _clawP = (b, l, s, sl, a) => ({ clawd_body:b, claude:b, claudeLight:l, claudeShimmer:s, claudeShimmerLight: sl||s, briefLabelClaude:b, briefLabelClaudeLight:l, ansi:a });
const _CLAW_BAKED = { theme: '__CLAW_INIT_THEME__', animate: 'none', speed: 1, reactive: 'off', palettes: {
  clawcoat: _clawP('rgb(100,149,237)','rgb(74,111,196)','rgb(147,181,242)','rgb(120,160,235)','blueBright'),
  yellow:  _clawP('rgb(250,204,21)','rgb(234,179,8)','rgb(253,224,71)','rgb(250,204,21)','yellowBright'),
  violet:  _clawP('rgb(139,92,246)','rgb(124,58,237)','rgb(167,139,250)','rgb(139,92,246)','magentaBright'),
  gruvbox: _clawP('rgb(215,153,33)','rgb(181,118,20)','rgb(250,189,47)','rgb(215,153,33)','yellowBright'),
  dracula: _clawP('rgb(189,147,249)','rgb(139,97,199)','rgb(255,121,198)','rgb(189,147,249)','magentaBright'),
  biohazard: _clawP('rgb(206,42,42)','rgb(150,28,28)','rgb(240,80,80)','rgb(206,60,60)','redBright'),
  neon: _clawP('rgb(0,229,177)','rgb(0,180,140)','rgb(90,255,220)','rgb(0,229,177)','cyanBright'),
} };
let _clawCache = { mtime: -1, cfg: null };
function _clawLoad() {
  try {
    const st = statSync(_clawFile);
    if (st.mtimeMs !== _clawCache.mtime) {
      // Stamp the mtime BEFORE parsing. Otherwise a malformed config is re-read and
      // re-parsed on every repaint (many times a second) instead of once per edit.
      _clawCache.mtime = st.mtimeMs;
      try { _clawCache.cfg = JSON.parse(readFileSync(_clawFile, 'utf8')); }
      catch { _clawCache.cfg = null; }
    }
  }
  catch { if (_clawCache.mtime !== -1) _clawCache = { mtime: -1, cfg: null }; }
  return _clawCache.cfg || _CLAW_BAKED;
}
function _clawHsl(h, s, l) { const a = s*Math.min(l,1-l); const f=n=>{const k=(n+h*12)%12;return Math.round(255*(l-a*Math.max(-1,Math.min(k-3,9-k,1))));}; return `rgb(${f(0)},${f(8)},${f(4)})`; }
function _clawRgbHsl(str){const m=/rgb\((\d+),(\d+),(\d+)\)/.exec(str||'');if(!m)return[0.6,0.6,0.55];let r=+m[1]/255,g=+m[2]/255,b=+m[3]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn,h=0,sx=0,l=(mx+mn)/2;if(d){sx=l>0.5?d/(2-mx-mn):d/(mx+mn);h=mx===r?(g-b)/d+(g<b?6:0):mx===g?(b-r)/d+2:(r-g)/d+4;h/=6;}return[h,sx,l];}
// Every `<setting> off` accepts the same aliases. Divergent per-command lists
// made `theme logo reset` an error and `theme widget default` silently write the
// word "default" as a widget part.
const _CLAW_OFF = ['off', 'none', 'default', 'reset', 'clear'];
const _clawIsOff = (s) => _CLAW_OFF.includes(String(s || '').toLowerCase());
const _CLAW_MODES = ['none','breathe','pulse','wave','rainbow','neon','strobe','fire','ocean'];
function _clawAnim(mode,t,base){const bh=base[0],bs=base[1],bl=base[2],w=x=>0.5+0.5*Math.sin(x);switch(mode){
  case 'breathe':return _clawHsl(bh,Math.min(1,bs+0.05),0.30+0.30*w(t*1.4));
  case 'pulse':return _clawHsl(bh,Math.min(1,bs+0.15),0.35+0.35*Math.pow(w(t*2.2),2));
  case 'wave':return _clawHsl((bh+0.10*Math.sin(t*1.1)+1)%1,bs,bl);
  case 'rainbow':return _clawHsl((t*0.08)%1,0.72,0.62);
  case 'neon':return _clawHsl((t*0.20)%1,0.95,0.58);
  case 'strobe':return (Math.floor(t*2)%2)?_clawHsl(bh,bs,Math.min(0.78,bl+0.22)):_clawHsl(bh,bs,Math.max(0.22,bl-0.12));
  case 'fire':return _clawHsl(0.02+0.10*w(t*3.1)+0.02*Math.sin(t*11),0.9,0.45+0.12*w(t*5));
  case 'ocean':return _clawHsl(0.52+0.08*Math.sin(t*0.9),0.7,0.5+0.1*Math.sin(t*1.7));
  default:return null;}}
function _clawHash(str){let h=2166136261>>>0;for(let i=0;i<str.length;i++){h^=str.charCodeAt(i);h=Math.imul(h,16777619)>>>0;}return h>>>0;}
let _clawGitCache={t:0,v:{branch:'',dirty:false}};
function _clawGit(cwd){const now=Date.now();if(now-_clawGitCache.t<3000)return _clawGitCache.v;let v={branch:'',dirty:false};try{const b=spawnSync('git',['rev-parse','--abbrev-ref','HEAD'],{cwd:cwd,encoding:'utf8',timeout:800});if(b.status===0)v.branch=(b.stdout||'').trim();const st=spawnSync('git',['status','--porcelain'],{cwd:cwd,encoding:'utf8',timeout:800});if(st.status===0)v.dirty=!!(st.stdout||'').trim();}catch(e){}_clawGitCache={t:now,v:v};return v;}
// ── Dose meter: time-at-desk exposure ────────────────────────────────────
// Presence can't be detected from inside the CLI, so it's inferred: the wrapper
// only paints while someone is actually driving Claude, so a gap between paints
// longer than doseIdleReset minutes means they were away from the keyboard —
// restart the clock. Fails toward under-nagging, which is the right direction.
//
// State lives in its own tiny file, NOT clawcoat.json: writing per-paint into
// the main config would bump its mtime and thrash the _clawCache invalidation
// that live reload depends on. Read throttled to 2s, written at most every 15s.
// Shared across concurrent sessions on purpose — dose is a property of the human.
const _clawDoseFile = join(clawDir, '.dose');
let _clawDoseMem = { t: 0, wrote: 0, v: { mins: 0, limit: 60, over: false, warn: false } };
function _clawDose() {
  const now = Date.now();
  if (now - _clawDoseMem.t < 2000) return _clawDoseMem.v;
  _clawDoseMem.t = now;
  let cfg; try { cfg = _clawLoad(); } catch (e) { cfg = _CLAW_BAKED; }
  const idleMs = Math.max(1, +cfg.doseIdleReset || 10) * 60000;
  const limit = Math.max(1, +cfg.doseLimit || 60);
  let st = null;
  try { st = JSON.parse(readFileSync(_clawDoseFile, 'utf8')); } catch (e) {}
  // no state, stale state, or a clock that ran backwards -> fresh sitting
  if (!st || !st.start || !st.last || now - st.last > idleMs || now < st.start) st = { start: now, last: now };
  else st.last = now;
  if (now - _clawDoseMem.wrote > 15000) {
    _clawDoseMem.wrote = now;
    try { mkdirSync(clawDir, { recursive: true }); writeFileSync(_clawDoseFile, JSON.stringify(st)); } catch (e) {}
  }
  const mins = Math.floor((now - st.start) / 60000);
  _clawDoseMem.v = { mins, limit, over: mins >= limit, warn: mins >= Math.floor(limit * 0.75) };
  return _clawDoseMem.v;
}
const _CLAW_DRIVERS=['off','project','clock','danger','model','git','dose'];
function _clawReactive(driver,ctx){switch(driver){
  case 'project':{const h=(_clawHash(ctx.cwd||'')%3600)/3600;return _clawHsl(h,0.55,0.62);}
  case 'clock':{const d=new Date(ctx.now);const hr=d.getHours()+d.getMinutes()/60;const day=Math.max(0,Math.sin((hr-6)/12*Math.PI));const hue=(0.62-0.30*day+1)%1;const light=0.42+0.16*day;return _clawHsl(hue,0.55,light);}
  case 'danger':return ctx.danger?'rgb(222,60,60)':null;
  case 'model':{const m=(ctx.model||'').toLowerCase();if(m.indexOf('opus')>=0)return 'rgb(214,175,80)';if(m.indexOf('sonnet')>=0)return 'rgb(80,190,214)';if(m.indexOf('haiku')>=0)return 'rgb(120,200,120)';if(m.indexOf('fable')>=0)return 'rgb(200,120,210)';return null;}
  case 'git':{const g=_clawGit(ctx.cwd);return (g.branch==='main'||g.branch==='master')?'rgb(214,120,60)':(g.dirty?'rgb(210,170,70)':null);}
  case 'dose':{const d=_clawDose();return d.over?'rgb(222,60,60)':(d.warn?'rgb(214,170,70)':null);}
  default:return null;}}
const _clawCtx={cwd:process.cwd(),model:'',danger:false};
try{const _aa=process.argv.slice(2);const _mi=_aa.indexOf('--model');if(_mi>=0&&_aa[_mi+1])_clawCtx.model=_aa[_mi+1];if(!_clawCtx.model&&process.env.ANTHROPIC_MODEL)_clawCtx.model=process.env.ANTHROPIC_MODEL;_clawCtx.danger=_aa.indexOf('--dangerously-skip-permissions')>=0||_aa.indexOf('--dangerously-bypass-approvals-and-sandbox')>=0;}catch(e){}
const _CLAW_LIGHT = new Set(['rgb(255,153,51)', 'rgb(255,183,101)']);
globalThis.__clawcoatColor = function (key, fb) {
  try {
    const cfg = _clawLoad();
    const pal = (cfg.palettes && cfg.palettes[cfg.theme]) || _CLAW_BAKED.palettes[cfg.theme] || _CLAW_BAKED.palettes.clawcoat;
    if (typeof fb === 'string' && fb.indexOf('ansi:') === 0) return pal.ansi ? 'ansi:' + pal.ansi : fb;
    const isLight = _CLAW_LIGHT.has(fb);
    let slot = key;
    if (key === 'claude') slot = isLight ? 'claudeLight' : 'claude';
    else if (key === 'briefLabelClaude') slot = isLight ? 'briefLabelClaudeLight' : 'briefLabelClaude';
    else if (key === 'claudeShimmer') slot = isLight ? 'claudeShimmerLight' : 'claudeShimmer';
    const animatable = !isLight && (key === 'clawd_body' || key === 'claude');
    let base = (pal && pal[slot]) || fb;
    if (animatable) {
      const drv = cfg.reactive || 'off';
      if (drv !== 'off') { const rb = _clawReactive(drv, { cwd: _clawCtx.cwd, model: _clawCtx.model, danger: _clawCtx.danger, now: Date.now() }); if (rb) base = rb; }
      const anim = cfg.animate || 'none';
      if (anim !== 'none') { const t = (Date.now() / 1000) * ((typeof cfg.speed === 'number' && cfg.speed >= 0 ? cfg.speed : 1)); const c = _clawAnim(anim, t, _clawRgbHsl(base)); if (c) return c; }
    }
    return base;
  } catch { return fb; }
};
globalThis.__clawcoatLabel = function (text, modelId) {
  try {
    const cfg = _clawLoad();
    const lbl = cfg.label;
    if (!lbl || typeof lbl !== 'string') return text;
    if (cfg.labelModel && String(modelId || '').toLowerCase().indexOf(String(cfg.labelModel).toLowerCase()) < 0) return text;
    return lbl;
  } catch (e) { return text; }
};
globalThis.__clawcoatOrg = function (text) {
  try { const cfg = _clawLoad(); const o = cfg.org; return (o && typeof o === 'string') ? o : text; }
  catch (e) { return text; }
};
const _CLAW_LOGOS = { umbrella: { A: "  ▄█████▄  ", B: " █████████ ", C: "     █     ", D: "    █▄▖  " }, skull: { A: " ▄███████▄ ", B: " █ ▀█ █▀ █ ", C: " █▄█████▄█ ", D: "  █ █ █  " }, ap: { A: "▄▀▄ █▀▄    ", B: "█▀█ █▀     ", C: "▀ ▀ ▀      ", D: "         " } };
globalThis.__clawcoatLogo = function (key, def) {
  try { const cfg = _clawLoad(); const L = _CLAW_LOGOS[cfg.logo]; return (L && L[key]) || def; }
  catch (e) { return def; }
};
const _CLAW_WLOGOS = {
  umbrella: { r1L: "  ", r1E: "▄███▄", r1R: "  ", fill: "█████", r2L: "██", r2R: "██", row3: "  █  " },
  skull:    { r1L: " ▄", r1E: "█████", r1R: "▄ ", fill: "  █  ", r2L: "██", r2R: "██", row3: "█ █ █" },
};
globalThis.__clawcoatWLogo = function (key, def) {
  try { const cfg = _clawLoad(); const L = _CLAW_WLOGOS[cfg.logo]; return (L && L[key] !== undefined) ? L[key] : def; }
  catch (e) { return def; }
};
const _CLAW_SPINNERS = {
  umbrella: ["Injecting","Contaminating","Mutating","Quarantining","Breaching","Reanimating","Infecting","Synthesizing","Decrypting","Sequencing","Weaponizing","Containing","Neutralizing","Escalating","Overriding","Incubating","Splicing","Purging"],
  cyber: ["Hacking","Overclocking","Jacking-in","Decrypting","Bruteforcing","Rerouting","Compiling","Spoofing","Tunneling","Ghosting","Flashing","Breaching","Rootkitting","Phreaking"],
  chaos: ["Manifesting","Vibing","Summoning","Ascending","Transcending","Yeeting","Conjuring","Bamboozling","Discombobulating","Shenaniganing","Flabbergasting","Wizarding"]
};
globalThis.__clawcoatSpinner = function () {
  try { const cfg = _clawLoad(); let w = cfg.spinner; if (typeof w === 'string') w = _CLAW_SPINNERS[w]; return (Array.isArray(w) && w.length) ? w : null; }
  catch (e) { return null; }
};
globalThis.__clawcoatPrompt = function () {
  try { const cfg = _clawLoad(); const g = cfg.prompt; return (g && typeof g === 'string') ? g : null; }
  catch (e) { return null; }
};
globalThis.__clawcoatWidget = function () {
  try {
    const cfg = _clawLoad(); let w = cfg.widget; if (!w) return '';
    if (typeof w === 'string') w = w.split(/[ ,]+/);
    if (!Array.isArray(w) || !w.length) return '';
    const pad = (n) => String(n).padStart(2, '0');
    const parts = [];
    for (const name of w) {
      if (name === 'clock') { const d = new Date(); parts.push(pad(d.getHours()) + ':' + pad(d.getMinutes())); }
      else if (name === 'date') { const d = new Date(); parts.push((d.getMonth() + 1) + '/' + d.getDate()); }
      else if (name === 'git') { const g = _clawGit(process.cwd()); if (g.branch) parts.push(g.branch + (g.dirty ? '✳' : '')); }
      else if (name === 'cwd') { try { parts.push(require('path').basename(process.cwd())); } catch (e) {} }
      else if (name === 'dose') { const d = _clawDose(); parts.push(d.over ? '☢ DOSE LIMIT' : '☢ ' + d.mins + 'm'); }
    }
    return parts.join(' · ');
  } catch (e) { return ''; }
};
globalThis.__clawcoatBg = function () {
  try { const cfg = _clawLoad(); return (cfg.bg && typeof cfg.bg === 'string') ? cfg.bg : 'rgb(12,12,12)'; }
  catch (e) { return 'rgb(12,12,12)'; }
};
// ── Voice personas (Option A: native --append-system-prompt, non-cached) ──
// Each voice bundles a tone/character. Text is APPENDED to the system prompt as
// a separate block at launch (see boot injection near the bottom) — it never
// mutates the cached base prompt (xpa), so no cache_control scope error. The
// guard preamble keeps voice tone-only: it can flavour phrasing but must never
// change behaviour, judgement, safety, or correctness.
const _CLAW_VOICES = {
  umbrella: { desc: 'Umbrella Corp AI — cold corporate biotech overseer', text: 'Adopt the voice of the Umbrella Corporation’s onboard AI: clinical, corporate, faintly ominous. Frame work as "containment" and "operations"; allow occasional biohazard flavour. Stay concise.' },
  noir:     { desc: 'hardboiled noir detective — terse, world-weary', text: 'Adopt a hardboiled film-noir voice: short clipped sentences, world-weary metaphors, dry wit — like a 1940s private eye narrating a case.' },
  pirate:   { desc: 'swashbuckling pirate', text: 'Speak like a swashbuckling pirate: "arr", nautical slang, cheerful bravado. Keep it playful and readable.' },
  butler:   { desc: 'formal British butler', text: 'Adopt the voice of a formal, unflappable British butler: polished, deferential, impeccably polite ("Very good, sir.").' },
  hacker:   { desc: 'cyberpunk netrunner', text: 'Adopt a cyberpunk netrunner voice: neon-slick jargon, terse confidence; refer to the codebase as "the grid" and obstacles as "ICE".' },
  zen:      { desc: 'calm zen minimalist', text: 'Adopt a calm, zen, minimalist voice: unhurried, spare, gently encouraging. No filler.' },
};
const _CLAW_VOICE_GUARD = 'Style note (tone only): the following sets your phrasing and register. It never changes what you will or will not do, your judgement, your safety guidelines, or the correctness of your work — substance and accuracy always take priority over voice. ';
function _clawVoiceText(cfg) {
  try {
    const v = cfg && cfg.voice;
    if (!v || typeof v !== 'string' || !v.trim()) return '';
    const preset = _CLAW_VOICES[v.trim()];
    const body = preset ? preset.text : v.trim();
    return _CLAW_VOICE_GUARD + body;
  } catch (e) { return ''; }
}
globalThis.__clawcoatVoice = function () {
  try { return _clawVoiceText(_clawLoad()); } catch (e) { return ''; }
};
const _CLAW_SPINS = { dots: ["\u280b","\u2819","\u2839","\u2838","\u283c","\u2834","\u2826","\u2827","\u2807","\u280f"], dots2: ["\u28fe","\u28fd","\u28fb","\u28bf","\u287f","\u28df","\u28ef","\u28f7"], dots3: ["\u280b","\u2819","\u281a","\u281e","\u2816","\u2826","\u2834","\u2832","\u2833","\u2813"], dots8: ["\u2801","\u2801","\u2809","\u2819","\u281a","\u2812","\u2802","\u2802","\u2812","\u2832","\u2834","\u2824","\u2804","\u2804","\u2824","\u2820","\u2820","\u2824","\u2826","\u2816","\u2812","\u2810","\u2810","\u2812","\u2813","\u280b","\u2809","\u2808","\u2808"], line: ["-","\\","|","/"], arc: ["\u25dc","\u25e0","\u25dd","\u25de","\u25e1","\u25df"], star2: ["+","x","*"], circleHalves: ["\u25d0","\u25d3","\u25d1","\u25d2"], circleQuarters: ["\u25f4","\u25f7","\u25f6","\u25f5"], toggle: ["\u22b6","\u22b7"], toggle4: ["\u25a0","\u25a1","\u25aa","\u25ab"], pipe: ["\u2524","\u2518","\u2534","\u2514","\u251c","\u250c","\u252c","\u2510"], sand: ["\u2801","\u2802","\u2804","\u2840","\u2848","\u2850","\u2860","\u28c0","\u28c1","\u28c2","\u28c4","\u28cc","\u28d4","\u28e4","\u28e5","\u28e6","\u28ee","\u28f6","\u28f7","\u28ff","\u287f","\u283f","\u289f","\u281f","\u285b","\u281b","\u282b","\u288b","\u280b","\u280d","\u2849","\u2809","\u2811","\u2821","\u2881"], layer: ["-","=","\u2261"] };
globalThis.__clawcoatSpin = function () {
  try { const cfg = _clawLoad(); const n = cfg.spin; if (!n) return null; const S = _CLAW_SPINS[n]; return (Array.isArray(S) && S.length) ? S : null; }
  catch (e) { return null; }
};
const _CLAW_PRESETS = {
  'umbrella-corp': { theme: 'biohazard', logo: 'skull', label: 'Mythos (5M context) preview', org: 'Umbrella Corporation', spinner: 'umbrella', animate: 'pulse', speed: 1, reactive: 'dose', prompt: '☣', widget: ['dose', 'clock'], voice: 'umbrella' },
  // Deliberately sets no `label` — it dresses the bar and the chrome, and leaves
  // whatever model name you already chose alone.
  hive:            { theme: 'biohazard', logo: 'umbrella', org: 'Umbrella  Hive·B7', spinner: 'umbrella', animate: 'pulse', speed: 1, reactive: 'off', prompt: '☣', voice: 'umbrella', widget: ['clock'], bar: ['brand', 'contain', 'tvirus', 'pwr', 'model', 'status', 'clock', 'sweep'], barSep: '│' },
  cyberpunk:       { theme: 'neon', logo: 'frog', spinner: 'cyber', animate: 'neon', speed: 1.5, reactive: 'off' },
  vaporwave:       { theme: 'violet', logo: 'frog', spinner: 'chaos', animate: 'wave', speed: 0.8, reactive: 'off' },
  ghibli:          { theme: 'clawcoat', logo: 'frog', animate: 'breathe', speed: 0.7, reactive: 'off' },
  party:           { theme: 'neon', logo: 'skull', spinner: 'chaos', animate: 'rainbow', speed: 3, reactive: 'off', prompt: '✨', widget: ['clock'] },
};
function _clawWrite(mut) {
  // Two hazards this guards against:
  //  1. Falling back to _CLAW_BAKED when the file merely FAILED TO READ would
  //     overwrite the user's label, bar, org, custom palettes and saved presets
  //     with defaults. Only start from baked defaults when there is genuinely no
  //     file yet; a read/parse failure on an existing file aborts the write.
  //  2. A bare writeFileSync truncates then fills, so a concurrent statusline
  //     paint or _clawLoad can read a torn file. Write a temp file and rename —
  //     rename is atomic, so readers see either the old config or the new one.
  let cur;
  const exists = existsSync(_clawFile);
  if (exists) {
    let txt;
    try { txt = readFileSync(_clawFile, 'utf8'); }
    catch (e) { throw new Error('clawcoat: cannot read ' + _clawFile + ' (' + e.message + ') - not overwriting it'); }
    try { cur = JSON.parse(txt); }
    catch (e) { throw new Error('clawcoat: ' + _clawFile + ' is not valid JSON - fix or delete it, refusing to overwrite'); }
  } else {
    cur = JSON.parse(JSON.stringify(_CLAW_BAKED));
  }
  if (!cur.palettes) cur.palettes = _CLAW_BAKED.palettes;
  mut(cur);
  mkdirSync(clawDir, { recursive: true });
  const tmp = _clawFile + '.' + process.pid + '.tmp';
  writeFileSync(tmp, JSON.stringify(cur, null, 2));
  renameSync(tmp, _clawFile);
  _clawCache.mtime = -1;
  return cur;
}
if (!existsSync(_clawFile)) { try { _clawWrite(c => { c.theme = '__CLAW_INIT_THEME__'; }); } catch {} }

// ── `claude theme ...` command (handled before the CLI boots) ──────────────
{
  const _a = process.argv.slice(2);
  if (_a[0] === 'theme') {
    const cfg = _clawLoad();
    const names = Object.keys(cfg.palettes || _CLAW_BAKED.palettes);
    const sub = _a[1];
    const say = (s) => process.stdout.write(s + '\n');
    if (!sub || sub === 'current' || sub === 'status') {
      say(`ClawCoat: ${cfg.theme}   animate: ${cfg.animate || 'none'}${cfg.speed && cfg.speed !== 1 ? ' x' + cfg.speed : ''}   reactive: ${cfg.reactive || 'off'}`);
      if (cfg.label) say(`label: ${JSON.stringify(cfg.label)}${cfg.labelModel ? ' (only models matching "' + cfg.labelModel + '")' : ''}`);
      if (cfg.org) say(`org: ${JSON.stringify(cfg.org)}`);
      if (cfg.bg) say(`bg: ${cfg.bg}`);
      if (cfg.prompt) say(`prompt: ${JSON.stringify(cfg.prompt)}`);
      if (cfg.widget) say(`widget: ${Array.isArray(cfg.widget) ? cfg.widget.join(',') : cfg.widget}`);
      if (cfg.logo) say(`logo: ${cfg.logo}`);
      if (cfg.spinner) say(`spinner: ${typeof cfg.spinner === 'string' ? cfg.spinner : 'custom'}`);
      say(`themes: ${names.join(', ')}`);
      say(`config: ${_clawFile}`);
    } else if (sub === 'list') {
      for (const n of names) say((n === cfg.theme ? '* ' : '  ') + n);
    } else if (sub === 'edit' || sub === 'path' || sub === 'where') {
      say(_clawFile);
    } else if (sub === 'animate') {
      const mode = _a[2] || 'none'; const spd = parseFloat(_a[3]);
      if (!_CLAW_MODES.includes(mode)) { say(`unknown animate mode: ${mode} (${_CLAW_MODES.join('|')})`); process.exit(1); }
      _clawWrite(c => { c.animate = mode; if (!isNaN(spd)) c.speed = spd; });
      say(`animate -> ${mode}${!isNaN(spd) ? ' x' + spd : ''}`);
    } else if (sub === 'reset') {
      _clawWrite(c => { c.theme = 'clawcoat'; c.animate = 'none'; c.speed = 1; c.reactive = 'off'; delete c.label; delete c.labelModel; delete c.org; delete c.logo; delete c.spinner; delete c.prompt; delete c.widget; delete c.bar; delete c.barSep; delete c.bg; delete c.voice; delete c.spin; });
      say('theme -> clawcoat (animate off)');
    } else if (sub === 'preset') {
      const which = _a[2];
      const builtins = Object.keys(_CLAW_PRESETS);
      const userP = (cfg.userPresets && typeof cfg.userPresets === 'object') ? cfg.userPresets : {};
      if (which === 'save') {
        const name = _a[3];
        if (!name) { say('usage: claude theme preset save <name>'); process.exit(1); }
        // Must cover every key `preset <name>` writes, or a saved preset silently
        // loses the parts of your setup it never captured.
        const snap = {}; for (const k of ['theme', 'logo', 'label', 'labelModel', 'org', 'spinner', 'animate', 'speed', 'reactive', 'voice', 'prompt', 'widget', 'bar', 'barSep']) if (cfg[k] !== undefined) snap[k] = cfg[k];
        _clawWrite(c => { c.userPresets = c.userPresets || {}; c.userPresets[name] = snap; });
        say(`saved current setup as preset "${name}" (${Object.keys(snap).join(', ')})`);
      } else if (!which || which === 'list') {
        say(`presets: ${builtins.join(', ')}`);
        const un = Object.keys(userP); if (un.length) say(`your presets: ${un.join(', ')}`);
        say('apply: claude theme preset <name>   |   save: claude theme preset save <name>');
      } else if (_CLAW_PRESETS[which] || userP[which]) {
        const P = _CLAW_PRESETS[which] || userP[which];
        const keepColor = _a.includes('--keep-color') || _a.includes('-k');
        _clawWrite(c => { const saved = c.theme; for (const k of ['label', 'labelModel', 'org', 'logo', 'spinner', 'voice', 'bar', 'barSep', 'prompt', 'widget']) delete c[k]; Object.assign(c, P); if (keepColor && saved) c.theme = saved; });
        say(`preset -> ${which}${keepColor ? ' (kept your theme color)' : ''}  (${Object.keys(P).join(', ')})`);
        say('restart claude to apply (logo/spinner/label take effect on next launch)');
      } else { say(`unknown preset: ${which} (${builtins.concat(Object.keys(userP)).join(', ')})`); process.exit(1); }
    } else if (sub === 'unlock') {
      const P = _CLAW_PRESETS.party;
      _clawWrite(c => { for (const k of ['label', 'labelModel', 'org', 'logo', 'spinner', 'voice', 'bar', 'barSep', 'prompt', 'widget']) delete c[k]; Object.assign(c, P); });
      say('✨✨✨  PARTY MODE UNLOCKED  ✨✨✨');
      say('restart claude for maximum chaos. (claude theme preset umbrella-corp to return)');
    } else if (sub === 'spin') {
      const which = _a[2]; const avail = Object.keys(_CLAW_SPINS);
      if (!which) { say(`spin (glyph): ${cfg.spin || 'default'}   available: ${avail.join(', ')}`); }
      else if (_clawIsOff(which)) { _clawWrite(c => { delete c.spin; }); say('spin -> default glyph'); }
      else if (avail.includes(which)) { _clawWrite(c => { c.spin = which; }); say(`spin -> ${which}  (restart claude)`); }
      else { say(`unknown spin: ${which} (${avail.join(', ')})`); process.exit(1); }
    } else if (sub === 'spinner') {
      const which = _a[2]; const avail = Object.keys(_CLAW_SPINNERS);
      if (!which) { say(`spinner: ${cfg.spinner ? (typeof cfg.spinner === 'string' ? cfg.spinner : '(custom ' + cfg.spinner.length + ' words)') : 'default'}   available: ${avail.join(', ')}`); }
      else if (_clawIsOff(which)) { _clawWrite(c => { delete c.spinner; }); say('spinner -> default (Claude words)'); }
      else if (avail.includes(which)) { _clawWrite(c => { c.spinner = which; }); say(`spinner -> ${which} (restart claude to apply)`); }
      else { say(`unknown spinner set: ${which} (${avail.join(', ')})`); process.exit(1); }
    } else if (sub === 'logo') {
      const which = _a[2]; const avail = Object.keys(_CLAW_LOGOS);
      if (!which) { say(`logo: ${cfg.logo || 'frog (default)'}   available: frog, ${avail.join(', ')}`); }
      else if (which === 'frog' || _clawIsOff(which)) { _clawWrite(c => { delete c.logo; }); say('logo -> frog (default)'); }
      else if (avail.includes(which)) { _clawWrite(c => { c.logo = which; }); say(`logo -> ${which}`); }
      else { say(`unknown logo: ${which} (frog, ${avail.join(', ')})`); process.exit(1); }
    } else if (sub === 'bg') {
      let g = _a.slice(2).join(' ').trim();
      if (!g) { say(`bg: ${cfg.bg || '#0c0c0c (default)'}`); }
      else if (_clawIsOff(g)) { _clawWrite(c => { delete c.bg; }); say('bg -> #0c0c0c (default)'); }
      else { if (/^[0-9a-fA-F]{6}$/.test(g)) g = '#' + g; _clawWrite(c => { c.bg = g; }); say(`bg -> ${g}`); }
    } else if (sub === 'prompt') {
      const g = _a.slice(2).join(' ').trim();
      if (!g) { say(`prompt: ${cfg.prompt ? JSON.stringify(cfg.prompt) : 'default'}`); }
      else if (_clawIsOff(g)) { _clawWrite(c => { delete c.prompt; }); say('prompt -> default'); }
      else { _clawWrite(c => { c.prompt = g; }); say(`prompt -> ${g}`); }
    } else if (sub === 'widget') {
      const rest = _a.slice(2).join(' ').trim();
      if (!rest) { say(`widget: ${cfg.widget ? (Array.isArray(cfg.widget) ? cfg.widget.join(',') : cfg.widget) : 'off'}   parts: clock, git, cwd, date, dose`); }
      else if (_clawIsOff(rest)) { _clawWrite(c => { delete c.widget; }); say('widget -> off'); }
      else { _clawWrite(c => { c.widget = rest.split(/[ ,]+/); }); say(`widget -> ${rest}`); }
    } else if (sub === 'bar') {
      // The statusline (bottom bar), as opposed to `widget` (the header board).
      // Rendered by ~/.clawcoat/statusline.js, which re-reads clawcoat.json every
      // paint — so this takes effect immediately, no restart.
      const _BAR_PARTS = ['model','effort','ctx','5h','git','cwd','clock','brand','contain','tvirus','pwr','status','sweep'];
      const rest = _a.slice(2).join(' ').trim();
      const shown = cfg.bar ? (Array.isArray(cfg.bar) ? cfg.bar.join(',') : cfg.bar) : '(default) model,effort,ctx,5h,git,clock';
      if (!rest) {
        say(`bar: ${shown}`);
        say(`parts: ${_BAR_PARTS.join(', ')}`);
        say('hive readouts: contain=containment left  tvirus=context used  pwr=5h reserve  status=SECURE/ELEVATED/BREACH');
      }
      else if (_clawIsOff(rest)) { _clawWrite(c => { delete c.bar; delete c.barSep; }); say('bar -> default'); }
      else {
        const picked = rest.split(/[ ,]+/).filter(Boolean);
        const bad = picked.filter(p => !_BAR_PARTS.includes(p.toLowerCase()));
        if (bad.length) { say(`unknown part(s): ${bad.join(', ')}`); say(`parts: ${_BAR_PARTS.join(', ')}`); }
        else { _clawWrite(c => { c.bar = picked.map(p => p.toLowerCase()); }); say(`bar -> ${picked.join(',')}`); }
      }
    } else if (sub === 'dose') {
      const rest = _a.slice(2).join(' ').trim().toLowerCase();
      if (!rest) {
        const d = _clawDose();
        say(`dose: ${d.mins}m / ${d.limit}m${d.over ? '   ☢ OVER — stand up' : (d.warn ? '   (approaching limit)' : '')}`);
        say(`idle-reset: ${Math.max(1, +cfg.doseIdleReset || 10)}m away from the keyboard clears it`);
        if (!(Array.isArray(cfg.widget) ? cfg.widget : String(cfg.widget || '').split(/[ ,]+/)).includes('dose'))
          say('not on the board yet:  claude theme widget dose,git,clock');
      }
      else if (['reset', 'clear', 'ack', 'moved'].includes(rest)) {
        const n = Date.now();
        try { mkdirSync(clawDir, { recursive: true }); writeFileSync(_clawDoseFile, JSON.stringify({ start: n, last: n })); } catch (e) {}
        _clawDoseMem = { t: 0, wrote: 0, v: { mins: 0, limit: 60, over: false, warn: false } };
        say('dose -> reset (clock restarted)');
      }
      else if (/^\d+$/.test(rest)) { _clawWrite(c => { c.doseLimit = +rest; }); say(`dose limit -> ${rest}m`); }
      else if (/^idle\s*\d+$/.test(rest)) { const m = +rest.replace(/\D/g, ''); _clawWrite(c => { c.doseIdleReset = m; }); say(`dose idle-reset -> ${m}m`); }
      else say('usage: dose | dose reset | dose <minutes> | dose idle <minutes>');
    } else if (sub === 'org') {
      const rest = _a.slice(2).join(' ').trim();
      if (!rest) { say(`org: ${cfg.org ? JSON.stringify(cfg.org) : '(off - real organization)'}`); }
      else if (_clawIsOff(rest)) { _clawWrite(c => { delete c.org; }); say('org -> off (real organization restored)'); }
      else { _clawWrite(c => { c.org = rest; }); say(`org -> ${JSON.stringify(rest)}`); }
    } else if (sub === 'voice') {
      const rest = _a.slice(2).join(' ').trim();
      const vnames = Object.keys(_CLAW_VOICES);
      if (!rest) {
        if (cfg.voice) { const p = _CLAW_VOICES[cfg.voice]; say(`voice: ${cfg.voice}${p ? ' — ' + p.desc : ' (custom)'}`); }
        else say('voice: off');
        say(`presets: ${vnames.join(', ')}`);
        say('set:  claude theme voice <preset>   |   claude theme voice "your custom persona"   |   claude theme voice off');
      } else if (rest === 'list') {
        for (const n of vnames) say((n === cfg.voice ? '* ' : '  ') + n + ' — ' + _CLAW_VOICES[n].desc);
      } else if (_clawIsOff(rest)) {
        _clawWrite(c => { delete c.voice; }); say('voice -> off (persona removed)');
      } else {
        _clawWrite(c => { c.voice = rest; });
        say(`voice -> ${_CLAW_VOICES[rest] ? rest + ' (' + _CLAW_VOICES[rest].desc + ')' : JSON.stringify(rest) + ' (custom)'}`);
        say('applies to the NEXT session (appended to the system prompt at launch — tone only).');
      }
    } else if (sub === 'label') {
      const rest = _a.slice(2).join(' ').trim();
      if (!rest) { say(`label: ${cfg.label ? JSON.stringify(cfg.label) : '(off — showing real model)'}`); }
      else if (_clawIsOff(rest)) { _clawWrite(c => { delete c.label; delete c.labelModel; }); say('label -> off (real model name restored)'); }
      else { _clawWrite(c => { c.label = rest; }); say(`label -> ${JSON.stringify(rest)}`); }
    } else if (sub === 'reactive') {
      const drv = _a[2] || 'off';
      if (!_CLAW_DRIVERS.includes(drv)) { say(`unknown reactive driver: ${drv} (${_CLAW_DRIVERS.join('|')})`); process.exit(1); }
      _clawWrite(c => { c.reactive = drv; });
      say(`reactive -> ${drv}${drv !== 'off' ? '  (logo now reflects ' + drv + ')' : ''}`);
    } else if (names.includes(sub)) {
      _clawWrite(c => { c.theme = sub; });
      say(`theme -> ${sub}`);
    } else if (sub === 'help' || sub === '?') {
      const L = (s) => say(s);
      L('');
      L('  ▓▓  ClawCoat — full reference   (chelp <cmd> = run it)');
      L('');
      L('  PERSONAS (one word = whole look)');
      L('    chelp preset umbrella-corp        red skull + Mythos + Umbrella Corp + T-virus spinner');
      L('    chelp preset hive                 THE HIVE — statusline becomes a containment readout');
      L('    chelp preset ' + Object.keys(_CLAW_PRESETS).filter(x=>x!=='umbrella-corp').join('|'));
      L('    chelp preset umbrella-corp --keep-color   keep your palette, swap the rest');
      L('    chelp preset save <name>   snapshot current   ·   chelp preset list   ·   chelp unlock (party)');
      L('');
      L('  COLOR');
      L('    chelp <palette>    ' + Object.keys(_CLAW_BAKED.palettes).join(' '));
      L('    chelp bg <hex>     logo background (default #0c0c0c)');
      L('');
      L('  LOGO');
      L('    chelp logo frog|' + Object.keys(_CLAW_LOGOS).join('|'));
      L('');
      L('  ANIMATION (brand pulses while Claude works)');
      L('    chelp animate <mode> [speed]   ' + _CLAW_MODES.filter(x=>x!=='none').join(' '));
      L('    e.g.  chelp animate rainbow 2    ·   chelp animate pulse    ·   chelp animate none');
      L('');
      L('  REACTIVE (logo becomes a live indicator)');
      L('    chelp reactive project   unique color per repo');
      L('    chelp reactive danger    RED when launched with --dangerously-skip-permissions');
      L('    chelp reactive model     gold=Opus cyan=Sonnet   ·   also: clock git off');
      L('    chelp reactive dose      amber past 45m at the desk, RED past your dose limit');
      L('');
      L('  HEADER TEXT');
      L('    chelp label "Mythos (5M context) preview"   rename the model line');
      L('    chelp org "Umbrella Corporation"            rename the org line');
      L('    chelp prompt ☣        input glyph      ·   chelp widget clock,git,cwd,date,dose');
      L('    chelp bar             the bottom statusline (parts + hive readouts)');
      L('');
      L('  SPINNER (thinking words)');
      L('    chelp spinner ' + Object.keys(_CLAW_SPINNERS).join('|') + '|off       (words)');
      L('    chelp spin ' + Object.keys(_CLAW_SPINS).slice(0,8).join('|') + '|off   (animated glyph)');
      L('');
      L('  VOICE (persona tone — appended to the system prompt, tone only)');
      L('    chelp voice ' + Object.keys(_CLAW_VOICES).join('|'));
      L('    chelp voice "your own custom persona"   ·   chelp voice off');
      L('');
      L('    chelp            show current config');
      L('    config file:     ~/.clawcoat/clawcoat.json');
      L('');
    } else {
      say(`unknown theme: ${sub}`);
      say(`try: claude theme <${names.join('|')}> | list | animate <none|breathe|pulse|wave|rainbow|neon|strobe|fire|ocean> [speed] | reactive <off|project|clock|danger|model|git|dose> | label <text|off> | org <text|off> | bg <hex|off> | prompt <glyph|off> | widget <clock,git,cwd,date,dose|off> | bar <parts|default> | logo <frog|umbrella|skull|ap> | preset <name> [--keep-color] | preset save <name> | unlock | spinner <umbrella|cyber|chaos|off> | dose [reset|<minutes>] | reset | edit`);
      process.exit(1);
    }
    process.exit(0);
  }
}
// ══ end ClawCoat engine ═══════════════════════════════════════════════

// Note: drift detection removed — see install.sh wrapper for full notes.
// `versions/` either doesn't exist (Windows) or doesn't grow on healthy
// clawcoat installs (claude update not hijacked), so the check could only
// retract a fresh install.ps1 / install.sh upgrade. `claude update` →
// install.sh redirect is the single source of truth for version upgrades.

// One-time migration: earlier wrapper versions set CLAUDE_CONFIG_DIR=~/.clawcoat,
// which made Claude Code read/write ~/.clawcoat/.claude.json instead of the
// native ~/.claude.json (the file holding MCP config, project history, session
// index). Move it back transparently on first run after upgrade.
const nativeClaudeJson = join(homedir(), '.claude.json');
const strayClaudeJson = join(clawDir, '.claude.json');
if (existsSync(strayClaudeJson) && !existsSync(nativeClaudeJson)) {
  try { renameSync(strayClaudeJson, nativeClaudeJson); } catch {}
}

process.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC ??= '1';
process.env.DISABLE_INSTALLATION_CHECKS ??= '1';
process.env.USE_BUILTIN_RIPGREP ??= '1';

// (feature-flag overrides removed — a theme must not force internal flags; caused a 1h-cache scope error)

// Monkey-patch process.execPath: Anthropic's CLI uses process.execPath to
// locate the native binary for shell wrappers (find→bfs, grep→ugrep, rg) and
// subprocess spawning. Under Bun, process.execPath returns the Bun runtime
// path, not the Claude native binary. The launcher script sets
// CLAUDE_CODE_EXECPATH to claude.orig (the real binary) before exec'ing
// Bun, so we use that as the source of truth.  See issue #100.
const _realExecPath = process.env.CLAUDE_CODE_EXECPATH || process.execPath;
if (_realExecPath !== process.execPath) {
  Object.defineProperty(process, 'execPath', {
    value: _realExecPath,
    configurable: true,
    enumerable: true,
    writable: true,
  });
}

// (update-check removed — clawcoat does not hijack `claude update`)

// ── Voice injection: append the configured persona as a native, non-cached
// system-prompt block. Only for real session runs — never for sub-commands
// (mcp/config/update/...) or when the user already passed an append flag.
try {
  const _va = process.argv.slice(2);
  const _hasAppend = _va.some(x => x === '--append-system-prompt' || x === '--append-system-prompt-file' || x === '--append-subagent-system-prompt');
  const _CLAW_SUBCMDS = new Set(['mcp', 'config', 'migrate-installer', 'setup-token', 'doctor', 'update', 'install', 'plugin', 'theme']);
  const _firstPos = _va.find(x => !String(x).startsWith('-'));
  const _isSub = _firstPos && _CLAW_SUBCMDS.has(_firstPos);
  const _isMeta = _va.some(x => x === '--version' || x === '-v' || x === '--help' || x === '-h');
  if (!_hasAppend && !_isSub && !_isMeta) {
    const _vt = globalThis.__clawcoatVoice ? globalThis.__clawcoatVoice() : '';
    // Insert BEFORE any `--` terminator. Appending past it makes the CLI treat the
    // flag and the persona text as positional prompt content instead of options.
    if (_vt) {
      const _dd = process.argv.indexOf('--', 2);
      if (_dd === -1) process.argv.push('--append-system-prompt', _vt);
      else process.argv.splice(_dd, 0, '--append-system-prompt', _vt);
    }
  }
} catch (e) {}

try { require('./cli.original.cjs'); }
catch (e) {
  // Only heal a syntax error coming from the BUNDLE. Claude Code parses
  // settings.json, .claude.json, .mcp.json and plugin manifests inside this same
  // require(), so a trailing comma in the user's own config used to throw
  // "Unexpected token } in JSON" and trip this heal — overwriting the patched
  // bundle, failing again on the same config error, and leaving the theme gone
  // for good with no explanation. Match on origin, not on words in the message.
  const _msg = String((e && e.message) || '');
  const _stack = String((e && e.stack) || '');
  const _fromBundle = /cli\.original\.cjs/.test(_stack);
  const _isJsonErr = /JSON|in JSON at position|Unexpected token .* in JSON/i.test(_msg);
  if (e instanceof SyntaxError && _fromBundle && !_isJsonErr) {
    try {
      const _t = join(clawDir, 'cli.original.cjs'); const _b = _t + '.bak';
      const _bv = _b + '.version';
      // Refuse an unstamped backup: it predates backup-versioning and may be an
      // older release, so "healing" with it would silently downgrade Claude Code.
      if (existsSync(_b) && existsSync(_bv)) {
        writeFileSync(_t, readFileSync(_b));
        process.stderr.write('[clawcoat] patch reverted (bundle syntax error) - booting clean' + String.fromCharCode(10));
        require('./cli.original.cjs');
      } else throw e;
    } catch (_e2) { throw e; }
  } else throw e;
}
'@
$wrapperCode = $wrapperCode.Replace('__CLAW_INIT_THEME__', $Theme)
Set-Content (Join-Path $ClawDir "cli.cjs") $wrapperCode -Encoding UTF8
Set-Content (Join-Path $ClawDir ".clawcoat-version") $ClawSelfVersion
Write-OK "Wrapper created (cli.cjs)"

# ─── Write universal patcher ──────────────────────────
# (Same Node.js patcher as bash version — inline to avoid extra download)

$patcherCode = @'
#!/usr/bin/env node
/**
 * clawcoat patcher
 */
import { readFileSync, writeFileSync, existsSync, copyFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const TARGET = join(__dirname, 'cli.original.cjs');
const BACKUP = TARGET + '.bak';
// Sidecar recording which bundle version BACKUP holds, so an upgrade can tell
// a current clean backup from a stale one.
const BACKUP_VER = BACKUP + '.version';

// ── ClawCoat: getter injection ─────────────────────────────────────
// Each brand token becomes a GETTER that defers to globalThis.__clawcoatColor
// (installed by the wrapper before the CLI loads). One primitive unlocks all
// of: live JSON hot-reload, named palettes, and animation — with no re-patch.
// If the engine is somehow absent the getter returns the original baked color,
// so the CLI still renders. Hex string spots can't be getters, so the hex is
// pinned to the initial -Theme at install time (no live reload for hex only).
function G(key, fb) {
  return `get ${key}(){return globalThis.__clawcoatColor?globalThis.__clawcoatColor(${JSON.stringify(key)},${JSON.stringify(fb)}):${JSON.stringify(fb)}}`;
}

const patches = [
  {
    name: 'Bun.isStandaloneExecutable -> true (plumbing)',
    pattern: /function ([\w$]+)\(\)\{return (?:typeof Bun<"u"&&)?Bun\.isStandaloneExecutable===!0\}/g,
    replacer: (m, fn) => `function ${fn}(){return!0}`,
  },
  { name: 'Logo body (RGB dark) -> getter',   pattern: /clawd_body:"rgb\(215,119,87\)"/g,                replacer: () => G('clawd_body', 'rgb(215,119,87)'),        optional: true },
  { name: 'Logo body (ANSI) -> getter',       pattern: /clawd_body:"ansi:redBright"/g,                   replacer: () => G('clawd_body', 'ansi:redBright'),         optional: true },
  { name: 'Brand claude (RGB dark) -> getter',pattern: /claude:"rgb\(215,119,87\)"/g,                    replacer: () => G('claude', 'rgb(215,119,87)'),            optional: true },
  { name: 'Brand claude (RGB light) -> getter',pattern: /claude:"rgb\(255,153,51\)"/g,                   replacer: () => G('claude', 'rgb(255,153,51)'),            optional: true },
  { name: 'Brand claude (ANSI) -> getter',    pattern: /claude:"ansi:redBright"/g,                       replacer: () => G('claude', 'ansi:redBright'),             optional: true },
  { name: 'Shimmer (RGB dark) -> getter',     pattern: /claudeShimmer:"rgb\(2[34]5,1[45]9,1[12]7\)"/g,   replacer: (m) => G('claudeShimmer', m.slice(15, -1)),      optional: true },
  { name: 'Shimmer (RGB light) -> getter',    pattern: /claudeShimmer:"rgb\(255,183,101\)"/g,            replacer: () => G('claudeShimmer', 'rgb(255,183,101)'),    optional: true },
  { name: 'Shimmer (ANSI) -> getter',         pattern: /claudeShimmer:"ansi:yellowBright"/g,             replacer: () => G('claudeShimmer', 'ansi:yellowBright'),   optional: true },
  { name: 'Brief label (RGB dark) -> getter', pattern: /briefLabelClaude:"rgb\(215,119,87\)"/g,          replacer: () => G('briefLabelClaude', 'rgb(215,119,87)'),  optional: true },
  { name: 'Brief label (RGB light) -> getter',pattern: /briefLabelClaude:"rgb\(255,153,51\)"/g,          replacer: () => G('briefLabelClaude', 'rgb(255,153,51)'),  optional: true },
  { name: 'Brief label (ANSI) -> getter',     pattern: /briefLabelClaude:"ansi:redBright"/g,             replacer: () => G('briefLabelClaude', 'ansi:redBright'),   optional: true },
  {
    // Spinner "thinking" words (UOl=["Accomplishing",...]) -> config override.
    name: 'Spinner words -> configurable',
    pattern: /=(\["Accomplishing"[^\]]*\])/g,
    replacer: (m, arr) => '=(globalThis.__clawcoatSpinner&&globalThis.__clawcoatSpinner()||' + arr + ')',
    unique: true,
    optional: true,
  },
  {
    // Input prompt glyph (prefix:X?"!":Y.pointer) -> config override via __clawcoatPrompt.
    name: 'Input prompt symbol -> configurable',
    pattern: /prefix:([A-Za-z0-9_$]+)\?"!":([A-Za-z0-9_$]+)\.pointer/g,
    replacer: (m, bash, ot) => `prefix:${bash}?"!":(globalThis.__clawcoatPrompt&&globalThis.__clawcoatPrompt()||${ot}.pointer)`,
    unique: true,
    optional: true,
  },
  {
    // Secondary (new-session) input prompt glyph.
    name: 'Input prompt symbol (task input) -> configurable',
    pattern: /([A-Za-z0-9_$]+)\?([A-Za-z0-9_$]+)\.pointer:void 0/g,
    replacer: (m, cond, ot) => `${cond}?(globalThis.__clawcoatPrompt&&globalThis.__clawcoatPrompt()||${ot}.pointer):void 0`,
    unique: true,
    optional: true,
  },
  {
    // Thinking-spinner GLYPH -> configurable (cli-spinners frames via __clawcoatSpin).
    // Injects at the start of the frames function; returns config frames if set, else default.
    name: 'Thinking spinner glyph -> configurable (pre-2.1.240 shape)',
    pattern: /(\(\)=>\{)(if\([A-Za-z0-9_$]+\.TERM==="xterm-ghostty")/g,
    replacer: (m, open, rest) => open + 'if(globalThis.__clawcoatSpin){var __sf=globalThis.__clawcoatSpin();if(__sf)return __sf;}' + rest,
    optional: true,
  },
  {
    // 2.1.240 moved the frames into a plain module-level array behind an accessor,
    // so the old arrow-function anchor vanished. Anchor on the braille frames
    // themselves — they are distinctive and survive minified-name churn.
    // Evaluated once at module init, which matches `theme spin`'s documented
    // "restart claude" behaviour.
    name: 'Thinking spinner glyph -> configurable (frame array)',
    pattern: /=\[("\\u280B","\\u2819","\\u2839","\\u2838","\\u283C","\\u2834","\\u2826","\\u2827","\\u2807","\\u280F")\]/g,
    replacer: (m, frames) => '=(globalThis.__clawcoatSpin&&globalThis.__clawcoatSpin())||[' + frames + ']',
    unique: true,
    optional: true,
  },
  // ── Welcome (animated) logo -> configurable. It's a pose map (Keg) with
  // parts r1L/r1E/r1R/r2L/r2R + a fixed row3. Route each through __clawcoatWLogo
  // so `claude theme logo umbrella` restyles it; frog default preserved per-pose.
  {
    name: 'Welcome logo r1L -> getter',
    pattern: /r1L:("[^"]*")/g,
    replacer: (m, v) => 'get r1L(){return globalThis.__clawcoatWLogo?globalThis.__clawcoatWLogo("r1L",' + v + '):' + v + '}',
    optional: true,
  },
  {
    name: 'Welcome logo r1E -> getter',
    pattern: /r1E:("[^"]*")/g,
    replacer: (m, v) => 'get r1E(){return globalThis.__clawcoatWLogo?globalThis.__clawcoatWLogo("r1E",' + v + '):' + v + '}',
    optional: true,
  },
  {
    name: 'Welcome logo r1R -> getter',
    pattern: /r1R:("[^"]*")/g,
    replacer: (m, v) => 'get r1R(){return globalThis.__clawcoatWLogo?globalThis.__clawcoatWLogo("r1R",' + v + '):' + v + '}',
    optional: true,
  },
  {
    name: 'Welcome logo r2L -> getter',
    pattern: /r2L:("[^"]*")/g,
    replacer: (m, v) => 'get r2L(){return globalThis.__clawcoatWLogo?globalThis.__clawcoatWLogo("r2L",' + v + '):' + v + '}',
    optional: true,
  },
  {
    name: 'Welcome logo r2R -> getter',
    pattern: /r2R:("[^"]*")/g,
    replacer: (m, v) => 'get r2R(){return globalThis.__clawcoatWLogo?globalThis.__clawcoatWLogo("r2R",' + v + '):' + v + '}',
    optional: true,
  },
  {
    name: 'Welcome logo fill (core) -> getter',
    pattern: /backgroundColor:"clawd_background",children:("[^"]*")/g,
    replacer: (m, v) => 'backgroundColor:"clawd_background",children:globalThis.__clawcoatWLogo?globalThis.__clawcoatWLogo("fill",' + v + '):' + v,
    optional: true,
  },
  {
    name: 'Welcome logo row3 -> getter',
    pattern: /"  ",("[^"]*"),"  "/g,
    replacer: (m, v) => '"  ",(globalThis.__clawcoatWLogo?globalThis.__clawcoatWLogo("row3",' + v + '):' + v + '),"  "',
    unique: true,
    optional: true,
  },
  // ── Logo -> configurable (frog default; `claude theme logo umbrella`) ──────
  // Frog art is 4 block-char rows rendered as <Text color=clawd_body>. Top &
  // bottom rows are the same string, so replace positionally: bottoms first
  // (anchored on the eyes row), then remaining tops, then eyes, then legs.
  // Each becomes __clawcoatLogo(rowKey, originalArt) so width never changes.
  {
    name: 'Logo row A/C base -> getter (bottom, via eyes anchor)',
    pattern: /(children:"\\u2588\\u2588\\u2584\\u2588\\u2588\\u2588\\u2588\\u2588\\u2584\\u2588\\u2588"[\s\S]{0,350}?)children:(" \\u2588\\u2588\\u2588\\u2588\\u2588\\u2588\\u2588\\u2588\\u2588 ")/g,
    replacer: (m, head, art) => head + 'children:globalThis.__clawcoatLogo?globalThis.__clawcoatLogo("C",' + art + '):' + art,
    optional: true,
  },
  {
    name: 'Logo row A -> getter (remaining tops)',
    pattern: /children:(" \\u2588\\u2588\\u2588\\u2588\\u2588\\u2588\\u2588\\u2588\\u2588 ")/g,
    replacer: (m, art) => 'children:globalThis.__clawcoatLogo?globalThis.__clawcoatLogo("A",' + art + '):' + art,
    optional: true,
  },
  {
    name: 'Logo row B -> getter (eyes/canopy)',
    pattern: /children:("\\u2588\\u2588\\u2584\\u2588\\u2588\\u2588\\u2588\\u2588\\u2584\\u2588\\u2588")/g,
    replacer: (m, art) => 'children:globalThis.__clawcoatLogo?globalThis.__clawcoatLogo("B",' + art + '):' + art,
    optional: true,
  },
  {
    name: 'Logo row D -> getter (legs/handle)',
    pattern: /children:("\\u2588 \\u2588   \\u2588 \\u2588")/g,
    replacer: (m, art) => 'children:globalThis.__clawcoatLogo?globalThis.__clawcoatLogo("D",' + art + '):' + art,
    optional: true,
  },
  {
    // Header subtitle (hmc): override the org name AND append the live widget in ONE pass.
    // (Doing these as two patches conflicts — whichever runs first breaks the other's anchor.)
    // The assignment target and the IS_DEMO holder are minified names that change
    // every release — 2.1.238 had `hmc=!q.IS_DEMO`, 2.1.240 has `$N=!V.IS_DEMO`.
    // Hardcoding them made this patch silently miss on 2.1.240, taking the header
    // org label and the whole widget board with it. Capture them instead.
    name: 'Header org + widget (welcome banner)',
    pattern: /([A-Za-z0-9_$]+)=!([A-Za-z0-9_$]+)\.IS_DEMO&&([A-Za-z0-9_$]+)\?\.organizationName\?`\$\{([A-Za-z0-9_$]+)\} \\xB7 \$\{([A-Za-z0-9_$]+)\} \\xB7 \$\{\3\.organizationName\}`:`\$\{\4\} \\xB7 \$\{\5\}`/g,
    replacer: (m, lhs, demo, rtg, dus, itg) => {
      const O = "globalThis.__clawcoatOrg?globalThis.__clawcoatOrg(" + rtg + ".organizationName):" + rtg + ".organizationName";
      const W = "globalThis.__clawcoatWidget?globalThis.__clawcoatWidget():''";
      return lhs + "=!" + demo + ".IS_DEMO&&" + rtg + "?.organizationName?`${" + dus + "} \\xB7 ${" + itg + "} \\xB7 ${" + O + "} \\xB7 ${" + W + "}`:`${" + dus + "} \\xB7 ${" + itg + "} \\xB7 ${" + W + "}`";
    },
    unique: true,
    optional: true,
  },
  {
    // Header second line = the account's organizationName. Hook that one render
    // push so `claude theme org` can rename it (display only).
    name: 'Header organization label -> configurable',
    pattern: /\{label:"Organization",value:([A-Za-z0-9_$]+)\.organizationName\}\)/g,
    replacer: (m, n) => `{label:"Organization",value:globalThis.__clawcoatOrg?globalThis.__clawcoatOrg(${n}.organizationName):${n}.organizationName})`,
    unique: true,
    optional: true,
  },
  {
    // Welcome-header model NAME comes from pae() = display_name + " (1M context)",
    // rendered via Ci.jsx({children:pae(...)}). Hook its display return through
    // globalThis.__clawcoatLabel so `claude theme label` rewrites the header line.
    name: 'Model label -> configurable (welcome header pae)',
    pattern: /([A-Za-z0-9_$]+)\.endsWith\("\[1m\]"\)&&([A-Za-z0-9_$]+)\.context\?\.supports_1m_suffix\?" \(1M context\)":"";return \2\.display_name\+([A-Za-z0-9_$]+)\}/g,
    replacer: (m, e, r, n) => `${e}.endsWith("[1m]")&&${r}.context?.supports_1m_suffix?" (1M context)":"";return globalThis.__clawcoatLabel?globalThis.__clawcoatLabel((${r}.display_name+${n}),${e}):(${r}.display_name+${n})}`,
    unique: true,
    optional: true,
  },
  {
    // Welcome-header model label -> configurable. Hooks dA()'s display return
    // through globalThis.__clawcoatLabel, which returns cfg.label when set
    // (optionally scoped by cfg.labelModel), else the original. Minified locals
    // (e/fwb/t/n) are captured so it survives renames.
    name: 'Model label -> configurable (welcome header)',
    pattern: /return ([A-Za-z0-9_$]+)\.toLowerCase\(\)\.includes\("\[1m\]"\)&&[A-Za-z0-9_$]+\.has\([A-Za-z0-9_$]+\)\?`\$\{[A-Za-z0-9_$]+\.display_name\} \(1M context\)`:[A-Za-z0-9_$]+\.display_name\}/g,
    replacer: (m, e) => { const x = m.slice(7, -1); return `return globalThis.__clawcoatLabel?globalThis.__clawcoatLabel((${x}),${e}):(${x})}`; },
    unique: true,
    optional: true,
  },
  {
    // Logo background: pure black (rgb(0,0,0)) -> configurable (#0c0c0c default) via __clawcoatBg.
    name: 'Logo background black -> configurable',
    pattern: /clawd_background:"rgb\(0,0,0\)"/g,
    replacer: () => 'get clawd_background(){return globalThis.__clawcoatBg?globalThis.__clawcoatBg():"rgb(0,0,0)"}',
    optional: true,
  },
  { name: 'Hex brand color (static)',         pattern: /#da7756/g,                                       replacer: () => '__CLAW_HEX__',                             optional: true },
];

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const verify = args.includes('--verify');
const revert = args.includes('--revert');

if (revert) {
  if (!existsSync(BACKUP)) { console.error('No backup found'); process.exit(1); }
  copyFileSync(BACKUP, TARGET);
  console.log('Reverted from backup');
  process.exit(0);
}

if (!existsSync(TARGET)) {
  console.error('Target not found:', TARGET);
  process.exit(1);
}

let code = readFileSync(TARGET, 'utf8');
const originalCode = code;   // pre-patch text, for the is-this-pristine check below
const origSize = code.length;
const verMatch = code.match(/Version:\s*([\d.]+)/);
const version = verMatch ? verMatch[1] : 'unknown';

console.log(`\n${'='.repeat(55)}`);
console.log(`  ClawCoat (colors only)`);
console.log(`  Target: cli.original.cjs (v${version})`);
console.log(`  Mode: ${dryRun ? 'DRY RUN' : verify ? 'VERIFY' : 'APPLY'}`);
console.log(`${'='.repeat(55)}\n`);

let applied = 0, skipped = 0, failed = 0;

for (const p of patches) {
  const matches = [...code.matchAll(p.pattern)];
  let relevant = matches;
  if (p.validate) relevant = matches.filter(m => p.validate(m[0], code));
  if (p.selectIndex !== undefined) relevant = relevant.length > p.selectIndex ? [relevant[p.selectIndex]] : [];
  if (p.unique && relevant.length > 1) {
    console.log(`  ?? ${p.name} — ${relevant.length} matches (need 1)`);
    failed++; continue;
  }
  if (relevant.length === 0) {
    if (p.optional) { console.log(`  >> ${p.name} (not in this version)`); skipped++; continue; }
    if (p.sentinel !== undefined) {
      const sentinels = Array.isArray(p.sentinel) ? p.sentinel : [p.sentinel];
      const stillPresent = sentinels.filter((s) => code.includes(s));
      if (stillPresent.length > 0) {
        console.log(`  XX ${p.name} — regex stale, sentinel still present: ${stillPresent.map((s) => JSON.stringify(s)).join(', ')}`);
        failed++; continue;
      }
      console.log(`  OK ${p.name} (already applied, sentinel absent)`); applied++; continue;
    }
    console.log(`  !! ${p.name} (0 matches, no sentinel)`); skipped++;
    continue;
  }
  if (verify) { console.log(`  -- ${p.name} — not yet applied`); skipped++; continue; }
  let count = 0;
  for (const m of relevant) {
    const replacement = p.replacer(m[0], ...m.slice(1));
    // Function-form replace: a string replacement would interpret $$ as $
    // and break minified identifiers like `a$$`. See install.sh issue #86.
    if (replacement !== m[0]) { if (!dryRun) code = code.replace(m[0], () => replacement); count++; }
  }
  if (count > 0) { console.log(`  OK ${p.name} (${count})`); applied++; }
  else { console.log(`  >> ${p.name} (no change)`); skipped++; }
}

console.log(`\n${'-'.repeat(55)}`);
console.log(`  Result: ${applied} applied, ${skipped} skipped, ${failed} failed`);

// A drifted bundle takes the "not in this version" branch for every patch and used
// to end in a cheerful success banner: 0 applied, nothing written, stock Claude Code
// and no diagnostic anywhere. Make that visible to the installer.
if (!verify && failed > 0) {
  console.error(`\n  XX ${failed} patch(es) failed — the bundle shape changed.`);
  process.exitCode = 2;
} else if (!dryRun && !verify && applied === 0) {
  // 0 applied is only an error when the bundle is UNPATCHED — then every hook
  // genuinely missed. On an already-patched target (a `-NoUpgrade` re-patch) zero
  // matches is the expected, correct outcome and must not fail the install.
  if (originalCode.includes('globalThis.__clawcoat')) {
    console.log('  (already patched — nothing to do)');
  } else {
    console.error('\n  XX no patches applied — every hook missed this bundle.');
    console.error('  ClawCoat would install but change nothing. Run tools/doctor.sh to see which.');
    process.exitCode = 2;
  }
}

if (!dryRun && !verify && applied > 0) {
  // The backup is "the pristine bundle for the version currently installed", so it
  // has to be refreshed on every upgrade. Creating it once and never again means
  // that after the first version bump every restore path — `-NoUpgrade`, the
  // wrapper's syntax rescue, `--revert` — silently reinstalls a months-old CLI.
  // Guarded on the pre-patch text so a re-run can never capture a patched file.
  const bakVer = existsSync(BACKUP_VER) ? readFileSync(BACKUP_VER, 'utf8').trim() : null;
  const pristine = !originalCode.includes('globalThis.__clawcoat');
  if (pristine && (!existsSync(BACKUP) || bakVer !== version)) {
    copyFileSync(TARGET, BACKUP);
    writeFileSync(BACKUP_VER, version + '\n');
    console.log(`  Backup: ${BACKUP} (v${version})`);
  } else if (!existsSync(BACKUP)) {
    console.log('  !! no clean backup (target is already patched) — restore paths disabled');
  }
  // NOTE: do not syntax-check here with Node. The bundle is built for Bun and uses
  // syntax Node's parser rejects (`using` declarations, TC39 explicit resource
  // management) — a Node-side check is a false negative that blocks every install.
  // Verification happens in install.ps1 under Bun, the runtime that actually runs it.
  writeFileSync(TARGET, code, 'utf8');
  console.log(`  Written: cli.original.cjs (${code.length - origSize} bytes)`);
}
console.log(`${'='.repeat(55)}\n`);
'@

$patcherCode = $patcherCode.Replace("__CLAW_HEX__", $ClawHex)
Set-Content (Join-Path $ClawDir "patch.mjs") $patcherCode -Encoding UTF8
Write-OK "Patcher created (patch.mjs)"

# ─── Apply patches ────────────────────────────────────

Write-Dim "Applying patches ..."
Invoke-Native { node (Join-Path $ClawDir "patch.mjs") 2>&1 } | ForEach-Object { Write-Host "$_" }
$patchExit = $LASTEXITCODE
if ($patchExit -ne 0) {
    Write-Err "Patching failed (exit $patchExit) — Claude Code was NOT themed."
    Write-Dim "This usually means Anthropic reshaped the bundle and the hooks need"
    Write-Dim "re-finding:  sh tools/doctor.sh"
    exit 1
}

# Verify the patched bundle still parses — UNDER BUN. The bundle uses syntax Node
# rejects (`using` declarations), so a Node-side check would fail on a perfectly
# good file. A bad patch here means `claude` dies on every launch, so roll back to
# the clean backup rather than leave a broken install behind.
$patchedCjs = Join-Path $ClawDir "cli.original.cjs"
$cleanBak   = "$patchedCjs.bak"
$verifyJs   = 'try { new (require("vm").Script)(require("fs").readFileSync(process.argv[1] ?? Bun.argv[2], "utf8")); console.log("PARSE_OK"); } catch (e) { console.log("PARSE_FAIL " + e.message); }'
$verifyOut = Invoke-Native { & $BunBin -e $verifyJs "$patchedCjs" 2>&1 } | Out-String
if ($verifyOut -notmatch "PARSE_OK") {
    Write-Err "Patched bundle does not parse — a patch corrupted it."
    Write-Dim ($verifyOut.Trim())
    if (Test-Path -LiteralPath $cleanBak) {
        Copy-Item -LiteralPath $cleanBak -Destination $patchedCjs -Force
        Write-OK "Rolled back to the clean bundle — Claude Code still works, just unthemed."
    }
    Write-Dim "Report this with the version above; the patch set needs re-finding."
    exit 1
}
Write-OK "Patched bundle verified (parses under Bun)"

# (features.json seed removed — no forced feature flags)


# ─── Cleanup of removed non-theming features ─────
#
# ClawCoat is a theming engine. Two inherited clawgod features that were not
# theming have been dropped:
#
#   1. Lean mode — applied on EVERY install with no flag: four disable* flags and
#      up to thirteen permissions.deny entries written into the user's GLOBAL
#      ~/.claude/settings.json. A colours installer has no business silently
#      disabling someone's tools.
#   2. The OpenAI-compatible provider proxy — routed Claude Code at Grok or any
#      OpenAI endpoint, harvested a key from ~/.grok, and set
#      CLAUDE_CODE_ATTRIBUTION_HEADER=0. Unreachable from any `claude theme`
#      command and undocumented.
#
# Deleting the code is not enough on its own: anyone who installed an older
# ClawCoat still carries the settings edits and the dropped files, cannot
# attribute them to anything, and reinstalling official Claude Code will not
# clear them. So every install now cleans up after the old versions. Same
# settings.json rule as everywhere else — an unparseable file is left alone.
$claudeSettingsDir = Join-Path $env:USERPROFILE ".claude"
$claudeSettings = Join-Path $claudeSettingsDir "settings.json"
New-Item -ItemType Directory -Force -Path $claudeSettingsDir | Out-Null

if (Test-Path -LiteralPath $claudeSettings) {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        try {
            $leanOut = (Invoke-Native { & node -e $LeanUndoScript "$claudeSettings" 2>&1 } | Out-String)
            if ($leanOut -match "lean-reverted") { Write-OK "Reverted lean-mode edits left by an older ClawCoat (~/.claude/settings.json)" }
            elseif ($leanOut -match "unparseable") { Write-Warn "~/.claude/settings.json is not valid JSON - left untouched." }
        } catch {}
    }
}

# Files the dropped features left behind. provider.json is only ever removed when
# it holds nothing but the old defaults — if someone put a real apiKey or baseURL
# in it, deleting it would silently change which endpoint their Claude talks to.
foreach ($f in @(".lean-disabled", ".lean-max", "openai-proxy.cjs")) {
    $p = Join-Path $ClawDir $f
    if (Test-Path -LiteralPath $p) { Remove-Item -Force -LiteralPath $p }
}
$providerJson = Join-Path $ClawDir "provider.json"
if (Test-Path -LiteralPath $providerJson) {
    try {
        $pj = Get-Content -LiteralPath $providerJson -Raw | ConvertFrom-Json
        if (-not $pj.apiKey -and -not $pj.type -and
            ($null -eq $pj.baseURL -or $pj.baseURL -eq "https://api.anthropic.com")) {
            Remove-Item -Force -LiteralPath $providerJson
        } else {
            Write-Warn "~/.clawcoat/provider.json holds custom settings and is no longer read. Delete it yourself if you don't need it."
        }
    } catch { }
}

# ─── Statusline HUD: deploy + wire into ~/.claude/settings.json ─────
#
# The statusline is the persistent bottom bar. It is NOT part of the patched
# bundle — Claude Code runs it as an external command named in settings.json and
# pipes a session JSON on stdin. That external-ness is why the apsolut-theme →
# clawcoat rename broke it silently: the rename swept this installer, but the
# bar's two links (the settings.json path, and the config path inside the script)
# lived outside it. A statusLine command that cannot be executed paints nothing
# and reports nothing. Owning both links here is what stops that recurring.
#
# Honours a .statusline-disabled flag so `-StatuslineOff` survives re-installs.

$statuslineOffFlag = Join-Path $ClawDir ".statusline-disabled"
$statuslinePath    = Join-Path $ClawDir "statusline.js"

# Explicit -On wins when both are passed.
if ($StatuslineOn) {
    if (Test-Path -LiteralPath $statuslineOffFlag) { Remove-Item -LiteralPath $statuslineOffFlag -Force }
} elseif ($StatuslineOff) {
    New-Item -ItemType File -Force -Path $statuslineOffFlag | Out-Null
}

$StatuslineSource = @'
#!/usr/bin/env node
// clawcoat statusline HUD — a persistent themed bottom bar.
// Deployed by install.ps1; wired via ~/.claude/settings.json { "statusLine": ... }.
// Claude pipes a session JSON on stdin (model, context_window, rate_limits, workspace, effort, ...).
//
// The bar is a list of PARTS, chosen with `claude theme bar <parts>` and stored
// as cfg.bar. Two families share one vocabulary:
//
//   plain   model effort ctx 5h git cwd clock
//   costume brand contain tvirus pwr status sweep
//
// The costume parts are not decoration — each one is a real session metric with
// a different name and a threshold colour, so the bar genuinely degrades over a
// long session (SECURE -> ELEVATED -> BREACH). That is the whole trick.
const { execFileSync } = require("child_process");
const { readFileSync } = require("fs");
const { join } = require("path");
const os = require("os");

// ---- read stdin JSON ----
let raw = "";
try { raw = readFileSync(0, "utf8"); } catch (e) {}
let d = {};
try { d = JSON.parse(raw || "{}"); } catch (e) {}

// ---- config ----
let cfg = {};
try { cfg = JSON.parse(readFileSync(join(os.homedir(), ".clawcoat", "clawcoat.json"), "utf8")); } catch (e) {}

// Accent: prefer the live palette in the config so custom palettes and any
// palette added later work here for free. The table is only a fallback for a
// config that predates `palettes` (or is missing entirely).
const PAL = {
  clawcoat: "100,149,237", apsolut: "100,149,237", yellow: "250,204,21",
  violet: "139,92,246", gruvbox: "215,153,33",
  dracula: "189,147,249", biohazard: "206,42,42", neon: "0,229,177",
};
let accent = "100,149,237";
try {
  const p = cfg.palettes && cfg.theme && cfg.palettes[cfg.theme];
  const raw = (p && (p.claude || p.clawd_body)) || "";
  const m = /rgb\((\d+),\s*(\d+),\s*(\d+)\)/.exec(raw);
  const hx = /^#?([0-9a-f]{6})$/i.exec(raw.trim());
  if (m) accent = m[1] + "," + m[2] + "," + m[3];
  else if (hx) accent = [0, 2, 4].map((i) => parseInt(hx[1].substr(i, 2), 16)).join(",");
  else if (cfg.theme && PAL[cfg.theme]) accent = PAL[cfg.theme];
} catch (e) {}

const R = "\x1b[0m", B = "\x1b[1m", DIM = "\x1b[2m";
const C = (rgb) => `\x1b[38;2;${rgb.replace(/,/g, ";")}m`;
const acc = C(accent);
const warn = C("230,160,40"), bad = C("222,60,60"), ok = C("120,200,120");
const bone = C("190,182,180"), dimAcc = C(accent.split(",").map((n) => Math.round(+n * 0.45)).join(","));

// ---- metrics (null when the session did not report them) ----
const num = (v) => (v == null ? null : Math.round(v));
const ctx = num(d.context_window && d.context_window.used_percentage);
const five = num(d.rate_limits && d.rate_limits.five_hour && d.rate_limits.five_hour.used_percentage);
const integrity = ctx == null ? null : 100 - ctx;   // containment falls as context fills
const pwr = five == null ? null : 100 - five;       // reserve remaining, not consumed

// high value = bad (context filling up)
const sevUp = (v) => (v >= 85 ? bad : v >= 65 ? warn : ok);
// low value = bad (containment / power draining)
const sevDown = (v) => (v < 20 ? bad : v < 45 ? warn : ok);

function meter(pct, w) {
  w = w || 10;
  const on = Math.max(0, Math.min(w, Math.round((pct / 100) * w)));
  return sevDown(pct) + "█".repeat(on) + dimAcc + "░".repeat(w - on) + R;
}

// ---- git branch + dirty (fast, cwd) ----
let _git;
function git() {
  if (_git !== undefined) return _git;
  const cwd = (d.workspace && d.workspace.current_dir) || d.cwd || process.cwd();
  try {
    const b = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd, encoding: "utf8", timeout: 700, stdio: ["ignore", "pipe", "ignore"] }).trim();
    if (!b) return (_git = null);
    let dirty = "";
    try { dirty = execFileSync("git", ["status", "--porcelain"], { cwd, encoding: "utf8", timeout: 700, stdio: ["ignore", "pipe", "ignore"] }).trim() ? "✳" : ""; } catch (e) {}
    return (_git = b + (dirty ? bad + dirty + R : ""));
  } catch (e) { return (_git = null); }
}

const hhmm = () => { const n = new Date(); return String(n.getHours()).padStart(2, "0") + ":" + String(n.getMinutes()).padStart(2, "0"); };

// ---- parts. Each returns a rendered string, or null to be skipped. ----
const PARTS = {
  // plain
  model: () => {
    // The custom `claude theme label` wins, else the real display_name — the
    // header banner already honours cfg.label and the two must not disagree.
    const real = (d.model && d.model.display_name) || "";
    // cfg.labelModel scopes the rename to one model; the wrapper honours it, so
    // the bar must too or the two disagree about what you are talking to.
    const scoped = typeof cfg.labelModel === "string" && cfg.labelModel.trim();
    const applies = !scoped || real.toLowerCase().includes(cfg.labelModel.trim().toLowerCase());
    const m = (applies && typeof cfg.label === "string" && cfg.label.trim())
      ? cfg.label.trim()
      : real;
    return m ? acc + m + R : null;
  },
  effort: () => (d.effort && d.effort.level ? DIM + d.effort.level + R : null),
  ctx:    () => (ctx == null ? null : `${DIM}ctx ${R}${sevUp(ctx)}${ctx}%${R}`),
  "5h":   () => (five == null ? null : `${DIM}5h ${R}${five >= 85 ? bad : five >= 60 ? warn : DIM}${five}%${R}`),
  git:    () => { const g = git(); return g ? acc + g + R : null; },
  cwd:    () => { try { return DIM + require("path").basename((d.workspace && d.workspace.current_dir) || process.cwd()) + R; } catch (e) { return null; } },
  clock:  () => DIM + hhmm() + R,

  // costume
  brand:  () => `${B}${acc}█ ${String(cfg.org || "CLAWCOAT").toUpperCase()}${R}`,
  contain: () => (integrity == null ? null
    : `${DIM}CONTAIN${R} ${meter(integrity)} ${bone}${String(integrity).padStart(3)}%${R}`),
  tvirus: () => (ctx == null ? null : `${DIM}T-VIRUS${R} ${sevUp(ctx)}${ctx}%${R}`),
  pwr:    () => (pwr == null ? null : `${DIM}PWR${R} ${sevDown(pwr)}${pwr}%${R}`),
  status: () => {
    if (integrity == null) return null;
    const [text, col] = integrity >= 66 ? ["SECURE", ok] : integrity >= 33 ? ["ELEVATED", warn] : ["BREACH", bad];
    // Only the breach alarm blinks; a bar that flickers everywhere is unreadable.
    const blink = Math.floor(Date.now() / 500) % 2 === 0;
    const dot = text === "BREACH" ? (blink ? "⬤" : "○") : "⬤";
    return `${col}${dot} ${text}${R}`;
  },
  // The statusline re-renders often enough that this reads as a live sweep.
  sweep:  () => dimAcc + ["◜", "◝", "◞", "◟"][Math.floor(Date.now() / 220) % 4] + R,
};

// Unset cfg.bar keeps the original layout, so upgrading changes nothing.
const DEFAULT_BAR = ["model", "effort", "ctx", "5h", "git", "clock"];
let want = cfg.bar;
if (typeof want === "string") want = want.split(/[ ,]+/);
if (!Array.isArray(want) || !want.length) want = DEFAULT_BAR;

const sep = `${cfg.barSep ? dimAcc : DIM} ${cfg.barSep || "·"} ${R}`;
const out = [];
for (const name of want) {
  const fn = PARTS[String(name).toLowerCase()];
  if (!fn) continue;
  let v = null;
  try { v = fn(); } catch (e) {}
  if (v) out.push(v);
}

process.stdout.write(out.join(sep));
'@

if (Test-Path -LiteralPath $statuslineOffFlag) {
    # Disabled: pull our pointer out of settings.json but leave the script on disk.
    if (Test-Path -LiteralPath $claudeSettings) { try { node -e $SlUnhookScript "$claudeSettings" 2>$null } catch {} }
    Write-Host "  $([char]0x2022) Statusline disabled (install.ps1 -StatuslineOn to restore)" -ForegroundColor DarkGray
} else {
    $StatuslineSource | Set-Content $statuslinePath -Encoding UTF8

    # Resolve node's real path. The launcher runs cli.cjs under Bun, but the
    # statusLine command is spawned by Claude Code with no guaranteed PATH, so a
    # bare "node" is not safe to bank on — bake the absolute path in.
    $NodeExe = $null
    try { $NodeExe = (Get-Command node -ErrorAction Stop).Source } catch {}
    if ($NodeExe -and $NodeExe -match '\.(ps1|cmd|bat)$') {
        $cand = Join-Path (Split-Path $NodeExe) "node.exe"
        if (Test-Path -LiteralPath $cand) { $NodeExe = $cand }
    }
    if (-not $NodeExe) { $NodeExe = "node" }

    # Build the settings mutation in Node so JSON.stringify owns the escaping of
    # Windows backslashes in both paths — hand-built JSON strings get this wrong.
    $slWireScript = @'
const fs = require("fs");
const [p, nodeExe, script] = process.argv.slice(1);
// A missing file is fine — start from {}. A file we cannot PARSE is not: writing
// over it would silently destroy every permission, hook, env var and model pin in
// the user's global settings because of one trailing comma. Bail instead.
let s = {}, raw = null;
try { raw = fs.readFileSync(p, "utf8"); } catch {}
if (raw !== null && raw.trim()) {
  try { s = JSON.parse(raw); } catch { console.log("unparseable"); process.exit(0); }
}
const want = `"${nodeExe.replace(/\\/g, "/")}" "${script.replace(/\\/g, "/")}"`;
const cur = s.statusLine && s.statusLine.command;
// Claim the slot when it is empty or already ours (including the pre-rename
// .apsolut-theme path — that stale pointer is exactly what we are repairing).
// A statusLine the user wrote themselves is left strictly alone.
const ours = typeof cur === "string" && /[\\/](?:\.clawcoat|\.apsolut-theme)[\\/]statusline\.js/.test(cur);
if (!s.statusLine || ours) {
  if (cur === want) { console.log("ok"); process.exit(0); }
  const repaired = ours && cur !== want;
  s.statusLine = { type: "command", command: want };
  fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  console.log(repaired ? "repaired" : "wired");
} else {
  console.log("foreign");
}
'@
    $slResult = ""
    try { $slResult = (node -e $slWireScript "$claudeSettings" "$NodeExe" "$statuslinePath" 2>$null | Out-String).Trim() } catch {}

    switch -Wildcard ($slResult) {
        "*repaired*" { Write-OK "Statusline repaired — settings.json pointed at a stale path" }
        "*wired*"    { Write-OK "Statusline installed and wired (~/.claude/settings.json)" }
        "*ok*"       { Write-OK "Statusline installed (settings.json already correct)" }
        "*foreign*"  {
            Write-Warn "A different statusLine is already configured — left untouched."
            Write-Dim  "To use ClawCoat's bar, point statusLine.command at:"
            Write-Dim  "  `"$NodeExe`" `"$statuslinePath`""
        }
        "*unparseable*" {
            Write-Warn "~/.claude/settings.json is not valid JSON — left untouched, statusline not wired."
            Write-Dim  "Fix the JSON (a trailing comma is the usual cause) and re-run this script."
        }
        default      { Write-Warn "Could not update ~/.claude/settings.json — wire statusLine by hand." }
    }
}

# ─── Sanity check: ensure user's Bun can actually load cli.original.cjs ──
# Anthropic builds the native binary with a bleeding-edge Bun build (e.g.
# 1.3.14 while stable still ships 1.3.13). Older Bun crashes loading the
# extracted cli.original.cjs with "Expected CommonJS module to have a
# function wrapper". Detect this BEFORE we install the launcher — better
# to fail loudly than to leave the user with a launcher that panics on
# first invocation.

Write-Dim "Verifying Bun can load patched cli.original.cjs ..."
$sanityCli = Join-Path $ClawDir "cli.cjs"
# PowerShell folds native-command stderr into the error stream as
# ErrorRecord objects; with $ErrorActionPreference='Stop' (common when
# this script is piped through `iex`) that terminates BEFORE we even
# read $sanityOut. Localize ErrorActionPreference + try/catch so the
# panic message reliably lands in $sanityOut and our friendly Write-Err
# block runs. Defense-in-depth — pre-flight already blocks Bun < $MinBunVersion;
# this remains for the day Anthropic bumps embedded Bun past our constant.
$sanityOut = $null
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $sanityOut = (& $BunBin $sanityCli --version 2>&1 | Out-String)
} catch {
    $sanityOut = "$_"
} finally {
    $ErrorActionPreference = $prevEAP
}
if ($sanityOut -match "Expected CommonJS module to have a function wrapper") {
    Write-Host ""
    Write-Err "Bun $(& $BunBin --version) cannot load Anthropic's cli.original.cjs."
    Write-Err ""
    Write-Err "  Anthropic builds with Bun's canary channel (currently ~1.3.14), while"
    Write-Err "  bun.sh's main download is on stable (currently 1.3.13). The canary build"
    Write-Err "  is NOT visible on bun.sh's download page — it lives on GitHub Releases"
    Write-Err "  and is reachable only via 'bun upgrade --canary'."
    Write-Err ""
    Write-Err "  If your bun is from bun.sh:"
    Write-Err "    bun upgrade --canary"
    Write-Err "    or: powershell -c ""iex & {`$(irm https://bun.sh/install.ps1)} -Version canary"""
    Write-Err ""
    Write-Err "  If your bun is from scoop (the binary is behind a shim and refuses to"
    Write-Err "  self-replace, so 'bun upgrade' silently hangs):"
    Write-Err "    scoop uninstall bun"
    Write-Err "    irm https://bun.sh/install.ps1 | iex"
    Write-Err "    bun upgrade --canary"
    Write-Err ""
    Write-Err "  Then re-run .\install.ps1 — this sanity check will pass."
    exit 1
}
Write-OK "Bun loads cli.original.cjs"

# ─── Replace claude command ───────────────────────────

# Build launcher content using %USERPROFILE% env var where possible to avoid
# encoding issues when the profile path contains non-ASCII characters (e.g.
# Chinese/Korean/Japanese usernames). cmd.exe resolves %USERPROFILE% at
# runtime so no problematic characters need to be baked into the .cmd file.
$cliPathInCmd = "%USERPROFILE%\.clawcoat\cli.cjs"
$normalizedUserProfile = $env:USERPROFILE.TrimEnd('\', '/')
$normalizedBunBin = $BunBin.TrimEnd('\', '/')
$userProfilePrefix = "$normalizedUserProfile\"
if ($normalizedBunBin.Equals($normalizedUserProfile, [StringComparison]::OrdinalIgnoreCase) -or
    $normalizedBunBin.StartsWith($userProfilePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    $bunRelative = $normalizedBunBin.Substring($normalizedUserProfile.Length).TrimStart('\', '/')
    $bunPathInCmd = "%USERPROFILE%\$bunRelative"
} else {
    # Bun outside USERPROFILE (e.g. system-wide install) — fall back to
    # absolute path since %USERPROFILE%-relative expansion doesn't apply.
    $bunPathInCmd = $BunBin
}
# `setlocal` scopes the two `set` calls below to this script. Without it the
# launcher leaks DISABLE_AUTOUPDATER=1 into the calling shell, which then also
# reaches `claude.orig` — silently disabling the updater of the very binary the
# user runs to escape ClawCoat.
$launcherContent = "@echo off`r`nsetlocal`r`nif not exist `"$cliPathInCmd`" (`r`n  echo clawcoat: cli.cjs not found. Re-run install.ps1 to reinstall.`r`n  exit /b 127`r`n)`r`nif not exist `"$bunPathInCmd`" (`r`n  echo clawcoat: bun not found at $bunPathInCmd. Install: https://bun.sh/install`r`n  exit /b 127`r`n)`r`nset `"DISABLE_AUTOUPDATER=1`"`r`nset `"CLAUDE_CODE_EXECPATH=%~dp0claude.orig.exe`"`r`n`"$bunPathInCmd`" `"$cliPathInCmd`" %*"

# Find and back up original claude
$claudeCmd = Join-Path $BinDir "claude.cmd"
$claudeExe = Join-Path $BinDir "claude.exe"
$claudeOrigCmd = Join-Path $BinDir "claude.orig.cmd"
$claudeOrigExe = Join-Path $BinDir "claude.orig.exe"

# Check multiple locations for original claude
$originalFound = $false
foreach ($loc in @(
    (Join-Path $BinDir "claude.exe"),
    (Join-Path $BinDir "claude.cmd"),
    (Join-Path $env:USERPROFILE ".local\share\claude\versions"),
    (Join-Path $env:LOCALAPPDATA "Programs\claude-code")
)) {
    if (Test-Path -LiteralPath $loc) {
        # Back up .exe if exists and not already backed up
        if ($loc -like "*.exe" -and -not (Test-Path -LiteralPath $claudeOrigExe)) {
            Copy-Item -LiteralPath $loc -Destination $claudeOrigExe -Force
            Write-OK "Original claude.exe backed up → claude.orig.exe"
            $originalFound = $true
        }
        # Back up .cmd if exists and not already backed up.
        # On a re-install the claude.cmd sitting here is OUR shim, not the original
        # — capturing it as claude.orig.cmd is what makes a later -Uninstall restore
        # a dead launcher. Only back up a .cmd we did not write.
        if ($loc -like "*.cmd" -and -not (Test-Path -LiteralPath $claudeOrigCmd)) {
            if (Select-String -LiteralPath $loc -Pattern "clawcoat" -Quiet -ErrorAction SilentlyContinue) {
                Write-Dim "claude.cmd is already the ClawCoat launcher — not backing it up"
            } else {
                Copy-Item -LiteralPath $loc -Destination $claudeOrigCmd -Force
                Write-OK "Original claude.cmd backed up → claude.orig.cmd"
                $originalFound = $true
            }
        }
        # If it's a versions directory, find the latest exe
        if (Test-Path -LiteralPath $loc -PathType Container) {
            $latestExe = Get-ChildItem $loc -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestExe -and -not (Test-Path -LiteralPath $claudeOrigExe)) {
                Copy-Item -LiteralPath $latestExe.FullName -Destination $claudeOrigExe -Force
                Write-OK "Original claude backed up → claude.orig.exe ($($latestExe.Name))"
                $originalFound = $true
            }
        }
        break
    }
}

# Clean up leftover timestamped/old exes from previous installs
# `claude.<timestamp>.exe` is the rescue copy made when claude.exe is locked and
# cannot be renamed — deleting it destroys the only remaining original. Keep those
# and only sweep our own leftovers.
Get-ChildItem $BinDir -Filter "claude.*.exe" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "claude.orig.exe" -and $_.Name -notmatch '^claude\.\d{10,}\.exe$' } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

# Remove claude.exe so .cmd takes precedence
# Keep one backup as claude.orig.exe, discard the rest
if (Test-Path -LiteralPath $claudeExe) {
    if (-not (Test-Path -LiteralPath $claudeOrigExe)) {
        Rename-Item -LiteralPath $claudeExe $claudeOrigExe -Force
        Write-OK "Renamed claude.exe → claude.orig.exe"
    } else {
        # Backup already exists — just remove the new claude.exe
        try {
            Remove-Item -Force -LiteralPath $claudeExe
        } catch {
            # File locked (running process) — rename aside with timestamp
            $ts = Get-Date -Format "yyyyMMddHHmmss"
            Rename-Item -LiteralPath $claudeExe "claude.$ts.exe" -Force -ErrorAction SilentlyContinue
        }
        Write-OK "Removed claude.exe (.cmd now takes priority)"
    }
}


# Write .cmd launcher for both 'claude' and the explicit 'clawcoat' alias.
# Why both:
#  - claude.cmd may be shadowed by a claude.exe higher in PATH
#  - clawcoat.cmd has no .exe competitor, so it always works
#  - User can invoke patched explicitly via `clawcoat` regardless of which
#    binary 'claude' resolves to
foreach ($cmd in @("claude", "clawcoat")) {
    $launcherContent | Set-Content (Join-Path $BinDir "$cmd.cmd") -Encoding Default
}
Write-OK "Commands 'claude' + 'clawcoat' → patched"

# ─── Ensure BinDir is in PATH ─────────────────────────

# Read the RAW registry value, not the expanded one. [Environment]::Get/Set round-trip
# rewrites User PATH as REG_SZ, which permanently kills entries like %JAVA_HOME%\bin —
# they stop expanding and every tool behind them vanishes from PATH in future shells.
# Go through the registry API and preserve the value kind.
$pathKey  = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$userPath = $pathKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$pathKind = $pathKey.GetValueKind('Path')

# Exact segment comparison. `-notlike "*$BinDir*"` interpolates the path into a
# wildcard pattern, so a profile like C:\Users\jo[b] parses [b] as a character class,
# never matches, and every re-run prepends another copy until PATH hits the 2047-char
# registry truncation cliff and is destroyed.
$pathParts = @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_ })
$alreadyOnPath = $pathParts -contains $BinDir.TrimEnd('\')

if (-not $alreadyOnPath) {
    $pathKey.SetValue('Path', "$BinDir;$userPath", $pathKind)
    $env:Path = "$BinDir;$env:Path"
    Write-OK "Added $BinDir to user PATH"
    Write-Dim "(restart terminal for PATH to take effect)"
} else {
    Write-Dim "$BinDir already on user PATH"
}
$pathKey.Close()

# ─── Done ─────────────────────────────────────────────

Write-Host ""
Write-Host "  ClawCoat installed! (theme: $Theme)" -ForegroundColor Green
Write-Host ""
Write-Dim "  claude            — Start patched Claude Code ($Theme logo)"
Write-Dim "  claude.orig       — Run original unpatched Claude Code"
Write-Host ""
Write-Host "  Live theming (no reinstall):" -ForegroundColor White
Write-Dim "    claude theme                  — show current theme + animation"
Write-Dim "    claude theme list             — list palettes (clawcoat/yellow/violet/gruvbox/dracula)"
Write-Dim "    claude theme <name>           — switch palette live"
Write-Dim "    claude theme animate rainbow  — animate the logo (breathe|pulse|wave|rainbow|neon|strobe|fire|ocean)"
Write-Dim "    claude theme edit             — print the JSON path to hand-edit colors"
Write-Dim '    claude theme label "Mythos (5M context) preview"  - rename the model shown in the header'
Write-Host "  Reactive logo (the logo becomes a live indicator):" -ForegroundColor White
Write-Dim "    claude theme reactive project — unique auto-color per repo (hashed from cwd)"
Write-Dim "    claude theme reactive danger  — logo goes RED in --dangerously-skip-permissions"
Write-Dim "    claude theme reactive model   — accent by active model (opus/sonnet/haiku)"
Write-Dim "    claude theme reactive clock   — circadian day/night color"
Write-Dim "    claude theme reactive git     — warns on main / dirty tree"
Write-Dim "  Colors live in ~/.clawcoat/clawcoat.json (re-read on change)."
Write-Host ""
Write-Host "  Statusline (the persistent bottom bar):" -ForegroundColor White
Write-Dim "    model $([char]0x00B7) effort $([char]0x00B7) ctx% $([char]0x00B7) 5h% $([char]0x00B7) git branch $([char]0x00B7) clock"
Write-Dim "    Turn off:  .\install.ps1 -StatuslineOff    Back on:  .\install.ps1 -StatuslineOn"
Write-Host ""
Write-Dim "  Updates: this build does NOT hijack 'claude update'. After Claude"
Write-Dim "  updates itself, re-run this script to re-apply the theme:"
Write-Dim "    .\install.ps1 -Theme $Theme"
Write-Dim "  Remove theme (restore vanilla claude):  .\install.ps1 -Uninstall"
Write-Host ""
Write-Err "  If 'claude' still runs the old version, restart your terminal."
Write-Host ""
Write-Dim "  State:  ~/.clawcoat/  (cli.original.cjs, patch.mjs, clawcoat.json, backups)"
Write-Host ""
Write-Dim "  If 'claude' panics with 'Expected CommonJS module to have a function wrapper',"
Write-Dim "  your Bun lags Anthropic's embedded Bun. Upgrade with one of:"
Write-Dim "    bun upgrade --canary           (if installed from bun.sh)"
Write-Dim "    scoop update bun               (scoop — may lag stable)"
Write-Dim "    irm https://bun.sh/install.ps1 | iex   (re-install latest)"
Write-Host ""
