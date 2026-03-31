# brew-newest

External `brew` subcommand for listing the newest formulae and casks in a table.

## Usage

Add this repository to a tap and run:

```sh
brew newest
brew newest --formula
brew newest --cask --count=20
brew newest -v --count=1
brew newest -d --count=1
brew newest --offline
```

If you just want to test it locally from this directory, run:

```sh
PATH="$PWD:$PATH" brew newest
```

The command prefers local `homebrew/core` and `homebrew/cask` git history for
add dates. If those taps are not cloned locally, it falls back to the GitHub
API and then to a shallow remote git cache in `/tmp`.

Use `-v` for step-by-step progress, `-d` for more detailed subprocess
tracing, or `-o`/`--offline` to avoid any network fetches and rely only on
local taps plus cached Homebrew API metadata.
