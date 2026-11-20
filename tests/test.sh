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


# ---------------------------------------------------------------- hook-text-diff.sh
ht_repo() {
  rm -rf "$T/ht"; mkdir -p "$T/ht/tools" "$T/ht/hooks" "$T/ht/skills" "$T/ht/x/hooks"; cd "$T/ht" || exit 1
  git init -q -b main
  printf '# hook texts\nhooks/**\n**/hooks/**\n**/hooks.json   # any depth\n' >tools/hook-text-paths.txt
  echo a >hooks/a.ts; echo d >skills/doc.md; echo h >x/hooks/h.ts; echo '{}' >x/hooks.json
  git add -A; git commit -qm base
}
ht_run() { git add -A; git commit -qm change; bash "$root/hook-text-diff.sh" HEAD~1 HEAD tools/hook-text-paths.txt >"$T/ht.out" 2>"$T/ht.err"; echo $?; }
ht_repo; echo more >>skills/doc.md; check "ht: change in a doc outside the list -> 0" 0 "$(ht_run)"
ht_repo; echo more >>hooks/a.ts; check "ht: change in a listed file -> 1" 1 "$(ht_run)"
check "ht: ... the file is named" yes "$(grep -q 'hooks/a.ts' "$T/ht.out" && echo yes || echo no)"
ht_repo; echo more >>x/hooks/h.ts; check "ht: ** matches nested hooks/ -> 1" 1 "$(ht_run)"
ht_repo; echo more >>x/hooks.json; check "ht: **/hooks.json matches at depth -> 1" 1 "$(ht_run)"
ht_repo; echo new >hooks/new.ts; check "ht: added file in a listed dir -> 1" 1 "$(ht_run)"
ht_repo; git rm -q hooks/a.ts; check "ht: deleted listed file -> 1" 1 "$(ht_run)"
ht_repo; sed -i '/^hooks/d' tools/hook-text-paths.txt; echo more >>hooks/a.ts
check "ht: the list is read from the base tree (upstream cannot shorten it) -> 1" 1 "$(ht_run)"
ht_repo; git rm -q tools/hook-text-paths.txt; git commit -qm nolist; echo more >>hooks/a.ts; git add -A; git commit -qm c2
check "ht: no list at the base -> 3" 3 "$(bash "$root/hook-text-diff.sh" HEAD~1 HEAD tools/hook-text-paths.txt >/dev/null 2>&1; echo $?)"
ht_repo; printf '# nothing\n' >tools/hook-text-paths.txt; git add -A; git commit -qm empty; echo more >>hooks/a.ts; git add -A; git commit -qm c3
check "ht: an empty list is an error (2)" 2 "$(bash "$root/hook-text-diff.sh" HEAD~1 HEAD tools/hook-text-paths.txt >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------- version-conflict.sh
vc() { printf '%s' "$1" >"$T/plugin.json"; cp "$T/plugin.json" "$T/plugin.orig"; bash "$root/version-conflict.sh" "$T/plugin.json" >/dev/null 2>&1; echo $?; }
VONLY=$'{\n<<<<<<< HEAD\n  "version": "1.0.0-fork.1",\n=======\n  "version": "1.1.0",\n>>>>>>> up\n  "name": "p"\n}\n'
MIXED=$'{\n<<<<<<< HEAD\n  "version": "1.0.0-fork.1",\n  "description": "d"\n=======\n  "version": "1.1.0",\n  "description": "d2"\n>>>>>>> up\n  "name": "p"\n}\n'
TWO=$'{\n<<<<<<< HEAD\n  "version": "1",\n=======\n  "version": "2",\n>>>>>>> up\n  "x": 1,\n<<<<<<< HEAD\n  "a": 1\n=======\n  "a": 2\n>>>>>>> up\n}\n'
check "vc: version-only hunk -> 0" 0 "$(vc "$VONLY")"
check "vc: ... file untouched (read-only)" yes "$(cmp -s "$T/plugin.json" "$T/plugin.orig" && echo yes || echo no)"
check "vc: hunk with another line -> 1" 1 "$(vc "$MIXED")"
check "vc: one version hunk + one other hunk -> 1" 1 "$(vc "$TWO")"
printf 'no markers\n' >"$T/plugin.json"; check "vc: no markers -> 1" 1 "$(bash "$root/version-conflict.sh" "$T/plugin.json" >/dev/null 2>&1; echo $?)"
printf '<<<<<<< a\n"version": "1"\n=======\n"version": "2"\n>>>>>>> b\n' >"$T/readme.txt"; check "vc: not a manifest name -> 1" 1 "$(bash "$root/version-conflict.sh" "$T/readme.txt" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------- sync.sh (gh is a stub)
mkdir -p "$T/stub"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
d=$STUB_DIR
echo "$*" >>"$d/calls.log"
title=""; head=""
case "$1 $2" in
  "pr list") cat "$d/prs.json" ;;
  "pr view") echo "https://example.invalid/pr/1" ;;
  "pr create" | "pr edit")
    while [ $# -gt 0 ]; do
      case $1 in --title) title=$2; shift ;; --body-file) cp "$2" "$d/body.md"; shift ;; --head) head=$2; shift ;; esac
      shift
    done
    echo "$title" >"$d/title.txt"
    [ -z "$head" ] || printf '[{"number":1,"headRefName":"%s"}]' "$head" >"$d/prs.json"
    echo "https://example.invalid/pr/1" ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/stub/gh"
