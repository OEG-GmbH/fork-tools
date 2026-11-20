#!/usr/bin/env bash
# hook-text-diff.sh <base-ref> <head-ref> <list-file>
#
# Lists the files of the fork's hook-text path list that differ between <base-ref> and
# <head-ref>: files whose content a hook puts in front of the model. The list is read from
# <base-ref> (the tree before the merge), so upstream cannot shorten it in the same change.
# One git pathspec per line, glob style (`hooks/**`, `**/hooks.json`); `#` starts a comment.
#
# Exit 0 no listed file changed, 1 listed files changed (bullets on stdout),
# 3 the fork has no list file at <base-ref>, 2 error.
set -euo pipefail

die() { echo "hook-text-diff: $*" >&2; exit 2; }
[ $# -eq 3 ] || die "usage: hook-text-diff.sh <base> <head> <list-file>"
base=$1
head=$2
list=$3
git rev-parse --verify -q "$base^{commit}" >/dev/null || die "unknown ref: $base"
git rev-parse --verify -q "$head^{commit}" >/dev/null || die "unknown ref: $head"
git cat-file -e "$base:$list" 2>/dev/null || exit 3

specs=()
while IFS= read -r line; do
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [ -z "$line" ] || specs+=(":(glob)$line")
done < <(git show "$base:$list")
[ ${#specs[@]} -gt 0 ] || die "$list lists no path (an empty list protects nothing)"

n=0
while IFS=$'\t' read -r st f; do
  [ -n "$f" ] || continue
  case $st in A) what=added ;; D) what=deleted ;; *) what=changed ;; esac
  printf -- '- Hook text %s: `%s`\n' "$what" "$f"
  n=$((n + 1))
done < <(git diff --no-renames --name-status "$base" "$head" -- "${specs[@]}")
[ "$n" -eq 0 ] || exit 1
exit 0
