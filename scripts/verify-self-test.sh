#!/usr/bin/env bash
#
# Self-test for the test stage of the verify gate (tools/verify.sh).
#
# A pre-push run on a full disk was reported to print testthat's
# `[ FAIL 7 ... ]` while the verify hook said Passed (PSLR-vacblucj). Against
# the live script that did not reproduce: a failing test, an erroring one, and
# a testthat-problems.rds that could not be written (a full volume included)
# all left Rscript exiting 1 and the gate red. The stage reads no result file
# of its own; its result is Rscript's exit status, carried by the script's
# `set -euo pipefail`. These cases pin that, so a later edit that drops the
# status (an `|| true`, a lost `set -e`, `stop_on_failure = FALSE`) goes red.
#
# Each case builds a throwaway package, copies tools/verify.sh into it, and
# runs the copy's `tests` tier: the same run_tests the standard tier calls,
# run in its own process under the script's own shell options. A case that
# should fail also names a line its log must contain, so it proves the
# scenario it describes happened rather than failing for some other reason.
#
# Offline, and seconds rather than minutes: each fixture has two one-line
# tests. pre-commit runs it on a push that changes either file.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify_sh="$repo_root/tools/verify.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/verify-self-test.XXXXXX")"
# Some cases remove permissions on purpose; restore them so rm can clean up.
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT

failures=0
cases=0

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

# run_case <name> <pass|fail> <log line or ""> <dir> [VAR=value ...]
#
# The child is a separate process, so `|| status=$?` here does not switch off
# errexit inside it: the gate script runs exactly as the pre-push hook runs it.
run_case() {
  local name="$1" want="$2" marker="$3" dir="$4" log status=0 ok=1
  shift 4
  log="$dir.log"
  cases=$((cases + 1))
  env "$@" bash "$dir/tools/verify.sh" tests > "$log" 2>&1 || status=$?

  if [ "$want" = pass ]; then
    [ "$status" -eq 0 ] || ok=0
    grep -q 'tests verify passed' "$log" || ok=0
  else
    [ "$status" -ne 0 ] || ok=0
    if grep -q 'tests verify passed' "$log"; then ok=0; fi
  fi
  if [ -n "$marker" ] && ! grep -qF -- "$marker" "$log"; then ok=0; fi

  if [ "$ok" -eq 1 ]; then
    printf '  ok  %s (exit %d)\n' "$name" "$status"
  else
    failures=$((failures + 1))
    printf '  xx  %s: wanted the gate to %s, got exit %d' "$name" "$want" "$status"
    [ -z "$marker" ] || printf ' (log must contain: %s)' "$marker"
    printf '\n----- log -----\n'
    cat "$log"
    printf -- '---------------\n'
  fi
}

# 1. Control: without it a gate that always fails would pass every case below.
make_pkg "$work/pass"
run_case "passing suite passes" pass "" "$work/pass"

# 2. A failing expectation.
make_pkg "$work/failure"
add_failing_test "$work/failure"
run_case "failing test fails the gate" fail "Test failures" "$work/failure"

# 3. An error inside a test, with the message the reported run showed.
make_pkg "$work/error"
printf '%s\n' \
  'test_that("errors", {' \
  '  con <- file(file.path(tempdir(), "missing", "x"), "r")' \
  '  close(con)' \
  '})' > "$work/error/tests/testthat/test-error.R"
run_case "erroring test fails the gate" fail \
  "cannot open the connection" "$work/error"

# 4. testthat cannot write its result file: something it cannot replace sits
#    where the check reporter saves testthat-problems.rds.
make_pkg "$work/unwritable"
add_failing_test "$work/unwritable"
mkdir "$work/unwritable/tests/testthat/testthat-problems.rds"
run_case "unwritable result file fails the gate" fail \
  "testthat-problems.rds" "$work/unwritable"

# 5. The result file exists but can be neither read nor written. Root ignores
#    file modes, so the case would not test anything there.
if [ "$(id -u)" -ne 0 ]; then
  make_pkg "$work/unreadable"
  add_failing_test "$work/unreadable"
  : > "$work/unreadable/tests/testthat/testthat-problems.rds"
  chmod 000 "$work/unreadable/tests/testthat/testthat-problems.rds"
  run_case "unreadable result file fails the gate" fail \
    "testthat-problems.rds" "$work/unreadable"
else
  printf '  --  unreadable result file: skipped as root\n'
fi

# 6 and 7. TMPDIR is missing, or read-only: R's session temp directory and
#    every tempfile() a test uses live under it.
make_pkg "$work/tmp-missing"
add_failing_test "$work/tmp-missing"
run_case "missing TMPDIR still fails the gate" fail "" "$work/tmp-missing" \
  TMPDIR="$work/no-such-dir"

make_pkg "$work/tmp-readonly"
add_failing_test "$work/tmp-readonly"
mkdir "$work/readonly-tmp"
chmod 555 "$work/readonly-tmp"
run_case "read-only TMPDIR still fails the gate" fail "" "$work/tmp-readonly" \
  TMPDIR="$work/readonly-tmp"

if [ "$failures" -gt 0 ]; then
  printf '\nverify self-test: %d of %d case(s) failed\n' "$failures" "$cases"
  exit 1
fi
printf '\nverify self-test: all %d cases passed\n' "$cases"