export STUB_DIR="$T/stubdata"

sy_fresh() {
  rm -rf "$T/up" "$T/origin.git" "$T/fork" "$STUB_DIR"; mkdir -p "$STUB_DIR"; echo '[]' >"$STUB_DIR/prs.json"; : >"$STUB_DIR/calls.log"
  git init -q -b main "$T/up"; cd "$T/up" || exit 1
  mkdir -p plug/hooks plug/.claude-plugin
  echo 'export const a = 1' >plug/hooks/a.ts
  echo 'readme' >README.md
  printf '{\n  "name": "p",\n  "version": "1.0.0",\n  "description": "d"\n}\n' >plug/.claude-plugin/plugin.json
  git add -A; git commit -qm init
  git clone -q --bare "$T/up" "$T/origin.git"
  git clone -q "$T/origin.git" "$T/fork"
  cd "$T/fork" || exit 1
  mkdir -p tools; echo '// fork-patch: keep callit()' >>plug/hooks/a.ts
  sed -i 's/"version": "1.0.0"/"version": "1.0.0-fork.1"/' plug/.claude-plugin/plugin.json
  printf 'plug/hooks/**\n**/hooks.json\n' >tools/hook-text-paths.txt
  cat >tools/fork-guard.sh <<'G'
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
grep -q 'fork-patch: keep' plug/hooks/a.ts || { echo "fork-guard: marker missing" >&2; exit 1; }
[ "$(grep -rho 'callit(' plug | wc -l)" -eq 1 ] || { echo "fork-guard: callit( must occur exactly once" >&2; exit 1; }
echo "fork-guard: ok"
G
  git add -A; git commit -qm "fork patch"; git push -q origin HEAD:main
}
sy_up() { cd "$T/up" || exit 1; "$@"; git add -A; git commit -qm "upstream change"; }
sy_run() { # prints the decision; the main of the origin is recorded before and after
  cd "$T/fork" || exit 1
  git checkout -q main; git fetch -q origin; git reset -q --hard origin/main; git clean -qfd
  MAIN_BEFORE=$(git -C "$T/origin.git" rev-parse main)
  PATH="$T/stub:$PATH" UPSTREAM_URL="$T/up" PLUGIN_PATHS=plug REPO=x/y "${SYNC_ENV[@]}" bash "$root/sync.sh" >"$T/sync.out" 2>&1
  rc=$?
  MAIN_AFTER=$(git -C "$T/origin.git" rev-parse main)
  printf '%s\n%s\n' "$MAIN_BEFORE" "$MAIN_AFTER" >"$T/main.rec"   # the caller runs us in $(...)
  [ $rc -eq 0 ] || { echo "rc$rc"; return; }
  sed -n 's/^DECISION=//p' "$T/sync.out"
}
SYNC_ENV=(env)
main_same() { check "$1: main of the origin unchanged" "$(sed -n 1p "$T/main.rec")" "$(sed -n 2p "$T/main.rec")"; }
body_has() { grep -q -F -- "$1" "$STUB_DIR/body.md" && echo yes || echo no; }
branches() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/upstream-sync/*'; }
title() { cat "$STUB_DIR/title.txt"; }

sy_fresh; check "sync: nothing new -> nothing" nothing "$(sy_run)"; main_same "sync: nothing new"
check "sync: ... no branch, no pr call" 00 "$(branches | wc -l)$(grep -c 'pr create' "$STUB_DIR/calls.log")"

# a harmless commit becomes a PR, not a merge
sy_fresh; sy_up sh -c 'echo more >>README.md'
check "sync: harmless README commit -> pr-created (no auto-merge)" pr-created "$(sy_run)"; main_same "sync: harmless commit"
check "sync: ... one upstream-sync branch exists" 1 "$(branches | wc -l)"
check "sync: ... the branch contains the upstream commit" yes "$(git -C "$T/origin.git" merge-base --is-ancestor "$(git -C "$T/up" rev-parse HEAD)" "$(branches | head -n1)" && echo yes || echo no)"
check "sync: ... the branch is named upstream-sync/<date>" "upstream-sync/$(date -u +%F)" "$(branches)"
check "sync: ... pr targets main" yes "$(grep -q -- '--base main' "$STUB_DIR/calls.log" && echo yes || echo no)"
check "sync: ... title is plain" "sync: upstream $(git -C "$T/up" rev-parse --short=12 HEAD)" "$(title)"
check "sync: ... body: no hits" yes "$(body_has '| Guardrail hits | 0 |')"
check "sync: ... body lists the upstream commit" yes "$(body_has 'upstream change')"
check "sync: ... body lists the changed file" yes "$(body_has 'README.md')"
check "sync: ... body: fork-guard passed" yes "$(body_has 'fork-guard on the merged tree | passed')"

# guardrail hits show up in the text
sy_fresh; sy_up sh -c 'mkdir -p plug/lib; echo "fetch(\"https://example.com\")" >plug/lib/n.ts'
check "sync: new fetch( -> pr-created" pr-created "$(sy_run)"; main_same "sync: fetch("
check "sync: ... body shows the pattern hit" yes "$(body_has 'plug/lib/n.ts')"
check "sync: ... hit counted" yes "$(body_has '| Guardrail hits | 1 |')"
check "sync: ... not a hook text change" no "$(grep -q 'hook texts changed' "$STUB_DIR/title.txt" && echo yes || echo no)"

# the hook-text rule: a change to a listed file is flagged, a change to an unlisted file is not
sy_fresh; sy_up sh -c 'sed -i "1s/.*/export const a = 2/" plug/hooks/a.ts'
check "sync: listed hook file changed -> pr-created" pr-created "$(sy_run)"; main_same "sync: hook text"
check "sync: ... title says so" "sync: upstream $(git -C "$T/up" rev-parse --short=12 HEAD) [hook texts changed]" "$(title)"
check "sync: ... body names the file" yes "$(body_has 'Hook text changed: `plug/hooks/a.ts`')"
check "sync: ... summary row" yes "$(body_has '| Hook texts changed | YES |')"
sy_fresh; sy_up sh -c 'mkdir -p plug/lib; echo "export const c = 1" >plug/lib/c.ts'
check "sync: unlisted file changed -> pr-created" pr-created "$(sy_run)"; main_same "sync: unlisted file"
check "sync: ... no hook text marker" no "$(grep -q 'hook texts changed' "$STUB_DIR/title.txt" && echo yes || echo no)"
check "sync: ... summary row says no" yes "$(body_has '| Hook texts changed | no |')"

