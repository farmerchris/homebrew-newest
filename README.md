# brew-newest

Homebrew tap providing the `brew newest` external command.

## Usage

Tap this repository and run:

```sh
brew tap farmerchris/brew-newest https://github.com/farmerchris/brew-newest
brew newest
brew newest --formula
brew newest --cask --count=20
brew newest -v --count=1
brew newest -d --count=1
brew newest --offline
```

The command prefers local `homebrew/core` and `homebrew/cask` git history for
add dates. If those taps are not cloned locally, it falls back to the GitHub
API and then to a shallow remote git cache in `/tmp`.

Use `-v` for step-by-step progress, `-d` for more detailed subprocess
tracing, or `-o`/`--offline` to avoid any network fetches and rely only on
local taps plus cached Homebrew API metadata.

## Layout

This tap exposes the command from [cmd/newest.rb](/Users/chris/src/brew-new/cmd/newest.rb).
Once the tap is installed, Homebrew discovers it automatically as `brew newest`.
