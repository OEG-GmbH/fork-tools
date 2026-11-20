#!/usr/bin/env bash
# version-conflict.sh <file>
#
# Read-only classifier for ONE conflicted manifest file (plugin.json, *.plugin.json,
# marketplace.json): are all conflict hunks made of "version" lines only?
# Used to label conflicts in the pull request; it never changes the file.
#
# Exit 0: every hunk consists of version lines only (a pure version conflict).
# Exit 1: anything else (another line in a hunk, not a manifest, no markers, missing file).
set -euo pipefail

f=${1:?usage: version-conflict.sh <file>}
[ -f "$f" ] || exit 1
case "$(basename "$f")" in
  plugin.json | *.plugin.json | marketplace.json) ;;
  *) exit 1 ;;
esac
grep -qE '^<<<<<<< ' "$f" || exit 1

awk '
  function isver(s) { return s ~ /^[[:space:]]*"version"[[:space:]]*:/ }
  /^<<<<<<< /  { st = 1; nours = 0; ntheirs = 0; ok = 1; next }
  /^\|\|\|\|\|\|\| / && st == 1 { st = 2; next }
  /^=======$/ && st >= 1 && st <= 2 { st = 3; next }
  /^>>>>>>> / && st == 3 {
    if (nours == 0 || ntheirs == 0 || !ok) bad = 1
    st = 0; next
  }
  st == 1 { nours++; if (!isver($0)) ok = 0; next }
  st == 2 { next }
  st == 3 { ntheirs++; if (!isver($0)) ok = 0; next }
  END { exit (bad || st != 0) ? 1 : 0 }' "$f"