# fork-guard result on the merged tree
sy_fresh; sy_up sh -c 'mkdir -p plug/lib; echo "callit()" >plug/lib/c.ts'
check "sync: clean merge that breaks the patch -> pr-created" pr-created "$(sy_run)"; main_same "sync: guard"
check "sync: ... title flags fork-guard" "sync: upstream $(git -C "$T/up" rev-parse --short=12 HEAD) [fork-guard failed]" "$(title)"
check "sync: ... body has the guard message" yes "$(body_has 'callit( must occur exactly once')"

# conflicts, with version conflicts labelled
sy_fresh; sy_up sh -c 'sed -i "s/\"version\": \"1.0.0\"/\"version\": \"1.1.0\"/" plug/.claude-plugin/plugin.json'
check "sync: version-only manifest conflict -> pr-created" pr-created "$(sy_run)"; main_same "sync: version conflict"
check "sync: ... labelled as version lines only" yes "$(body_has 'plugin.json` (version lines only)')"
sy_fresh; sy_up sh -c 'sed -i "s/\"version\": \"1.0.0\"/\"version\": \"1.1.0\"/; s/\"description\": \"d\"/\"description\": \"d2\"/" plug/.claude-plugin/plugin.json'
check "sync: manifest conflict beyond the version line -> pr-created" pr-created "$(sy_run)"
check "sync: ... labelled as not only version lines" yes "$(body_has 'not only version lines')"
sy_fresh; sy_up sh -c 'echo line >>plug/hooks/a.ts'
check "sync: conflict in code -> pr-created" pr-created "$(sy_run)"; main_same "sync: code conflict"
check "sync: ... listed as merge conflict" yes "$(body_has 'Merge conflict')"

# workflow files are withheld
sy_fresh; sy_up sh -c 'mkdir -p .github/workflows; echo "on: push" >.github/workflows/up.yml'
check "sync: upstream workflow -> pr-created" pr-created "$(sy_run)"; main_same "sync: workflow"
check "sync: ... body names it" yes "$(body_has '.github/workflows/up.yml')"
check "sync: ... the file is not on the pushed branch" no "$(git -C "$T/origin.git" ls-tree -r --name-only "$(branches | head -n1)" | grep -q '^.github/workflows/up.yml$' && echo yes || echo no)"

