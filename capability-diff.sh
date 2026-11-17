#!/usr/bin/env bash
# capability-diff.sh <base-ref> <head-ref> <plugin_path>...
#
# Compares what a plugin could DO at <base-ref> (the fork's main) with <head-ref>
# (the merge result) and prints one markdown bullet per finding.
#
# Exit 0 = nothing found, 1 = findings (printed on stdout), 2 = tool error.
# Run from the repository root. Fail-closed: anything it cannot read is exit 2.
set -euo pipefail

die() { echo "capability-diff: $*" >&2; exit 2; }

[ $# -ge 3 ] || die "usage: capability-diff.sh <base> <head> <plugin_path>..."
base=$1
head=$2
shift 2
command -v jq >/dev/null || die "jq missing"
git rev-parse --verify -q "$base^{commit}" >/dev/null || die "unknown ref: $base"
git rev-parse --verify -q "$head^{commit}" >/dev/null || die "unknown ref: $head"

out=$(mktemp)
trap 'rm -f "$out"' EXIT
add() { printf '%s\n' "$*" >>"$out"; }

# Added lines that look like new reach (network, process, dynamic code).
CODE_PATTERN='fetch\(|https?://|curl|wget|child_process|spawn\(|spawnSync\(|exec\(|execSync\(|execFile(Sync)?\(|eval\(|new Function|npx|pip3? install|base64 +(-d|--decode)|Bun\.spawn|Bun\.\$|Deno\.run|Deno\.Command|subprocess|os\.system'
# Added front-matter lines that widen what a prompt file may do.
PRIV_PATTERN='(allowed-tools|hooks|permissionMode)[[:space:]]*:|bypassPermissions'
CODE_EXT='js|mjs|cjs|jsx|ts|tsx|mts|cts|py|sh|bash|zsh|ksh|rb|pl|php|go|rs|ps1|bat|cmd|lua|mk'
BINARY_OK='png|jpe?g|gif|webp|ico|bmp|woff2?|ttf|otf|pdf'

tree_has() { git cat-file -e "$1:$2" 2>/dev/null; }

# Added lines of one file as "<new line>:<text>".
added_lines() {
  git diff --no-renames -U0 "$base" "$head" -- "$1" | awk '
    /^@@/ { s = $3; sub(/^\+/, "", s); split(s, a, ","); n = a[1] + 0; next }
    /^\+\+\+/ { next }
    /^\+/ { print n ":" substr($0, 2); n++ }'
}

# Hooks, MCP servers and component lists inside a JSON manifest.
json_caps() {
  local ref=$1 f=$2
  tree_has "$ref" "$f" || { echo null; return 0; }
  git show "$ref:$f" | jq -cS '[.. | objects | to_entries[]
    | select(.key | IN("hooks","mcpServers","lspServers","commands","agents","outputStyles"))]' 2>/dev/null \
    || echo PARSE_ERROR
}

json_pkg() {
  local ref=$1 f=$2
  tree_has "$ref" "$f" || { echo null; return 0; }
  git show "$ref:$f" | jq -cS '{scripts,dependencies,devDependencies,optionalDependencies,peerDependencies,bin}' 2>/dev/null \
    || echo PARSE_ERROR
}

# Lines `file:line: text`, trimmed, for the report.
report_hits() {
  local label=$1 f=$2 hits=$3
  add "- $label \`$f\`:"
  add ''
  add '  ````'
  printf '%s\n' "$hits" | head -n 20 | cut -c1-200 | sed 's/^/  /' >>"$out"
  [ "$(printf '%s\n' "$hits" | wc -l)" -le 20 ] || add '  ... (more lines omitted)'
  add '  ````'
  add ''
}

