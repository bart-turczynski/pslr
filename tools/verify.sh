#!/usr/bin/env bash
#
# A thin wrapper over the fleet-ci local gate, plus the one local-only leg.
#
# The merge gate is fleet-ci's: .fleet-ci/gate, run in the fleet Docker image
# by the .fleet-ci/pre-push hook on every push (settings in .fleet-ci.yml;
# seor ADR 0012). T0 (docs) and T1 (full) replace this script's former
# `standard`, `full`, `tests` and `docs` tiers; T2 (the weekly deep-check
# schedule) and T3 (a RELEASE=1 web pipeline, a v* tag) replace `matrix` and
# `cran`. docs/git-workflow.md has the tiers.
#
# Usage:
#   tools/verify.sh [auto|docs|full]   the fleet-ci gate on HEAD (default auto)
#   tools/verify.sh sanitize           ASAN + UBSAN, then valgrind, via Docker
#   tools/verify.sh psl-upstream       is the bundled PSL snapshot behind?
#
#   auto|docs|full  `.fleet-ci/gate <tier>`: auto lets the classifier pick
#                   the tier from the diff against main; a pass is stamped,
#                   and a stamped tree is skipped.
#   sanitize        the test suite over the C++ matcher under ASAN + UBSAN,
#                   then under valgrind, via Docker. CI runs an ASAN + UBSAN
#                   leg in T2 (x-sanitizers-gcc and the template's
#                   t2-sanitizers); valgrind runs only here.
#   psl-upstream    the pinned upstream commit in data-raw/update_psl.R
#                   against the latest one touching public_suffix_list.dat;
#                   exit 1 when upstream has moved or cannot be read. T3's
#                   x-psl-upstream-check does this and opens the MR.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# R version for the `sanitize` tier. One release version is enough: the tier
# exercises the C++ matcher, not R's version surface, and each leg is slow.
sanitize_version=4.5

if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_bold=$'\033[1m'
  c_red=$'\033[31m'; c_green=$'\033[32m'
else
  c_reset=''; c_bold=''; c_red=''; c_green=''
fi

step() { printf '\n%s==> %s%s\n' "$c_bold" "$1" "$c_reset"; }
ok()   { printf '%s  ok%s  %s\n' "$c_green" "$c_reset" "$1"; }
fail() { printf '%s  xx%s  %s\n' "$c_red" "$c_reset" "$1"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { fail "required command not found: $1"; return 1; }
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
# rhub.yaml used to provide (PSLR-avwlybsw).
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
  # without it undefined behavior is a line of stderr the exit status ignores.
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

run_psl_upstream() {
  step "upstream PSL snapshot"
  # Detection only. Regeneration is data-raw/update_psl.R, run deliberately —
  # this must never rewrite the bundled snapshot as a side effect of a check.
  local pinned upstream
  pinned="$(sed -nE 's/^default_commit <- "([0-9a-f]{40})".*/\1/p' data-raw/update_psl.R)"
  if [ -z "$pinned" ]; then
    fail "could not read 'default_commit' from data-raw/update_psl.R"
    return 1
  fi
  upstream="$(curl -sSf --max-time 20 \
    'https://api.github.com/repos/publicsuffix/list/commits?path=public_suffix_list.dat&per_page=1' \
    2>/dev/null | jq -r '.[0].sha' 2>/dev/null || true)"
  if ! printf '%s' "${upstream:-}" | grep -qxE '[0-9a-f]{40}'; then
    fail "upstream lookup failed (offline, or the GitHub API is unhappy) — snapshot not compared"
    return 1
  fi
  if [ "$pinned" = "$upstream" ]; then
    ok "bundled snapshot is current"
  else
    fail "upstream has moved: pinned ${pinned:0:12}, latest ${upstream:0:12} — run 'Rscript data-raw/update_psl.R ${upstream}'"
    return 1
  fi
}

tier="${1:-auto}"

case "$tier" in
  auto | docs | full)
    exec .fleet-ci/gate "$tier"
    ;;

  sanitize)
    run_sanitize
    printf '\n%ssanitize verify passed%s\n' "$c_green" "$c_reset"
    ;;

  psl-upstream)
    need_cmd curl
    need_cmd jq
    run_psl_upstream
    ;;

  *)
    echo "unknown tier: $tier" >&2
    sed -n '/^# Usage:/,/^#   psl-upstream  /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
