#!/usr/bin/env bash
# sync.sh - proposes the upstream default branch to a fork as a pull request. It never
# merges and never pushes to the fork's base branch: the only ref it writes is
# upstream-sync/<date>, and a person merges the pull request.
#
# Run from the root of the fork checkout (full history, base branch checked out).
# Input (environment):
#   UPSTREAM         owner/repo of the upstream            (required unless UPSTREAM_URL)
#   BRANCH           upstream branch (default: the upstream's default branch)
#   BASE             fork branch the pull request targets  (default: main)
#   PLUGIN_PATHS     newline-separated paths scanned by capability-diff.sh (default: .)
#   HOOK_PATHS_FILE  the fork's hook-text path list         (default: tools/hook-text-paths.txt)
#   REPO             owner/repo of the fork                (default: $GITHUB_REPOSITORY)
#   UPSTREAM_URL     overrides the clone URL (tests)
#   DRY_RUN=1        build and print everything, push and open nothing
#
# Result (last line "DECISION=<x>", also written to $GITHUB_OUTPUT with pr_url):
#   nothing          upstream has nothing new
#   pr-created       new branch and pull request
#   pr-updated       the open sync pull request got the newer upstream state
#   pr-unchanged     the open sync pull request already carries upstream and the base
#   pr-human-edits   the open sync branch has commits by a person; left alone
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
base_branch=${BASE:-main}
up_branch=${BRANCH:-}
hook_list=${HOOK_PATHS_FILE:-tools/hook-text-paths.txt}
repo=${REPO:-${GITHUB_REPOSITORY:-}}
dry=${DRY_RUN:-0}
bot_name='github-actions[bot]'
bot_email='41898282+github-actions[bot]@users.noreply.github.com'
workdir=$(mktemp -d)
trap 'rm -rf "$workdir" .fork-guard-run' EXIT

die() { echo "sync: $*" >&2; exit 1; }
decide() {
  echo "DECISION=$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "decision=$1" >>"$GITHUB_OUTPUT"
    [ -z "${2:-}" ] || echo "pr_url=$2" >>"$GITHUB_OUTPUT"
  fi
}
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; }

