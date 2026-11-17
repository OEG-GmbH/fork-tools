#!/usr/bin/env bash
# Local tests for capability-diff.sh and sync.sh against throw-away git repos.
# Every guardrail is held against a failing case AND a passing case.
#   bash tests/test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
fail=0
pass=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1 (expected '$2', got '$3')"; fi
}

# ---------------------------------------------------------------- capability-diff
cd_repo() { # builds $T/cd with a base commit; files from the base set
  rm -rf "$T/cd"; mkdir -p "$T/cd/plug/hooks" "$T/cd/other"; cd "$T/cd" || exit 1
  git init -q -b main
  echo '{"name":"p","version":"1"}' >plug/plugin.json
  echo 'export const a = 1' >plug/hooks/a.ts
  echo '{"name":"p","scripts":{"test":"x"},"dependencies":{"a":"1"}}' >plug/package.json
  echo 'readme' >plug/README.md
  echo 'x' >other/o.ts
  git add -A; git commit -qm base
}
cd_run() { # args: paths; prints exit code
  git add -A; git commit -qm change
  bash "$root/capability-diff.sh" HEAD~1 HEAD "$@" >"$T/cd.out" 2>"$T/cd.err"; echo $?
}

cd_repo; echo 'note' >>plug/README.md; check "cd: docs-only change is clean" 0 "$(cd_run plug)"
cd_repo; echo 'see https://example.com/docs' >>plug/README.md; check "cd: url in markdown is not scanned" 0 "$(cd_run plug)"
cd_repo; echo 'const b = 2' >>plug/hooks/a.ts; check "cd: harmless code line is clean" 0 "$(cd_run plug)"
cd_repo; echo '// fetchy' >>plug/hooks/a.ts; check "cd: fetchy is not fetch(" 0 "$(cd_run plug)"
cd_repo; echo 'fetch("https://example.com")' >>other/o.ts; check "cd: code outside plugin_paths is not scanned" 0 "$(cd_run plug)"
cd_repo; echo 'fetch("https://example.com")' >>other/o.ts; check "cd: same line inside plugin_paths ('.') fires" 1 "$(cd_run .)"

# every pattern of the spec, one at a time (each must fire in a code file)
i=0
while IFS= read -r line; do
  i=$((i + 1)); cd_repo; printf '%s\n' "$line" >>plug/hooks/a.ts
  check "cd: pattern fires: $line" 1 "$(cd_run plug)"
done <<'PATTERNS'
await fetch(url)
const u = "http://x"
const u = "https://x"
run curl -s x
run wget x
import cp from "node:child_process"
spawn("ls")
exec("ls")
eval(code)
const f = new Function("a")
npx some-tool
pip install requests
echo aGk= | base64 -d
Bun.spawn(["ls"])
Deno.run({cmd: []})
execSync("ls")
subprocess.run(x)
PATTERNS

# only ADDED lines count: a removed fetch( must not fire
cd_repo; echo 'fetch("https://old")' >>plug/hooks/a.ts; git add -A; git commit -qm pre
echo 'export const a = 2' >plug/hooks/a.ts
check "cd: removing a fetch( line is clean" 0 "$(cd_run plug)"

