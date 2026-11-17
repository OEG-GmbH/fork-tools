# fork-tools

Keeps forks of third-party plugin repositories on the newest upstream state, and keeps risky
upstream changes out of the fork's default branch until a person has looked at them.

## How it works

A reusable workflow (`.github/workflows/upstream-sync.yml`) fetches the upstream branch.

- Nothing new compared with the fork: the run ends green.
- Otherwise the upstream commit is merged into `sync/<sha12>` and checked:
  1. the fork's own `tools/fork-guard.sh`, if present (taken from the pre-merge tree, run against the merged tree),
  2. `capability-diff.sh` for every path in `plugin_paths`,
  3. merge conflicts.
- All clean: fast-forward push to the branch, sync branch removed. Never a force push on the branch.
- Anything found: the branch is pushed and a pull request `sync: upstream <sha12> needs review` lists the findings.

Changes to `.github/workflows/` are never pushed (the workflow token is not allowed to); they are
reverted on the sync branch and listed in the pull request.

## Caller

```yaml
name: upstream-sync
on:
  schedule:
    - cron: '17 4 * * *'
  workflow_dispatch:
permissions: {}
jobs:
  sync:
    permissions:
      contents: write
      pull-requests: write
    uses: <owner>/fork-tools/.github/workflows/upstream-sync.yml@<full commit sha>
    with:
      upstream: owner/repo
      plugin_paths: |
        plugins/example
```

The fork needs "Allow GitHub Actions to create and approve pull requests" for the pull request path.

## What `capability-diff.sh` reports

Per plugin path, comparing the fork's branch with the merge result:

- added or changed `hooks/hooks.json`, `.mcp.json`; `hooks`, `mcpServers`, `lspServers`, `commands`, `agents`, `outputStyles` changed inside `plugin.json` / `marketplace.json`
- new files below `hooks/`, `commands/`, `agents/`
- `package.json` changes in scripts, dependencies, bin
- front matter lines `allowed-tools:`, `hooks:`, `permissionMode:` or `bypassPermissions` added to prompt files
- binary files other than images, fonts, pdf; symlinks; files that became executable
- ADDED lines of code and script files (by extension, `Makefile`, `Dockerfile`, `package.json`, or a `#!` first line) matching:
  `fetch(`, `http://`, `https://`, `curl`, `wget`, `child_process`, `spawn(`, `spawnSync(`, `exec(`, `execSync(`, `execFile(`, `eval(`, `new Function`, `npx`, `pip install`, `base64 -d`, `Bun.spawn`, `Bun.$`, `Deno.run`, `Deno.Command`, `subprocess`, `os.system`
- anywhere in the repository: changes to `tools/fork-guard.sh` and `.github/workflows/`

Exit 0 clean, 1 findings, 2 error (an unreadable ref or unknown path fails the job, nothing is pushed).

## Limits

This is a tripwire for the obvious, not a review.

- Pattern matching sees text, not behaviour: obfuscated or assembled strings (`"fe" + "tch"`), `import()` of remote code, or a changed argument to an existing call are not caught. `exec(` also matches `RegExp.exec(`; false positives only cost a pull request.
- Only added lines are inspected, only inside `plugin_paths`, and not in Markdown. Prose that instructs a model (skill and command bodies) is not analysed.
- Changed lockfiles and vendored dependencies are not read.
- The fork's own guard decides whether fork patches survive; this tool does not know them.

## Tests

`bash tests/test.sh` builds throw-away repositories and holds every guardrail against a failing and a passing case.
