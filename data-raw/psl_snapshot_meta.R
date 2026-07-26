#!/usr/bin/env Rscript
# Print the bundled snapshot's provenance as KEY=VALUE lines.
#
# Usage (from the package root):
#   Rscript data-raw/psl_snapshot_meta.R [<path-to-sysdata.rda>]
#
# Reads R/sysdata.rda directly with base `load()` -- no package load, no
# network, no dependency on the very index being inspected. That is what lets
# it run both BEFORE and AFTER data-raw/update_psl.R to describe what a
# regeneration actually changed. It is a reader only; regeneration logic lives
# in update_psl.R and is not duplicated here.
#
# Consumed by .github/workflows/psl-upstream-check.yaml to build its PR body.

cli_args <- commandArgs(trailingOnly = TRUE)
sysdata_path <- if (length(cli_args) >= 1L && nzchar(cli_args[1])) {
  cli_args[1]
} else {
  "R/sysdata.rda"
}

if (!file.exists(sysdata_path)) {
  stop("no such file: ", sysdata_path, call. = FALSE)
}

env <- new.env(parent = emptyenv())
load(sysdata_path, envir = env)
if (is.null(env$pslr_bundled)) {
  stop("'", sysdata_path, "' contains no `pslr_bundled` object", call. = FALSE)
}

snapshot <- env$pslr_bundled
meta <- snapshot$meta

emit <- function(key, value) {
  flat <- if (is.null(value) || length(value) == 0L) "" else as.character(value)
  cat(sprintf("%s=%s\n", key, flat[1]))
}

emit("commit", meta$commit)
emit("list_date", meta$list_date)
emit("checksum", meta$checksum)
emit("size", meta$size)
emit("rules", nrow(snapshot$rules))
emit("icann", sum(snapshot$rules$section == "icann"))
emit("private", sum(snapshot$rules$section == "private"))
emit("profile", meta$normalization_profile)
emit("unicode_version", meta$unicode_version)
emit("normalizer", meta$normalizer)
emit("normalizer_version", meta$normalizer_version)
