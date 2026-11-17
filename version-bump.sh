#!/usr/bin/env bash
# version-bump.sh <base-ref> <upstream-ref> <plugin_path>...
#
# Claude Code updates an installed plugin only when `version` in its manifest changes, so a
# sync that takes upstream content must also change the version. Run in the merged working
# tree (HEAD = merge result). For every plugin root below the given paths whose content differs
# from <base-ref>:
#
#   upstream bumped its version (cu != core of the fork's version):
#       fork patched (FORK_PATCHED=1)  -> <cu>-fork.1
#       fork not patched               -> <cu>
#   upstream changed content, same version:
#       <cu>-fork.<n+1>   (n = current fork suffix of the fork's version, 0 if none)
#
# All version-bearing manifests of the root are set to the same value, and so is the matching
# entry of every marketplace.json that lists the root by `source` and carries a version.
# Nothing is committed here.
#
# Exit 0 ok (see stdout for what changed), 2 error, 3 a root was skipped (manifest is not
# valid JSON, e.g. unresolved conflict markers): the caller reports that.
set -euo pipefail

die() { echo "version-bump: $*" >&2; exit 2; }

[ $# -ge 3 ] || die "usage: version-bump.sh <base> <upstream> <plugin_path>..."
base=$1
up=$2
shift 2
patched=${FORK_PATCHED:-0}
command -v jq >/dev/null || die "jq missing"
git rev-parse --verify -q "$base^{commit}" >/dev/null || die "unknown ref: $base"
git rev-parse --verify -q "$up^{commit}" >/dev/null || die "unknown ref: $up"

MANIFESTS=(.claude-plugin/plugin.json plugin.json .codex-plugin/plugin.json .factory-plugin/plugin.json .qoder-plugin/plugin.json kimi.plugin.json)
MARKETS=(.claude-plugin/marketplace.json .agents/plugins/marketplace.json .factory-plugin/marketplace.json)
JQ_VER='if (.version | type) == "string" then .version else empty end'

join() { if [ "$1" = . ]; then printf '%s\n' "$2"; else printf '%s/%s\n' "$1" "$2"; fi; }
norm() { local s=${1#./}; s=${s%/}; [ -n "$s" ] || s=.; printf '%s\n' "$s"; }

# version of a manifest in a ref ("" when absent or without a version); 1 = invalid JSON
ver_ref() {
  git cat-file -e "$1:$2" 2>/dev/null || return 0
  git show "$1:$2" | jq -r "$JQ_VER"
}
ver_file() { jq -r "$JQ_VER" "$1"; }

core() { printf '%s\n' "$1" | sed -E 's/-fork\.[0-9]+$//'; }
forkn() { local n; n=$(printf '%s\n' "$1" | sed -nE 's/.*-fork\.([0-9]+)$/\1/p'); printf '%s\n' "${n:-0}"; }

declare -A seen
roots=()
add_root() { [ -z "${seen[$1]:-}" ] || return 0; seen[$1]=1; roots+=("$1"); }

for p in "$@"; do
  case "$p" in /* | *..* | '') die "bad plugin_path: $p" ;; esac
  p=${p%/}
  add_root "$p"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$f" = ".claude-plugin/plugin.json" ]; then add_root .; else add_root "${f%/.claude-plugin/plugin.json}"; fi
  done < <(git ls-files -- "$p" | grep -E '(^|/)\.claude-plugin/plugin\.json$' || true)
done

skipped=0
for R in "${roots[@]}"; do
  git diff --quiet "$base" HEAD -- "$R" && continue   # nothing taken from upstream here

  mf=()
  bad=0
  for m in "${MANIFESTS[@]}"; do
    f=$(join "$R" "$m")
    [ -f "$f" ] || continue
    if ! v=$(ver_file "$f" 2>/dev/null); then bad=1; break; fi
    [ -z "$v" ] || mf+=("$f")
  done
  if [ "$bad" = 1 ]; then
    echo "SKIP $R: a manifest is not valid JSON"
    skipped=1
    continue
  fi
  [ ${#mf[@]} -gt 0 ] || continue

  vb=""
  vu=""
  for f in "${mf[@]}"; do
    vb=$(ver_ref "$base" "$f") || die "$base:$f is not valid JSON"
    if [ -n "$vb" ]; then vu=$(ver_ref "$up" "$f") || die "$up:$f is not valid JSON"; break; fi
  done
  [ -n "$vb" ] || continue   # plugin is new in this merge: take upstream as it is

  cb=$(core "$vb")
  [ -n "$vu" ] || vu=$cb
  cu=$(core "$vu")
  if [ "$cu" != "$cb" ]; then
    if [ "$patched" = 1 ]; then target="$cu-fork.1"; else target=$cu; fi
  else
    target="$cu-fork.$(($(forkn "$vb") + 1))"
  fi
  echo "ROOT $R: fork $vb, upstream $vu -> $target"

  for f in "${mf[@]}"; do
    cur=$(ver_file "$f")
    [ "$cur" != "$target" ] || continue
    old=$(printf '%s' "$cur" | sed 's/[.+]/\\&/g')
    sed -i -E "0,/\"version\"[[:space:]]*:[[:space:]]*\"$old\"/s//\"version\": \"$target\"/" "$f"
    [ "$(ver_file "$f")" = "$target" ] || die "could not set the version in $f"
  done

  for m in "${MARKETS[@]}"; do
    f=$m
    [ -f "$f" ] || continue
    before=$(jq -c --arg r "$R" --arg t "$target" '
      [.plugins[]? | (.source | if type == "string" then (sub("^\\./"; "") | sub("/$"; "") | if . == "" then "." else . end) else null end) as $s
       | {source: (.source | tostring), version: (if $s == $r and (.version | type) == "string" then $t else .version end)}]' "$f") \
      || die "$f is not valid JSON"
    cur=$(jq -c '[.plugins[]? | {source: (.source | tostring), version}]' "$f")
    [ "$before" != "$cur" ] || continue
    awk -v r="$R" -v t="$target" '
      function norm(s) { sub(/^\.\//, "", s); sub(/\/$/, "", s); return s == "" ? "." : s }
      /"source"[[:space:]]*:[[:space:]]*"/ {
        s = $0; sub(/^.*"source"[[:space:]]*:[[:space:]]*"/, "", s); sub(/".*$/, "", s)
        hit = (norm(s) == r)
      }
      hit && /"version"[[:space:]]*:[[:space:]]*"/ {
        sub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"version\": \"" t "\""); hit = 0
      }
      { print }' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    after=$(jq -c '[.plugins[]? | {source: (.source | tostring), version}]' "$f") || die "$f no longer valid JSON"
    [ "$after" = "$before" ] || die "marketplace edit in $f did not give the expected result"
    echo "MARKETPLACE $f: $R -> $target"
  done
done

[ "$skipped" = 0 ] || exit 3
exit 0