cd_repo; echo '#!/bin/sh' >plug/run; echo 'curl x' >>plug/run; check "cd: shebang file without extension is scanned" 1 "$(cd_run plug)"
cd_repo; echo '{"hooks":{}}' >plug/hooks/hooks.json; check "cd: new hooks/hooks.json fires" 1 "$(cd_run plug)"
cd_repo; echo '{"mcpServers":{}}' >plug/.mcp.json; check "cd: new .mcp.json fires" 1 "$(cd_run plug)"
cd_repo; echo '{"name":"p","version":"2","hooks":{"X":[]}}' >plug/plugin.json; check "cd: plugin.json gains hooks" 1 "$(cd_run plug)"
cd_repo; echo '{"name":"p","version":"2"}' >plug/plugin.json; check "cd: plugin.json version bump is clean" 0 "$(cd_run plug)"
cd_repo; echo '{"name":"p","mcpServers":{"s":{"command":"x"}}}' >plug/plugin.json; check "cd: plugin.json gains mcpServers" 1 "$(cd_run plug)"
cd_repo; echo '{broken' >plug/plugin.json; check "cd: plugin.json broken fires" 1 "$(cd_run plug)"
cd_repo; mkdir plug/commands; echo '# c' >plug/commands/new.md; check "cd: new command fires" 1 "$(cd_run plug)"
cd_repo; mkdir plug/agents; echo '# a' >plug/agents/new.md; check "cd: new agent fires" 1 "$(cd_run plug)"
cd_repo; echo 'export const z = 1' >plug/hooks/new.ts; check "cd: new hook file fires" 1 "$(cd_run plug)"
cd_repo; mkdir -p plug/skills/s; printf -- '---\nallowed-tools: Bash\n---\n' >plug/skills/s/SKILL.md; check "cd: skill front-matter allowed-tools fires" 1 "$(cd_run plug)"
cd_repo; mkdir -p plug/skills/s; printf -- '---\nname: s\n---\ntext\n' >plug/skills/s/SKILL.md; check "cd: plain new skill is clean" 0 "$(cd_run plug)"
cd_repo; echo '{"name":"p","scripts":{"test":"x","postinstall":"y"},"dependencies":{"a":"1"}}' >plug/package.json; check "cd: package.json new script fires" 1 "$(cd_run plug)"
cd_repo; echo '{"name":"p","version":"9","scripts":{"test":"x"},"dependencies":{"a":"1"}}' >plug/package.json; check "cd: package.json version bump is clean" 0 "$(cd_run plug)"
cd_repo; printf 'ELF\0\1\2\3\0\0' >plug/blob.bin; check "cd: new binary fires" 1 "$(cd_run plug)"
cd_repo; printf '\x89PNG\r\n\x1a\n\0\0\0' >plug/p.png; check "cd: new png is clean" 0 "$(cd_run plug)"
cd_repo; ln -s /etc/passwd plug/link; check "cd: new symlink fires" 1 "$(cd_run plug)"
cd_repo; chmod +x plug/hooks/a.ts; check "cd: exec bit set fires" 1 "$(cd_run plug)"
cd_repo; mkdir -p .github/workflows; echo 'on: push' >.github/workflows/x.yml; check "cd: workflow change fires" 1 "$(cd_run plug)"
cd_repo; mkdir tools; echo 'true' >tools/fork-guard.sh; check "cd: fork-guard change fires" 1 "$(cd_run plug)"
cd_repo; check "cd: unknown plugin path is an error (2)" 2 "$(git commit -q --allow-empty -m e; bash "$root/capability-diff.sh" HEAD~1 HEAD nope >/dev/null 2>&1; echo $?)"
cd_repo; check "cd: bad ref is an error (2)" 2 "$(bash "$root/capability-diff.sh" nope HEAD plug >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------- sync.sh
# fresh upstream + fork; the fork carries a patch marker and a guard
sy_fresh() {
  rm -rf "$T/up" "$T/origin.git" "$T/fork"
  git init -q -b main "$T/up"; cd "$T/up" || exit 1
  mkdir -p plug/hooks
  echo 'export const a = 1' >plug/hooks/a.ts
  echo 'readme' >README.md
  echo '{"name":"p"}' >plug/plugin.json
  git add -A; git commit -qm init
  git clone -q --bare "$T/up" "$T/origin.git"
  git clone -q "$T/origin.git" "$T/fork"
  cd "$T/fork" || exit 1
  mkdir -p tools; echo '// fork-patch: keep callit()' >>plug/hooks/a.ts
  cat >tools/fork-guard.sh <<'G'
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
grep -q 'fork-patch: keep' plug/hooks/a.ts || { echo "fork-guard: marker missing" >&2; exit 1; }
[ "$(grep -rho 'callit(' plug | wc -l)" -eq 1 ] || { echo "fork-guard: callit( must occur exactly once" >&2; exit 1; }
echo ok
G
  git add -A; git commit -qm "fork patch"; git push -q origin HEAD:main
}
sy_up() { cd "$T/up" || exit 1; "$@"; git add -A; git commit -qm "upstream change"; }
sy_run() { # prints decision
  cd "$T/fork" || exit 1
  git checkout -q main; git fetch -q origin; git reset -q --hard origin/main
  UPSTREAM_URL="$T/up" PLUGIN_PATHS=plug DRY_RUN=1 bash "$root/sync.sh" >"$T/sync.out" 2>&1
  rc=$?
  [ $rc -eq 0 ] || { echo "rc$rc"; return; }
  sed -n 's/^DECISION=//p' "$T/sync.out"
}

