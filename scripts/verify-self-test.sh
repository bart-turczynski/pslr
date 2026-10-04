#!/usr/bin/env bash
#
# Self-test for the test stage of the verify gate (tools/verify.sh).
#
# A pre-push run on a full disk was reported to print testthat's
# `[ FAIL 7 ... ]` while the verify hook said Passed (PSLR-vacblucj). That did
# not reproduce, but nothing stopped it either: the stage trusted testthat's
# stop_on_failure alone. run_tests now also reads the results testthat returns
# and exits 1 itself when no test ran, or when any test failed or errored. This
# script pins both layers, so that an edit to the gate, or a testthat upgrade
# that changes what stop_on_failure does, turns it red.
#
# Each case builds a throwaway package, copies tools/verify.sh into it and runs
# the copy in its own process, under the script's own `set -euo pipefail`, the
# way the pre-push hook runs it. Most cases use the `tests` tier, which runs
# run_tests alone; one runs `standard`, the pre-push tier, with its lint,
# spelling and URL steps stubbed out. A case that should fail also names a line
# its log must contain, so it proves its scenario happened rather than failing
# for some other reason.
#
# Offline, and seconds rather than minutes: each fixture has one or two
# one-line tests. pre-commit runs it on every push.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify_sh="$repo_root/tools/verify.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/verify-self-test.XXXXXX")"
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT

failures=0
cases=0

# What run_tests prints when its own result check fails the stage.
fail_closed_line='verify: the test stage failed closed'

fail_case() {
  failures=$((failures + 1))
  printf '  xx  %s\n' "$1"
}

# Both the pre-push tier and the `tests` tier must call run_tests as a plain
# statement, never under `if`, `||` or `&&`, where `set -e` would not stop the
# gate on its failure. The cases below run `tests`; this ties them to
# `standard`.
check_tier_calls_run_tests() {
  local tier="$1" body
  cases=$((cases + 1))
  body="$(awk -v t="  ${tier})" '
    $0 == t { inside = 1; next }
    inside && /^    ;;$/ { exit }
    inside { print }
  ' "$verify_sh")"
  if printf '%s\n' "$body" | grep -qx '    run_tests'; then
    printf '  ok  the %s tier calls run_tests as a plain statement\n' "$tier"
  else
    fail_case "the ${tier} tier no longer calls run_tests as a plain statement"
  fi
}

# make_pkg <dir>: a minimal package with one passing test and a copy of the
# gate script, so the copy's repo root is the fixture.
make_pkg() {
  local dir="$1"
  mkdir -p "$dir/R" "$dir/tests/testthat" "$dir/tools"
  cat > "$dir/DESCRIPTION" <<'EOF'
Package: verifyselftest
Version: 0.0.1
Title: Fixture for the Verify Gate Self-Test
Description: A throwaway package; never built or installed.
License: MIT
Encoding: UTF-8
Config/testthat/edition: 3
EOF
  printf 'fixture <- function() 1\n' > "$dir/R/fixture.R"
  printf 'test_that("passes", expect_equal(1, 1))\n' \
    > "$dir/tests/testthat/test-pass.R"
  cp "$verify_sh" "$dir/tools/verify.sh"
}

add_failing_test() {
  printf 'test_that("fails", expect_equal(1, 2))\n' \
    > "$1/tests/testthat/test-fail.R"
}

add_erroring_test() {
  printf '%s\n' \
    'test_that("errors", {' \
    '  con <- file(file.path(tempdir(), "missing", "x"), "r")' \
    '  close(con)' \
    '})' > "$1/tests/testthat/test-error.R"
}

# Switches testthat's own stop_on_failure off in the fixture's copy, so only
# run_tests' result check stands between a failure and a pass.
disable_stop_on_failure() {
  local copy="$1/tools/verify.sh"
  sed 's/reporter = "check", stop_on_failure = TRUE/reporter = "check", stop_on_failure = FALSE/' \
    "$copy" > "$copy.new"
  mv "$copy.new" "$copy"
  grep -q 'reporter = "check", stop_on_failure = FALSE' "$copy"
}

# Stubs the standard tier's lint, spelling and URL steps in the fixture's copy:
# they are not what this tests, and lint alone takes longer than every case
# here together. Later definitions win, so the stubs go just above the tier
# dispatch.
stub_standard_steps() {
  local copy="$1/tools/verify.sh"
  awk '
    $0 == "tier=\"${1:-standard}\"" {
      print "run_lint() { :; }"
      print "run_spelling() { :; }"
      print "run_urls() { :; }"
      found = 1
    }
    { print }
    END { exit !found }
  ' "$copy" > "$copy.new"
  mv "$copy.new" "$copy"
}

