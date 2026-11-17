#!/usr/bin/env bash
# sync.sh - pulls the upstream branch into a fork, behind guardrails.
#
# Run from the root of the fork checkout (full history, branch checked out).
# Input (environment):
#   UPSTREAM       owner/repo of the upstream            (required unless UPSTREAM_URL)
#   BRANCH         branch name, same on upstream and fork (default: main)
#   PLUGIN_PATHS   newline-separated paths scanned by capability-diff.sh (default: .)
#   REPO           owner/repo of the fork                (default: $GITHUB_REPOSITORY)
#   UPSTREAM_URL   overrides the clone URL (tests)
#   DRY_RUN=1      decide and print, push and open nothing
#
# Decisions (last line "DECISION=<x>", also written to $GITHUB_OUTPUT):
#   nothing  upstream has nothing new                       -> exit 0
#   push     all guardrails clean, main fast-forwarded      -> exit 0
#   pr       a guardrail fired, sync branch + PR            -> exit 0
# Any error ends non-zero without touching main.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
branch=${BRANCH:-main}
repo=${REPO:-${GITHUB_REPOSITORY:-}}
dry=${DRY_RUN:-0}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir" .fork-guard-run' EXIT

die() { echo "sync: $*" >&2; exit 1; }
decide() {
  echo "DECISION=$1"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "decision=$1" >>"$GITHUB_OUTPUT"
}
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; }

[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "bad branch name: $branch"
if [ -z "${UPSTREAM_URL:-}" ]; then
  [[ ${UPSTREAM:-} =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "UPSTREAM must be owner/repo"
  UPSTREAM_URL=https://github.com/$UPSTREAM.git
fi
[ "$dry" = 1 ] || [ -n "$repo" ] || die "REPO or GITHUB_REPOSITORY required"

paths=()
while IFS= read -r line; do
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [ -z "$line" ] || paths+=("$line")
done <<<"${PLUGIN_PATHS:-}"
[ ${#paths[@]} -gt 0 ] || paths=(.)

[ "$(git rev-parse --abbrev-ref HEAD)" = "$branch" ] || die "checkout is not on $branch"
base=$(git rev-parse HEAD)

# The checkout step leaves a token header for github.com; upstream needs none.
git -c 'http.https://github.com/.extraheader=' fetch -q --no-tags "$UPSTREAM_URL" \
  "+refs/heads/$branch:refs/remotes/sync-upstream/$branch"
up=$(git rev-parse "refs/remotes/sync-upstream/$branch^{commit}")
short=${up:0:12}
sb=sync/$short

if git merge-base --is-ancestor "$up" "$base"; then
  echo "Nothing new upstream ($short is already contained in $branch)."
  summary "Nothing new upstream (\`$short\`)."
  decide nothing
  exit 0
fi

findings=$workdir/findings.md
: >"$findings"
note() { printf '%s\n' "$*" >>"$findings"; }

git checkout -q -B "$sb" "$base"
msg="chore(sync): merge upstream $short"
if ! git merge --no-edit -m "$msg" "$up" >"$workdir/merge.log" 2>&1; then
  conflicts=$(git diff --name-only --diff-filter=U)
  [ -n "$conflicts" ] || { cat "$workdir/merge.log" >&2; die "merge failed without conflicts"; }
  note "- **Merge conflict.** The branch carries the conflict markers as committed text; resolve them before merging. Files:"
  while IFS= read -r c; do note "  - \`$c\`"; done <<<"$conflicts"
  git add -A
  git commit -q -m "$msg (conflict markers committed, do not merge as is)"
fi

# GITHUB_TOKEN may not create or change workflow files; keep the fork's own.
wf=$(git diff --name-only "$base" HEAD -- .github/workflows)
if [ -n "$wf" ]; then
  while IFS= read -r w; do
    if git cat-file -e "$base:$w" 2>/dev/null; then git checkout -q "$base" -- "$w"; else git rm -q -f -- "$w"; fi
  done <<<"$wf"
  git commit -q -m "chore(sync): withhold upstream workflow changes"
  note "- **Upstream changed workflow files.** They are withheld (the token cannot push them); apply by hand if wanted:"
  while IFS= read -r w; do note "  - \`$w\`"; done <<<"$wf"
fi

# (a) the repository's own guard, taken from the pre-merge tree so that upstream
#     cannot swap the checker. It runs against the merged tree.
if git cat-file -e "$base:tools/fork-guard.sh" 2>/dev/null; then
  mkdir -p .fork-guard-run
  git show "$base:tools/fork-guard.sh" >.fork-guard-run/fork-guard.sh
  if gout=$(sh .fork-guard-run/fork-guard.sh 2>&1); then
    echo "fork-guard: ok"
  else
    note "- **tools/fork-guard.sh failed** on the merged tree:"
    note ""
    note '  ````'
    note "$(printf '%s\n' "$gout" | head -n 20 | cut -c1-200 | sed 's/^/  /')"
    note '  ````'
  fi
  rm -rf .fork-guard-run
else
  echo "fork-guard: none in this repository"
fi

# (b) what the merge adds in capabilities
set +e
cout=$(bash "$here/capability-diff.sh" "$base" HEAD "${paths[@]}")
crc=$?
set -e
case $crc in
  0) echo "capability-diff: clean" ;;
  1) note "- **Capability diff found changes:**"; note ""; note "$cout" ;;
  *) die "capability-diff failed (exit $crc)" ;;
esac

if [ ! -s "$findings" ]; then
  if [ "$dry" = 1 ]; then
    echo "DRY RUN: would fast-forward $branch to $(git rev-parse HEAD)"
  else
    # Plain push: git refuses anything that is not a fast-forward of the branch.
    git push origin "HEAD:refs/heads/$branch"
    git push origin --delete "$sb" 2>/dev/null || true
  fi
  git checkout -q "$branch" 2>/dev/null || true
  git branch -q -D "$sb" 2>/dev/null || true
  summary "Merged upstream \`$short\` into \`$branch\` (guardrails clean)."
  decide push
  exit 0
fi

echo "Guardrails fired; the merge goes to $sb for review:"
cat "$findings"

if [ "$dry" = 1 ]; then
  summary "DRY RUN: guardrails fired for \`$short\`."
  decide pr
  exit 0
fi

existing=$(gh pr list -R "$repo" --head "$sb" --state all --json number --jq length)
if [ "$existing" -gt 0 ]; then
  echo "A pull request for $sb exists already; leaving it alone."
  summary "Upstream \`$short\` waits in an existing pull request."
  decide pr
  exit 0
fi

git push --force-with-lease origin "+refs/heads/$sb:refs/heads/$sb"
{
  echo "Upstream \`$short\` was merged into \`$sb\`. At least one guardrail fired, so \`$branch\` stays untouched until someone reviews this."
  echo
  echo "## Findings"
  echo
  cat "$findings"
  echo
  echo "## New upstream commits"
  echo
  echo '````'
  git log --no-merges --format='%h %an: %s' "$base..$up" | head -n 50 | cut -c1-200
  echo '````'
} >"$workdir/body.md"
url=$(gh pr create -R "$repo" --base "$branch" --head "$sb" \
  --title "sync: upstream $short needs review" --body-file "$workdir/body.md")
echo "Opened $url"
summary "Guardrails fired for \`$short\`: $url"
decide pr