sy_fresh; check "sync: nothing new" nothing "$(sy_run)"
sy_fresh; sy_up sh -c 'echo more >>README.md'; check "sync: harmless README commit -> push" push "$(sy_run)"
sy_fresh; sy_up sh -c 'echo "fetch(\"https://example.com\")" >>plug/hooks/b.ts'; check "sync: new fetch( -> pr" pr "$(sy_run)"
sy_fresh; sy_up sh -c 'sed -i "/fork-patch/d" plug/hooks/a.ts; echo x >>plug/hooks/a.ts'; check "sync: marker removed -> pr (conflict or guard)" pr "$(sy_run)"
# a clean merge that still breaks the fork patch: only the guard can see it
sy_fresh
sy_up sh -c 'mkdir -p plug/lib; echo "callit()" >plug/lib/c.ts'
check "sync: clean merge that breaks the patch -> pr" pr "$(sy_run)"
grep -q 'fork-guard.sh failed' "$T/sync.out" && r=guard || r=other
check "sync: ... and it is the guard that says so" guard "$r"
grep -q 'Capability diff' "$T/sync.out" && r=fired || r=quiet
check "sync: ... while capability-diff stays quiet" quiet "$r"
sy_fresh
sy_up sh -c 'mkdir -p plug/lib; echo "// callit" >plug/lib/c.ts'
check "sync: same shape, patch intact -> push (guard negative control)" push "$(sy_run)"
sy_fresh; sy_up sh -c 'echo "{\"hooks\":{}}" >plug/hooks/hooks.json'; check "sync: new hooks.json -> pr" pr "$(sy_run)"
sy_fresh; sy_up sh -c 'echo "line" >>plug/hooks/a.ts'; check "sync: conflicting change to the patched file -> pr" pr "$(sy_run)"
grep -q 'Merge conflict' "$T/sync.out" && r=ok || r=no; check "sync: ... reported as conflict" ok "$r"
sy_fresh; sy_up sh -c 'echo "fetch(\"https://x\")" >>other.ts'; check "sync: fetch( outside plugin_paths -> push (documented limit)" push "$(sy_run)"
sy_fresh; sy_up sh -c 'mkdir -p .github/workflows; echo "on: push" >.github/workflows/up.yml'; check "sync: upstream workflow -> pr" pr "$(sy_run)"
git -C "$T/fork" ls-tree -r --name-only HEAD | grep -q '^.github/workflows/up.yml$' && r=leaked || r=withheld
check "sync: upstream workflow file is withheld from the branch" withheld "$r"
# real (non-dry) push into a local origin: main advances by fast-forward, no sync branch is left
sy_fresh; sy_up sh -c 'echo more >>README.md'
cd "$T/fork" && git checkout -q main && before=$(git rev-parse origin/main)
UPSTREAM_URL="$T/up" PLUGIN_PATHS=plug REPO=x/y bash "$root/sync.sh" >"$T/sync.out" 2>&1
after=$(git -C "$T/origin.git" rev-parse main)
check "sync: real push moved origin main" yes "$([ "$before" != "$after" ] && echo yes || echo no)"
check "sync: origin main contains the upstream commit" yes "$(git -C "$T/origin.git" merge-base --is-ancestor "$(git -C "$T/up" rev-parse HEAD)" main && echo yes || echo no)"
check "sync: origin main is a descendant of the old main (fast-forward)" yes "$(git -C "$T/origin.git" merge-base --is-ancestor "$before" main && echo yes || echo no)"
check "sync: no sync branch left on origin" 0 "$(git -C "$T/origin.git" branch --list 'sync/*' | wc -l)"
check "sync: second run is nothing" nothing "$(sy_run)"

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
