#!/usr/bin/env bash
#
# The local verify gate.
#
# GitLab runner minutes are a paid resource, so the hosted pipeline assembles
# only when someone asks for it by name — `CRAN_PREP=1` or `DEPLOY_PAGES=1` on a
# manual run (see the `workflow:` rules in .gitlab-ci.yml). Nothing fires by
# itself: not a push, not a merge request, not a tag, not a schedule. Everything
# CI used to do on a schedule is done here instead, on the maintainer's machine,
# for free. This script is therefore the single definition of "is the tree
# healthy" — the pre-push hook, the AGENTS.md dev loop and the release checklist
# all call it rather than restating the command.
#
# Usage:
#   tools/verify.sh [standard|full|matrix|sanitize|cran]
#   tools/verify.sh --staleness
#
#   standard  lint + the test suite.  The per-push gate; what the pre-push hook
#             runs.  About two minutes, most of it the 2000-odd tests.
#   full      standard + R CMD check --as-cran, NEWS/version consistency,
#             README drift, coverage and both dependency audits.  Replaces the
#             weekly CI schedules.  Records a timestamp in .verify-stamp.
#   matrix    R 4.5 / 4.6 / devel via Docker.  Replaces the `full-check` job.
#   sanitize  the test suite over the C++ matcher under ASAN + UBSAN, then
#             under valgrind, via Docker.  Replaces the deleted rhub workflow.
#   cran      full + matrix + sanitize + the remote incoming checks.
#             Pre-submission.
#
# --staleness reports how long it has been since a successful `full` run and
# always exits 0, so it is safe to call from a hook or an agent without
# tripping `set -e`.  The first word of its output is FRESH, STALE or NEVER.
#
# Why `R CMD check` is NOT in the standard tier:  it was, for one afternoon.
# The very first push under the new hook was abandoned because the check took
# about five minutes, and the push only completed once the hook was skipped --
# the precise failure this design is supposed to avoid, reached in twenty
# minutes rather than the fortnight the comment predicted.  A gate that is
# habitually skipped protects nothing, so the expensive half moved behind the
# staleness nudge.  The accepted cost is that a defect only `R CMD check`
# catches now surfaces within a week instead of at push time.  This buys less
# than it first appears: the tier still takes about two minutes, because the
# suite is 2000-odd tests.  It is the difference between a hook you wait for
# and one you skip, not between slow and instant.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

stamp_file="$repo_root/.verify-stamp"
# Days after which `full` is considered overdue. A week: long enough that the
# nudge stays rare, short enough that an upstream advisory is not months old.
stale_after_days=7

# R versions for the `matrix` tier. Keep `devel` last: it is by far the slowest
# and the most likely to fail for reasons that are not the package's fault.
matrix_versions=(4.5 4.6 devel)

# R version for the `sanitize` tier. One release version is enough: the tier
# exercises the C++ matcher, not R's version surface, and each leg is slow.
sanitize_version=4.5

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_bold=$'\033[1m'
  c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
else
  c_reset=''; c_bold=''; c_red=''; c_green=''; c_yellow=''
fi

step() { printf '\n%s==> %s%s\n' "$c_bold" "$1" "$c_reset"; }
ok()   { printf '%s  ok%s  %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '%s  !!%s  %s\n' "$c_yellow" "$c_reset" "$1"; }
fail() { printf '%s  xx%s  %s\n' "$c_red" "$c_reset" "$1"; }

# Steps that were `allow_failure: true` in CI record a warning instead of
# aborting, so one soft finding does not hide the rest of the run.
soft_warnings=()

# ---------------------------------------------------------------------------
# Staleness
# ---------------------------------------------------------------------------

# Epoch seconds only: parsing a formatted date back differs between BSD and GNU
# `date`, and nothing here needs to render the stored value.
stamp_age_days() {
  [ -f "$stamp_file" ] || return 1
  local then now
  then="$(tr -dc '0-9' < "$stamp_file")"
  [ -n "$then" ] || return 1
  now="$(date +%s)"
  echo $(((now - then) / 86400))
}

report_staleness() {
  local age
  if ! age="$(stamp_age_days)"; then
    echo "NEVER  no successful \`tools/verify.sh full\` recorded yet — run it to establish a baseline"
    return 0
  fi
  if [ "$age" -ge "$stale_after_days" ]; then
    echo "STALE  full check last passed ${age} days ago — run \`tools/verify.sh full\` (~15 min)"
  else
    echo "FRESH  full check last passed ${age} days ago"
  fi
  return 0
}

write_stamp() {
  date +%s > "$stamp_file"
}

# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { fail "required command not found: $1"; return 1; }
}

