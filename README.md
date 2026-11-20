# fork-tools

Proposes the newest upstream state of a fork as a pull request, with the risky parts of the change
listed in the pull request text. **It never merges and never pushes to the fork's base branch**:
the only ref it writes is `upstream-sync/<date>`, and a person merges the pull request.

## How it works

A reusable workflow (`.github/workflows/upstream-sync.yml`) is called from a small workflow in each
fork (schedule daily, plus `workflow_dispatch`). `sync.sh` does the work:

1. Fetch the upstream default branch. Nothing new compared with the base branch: the run ends green.
2. Otherwise merge it into `upstream-sync/<date>` (a conflict is committed as markers and listed).
3. Open a pull request against the base branch. If a sync pull request is already open, its branch
   is rebuilt from the current base and the newest upstream and its text is replaced (nothing changes
   if it already carries both). A branch with commits by a person is left alone.
4. Push only through `push_sync_branch`, which refuses every ref outside `upstream-sync/*`.

The pull request text lists the upstream commits, the changed files, the guardrail findings and the
result of the fork's `tools/fork-guard.sh` on the merged tree (taken from the pre-merge tree, so a
merge cannot swap the checker). Changes to `.github/workflows/` are left out of the branch (the
workflow token may not push them) and listed.

## Guardrails (all of them only report)

| Check | Script | Reports |
|---|---|---|
| hook texts | `hook-text-diff.sh` | files of the fork's list `tools/hook-text-paths.txt` that differ (title gets `[hook texts changed]`) |
| capabilities and patterns | `capability-diff.sh` | see below |
| fork patches | the fork's `tools/fork-guard.sh` | pass/fail on the merged tree (title gets `[fork-guard failed]`) |
| conflicts | `version-conflict.sh` | conflicted files; manifests whose conflict is only `version` lines are labelled |

`tools/hook-text-paths.txt` lives in the fork and is versioned with it: one git glob per line
(`hooks/**`, `**/hooks.json`), `#` starts a comment. The list is read from the tree before the merge,
so an upstream change cannot shorten it. A fork without the file gets a note in the pull request.

### `capability-diff.sh`

Per plugin path, comparing the base branch with the merge result:

- added or changed `hooks/hooks.json`, `.mcp.json`; `hooks`, `mcpServers`, `lspServers`, `commands`, `agents`, `outputStyles` changed inside `plugin.json` / `marketplace.json`
- new files below `hooks/`, `commands/`, `agents/`
- `package.json` changes in scripts, dependencies, bin
- front matter lines `allowed-tools:`, `hooks:`, `permissionMode:` or `bypassPermissions` added to prompt files
- binary files other than images, fonts, pdf; symlinks; files that became executable
- ADDED lines of code and script files (by extension, `Makefile`, `Dockerfile`, `package.json`, or a `#!` first line) matching:
  `fetch(`, `http://`, `https://`, `curl`, `wget`, `child_process`, `spawn(`, `spawnSync(`, `exec(`, `execSync(`, `execFile(`, `eval(`, `new Function`, `npx`, `pip install`, `base64 -d`, `Bun.spawn`, `Bun.$`, `Deno.run`, `Deno.Command`, `subprocess`, `os.system`
- anywhere in the repository: changes to `tools/fork-guard.sh` and `.github/workflows/`

## Caller

```yaml
name: upstream-sync
on:
  schedule:
    - cron: '17 4 * * *'
  workflow_dispatch:
    inputs:
      base:
        description: Branch the pull request targets (default main)
        default: main
permissions: {}
jobs:
  sync:
    permissions:
      contents: write
      pull-requests: write
    uses: <owner>/fork-tools/.github/workflows/upstream-sync.yml@<full commit sha>
    with:
      upstream: owner/repo
      base: ${{ inputs.base || 'main' }}
      plugin_paths: |
        plugins/example
```

The fork needs "Allow GitHub Actions to create and approve pull requests". The token needs
`contents: write` to push the sync branch; GitHub cannot scope that to one branch, so the guarantee
that `main` stays untouched is `push_sync_branch` plus the tests, not the token.

To try the workflow against an artificially old state, push a branch whose content is older than
upstream and dispatch with `base` set to it: the pull request targets that branch.

## Limits

This is a tripwire for the obvious, not a review.

- Pattern matching sees text, not behaviour: obfuscated or assembled strings (`"fe" + "tch"`), `import()` of remote code, or a changed argument to an existing call are not caught. `exec(` also matches `RegExp.exec(`; false positives only cost reading time.
- Only added lines are inspected, only inside `plugin_paths`, and not in Markdown. Prose that instructs a model is only flagged when it sits in the hook-text list.
- Changed lockfiles and vendored dependencies are not read.
- The PR text is cut at fixed sizes (findings 20000 characters, commits 100, files 300).
- A closed sync pull request is not reopened; the next run with new upstream commits opens a new one.

## Tests

`bash tests/test.sh` builds throw-away repositories (and a stub `gh`) and holds every guardrail
against a failing and a passing case; each sync case also checks that the origin's `main` did not move.