# The one place that writes to the remote. Anything but a sync branch is refused.
push_sync_branch() { # branch expected-remote-sha (empty = must not exist yet)
  case "$1" in upstream-sync/*) ;; *) die "refusing to push '$1': only upstream-sync/* may be written" ;; esac
  git push "--force-with-lease=refs/heads/$1:$2" origin "+refs/heads/$1:refs/heads/$1"
}

[[ $base_branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "bad base branch name: $base_branch"
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

[ "$(git rev-parse --abbrev-ref HEAD)" = "$base_branch" ] || die "checkout is not on $base_branch"
export GIT_AUTHOR_NAME=$bot_name GIT_COMMITTER_NAME=$bot_name
export GIT_AUTHOR_EMAIL=$bot_email GIT_COMMITTER_EMAIL=$bot_email
base=$(git rev-parse HEAD)

# The checkout step leaves a token header for github.com; upstream needs none.
ugit() { git -c 'http.https://github.com/.extraheader=' "$@"; }
if [ -z "$up_branch" ]; then
  up_branch=$(ugit ls-remote --symref "$UPSTREAM_URL" HEAD | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')
  [ -n "$up_branch" ] || die "could not resolve the upstream default branch"
fi
ugit fetch -q --no-tags "$UPSTREAM_URL" "+refs/heads/$up_branch:refs/remotes/sync-upstream/$up_branch"
up=$(git rev-parse "refs/remotes/sync-upstream/$up_branch^{commit}")
short=${up:0:12}

if git merge-base --is-ancestor "$up" "$base"; then
  echo "Nothing new upstream ($short is already contained in $base_branch)."
  summary "Nothing new upstream (\`$short\`)."
  decide nothing
  exit 0
fi

# An open sync pull request is updated, otherwise a new branch is cut.
pr_num=""
sb=""
if [ "$dry" != 1 ]; then
  prs=$(gh pr list -R "$repo" --base "$base_branch" --state open --limit 100 --json number,headRefName)
  pr_num=$(jq -r '[.[] | select(.headRefName | startswith("upstream-sync/"))][0].number // empty' <<<"$prs")
  sb=$(jq -r '[.[] | select(.headRefName | startswith("upstream-sync/"))][0].headRefName // empty' <<<"$prs")
fi
remote_sha=""
if [ -n "$sb" ]; then
  git fetch -q origin "+refs/heads/$sb:refs/remotes/origin/$sb"
  remote_sha=$(git rev-parse "refs/remotes/origin/$sb")
  if [ -n "$(git log --first-parent --format='%ae' "$base..$remote_sha" 2>/dev/null | grep -v -F -x "$bot_email" || true)" ] \
    && ! git merge-base --is-ancestor "$remote_sha" "$base"; then
    echo "$sb carries commits by a person; not touching it."
    summary "Pull request #$pr_num carries commits by a person; the sync leaves it alone."
    decide pr-human-edits
    exit 0
  fi
  if git merge-base --is-ancestor "$up" "$remote_sha" && git merge-base --is-ancestor "$base" "$remote_sha"; then
    echo "Pull request #$pr_num already carries upstream $short and the current $base_branch."
    summary "Pull request #$pr_num is up to date (\`$short\`)."
    decide pr-unchanged
    exit 0
  fi
else
  sb=upstream-sync/$(date -u +%F)
  if [ "$dry" != 1 ] && [ -n "$(git ls-remote --heads origin "refs/heads/$sb")" ]; then sb=$sb-$short; fi
fi

findings=$workdir/findings.md
: >"$findings"
note() { printf '%s\n' "$*" >>"$findings"; }
nhits=0

git checkout -q -B "$sb" "$base"
msg="chore(sync): merge upstream $short"
if ! git merge --no-edit -m "$msg" "$up" >"$workdir/merge.log" 2>&1; then
  conflicts=$(git diff --name-only --diff-filter=U)
  [ -n "$conflicts" ] || { cat "$workdir/merge.log" >&2; die "merge failed without conflicts"; }
  note "- **Merge conflict.** The branch carries the conflict markers as committed text; resolve them before merging. Files:"
  nhits=$((nhits + 1))
  while IFS= read -r c; do
    kind=""
    if bash "$here/version-conflict.sh" "$c"; then kind=" (version lines only)"; fi
    case "$(basename "$c")" in plugin.json | *.plugin.json | marketplace.json) kind="${kind:- (manifest, not only version lines)}" ;; esac
    note "  - \`$c\`$kind"
  done <<<"$conflicts"
  git add -A
  git commit -q -m "$msg (conflict markers committed, do not merge as is)"
fi

git diff --no-renames --name-status "$base" HEAD >"$workdir/files.txt"

# GITHUB_TOKEN may not create or change workflow files; keep the fork's own.
wf=$(git diff --name-only "$base" HEAD -- .github/workflows)
if [ -n "$wf" ]; then
  while IFS= read -r w; do
    if git cat-file -e "$base:$w" 2>/dev/null; then git checkout -q "$base" -- "$w"; else git rm -q -f -- "$w"; fi
  done <<<"$wf"
  git commit -q -m "chore(sync): withhold upstream workflow changes"
  note "- **Upstream changed workflow files.** They are withheld from this branch (the workflow token cannot push them); apply by hand if wanted:"
  nhits=$((nhits + 1))
  while IFS= read -r w; do note "  - \`$w\`"; done <<<"$wf"
fi

# (1) hook texts: files a hook puts in front of the model
set +e
hout=$(bash "$here/hook-text-diff.sh" "$base" HEAD "$hook_list")
hrc=$?
set -e
hook_hit=0
case $hrc in
  0) ;;
  1) hook_hit=1; nhits=$((nhits + 1)); note "- **Hook texts changed** (list: \`$hook_list\`):"; note ""; note "$hout" ;;
  3) note "- This fork has no hook-text path list (\`$hook_list\`); changes to hook texts are not flagged." ;;
  *) die "hook-text-diff failed (exit $hrc)" ;;
esac

# (2) new capabilities and patterns
set +e
cout=$(bash "$here/capability-diff.sh" "$base" HEAD "${paths[@]}")
crc=$?
set -e
case $crc in
  0) ;;
  1) nhits=$((nhits + 1))
     note "- **Capability diff found changes:**"; note ""
     if [ "${#cout}" -gt 20000 ]; then cout="${cout:0:20000}"$'\n'"... (cut at 20000 characters; run capability-diff.sh for the rest)"; fi
     note "$cout" ;;
  *) die "capability-diff failed (exit $crc)" ;;
esac

# (3) the fork's own guard, taken from the pre-merge tree so that upstream cannot swap
#     the checker; it runs against the merged tree.
guard_state=none
guard_out=""
if git cat-file -e "$base:tools/fork-guard.sh" 2>/dev/null; then
  mkdir -p .fork-guard-run
  git show "$base:tools/fork-guard.sh" >.fork-guard-run/fork-guard.sh
  if guard_out=$(sh .fork-guard-run/fork-guard.sh 2>&1); then guard_state=passed; else guard_state=FAILED; nhits=$((nhits + 1)); fi
  rm -rf .fork-guard-run
fi

ncommits=$(git rev-list --no-merges --count "$base..$up")
nfiles=$(wc -l <"$workdir/files.txt" | tr -d ' ')
[ -s "$findings" ] || note "None."
{
  echo "Upstream \`$short\` (\`$up_branch\`) merged into \`$sb\`. **Nothing was merged into \`$base_branch\`:** a person reviews and merges this pull request."
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Upstream commits | $ncommits |"
  echo "| Files changed | $nfiles |"
  echo "| Guardrail hits | $nhits |"
  echo "| Hook texts changed | $([ "$hook_hit" = 1 ] && echo YES || echo no) |"
  echo "| fork-guard on the merged tree | $guard_state |"
  echo
  echo "## Guardrail findings"
  echo
  cat "$findings"
  echo
  echo "## fork-guard on the merged tree"
  echo
  case $guard_state in
    none) echo "This fork has no \`tools/fork-guard.sh\`." ;;
    passed) echo "Passed:"; echo; echo '````'; printf '%s\n' "$guard_out" | head -n 20 | cut -c1-200; echo '````' ;;
    FAILED) echo "**Failed:**"; echo; echo '````'; printf '%s\n' "$guard_out" | head -n 20 | cut -c1-200; echo '````' ;;
  esac
  echo
  echo "## Upstream commits"
  echo
  echo '````'
  git log --no-merges --format='%h %an: %s' "$base..$up" | head -n 100 | cut -c1-200
  [ "$ncommits" -le 100 ] || echo "... ($ncommits commits in total)"
  echo '````'
  echo
  echo "## Changed files"
  echo
  echo '````'
  head -n 300 "$workdir/files.txt" | cut -c1-200
  [ "$nfiles" -le 300 ] || echo "... ($nfiles files in total)"
  echo '````'
} >"$workdir/body.md"

title="sync: upstream $short"
[ "$hook_hit" = 0 ] || title="$title [hook texts changed]"
[ "$guard_state" != FAILED ] || title="$title [fork-guard failed]"

if [ "$dry" = 1 ]; then
  cat "$workdir/body.md"
  echo "DRY RUN: would push $sb and open a pull request titled: $title"
  decide pr-created
  exit 0
fi

push_sync_branch "$sb" "$remote_sha"
if [ -n "$pr_num" ]; then
  gh pr edit "$pr_num" -R "$repo" --title "$title" --body-file "$workdir/body.md"
  url=$(gh pr view "$pr_num" -R "$repo" --json url --jq .url)
  echo "Updated $url"
  summary "Updated the sync pull request for \`$short\`: $url"
  decide pr-updated "$url"
else
  url=$(gh pr create -R "$repo" --base "$base_branch" --head "$sb" --title "$title" --body-file "$workdir/body.md")
  echo "Opened $url"
  summary "Opened the sync pull request for \`$short\`: $url"
  decide pr-created "$url"
fi