# Only the tiers that run `R CMD check` and the README guard need these; the
# standard tier needs Rscript alone, and warning about qpdf on every push would
# be noise about a tool that tier never invokes.
check_toolchain() {
  need_cmd Rscript
  # `R CMD check` emits the PDF size-reduction check as a WARNING when qpdf is
  # absent, and the gate runs with error_on = "warning". Without qpdf the local
  # check is weaker than CI was: this is exactly what failed full-check on 4.5.
  if ! command -v qpdf >/dev/null 2>&1; then
    warn "qpdf not installed — the PDF size-reduction check will not run (brew install qpdf)"
    soft_warnings+=("qpdf missing")
  fi
  if ! command -v pandoc >/dev/null 2>&1; then
    warn "pandoc not installed — the README check cannot run"
    soft_warnings+=("pandoc missing")
  fi
}

run_lint() {
  step "lint (lintr)"
  Rscript -e 'lints <- lintr::lint_package(); if (length(lints)) { print(lints); quit(status = 1) }'
  ok "no lints"
}

run_tests() {
  step "tests (testthat)"
  # NOT_CRAN is deliberately unset: the suite must stay offline here, exactly as
  # it does inside `R CMD check`. The audit tiers set it for their own filters.
  Rscript -e 'testthat::test_local(reporter = "check", stop_on_failure = TRUE)'
  ok "tests passed"
}

# rcmdcheck summarises whatever 00check.log holds, and a check that aborted
# early leaves a log with no findings, which reads as a clean pass. Insist the
# log shows a run that reached the end.
#
# This lives in a variable, and both call sites go through run_check, because
# the `cran` tier once inlined its own rcmdcheck call to enable the remote
# incoming checks and did not carry the guard with it. On 2026-09-05 a
# 60-second timeout fetching CRAN's archive.rds halted the check at its first
# step and the tier reported "0 errors | 0 warnings | 0 notes", then
# "safe to submit" (PSLR-zibafvbq). The guard was missing from precisely the
# tier that gates a submission, and from the one form of the check whose
# network dependency makes an early abort likely.
check_ran_to_completion='
  log <- readLines(file.path(chk[["checkdir"]], "00check.log"), warn = FALSE)
  if (any(grepl("Execution halted", log, fixed = TRUE))) {
    stop("R CMD check aborted: Execution halted in 00check.log")
  }
  if (!any(grepl("^Status:", log))) {
    stop("R CMD check did not run to completion: no Status line in 00check.log")
  }
'

# run_check [remote]
#
#   (no argument)  mirrors the `check` job: --no-manual, incoming checks local.
#   remote         the pre-submission form: builds the manual and enables the
#                  CRAN incoming checks that talk to CRAN.
run_check() {
  if [ "${1:-}" = "remote" ]; then
    step "R CMD check --as-cran (remote incoming checks enabled)"
    # R runs the check in a separate process, so the parent's options() do not
    # reach it; R_DEFAULT_INTERNET_TIMEOUT seeds the child's `timeout` option.
    # The default 60s is not enough for CRAN's archive.rds on a slow day, which
    # is what aborted the check in PSLR-zibafvbq.
    _R_CHECK_CRAN_INCOMING_REMOTE_=true \
    R_DEFAULT_INTERNET_TIMEOUT=300 \
    Rscript -e '
      chk <- rcmdcheck::rcmdcheck(
        args = "--as-cran", error_on = "warning", check_dir = "check"
      )
      '"$check_ran_to_completion"'
    '
  else
    step "R CMD check --as-cran"
    Rscript -e '
      chk <- rcmdcheck::rcmdcheck(
        args = c("--no-manual", "--as-cran"), error_on = "warning",
        check_dir = "check"
      )
      '"$check_ran_to_completion"'
    '
  fi
  ok "check complete"
}