# run_case <name> <tier> <pass|fail> <log line or ""> <dir>
#
# The child is a separate process, so `|| status=$?` here does not switch off
# errexit inside it: the gate script runs exactly as the pre-push hook runs it.
run_case() {
  local name="$1" tier="$2" want="$3" marker="$4" dir="$5" log status=0 ok=1
  log="$dir.log"
  cases=$((cases + 1))
  bash "$dir/tools/verify.sh" "$tier" > "$log" 2>&1 || status=$?

  if [ "$want" = pass ]; then
    [ "$status" -eq 0 ] || ok=0
    grep -q "${tier} verify passed" "$log" || ok=0
  else
    [ "$status" -ne 0 ] || ok=0
    if grep -q "${tier} verify passed" "$log"; then ok=0; fi
  fi
  if [ -n "$marker" ] && ! grep -qF -- "$marker" "$log"; then ok=0; fi

  if [ "$ok" -eq 1 ]; then
    printf '  ok  %s (exit %d)\n' "$name" "$status"
  else
    fail_case "$(printf '%s: wanted the gate to %s, got exit %d' \
      "$name" "$want" "$status")"
    [ -z "$marker" ] || printf '      log must contain: %s\n' "$marker"
    printf '%s\n' '----- log -----'
    cat "$log"
    printf '%s\n' '---------------'
  fi
}

check_tier_calls_run_tests standard
check_tier_calls_run_tests tests

# Control: without it a gate that always fails would pass every case below.
make_pkg "$work/pass"
run_case "passing suite passes" tests pass "" "$work/pass"

make_pkg "$work/failure"
add_failing_test "$work/failure"
run_case "failing test fails the gate" tests fail \
  "Test failures" "$work/failure"

# The message the reported run showed.
make_pkg "$work/error"
add_erroring_test "$work/error"
run_case "erroring test fails the gate" tests fail \
  "cannot open the connection" "$work/error"

# testthat saves testthat-problems.rds only when a test failed, so this cannot
# isolate the file; it shows that a failure to save it does not swallow the
# test failure that made testthat try.
make_pkg "$work/unsaved"
add_failing_test "$work/unsaved"
mkdir "$work/unsaved/tests/testthat/testthat-problems.rds"
run_case "failing test still fails when testthat-problems.rds can't be written" \
  tests fail "testthat-problems.rds" "$work/unsaved"

# run_tests' own result check, with testthat's stop_on_failure switched off.
make_pkg "$work/check-failure"
add_failing_test "$work/check-failure"
if disable_stop_on_failure "$work/check-failure"; then
  run_case "result check fails a failing test without stop_on_failure" tests \
    fail "$fail_closed_line" "$work/check-failure"
else
  cases=$((cases + 1))
  fail_case "could not switch off stop_on_failure in the fixture: update disable_stop_on_failure"
fi

make_pkg "$work/check-error"
add_erroring_test "$work/check-error"
if disable_stop_on_failure "$work/check-error"; then
  run_case "result check fails an erroring test without stop_on_failure" tests \
    fail "$fail_closed_line" "$work/check-error"
else
  cases=$((cases + 1))
  fail_case "could not switch off stop_on_failure in the fixture: update disable_stop_on_failure"
fi

# A test file that runs no test: testthat passes it, the result check does not.
make_pkg "$work/no-tests"
printf 'invisible(NULL)\n' > "$work/no-tests/tests/testthat/test-pass.R"
run_case "suite that runs no test fails the gate" tests fail \
  "$fail_closed_line" "$work/no-tests"

# The tier the pre-push hook runs, end to end apart from the stubbed steps.
make_pkg "$work/standard"
add_failing_test "$work/standard"
if stub_standard_steps "$work/standard"; then
  run_case "standard tier fails on a failing test" standard fail \
    "Test failures" "$work/standard"
else
  cases=$((cases + 1))
  fail_case "could not stub the standard tier's steps: update stub_standard_steps"
fi

if [ "$failures" -gt 0 ]; then
  printf '\nverify self-test: %d of %d check(s) failed\n' "$failures" "$cases"
  exit 1
fi
printf '\nverify self-test: all %d checks passed\n' "$cases"