scan_path() {
  local p=$1 oldmode newmode f st b h hits scan a d
  case "$p" in /*|*..*|'') die "bad plugin_path: $p" ;; esac
  p=${p%/}
  [ -n "$(git ls-tree -r --name-only "$base" -- "$p")$(git ls-tree -r --name-only "$head" -- "$p")" ] \
    || die "plugin_path '$p' exists in neither $base nor $head"

  # Binary files (numstat shows "-" for them).
  while IFS=$'\t' read -r a d f; do
    [ "$a" = "-" ] && [ "$d" = "-" ] || continue
    printf '%s' "$f" | grep -Eqi "\.($BINARY_OK)$" && continue
    tree_has "$head" "$f" || continue
    add "- Binary file added or changed: \`$f\`"
  done < <(git diff --no-renames --numstat "$base" "$head" -- "$p")

  while IFS= read -r -d '' meta && IFS= read -r -d '' f; do
    # meta = ":<oldmode> <newmode> <oldsha> <newsha> <status>"
    read -r oldmode newmode _ _ st <<<"${meta#:}"
    st=${st:0:1}
    [ "$st" = "D" ] && continue
    if [ "$newmode" = "120000" ]; then
      add "- Symlink added or changed: \`$f\`"
    fi
    if [ "$newmode" = "100755" ] && [ "$oldmode" != "100755" ]; then
      add "- File is executable now: \`$f\`"
    fi

    # Definitions of hooks, MCP servers, commands, agents.
    case "$f" in
      */hooks/hooks.json|hooks/hooks.json|*/.mcp.json|.mcp.json)
        add "- Hook or MCP definition added or changed: \`$f\`" ;;
    esac
    case "$f" in
      */plugin.json|plugin.json|*/marketplace.json|marketplace.json)
        b=$(json_caps "$base" "$f"); h=$(json_caps "$head" "$f")
        if [ "$h" = PARSE_ERROR ]; then
          add "- Manifest is not valid JSON: \`$f\`"
        elif [ "$b" != "$h" ]; then
          add "- Manifest changed hooks, MCP servers or component lists: \`$f\`"
        fi ;;
      */package.json|package.json)
        b=$(json_pkg "$base" "$f"); h=$(json_pkg "$head" "$f")
        if [ "$h" = PARSE_ERROR ]; then
          add "- package.json is not valid JSON: \`$f\`"
        elif [ "$b" != "$h" ]; then
          add "- package.json changed scripts, dependencies or bin: \`$f\`"
        fi ;;
    esac
    if [ "$st" = "A" ]; then
      case "/$f" in
        */hooks/*) add "- New hook file: \`$f\`" ;;
      esac
      case "/$f" in
        */commands/*|*/agents/*) add "- New command or agent: \`$f\`" ;;
      esac
    fi

    # Front-matter privileges in prompt files.
    case "/$f" in
      */commands/*.md|*/agents/*.md|*/skills/*.md)
        hits=$(added_lines "$f" | grep -E "^[0-9]+:($PRIV_PATTERN)" || true)
        [ -z "$hits" ] || report_hits "Prompt file widens its privileges:" "$f" "$hits" ;;
    esac

    # Code and scripts: patterns on ADDED lines only.
    scan=0
    if printf '%s' "$f" | grep -Eqi "\.($CODE_EXT)$"; then scan=1; fi
    case "$f" in Makefile|*/Makefile|Dockerfile|*/Dockerfile|package.json|*/package.json) scan=1 ;; esac
    if [ "$scan" = 0 ] && [ "$(git show "$head:$f" 2>/dev/null | head -c 2 || true)" = '#!' ]; then scan=1; fi
    if [ "$scan" = 1 ]; then
      hits=$(added_lines "$f" | grep -iE "$CODE_PATTERN" || true)
      [ -z "$hits" ] || report_hits "Added lines with network, process or dynamic-code patterns in" "$f" "$hits"
    fi
  done < <(git diff --no-renames --raw -z "$base" "$head" -- "$p")
}

for p in "$@"; do scan_path "$p"; done

# Fork-owned guard and workflows, independent of the plugin paths.
while IFS= read -r -d '' meta && IFS= read -r -d '' f; do
  add "- Upstream changed a fork-owned control file: \`$f\`"
done < <(git diff --no-renames --raw -z "$base" "$head" -- tools/fork-guard.sh .github/workflows)

if [ -s "$out" ]; then
  cat "$out"
  exit 1
fi
exit 0
