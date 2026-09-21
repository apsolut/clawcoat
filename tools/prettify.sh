#!/usr/bin/env bash
# prettify.sh — Biome-unminify Claude Code's extracted cli.original.cjs into a
# readable, multi-line map for finding hook sites (technique from cc-antidebug).
#
# Usage:  sh tools/prettify.sh [input.cjs] [output.js]
# Default input:  ~/.clawcoat/cli.original.cjs.bak   (the clean extracted bundle)
# Default output: tools/cli.pretty.js                     (gitignored; a dev map, NOT deployed)
#
# We keep patching the MINIFIED live file; this pretty copy is only our search map.
set -e

IN="${1:-$HOME/.clawcoat/cli.original.cjs.bak}"
OUT="${2:-$(dirname "$0")/cli.pretty.js}"

[ -f "$IN" ] || { echo "input not found: $IN"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$IN" "$TMP/cli.js"
cat > "$TMP/biome.json" <<'JSON'
{
  "$schema": "https://biomejs.dev/schemas/2.5.9/schema.json",
  "files": { "maxSize": 104857600, "ignoreUnknown": true },
  "formatter": { "enabled": true, "formatWithErrors": true, "indentStyle": "space", "indentWidth": 2, "lineWidth": 120 },
  "linter": { "enabled": false }
}
JSON

echo "prettifying $(du -h "$IN" | cut -f1) bundle with Biome ..."
# `|| true` used to swallow every Biome failure, so a crash (or a missing npx)
# copied the untouched one-line bundle out and still reported success — you would
# only notice when grep -n gave you line 1 for everything. Keep stderr, and check
# the result actually got split into lines.
if ! ( cd "$TMP" && npx --yes @biomejs/biome format --write cli.js >/dev/null ); then
  echo "biome format failed — see the error above" >&2
  exit 1
fi
LINES=$(wc -l < "$TMP/cli.js")
if [ "$LINES" -lt 1000 ]; then
  echo "biome produced only $LINES lines — the bundle was not reformatted." >&2
  echo "refusing to write $OUT" >&2
  exit 1
fi
cp "$TMP/cli.js" "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1))"
echo "search it with real line numbers, e.g.:  grep -n 'monitor cost' \"$OUT\""
