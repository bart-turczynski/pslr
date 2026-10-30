#!/usr/bin/env Rscript
# Positive proof that the case-folding locale legs of test-parser.R ran.
#
# tests/testthat/test-parser.R runs one leg per locale listed in
# tests/testthat/fixtures/case-folding-locales.txt, and a leg skips on a
# machine that lacks its locale. A skip is a pass as far as R CMD check is
# concerned, so a CI image that silently lost a locale would go green while
# testing nothing (PSLR-mgqnsbjz). Checking that no skip message appears is
# not enough either: it also passes when the legs never ran at all.
#
# So this script runs test-parser.R against an installed pslr and demands, for
# every locale in the list, a test of the expected name that was not skipped,
# did not fail or error, and passed at least one expectation. Any skipped leg
# fails the job, whatever its locale. First, though, each locale must fold "I"
# to the dotless U+0131, the mapping the legs exist to survive: a leg run under
# a locale that does not would pass and prove nothing.
#
# It is a `locale_assertions` entry of .fleet-ci.yml: the fleet-ci local gate
# (full tier) runs it after each locale leg's check, and CI's `t2-locale` after
# each of its legs, with FLEET_RCHECK_DIR naming the leg's .Rcheck directory,
# where R CMD check installed pslr. The locales come from .fleet-ci.yml's
# `locales`, which must list every one in case-folding-locales.txt. The
# package's dependencies, testthat and withr among them, are in the run
# library: R_LIBS in the local gate, FLEET_RUN_LIB in CI.
#
# Usage, from the package root:
#   Rscript scripts/check-locale-legs.R <library holding the installed pslr>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L || !nzchar(args[[1L]])) {
  stop("usage: check-locale-legs.R <library holding pslr>", call. = FALSE)
}
run_lib <- Sys.getenv("FLEET_RUN_LIB")
.libPaths(c(
  args[[1L]],
  if (nzchar(run_lib) && dir.exists(run_lib)) run_lib,
  .libPaths()
))

locales <- readLines("tests/testthat/fixtures/case-folding-locales.txt")
if (!length(locales)) {
  stop("case-folding-locales.txt lists no locales", call. = FALSE)
}
for (l in locales) {
  old <- Sys.getlocale("LC_CTYPE")
  active <- suppressWarnings(Sys.setlocale("LC_CTYPE", l))
  folds <- identical(tolower("I"), intToUtf8(0x131L))
  invisible(Sys.setlocale("LC_CTYPE", old))
  if (!identical(active, l)) {
    stop("R cannot switch LC_CTYPE to ", l, call. = FALSE)
  }
  if (!folds) {
    stop(
      l,
      " does not fold I to dotless i; the test leg would prove nothing",
      call. = FALSE
    )
  }
  cat(l, "usable in R and folds I to dotless i\n")
}
results <- as.data.frame(testthat::test_file(
  "tests/testthat/test-parser.R",
  package = "pslr",
  load_package = "installed",
  reporter = "silent",
  stop_on_failure = FALSE
))

prefix <- "section names parse the same under "
legs <- results[startsWith(results$test, prefix), , drop = FALSE]
expected <- paste0(prefix, locales)
missing <- setdiff(expected, legs$test)
bad <- legs[
  legs$skipped | legs$error | legs$failed > 0L | legs$passed < 1L,
  ,
  drop = FALSE
]
if (length(missing) || nrow(bad)) {
  if (length(missing)) {
    message("Locale legs that did not run: ", toString(missing))
  }
  if (nrow(bad)) {
    message(
      "Locale legs that skipped, failed or proved nothing: ",
      toString(bad$test)
    )
  }
  stop("the case-folding locale legs did not all run and pass", call. = FALSE)
}
cat(sprintf(
  "Locale legs ran and passed (%d expectations): %s\n",
  sum(legs$passed),
  toString(locales)
))
