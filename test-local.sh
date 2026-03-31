#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CMD=(brew ruby "$ROOT_DIR/cmd/newest.rb" --)

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run_capture() {
  local __var_name="$1"
  shift

  local output
  if ! output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "command failed: $*"
  fi

  printf -v "$__var_name" '%s' "$output"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf '%s\n' "$haystack" >&2
    fail "$label"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    printf '%s\n' "$haystack" >&2
    fail "$label"
  fi
}

assert_line_count_at_least() {
  local text="$1"
  local min_count="$2"
  local label="$3"
  local count

  count="$(printf '%s\n' "$text" | wc -l | tr -d ' ')"
  if (( count < min_count )); then
    printf '%s\n' "$text" >&2
    fail "$label"
  fi
}

assert_dates_descending() {
  local text="$1"
  local section="$2"
  local dates

  dates="$(
    printf '%s\n' "$text" |
      awk -v section="$section" '
        $0 == section { in_section=1; header=0; next }
        in_section && $0 ~ /^Newest / && $0 != section { exit }
        in_section && $0 ~ /^-+/ { header=1; next }
        in_section && header && $0 !~ /^==>/ && NF > 0 { print $2 }
      '
  )"

  if [[ -z "$dates" ]]; then
    printf '%s\n' "$text" >&2
    fail "no dates found in section: $section"
  fi

  local previous=""
  local current=""
  while IFS= read -r current; do
    [[ -z "$current" ]] && continue
    if [[ -n "$previous" && "$current" > "$previous" ]]; then
      printf '%s\n' "$text" >&2
      fail "dates not descending in section: $section"
    fi
    previous="$current"
  done <<< "$dates"
}

assert_has_data_rows() {
  local text="$1"
  local section="$2"

  local rows
  rows="$(
    printf '%s\n' "$text" |
      awk -v section="$section" '
        $0 == section { in_section=1; header=0; next }
        in_section && $0 ~ /^Newest / && $0 != section { exit }
        in_section && $0 ~ /^-+/ { header=1; next }
        in_section && header && $0 !~ /^==>/ && NF > 0 { print }
      '
  )"

  [[ -n "$rows" ]] || fail "no data rows in section: $section"
}

printf 'Running local smoke tests for brew-newest\n'

run_capture syntax_output ruby -c "$ROOT_DIR/cmd/newest.rb"
assert_contains "$syntax_output" "Syntax OK" "ruby syntax check failed"
pass "ruby syntax"

run_capture style_output brew style --fix "$ROOT_DIR/cmd/newest.rb"
pass "brew style --fix"

run_capture base_output "${CMD[@]}"
assert_contains "$base_output" "Newest Formulae" "base run missing formula section"
assert_contains "$base_output" "Newest Casks" "base run missing cask section"
assert_has_data_rows "$base_output" "Newest Formulae"
assert_has_data_rows "$base_output" "Newest Casks"
assert_dates_descending "$base_output" "Newest Formulae"
assert_dates_descending "$base_output" "Newest Casks"
pass "default run"

run_capture formula_output "${CMD[@]}" --formula
assert_contains "$formula_output" "Newest Formulae" "formula-only run missing formula section"
assert_not_contains "$formula_output" "Newest Casks" "formula-only run unexpectedly included casks"
assert_has_data_rows "$formula_output" "Newest Formulae"
assert_dates_descending "$formula_output" "Newest Formulae"
pass "formula-only run"

run_capture cask_output "${CMD[@]}" --cask --count=20
assert_contains "$cask_output" "Newest Casks" "cask-only run missing cask section"
assert_not_contains "$cask_output" "Newest Formulae" "cask-only run unexpectedly included formulae"
assert_has_data_rows "$cask_output" "Newest Casks"
assert_dates_descending "$cask_output" "Newest Casks"
pass "cask-only run"

run_capture core_tap_output "${CMD[@]}" --tap=homebrew/core --formula
assert_contains "$core_tap_output" "Newest Formulae" "homebrew/core tap run missing formula section"
assert_has_data_rows "$core_tap_output" "Newest Formulae"
pass "homebrew/core tap run"

run_capture local_tap_output "${CMD[@]}" --tap=farmerchris/tap --formula
assert_contains "$local_tap_output" "Newest Formulae" "farmerchris/tap run missing formula section"
assert_contains "$local_tap_output" "farmerchris/tap/" "farmerchris/tap run missing tap-qualified formula"
pass "farmerchris/tap run"

run_capture mixed_tap_output "${CMD[@]}" --tap=homebrew/core,farmerchris/tap --formula
assert_contains "$mixed_tap_output" "Newest Formulae" "mixed tap run missing formula section"
assert_has_data_rows "$mixed_tap_output" "Newest Formulae"
pass "mixed tap run"

run_capture verbose_output "${CMD[@]}" -v --count=1
assert_contains "$verbose_output" "==> Collecting newest formulas" "verbose run missing progress output"
assert_contains "$verbose_output" "Newest Formulae" "verbose run missing formula section"
pass "verbose run"

run_capture debug_output "${CMD[@]}" -d --count=1
assert_contains "$debug_output" "debug: Running:" "debug run missing debug command trace"
assert_contains "$debug_output" "Newest Formulae" "debug run missing formula section"
pass "debug run"

run_capture offline_output "${CMD[@]}" --offline --count=1
assert_contains "$offline_output" "Newest Formulae" "offline run missing formula section"
assert_contains "$offline_output" "Newest Casks" "offline run missing cask section"
pass "offline run"

run_capture width_output "${CMD[@]}" --width=120 --count=1
assert_line_count_at_least "$width_output" 6 "width run output too short"
pass "custom width run"

printf 'All local smoke tests passed.\n'
