# AGENTS.md

This repository implements the `brew newest` external command.

## Purpose

- Show newly added formulae and casks.
- "Newest" means first introduction of a formula/cask file in tap git history.
- It does not mean latest upstream release or latest modification.

## Current Behavior Decisions

- Add dates come from git history, not from the Homebrew API.
- Entry classification is based on git diff status, not commit message text.
- Count `A` as a new entry.
- Count `R` and `C` as new entries, using the destination path as the new item.
- Exclude `M` updates.
- Sort results by discovered add date descending.
- With no `--tap`, show official results; if `homebrew/core` or `homebrew/cask` is installed locally, use it directly instead of cloning a remote cache.
- With `--tap`, show only the selected tap(s) from local git history.
- With `--all`, scan all installed taps from local git history and also include the official `homebrew/core`/`homebrew/cask` results.
- With `--force-homebrew-api`, skip local official taps and use the remote git cache from GitHub.
- Never update installed taps as part of `brew newest`.

## Important History Caveat

- Shallow git history can produce false positives for `git log --diff-filter=A` or equivalent add detection.
- In a shallow repository, commits listed in the git `shallow` file are boundary commits and cannot be trusted to classify old files as true additions.
- The command must ignore candidate additions from shallow-boundary commits.
- Remote fallback should deepen history when needed, but "enough rows" alone is not a reliable stopping condition if shallow-boundary false positives are present.
- Existing remote caches must not be refreshed with `--depth=200`, because that re-shallows previously deepened caches and forces the command to deepen again on later runs.

## Implementation Notes

- Main implementation: [cmd/newest.rb](/Users/chris/src/brew-new/cmd/newest.rb)
- Current parser uses:
  - `git log --diff-filter=ARC --name-status`
  - `__BREW_NEWEST_COMMIT__` marker for commit SHA
  - `__BREW_NEWEST_DATE__` marker for author date
- The parser:
  - reads commit markers and dates
  - skips entries from shallow-boundary commits
  - accepts only `A`, `R`, and `C`
  - maps `R`/`C` to the destination path
- Remote cache strategy:
  - if `homebrew/core` or `homebrew/cask` is installed locally as a real git repo, scan it directly instead of cloning a remote cache
  - when the official tap is not installed locally, fall back to cloning a bare cache from GitHub
  - initial clone uses depth 200
  - existing cache refresh uses plain `git fetch` and preserves current depth
  - bare official caches must fetch `refs/heads/main` into the local `refs/heads/main` ref explicitly; fetching only `main` can leave the cache stale while updating only `FETCH_HEAD`
  - deepening increases by 200 at a time up to max depth 2000
  - default mode refreshes only the dedicated official caches, not installed taps
- Performance strategy:
  - share `brew --repo` lookups across formula/cask work instead of recomputing them per thread
  - load installed tap names once when `--all` needs a full local scan
  - cache shallow-boundary commit sets per repo
  - resolve git dirs from `.git` metadata when possible instead of spawning `git rev-parse`
  - skip local `git log` when the relevant `Formula/` or `Casks/` directory is absent
  - scan local taps with a small worker pool (`LOCAL_SCAN_WORKERS = 4`)
  - limit local git log to 200 commits initially, deepening in steps of 200 up to 2000

## Maintenance Rule

- Keep this file up to date whenever behavior, assumptions, edge cases, or debugging findings change.
- If `brew newest` output looks suspicious, inspect shallow-history behavior first before changing sort or display logic.
