# brew-newest

Homebrew tap providing the `brew newest` external command.

`brew newest` shows newly added formulae and casks based on when their files
were first added to tap git history. It does not show recent version bumps,
modifications, or bottle rebuilds for existing entries.

It prints the newest entries in a table with:

- name
- add date
- homepage
- description

## Features

- Lists newly added formulae and casks in a readable table.
- Uses official Homebrew history by default.
- Supports `--tap` to restrict results to specific taps.
- Supports `--all` to also scan installed local taps.
- Supports `--formula` and `--cask` to limit the result type.
- Supports `--offline` to avoid network fetches.
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
brew newest --all --formula
brew newest --tap=farmerchris/tap --formula
brew newest --tap=farmerchris/tap,homebrew-cask-fonts --formula
brew newest -v --count=1
brew newest -d --count=1
brew newest --offline
```

Common options:

- `--formula`: show only formulae
- `--cask`: show only casks
- `-n`, `--count=N`: number of entries to print per selected type
- `--all`: also scan installed local taps
- `--tap=TAP[,TAP...]`: restrict search to one or more taps
- `-v`, `--verbose`: show progress and print untruncated homepage/description cells
- `-d`, `--debug`: show more detailed subprocess tracing
- `-o`, `--offline`: avoid network fetches

## How It Works

- Add dates come from git history.
- By default, `brew newest` uses dedicated cached history for `homebrew/core` and `homebrew/cask`.
- `--tap` searches only the selected installed tap checkouts.
- `--all` keeps the official cached history and also scans installed local taps.
- Installed taps are never updated automatically.
- In offline mode, the command avoids network refreshes and uses whatever history is already available locally or in the cache.
- If local-tap metadata is missing in offline mode, the row is still shown and missing fields fall back to `-`.

Use `-v` for step-by-step progress, `-d` for more detailed subprocess tracing,
or `-o`/`--offline` to avoid any network fetches.

## Notes

- "Newest" means newly added entries, not new upstream releases.
- Results are sorted by the date the formula or cask file was first added to a tap.
- `--tap=homebrew/core` or `--tap=homebrew/cask` only works if those taps exist locally.
- The command implementation lives in [cmd/newest.rb](/Users/chris/src/brew-new/cmd/newest.rb).