# the open pull request is updated, not duplicated
sy_fresh; sy_up sh -c 'echo one >>README.md'
check "pr: first run creates" pr-created "$(sy_run)"; b1=$(branches); sha1=$(git -C "$T/origin.git" rev-parse "$b1")
check "pr: same state again -> pr-unchanged" pr-unchanged "$(sy_run)"; main_same "pr: unchanged"
check "pr: ... branch not rewritten" "$sha1" "$(git -C "$T/origin.git" rev-parse "$b1")"
sy_up sh -c 'echo two >>README.md'
check "pr: newer upstream -> pr-updated" pr-updated "$(sy_run)"; main_same "pr: updated"
check "pr: ... still one branch, same name" "$b1" "$(branches)"
check "pr: ... branch moved" yes "$([ "$sha1" != "$(git -C "$T/origin.git" rev-parse "$b1")" ] && echo yes || echo no)"
check "pr: ... branch has the newer upstream commit" yes "$(git -C "$T/origin.git" merge-base --is-ancestor "$(git -C "$T/up" rev-parse HEAD)" "$b1" && echo yes || echo no)"
check "pr: ... body was edited, no second create" 1 "$(grep -c 'pr create' "$STUB_DIR/calls.log")"
check "pr: ... edit call happened" 1 "$(grep -c 'pr edit' "$STUB_DIR/calls.log")"
# a person pushed to the sync branch: the sync leaves it alone
cd "$T" && rm -rf human && git clone -q "$T/origin.git" human && cd human && git checkout -q "$b1" \
  && GIT_AUTHOR_EMAIL=h@example.invalid GIT_COMMITTER_EMAIL=h@example.invalid git commit -q --allow-empty -m "human fix" && git push -q origin "HEAD:refs/heads/$b1"
humansha=$(git -C "$T/origin.git" rev-parse "$b1")
sy_up sh -c 'echo three >>README.md'
check "pr: person's commit on the branch -> pr-human-edits" pr-human-edits "$(sy_run)"; main_same "pr: human edits"
check "pr: ... branch untouched" "$humansha" "$(git -C "$T/origin.git" rev-parse "$b1")"

# upstream default branch is resolved when none is given; other base branch is honoured
sy_fresh; cd "$T/up" && git branch -q -m trunk && echo more >>README.md && git add -A && git commit -qm c
check "sync: upstream default branch 'trunk' is found" pr-created "$(sy_run)"
sy_fresh; sy_up sh -c 'echo more >>README.md'
cd "$T/fork" && git checkout -q -b sync-test/base && git push -q origin HEAD:refs/heads/sync-test/base && git checkout -q main
SYNC_ENV=(env BASE=sync-test/base)
cd "$T/fork" && git checkout -q sync-test/base
MAIN_BEFORE=$(git -C "$T/origin.git" rev-parse main)
PATH="$T/stub:$PATH" UPSTREAM_URL="$T/up" PLUGIN_PATHS=plug REPO=x/y BASE=sync-test/base bash "$root/sync.sh" >"$T/sync.out" 2>&1
MAIN_AFTER=$(git -C "$T/origin.git" rev-parse main)
printf '%s\n%s\n' "$MAIN_BEFORE" "$MAIN_AFTER" >"$T/main.rec"
check "sync: BASE=<test branch> targets that branch" yes "$(grep -q -- '--base sync-test/base' "$STUB_DIR/calls.log" && echo yes || echo no)"; main_same "sync: test base"
SYNC_ENV=(env)

# dry run writes nothing
sy_fresh; sy_up sh -c 'echo more >>README.md'
SYNC_ENV=(env DRY_RUN=1); check "sync: DRY_RUN -> pr-created decision" pr-created "$(sy_run)"; SYNC_ENV=(env)
check "sync: ... but no branch on the origin" 0 "$(branches | wc -l)"

# structure: the single push in sync.sh is the guarded one, and it refuses other refs
check "sync: exactly one git push in sync.sh" 1 "$(grep -c 'git push' "$root/sync.sh")"
pf=$(sed -n '/^push_sync_branch()/,/^}/p' "$root/sync.sh")
check "sync: push_sync_branch refuses main" 9 "$(bash -c "die() { echo \"\$*\" >&2; exit 9; }; $pf; push_sync_branch main ''" >/dev/null 2>&1; echo $?)"
check "sync: push_sync_branch lets the sync namespace through to git" yes "$(bash -c "die() { exit 9; }; git() { echo PUSH; }; $pf; push_sync_branch upstream-sync/x ''" 2>&1 | grep -q PUSH && echo yes || echo no)"

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
