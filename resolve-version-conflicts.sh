#!/usr/bin/env bash
# resolve-version-conflicts.sh <file>
#
# Resolves the merge conflicts of ONE manifest file (plugin.json, *.plugin.json,
# marketplace.json) when every conflict hunk consists only of "version" lines on both sides.
# Each such hunk takes the upstream side; the caller sets the final version afterwards
# (version-bump.sh), so the value taken here is only a placeholder.
#
# Exit 0: all hunks were version-only, the file is rewritten without markers.
# Exit 1: some hunk touches anything else (or the file is no manifest, has no markers, is
#         missing): the file is left untouched.
set -euo pipefail

f=${1:?usage: resolve-version-conflicts.sh <file>}
[ -f "$f" ] || exit 1
case "$(basename "$f")" in
  plugin.json | *.plugin.json | marketplace.json) ;;
  *) exit 1 ;;
esac
grep -qE '^<<<<<<< ' "$f" || exit 1

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

awk '
  function isver(s) { return s ~ /^[[:space:]]*"version"[[:space:]]*:/ }
  /^<<<<<<< /  { st = 1; nours = 0; ntheirs = 0; ok = 1; next }
  /^\|\|\|\|\|\|\| / && st == 1 { st = 2; next }
  /^=======$/ && st >= 1 && st <= 2 { st = 3; next }
  /^>>>>>>> / && st == 3 {
    if (nours == 0 || ntheirs == 0) ok = 0
    if (!ok) bad = 1
    for (i = 1; i <= ntheirs; i++) out[++n] = theirs[i]
    st = 0; next
  }
  st == 1 { ours[++nours] = $0; if (!isver($0)) ok = 0; next }
  st == 2 { next }
  st == 3 { theirs[++ntheirs] = $0; if (!isver($0)) ok = 0; next }
  { out[++n] = $0 }
  END {
    if (bad || st != 0) exit 1
    for (i = 1; i <= n; i++) print out[i]
  }' "$f" >"$tmp" || exit 1

# nothing of the markers may survive
! grep -qE '^(<<<<<<<|=======$|>>>>>>>)' "$tmp" || exit 1
cat "$tmp" >"$f"