run_news_version() {
  step "NEWS.md / DESCRIPTION version consistency"
  local version heading tags missing released
  version="$(grep -E '^Version:' DESCRIPTION | head -n1 | sed -E 's/^Version:[[:space:]]*//')"
  heading="$(grep -m1 -E '^# ' NEWS.md | sed -E 's/^#[[:space:]]+pslr[[:space:]]*//')"
  if [ "$heading" != "(development version)" ] && [ "$heading" != "$version" ]; then
    fail "top NEWS.md heading ('$heading') is neither '(development version)' nor the DESCRIPTION Version ('$version')"
    return 1
  fi
  tags="$(git tag -l 'v*')"
  missing=0
  for tag in $tags; do
    released="${tag#v}"
    if ! grep -qxF "# pslr ${released}" NEWS.md; then
      fail "tag ${tag} has no matching '# pslr ${released}' heading in NEWS.md"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 1
  ok "version and NEWS headings agree"
}

run_readme() {
  step "README.md freshness"
  # Byte-for-byte, so the generator has to be reproducible. CI pinned pandoc to
  # PANDOC_VERSION for this reason; locally we use whatever is installed, so a
  # mismatch shows up as spurious drift. Report the version to make that
  # diagnosable rather than baffling.
  local want have
  want="$(sed -nE 's/^  PANDOC_VERSION: "(.+)"/\1/p' .gitlab-ci.yml | head -n1)"
  have="$(pandoc --version | head -n1 | awk '{print $2}')"
  if [ -n "$want" ] && [ "$want" != "$have" ]; then
    warn "local pandoc is ${have}, .gitlab-ci.yml pins ${want}; table formatting may differ"
  fi
  Rscript -e 'devtools::build_readme()'
  if ! git diff --exit-code -- README.md; then
    fail "README.md is out of sync with README.Rmd — commit the regenerated file"
    return 1
  fi
  ok "README.md matches README.Rmd"
}

run_coverage() {
  step "test coverage"
  Rscript -e 'cov <- covr::package_coverage(quiet = FALSE); cat(sprintf("Coverage: %.2f%%\n", covr::percent_coverage(cov)))'
  ok "coverage reported"
}

run_osv() {
  step "OSV dependency audit"
  # NOT_CRAN is set for the audits and only for the audits: skip_on_cran() in
  # these tests would otherwise skip the audit silently. It must not be set for
  # `check`, whose tests are required to stay offline.
  NOT_CRAN=true Rscript -e 'testthat::test_local(filter = "osv", stop_on_failure = TRUE)'
  ok "no OSV advisories"
}

# The path R itself would read the user's environment file from. Hardcoding
# ~/.Renviron would disagree with R on any machine that redirects it, and the
# whole point of this helper is that both halves of the audit look in one place.
# `${HOME:-}` because `set -u` would otherwise abort the whole gate in the one
# environment that has no HOME at all, which is not this check's business.
renviron_file() {
  printf '%s' "${R_ENVIRON_USER:-${HOME:-}/.Renviron}"
}

# Sets $1 from the R user environment file, but only when the environment does
# not already define it: an exported variable wins, so CI — which passes real
# environment variables — is unaffected and the file stays a fallback.
#
# `source` is deliberately not used. .Renviron is data, not a shell script, and
# sourcing it would execute whatever it happens to contain.
#
# The value never reaches stdout, stderr or the trace: xtrace is suspended
# around the assignment, so a future `bash -x tools/verify.sh` cannot print a
# credential, and no caller ever renders the value — only whether it is there.
load_from_renviron() {
  local name="$1" file line value xtrace=0
  case "$-" in *x*) xtrace=1; set +x ;; esac

  file="$(renviron_file)"
  if [ -r "$file" ]; then
    # The anchor rules out comments for free — a `#` before the name never
    # matches — and the last assignment wins, as a later line would in R.
    line="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$file" 2>/dev/null | tail -n1)" || line=''
    if [ -n "$line" ]; then
      # Everything after the FIRST `=`, because a token may contain one, then
      # at most one layer of matching surrounding quotes.
      value="${line#*=}"
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
      printf -v "$name" '%s' "$value"
      export "${name?}"
    fi
  fi

  [ "$xtrace" -eq 0 ] || set -x
  return 0
}

