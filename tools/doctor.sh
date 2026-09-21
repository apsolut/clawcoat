#!/usr/bin/env bash
# doctor.sh — hook health-check. Run after a Claude Code update to see which
# ClawCoat hooks still match the current bundle vs. drifted (need re-finding).
# It dry-runs the real patcher against a clean copy of the extracted bundle and
# checks the CORE feature hooks. Non-core misses (light-theme/ANSI variants) are
# expected and not flagged.
set -e
D="${1:-$HOME/.clawcoat}"
BAK="$D/cli.original.cjs.bak"
[ -f "$BAK" ] || { echo "no bundle at $BAK — install first"; exit 1; }
[ -f "$D/patch.mjs" ] || { echo "no patch.mjs at $D"; exit 1; }

VER=$(grep -aoE 'Version:[[:space:]]*[0-9.]+' "$BAK" | head -1)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$BAK" "$TMP/cli.original.cjs"; cp "$D/patch.mjs" "$TMP/patch.mjs"

echo "clawcoat hook doctor  ·  bundle $VER"
echo "----------------------------------------------"
OUT="$(cd "$TMP" && node patch.mjs --dry-run 2>&1 || true)"

# CORE hooks that MUST match on any supported version (feature -> patch-name substring)
CORE=(
  "Model label -> configurable (welcome header pae)|model name (Mythos)"
  "Header org + widget (welcome banner)|org + header widget"
  "Logo row A -> getter|static logo"
  "Welcome logo r1E -> getter|welcome logo"
  "Spinner words -> configurable|spinner words"
  "Thinking spinner glyph -> configurable|spinner glyph"
  "Input prompt symbol -> configurable|input glyph"
  "Logo background black -> configurable|logo background"
)

drift=0
for entry in "${CORE[@]}"; do
  name="${entry%%|*}"; label="${entry##*|}"
  # patcher prints "  OK <name> (N)" on match, "  >> <name> (not in this version)" on 0-match.
  # A feature can ship several version-specific patterns (e.g. the spinner glyph has a
  # pre-2.1.240 shape and a frame-array shape); it is healthy if ANY of them matched, so
  # search every line for the name rather than judging on the first one found.
  line="$(printf '%s\n' "$OUT" | grep -F "$name" | grep "OK " | head -1)"
  if [ -n "$line" ]; then
    n="$(printf '%s' "$line" | grep -oE '\([0-9]+\)' | tr -d '()')"
    printf "  \033[32mOK\033[0m   %-22s (%s)\n" "$label" "$n"
  else
    printf "  \033[31mDRIFT\033[0m %-22s <- re-find in tools/cli.pretty.js\n" "$label"
    drift=$((drift+1))
  fi
done

echo "----------------------------------------------"
tot=$(printf '%s\n' "$OUT" | grep -cE "^  OK " || true)
echo "total patches applied (dry-run): $tot"
if [ "$drift" -eq 0 ]; then
  echo "all core hooks OK."
else
  echo "$drift core hook(s) DRIFTED. Regenerate the map:  sh tools/prettify.sh"
  echo "then grep tools/cli.pretty.js for the feature and update install.ps1's pattern."
fi
