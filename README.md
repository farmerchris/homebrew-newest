# brew-newest

Homebrew tap providing the `brew newest` external command.

`brew newest` shows newly added formulae and casks based on when their files
were first added to tap git history. It does not show recent version bumps,
modifications, or bottle rebuilds for existing entries.

By default it searches across all installed taps, merges the results, sorts by
add date, and prints the newest entries in a table with:

- name
- add date
- homepage
- description

## Features

- Lists newly added formulae and casks in a readable table.
- Searches all installed taps by default, not just `homebrew/core` and `homebrew/cask`.
- Supports `--tap` to restrict results to one or more specific taps.
- Supports `--formula` and `--cask` to limit the result type.
- Supports `--offline` to avoid network fetches and use local tap history, the
  stored `/tmp` git cache, and local Homebrew API caches only.
- Streams results as metadata becomes available instead of waiting for the full
  result set.
- Uses batched metadata lookups for better performance.
- Supports `-v` for progress output and untruncated table cells.
- Supports `-d` for more detailed subprocess tracing.

## Installation

Tap the repository:

```sh
brew tap farmerchris/newest
```

Then run:

```sh
brew newest
```

If the tap is already installed and you update the repo manually:

```sh
brew untap farmerchris/newest
brew tap farmerchris/newest
```

## Usage

Basic examples:

```sh
brew newest --formula
brew newest --cask --count=20
brew newest --tap=homebrew/core --formula
brew newest --tap=farmerchris/tap --formula
brew newest --tap=homebrew/core,farmerchris/tap --formula
brew newest -v --count=1
brew newest -d --count=1
brew newest --offline
```

Common options:

- `--formula`: show only formulae
- `--cask`: show only casks
- `-n`, `--count=N`: number of entries to print per selected type
- `--tap=TAP[,TAP...]`: restrict search to one or more taps
- `-v`, `--verbose`: show progress and print untruncated homepage/description cells
- `-d`, `--debug`: show more detailed subprocess tracing
- `-o`, `--offline`: avoid network fetches

## Data Sources

The command discovers add dates from git history.

By default it:

- checks local installed tap repositories first
- uses cached/shallow remote git repos for `homebrew/core` and `homebrew/cask` when needed
- uses Homebrew metadata caches and `brew info --json=v2` for homepage and description

In offline mode it:

- uses local installed tap repositories
- reuses the stored `/tmp` bare git cache when present
- uses local Homebrew API cache files for metadata
- does not refresh anything over the network

Use `-v` for step-by-step progress, `-d` for more detailed subprocess
tracing, or `-o`/`--offline` to avoid any network fetches and rely only on
local taps plus cached Homebrew API metadata.

## Notes

- "Newest" means newly added entries, not new upstream releases.
- Results are sorted by the date the formula or cask file was first added to a tap.
- If you restrict with `--tap`, the command only searches those taps.
- Third-party taps are discovered from the locally installed tap checkout.
- The command implementation lives in [cmd/newest.rb](/Users/chris/src/brew-new/cmd/newest.rb).