# The audit runs inside R, which reads the R environment file; the shell guard
# in front of it did not, so on a machine with the credentials installed exactly
# where the old message said to put them the audit was skipped anyway
# (PSLR-lidgnomk) — PSLR-njeqwltb's vacuous green returning as a vacuous skip.
# Both gates call this, so both consult the environment and the file alike, and
# what they resolve is exported for the child R process.
#
# `:+set` rather than `:-`: both answer "is it there", but the plain expansion
# would substitute the credential itself into a traced command line, which is
# how the first draft of this leaked the value under `bash -x`.
ossindex_credentials_available() {
  [ -n "${OSSINDEX_TOKEN:+set}" ] || load_from_renviron OSSINDEX_TOKEN
  [ -n "${OSSINDEX_USER:+set}" ] || load_from_renviron OSSINDEX_USER
  [ -n "${OSSINDEX_TOKEN:+set}" ]
}

# The cran tier's preflight: the same resolution, but fatal. A pre-submission
# tier that skipped the audit would be asserting something it never checked.
require_ossindex_credentials() {
  ossindex_credentials_available && return 0
  fail "OSSINDEX_TOKEN is set in neither the environment nor $(renviron_file) — the cran tier requires it, a vacuous audit is not a pre-submission check"
  exit 1
}

run_security() {
  step "OSS Index dependency audit"
  if ! ossindex_credentials_available; then
    # OSS Index rejects anonymous requests with HTTP 401, so without a token
    # this audit is vacuous rather than green. Soft in `full` (the tree is
    # still checked by everything else), hard in `cran`.
    warn "OSSINDEX_TOKEN is set in neither the environment nor $(renviron_file) — skipping. Put OSSINDEX_USER='x' (the literal placeholder) and OSSINDEX_TOKEN in either (see PSLR-njeqwltb)."
    soft_warnings+=("OSS Index audit skipped: no token")
    return 0
  fi
  NOT_CRAN=true Rscript -e 'testthat::test_local(filter = "security", stop_on_failure = TRUE)'
  ok "no OSS Index advisories"
}

run_psl_upstream() {
  step "upstream PSL snapshot"
  # Detection only. Regeneration is data-raw/update_psl.R, run deliberately —
  # this must never rewrite the bundled snapshot as a side effect of a check.
  local pinned upstream
  pinned="$(sed -nE 's/^default_commit <- "([0-9a-f]{40})".*/\1/p' data-raw/update_psl.R)"
  if [ -z "$pinned" ]; then
    warn "could not read 'default_commit' from data-raw/update_psl.R"
    soft_warnings+=("PSL pin unreadable")
    return 0
  fi
  upstream="$(curl -sSf --max-time 20 \
    'https://api.github.com/repos/publicsuffix/list/commits?path=public_suffix_list.dat&per_page=1' \
    2>/dev/null | jq -r '.[0].sha' 2>/dev/null || true)"
  if ! printf '%s' "${upstream:-}" | grep -qxE '[0-9a-f]{40}'; then
    warn "upstream lookup failed (offline, or the GitHub API is unhappy) — snapshot not compared"
    soft_warnings+=("PSL upstream unchecked")
    return 0
  fi
  if [ "$pinned" = "$upstream" ]; then
    ok "bundled snapshot is current"
  else
    warn "upstream has moved: pinned ${pinned:0:12}, latest ${upstream:0:12} — run 'Rscript data-raw/update_psl.R ${upstream}'"
    soft_warnings+=("PSL snapshot is behind upstream")
  fi
}

run_matrix() {
  need_cmd docker
  local ver status=0
  for ver in "${matrix_versions[@]}"; do
    step "R CMD check on R ${ver} (docker)"
    # A named volume per R version keeps the dependency closure between runs;
    # rebuilding it every time would make this tier unusable.
    if docker run --rm \
      -v "$repo_root:/pkg" -w /pkg \
      -v "pslr-rlib-${ver}:/rlib" \
      -e R_LIBS_USER=/rlib \
      -e NOT_CRAN=false \
      -e _R_CHECK_CRAN_INCOMING_REMOTE_=false \
      -e PKG_SYSREQS=true \
      "rocker/r-ver:${ver}" \
      bash -c '
        set -eu
        apt-get update -qq
        # libcurl/libssl headers are here to bootstrap pak itself, not for the
        # package: pak installs system requirements, but only once it is
        # installed. R releases get a prebuilt pak binary and never compile, so
        # this is invisible on 4.5/4.6; on devel there is no binary, pak builds
        # its embedded curl from source, and without the headers the whole tier
        # fails before reaching any check.
        apt-get install -y --no-install-recommends \
          qpdf ghostscript pandoc git curl jq \
          libcurl4-openssl-dev libssl-dev >/dev/null
        mkdir -p "$R_LIBS_USER"
        Rscript -e "if (!requireNamespace(\"pak\", quietly = TRUE)) install.packages(\"pak\")"
        Rscript -e "pak::local_install_deps(dependencies = TRUE)"
        Rscript -e "pak::pak(\"rcmdcheck\")"
        Rscript -e "rcmdcheck::rcmdcheck(args = c(\"--no-manual\", \"--as-cran\"), error_on = \"warning\")"
      '; then
      ok "R ${ver} passed"
    else
      fail "R ${ver} failed"
      status=1
    fi
  done
  return "$status"
}

