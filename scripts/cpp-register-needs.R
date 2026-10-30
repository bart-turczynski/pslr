#!/usr/bin/env Rscript
#
# Install what cpp11::cpp_register() needs into the gate's run library, ahead
# of the docs-drift gate (.fleet-ci.yml's cheap_gates).
#
#   Rscript scripts/cpp-register-needs.R "$R_LIBS"
#
# scripts/check-docs-drift.R runs roxygen2, which loads pslr with pkgload,
# which compiles src/ and runs cpp11::cpp_register(). That needs packages pslr
# does not declare (decor today), so the gate's dependency install, which
# resolves DESCRIPTION alone, leaves them out and the drift check stops with
# "The decor package(s) are required". The installed cpp11 names them itself,
# in its own Config/Needs/cpp11/cpp_register field, so a cpp11 release that
# adds one needs no edit here. The former `docs-drift` CI job read the same
# field the same way.
#
# Any warning is an error: install.packages() reports a failed download or
# build as a warning and returns, which would leave the package missing and
# the drift check failing for a reason that is not drift.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L || !nzchar(args[[1L]])) {
  stop("usage: Rscript scripts/cpp-register-needs.R LIB", call. = FALSE)
}
lib <- strsplit(args[[1L]], .Platform$path.sep, fixed = TRUE)[[1L]][[1L]]
if (!dir.exists(lib)) {
  stop("run library '", lib, "' does not exist", call. = FALSE)
}
desc <- system.file("DESCRIPTION", package = "cpp11", lib.loc = lib)
if (!nzchar(desc)) {
  stop("cpp11 is not in the run library '", lib, "'", call. = FALSE)
}
needs <- read.dcf(desc, "Config/Needs/cpp11/cpp_register")[[1L]]
if (is.na(needs)) {
  stop(
    "cpp11 declares no Config/Needs/cpp11/cpp_register; check what ",
    "cpp_register() needs",
    call. = FALSE
  )
}
needs <- trimws(strsplit(needs, ",", fixed = TRUE)[[1L]])
needs <- sub("[[:space:]]*\\(.*$", "", needs[nzchar(needs)])
.libPaths(c(lib, .libPaths()))
missing <- needs[!vapply(needs, requireNamespace, NA, quietly = TRUE)]
if (length(missing)) {
  cat("cpp-register-needs: installing", toString(missing), "into", lib, "\n")
  local({
    op <- options(warn = 2L)
    on.exit(options(op))
    utils::install.packages(missing, lib = lib)
  })
}
still <- needs[!vapply(needs, requireNamespace, NA, quietly = TRUE)]
if (length(still)) {
  stop("still missing after the install: ", toString(still), call. = FALSE)
}
cat("cpp-register-needs: present:", toString(needs), "\n")