# Copy the tree out of the read-only bind mount, then drop the host's compiled
# artifacts. src/*.o and src/*.so are gitignored but present in a working tree
# that has ever been checked, and on this host they are Mach-O; `cp -a` carries
# them into a Linux container, where pkgload will happily reuse them and fail
# with "invalid ELF header". `R CMD INSTALL --preclean` below rebuilds them
# anyway, so this only removes a dependency on that ordering -- but the failure
# it prevents is one this tier hit for real while being written.
sanitize_prepare='
  cp -a /pkg /src && cd /src
  rm -f src/*.o src/*.so
  rm -rf check *.Rcheck
'

# Dependency closure for the sanitize legs. Shared verbatim by both so their
# libraries hold the same versions; only the compiler flags differ.
#
# `R_LIBS`, not `R_LIBS_USER`: rocker's Renviron sets R_LIBS_USER itself, so the
# container ignores an R_LIBS_USER passed with -e and every run reinstalls the
# closure into the image's site-library, which --rm then discards.
sanitize_deps='
  mkdir -p /rlib
  Rscript -e "if (!requireNamespace(\"pak\", quietly = TRUE)) install.packages(\"pak\", lib = \"/rlib\")"
  Rscript -e ".libPaths(\"/rlib\"); pak::local_install_deps(dependencies = TRUE, lib = \"/rlib\")"
  Rscript -e ".libPaths(\"/rlib\"); pak::pak(\"testthat\", lib = \"/rlib\")"
'

# Dynamic analysis of the C++ matcher: the coverage that .github/workflows/
# rhub.yaml used to provide and that no longer exists anywhere (PSLR-avwlybsw).
#
# Not R-hub: rhub v2 dispatches to the maintainer's own GitHub Actions runners
# and needs a GitHub repository, which the suspension removed (PSLR-thcaqtnw).
# Not the ghcr.io/r-hub/containers images either: they are published amd64-only
# and this is an arm64 host, so they run under emulation — which is both slow
# and the wrong architecture to be testing pointer arithmetic on. These legs
# build with the host's own toolchain instead, natively.
#
# The bind mount is read-only and the tree is copied inside the container: an
# instrumented build writes src/*.o and src/*.so, and those must never land in
# the working tree where a later `R CMD INSTALL` could pick them up.
run_sanitize() {
  need_cmd docker
  local status=0

  step "ASAN + UBSAN on R ${sanitize_version} (docker)"
  # -fno-sanitize-recover=all makes UBSAN abort rather than print and continue;
  # without it undefined behaviour is a line of stderr the exit status ignores.
  if docker run --rm \
    -v "$repo_root:/pkg:ro" \
    -v "pslr-rlib-asan:/rlib" \
    -e R_LIBS=/rlib \
    "rocker/r-ver:${sanitize_version}" \
    bash -c '
      set -eu
      '"$sanitize_prepare"'
      '"$sanitize_deps"'
      flags="-g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all"
      flags="$flags -fno-omit-frame-pointer"
      mkdir -p ~/.R
      {
        echo "CFLAGS = $flags"
        echo "CXXFLAGS = $flags"
        echo "LDFLAGS = -fsanitize=address,undefined"
      } > ~/.R/Makevars
      # --no-test-load: the post-install load test dlopens the instrumented .so
      # from an R that has no sanitizer runtime loaded, and ASAN refuses that
      # ("ASan runtime does not come first in initial library list"). The real
      # load happens below, under LD_PRELOAD.
      R CMD INSTALL --preclean --no-staged-install --no-test-load -l /rlib .
      # R itself is not instrumented, so leak detection here would report R own
      # allocations rather than the package. The valgrind leg covers leaks.
      LD_PRELOAD="$(gcc -print-file-name=libasan.so)" \
      ASAN_OPTIONS=detect_leaks=0 \
      UBSAN_OPTIONS=print_stacktrace=1 \
        Rscript -e "testthat::test_local(reporter = \"summary\", stop_on_failure = TRUE)"
    '; then
    ok "no ASAN or UBSAN findings"
  else
    fail "ASAN/UBSAN leg failed"
    status=1
  fi

  step "valgrind memcheck on R ${sanitize_version} (docker)"
  # A separate, uninstrumented build: valgrind cannot run ASAN-instrumented
  # code, so the two legs cannot share a library.
  if docker run --rm \
    -v "$repo_root:/pkg:ro" \
    -v "pslr-rlib-valgrind:/rlib" \
    -e R_LIBS=/rlib \
    "rocker/r-ver:${sanitize_version}" \
    bash -c '
      set -eu
      apt-get update -qq
      apt-get install -y --no-install-recommends valgrind >/dev/null
      '"$sanitize_prepare"'
      '"$sanitize_deps"'
      R CMD INSTALL --preclean -l /rlib .
      # --errors-for-leak-kinds=none: R is not valgrind-clean about its own
      # allocations, so counting leak kinds as errors would fail this leg on
      # every run whatever the package does. The gate is invalid reads and
      # writes; the leak summary is printed for a human to read.
      R -d "valgrind --tool=memcheck --leak-check=summary --errors-for-leak-kinds=none --error-exitcode=1" \
        --no-save -e "testthat::test_local(reporter = \"summary\", stop_on_failure = TRUE)"
    '; then
    ok "no invalid reads or writes"
  else
    fail "valgrind leg failed"
    status=1
  fi

  return "$status"
}

# ---------------------------------------------------------------------------
# Tiers
# ---------------------------------------------------------------------------

summarise() {
  if [ "${#soft_warnings[@]}" -gt 0 ]; then
    printf '\n%s%d warning(s):%s\n' "$c_yellow" "${#soft_warnings[@]}" "$c_reset"
    printf '  - %s\n' "${soft_warnings[@]}"
  fi
}

tier="${1:-standard}"

case "$tier" in
  --staleness)
    report_staleness
    exit 0
    ;;

  standard)
    need_cmd Rscript
    run_lint
    run_tests
    summarise
    printf '\n%sstandard verify passed%s\n' "$c_green" "$c_reset"
    # Deliberately does not touch .verify-stamp: only the full tier clears the
    # staleness nudge, or pushing often would silence a check that never ran.
    report_staleness
    ;;

  full)
    check_toolchain
    run_lint
    run_tests
    run_check
    run_news_version
    run_readme
    run_coverage
    run_osv
    run_security
    run_psl_upstream
    summarise
    write_stamp
    printf '\n%sfull verify passed%s\n' "$c_green" "$c_reset"
    ;;

  matrix)
    run_matrix
    printf '\n%smatrix verify passed%s\n' "$c_green" "$c_reset"
    ;;

  sanitize)
    run_sanitize
    printf '\n%ssanitize verify passed%s\n' "$c_green" "$c_reset"
    ;;

  cran)
    check_toolchain
    require_ossindex_credentials
    run_lint
    run_tests
    # CI disables the remote incoming checks because the rocker image points
    # `repos` at a binary mirror with no src/contrib, so the fetch 404s and
    # aborts the check. Locally `repos` points at CRAN proper, so the remote
    # half both works and is worth running before a submission.
    run_check remote
    run_news_version
    run_readme
    run_coverage
    run_osv
    run_security
    run_psl_upstream
    run_matrix
    # CRAN runs its own clang-ASAN/UBSAN and valgrind checks on submission.
    # Finding a hit from their report rather than from this run is the
    # expensive ordering, so the tier pays for it here.
    run_sanitize
    summarise
    write_stamp
    printf '\n%scran tier passed — safe to submit%s\n' "$c_green" "$c_reset"
    ;;

  *)
    echo "unknown tier: $tier" >&2
    sed -n '/^# Usage:/,/^# --staleness/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
