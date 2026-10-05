#!/usr/bin/env Rscript
#
# Generated-docs drift gate: fails if man/ or NAMESPACE differ from what
# roxygen2 would regenerate from the roxygen comments in R/.
#
# Why this exists: a stale .Rd is still perfectly valid .Rd, so nothing else in
# the verify gate can see it. lintr::lint_package() reads R/ and never looks at
# man/; spelling::spell_check_package() reads man/ as it is; R CMD check
# --as-cran validates the Rd it is given, not whether that Rd still matches its
# source comment. The fleet's logo sweep added man/figures/logo.svg without
# re-running devtools::document(), so man/pslr-package.Rd went on describing a
# package with no logo; nothing in this gate noticed, and it was fixed by hand
# in pslr !89 (SEOR-oopopupm). Regenerating and diffing is the only thing that
# catches it (SEOR-nwfmerhu). Ported from robotstxtr's dev/check-docs-drift.R,
# written after the same failure there (ROBO-cbzemsnq).
#
# Roxygen runs through its default loader, the same one devtools::document()
# uses, so what this gate demands is exactly what the documented fix produces.
# That costs a pkgload compile of src/ (the cpp11 matcher). The fidelity is
# worth it: a cheaper loader (load_code = "source") evaluates package code
# differently, so a future dynamic doc could make the gate reject a tree that
# document() considers clean -- an unfixable failure, the worst kind for a gate
# to have.
#
# The compile also means this must not run in a directory that rcmdcheck builds
# from: pkgload leaves .o files and a .so behind in src/ (and may rewrite the
# cpp11 glue), which would contaminate the build. tools/verify.sh therefore
# runs it against its own `git archive` export of the commit being pushed
# (PRE_COMMIT_TO_REF, else HEAD), never the working tree.
#
# Usage (from the package root):
#   Rscript scripts/check-docs-drift.R [package-dir]
#
# On drift the script prints the diff, exits 1, and LEAVES the regenerated
# files in place: run against a working tree, the fix is then already applied
# and only needs committing. Run by tools/verify.sh, the regenerated files are
# in a throwaway export, so the working tree is never touched.

args <- commandArgs(trailingOnly = TRUE)
pkg <- if (length(args) > 0L) args[[1L]] else "."

desc_path <- file.path(pkg, "DESCRIPTION")
if (!file.exists(desc_path)) {
  stop(sprintf(
    "No DESCRIPTION at %s (run from the package root?)",
    normalizePath(pkg, mustWork = FALSE)
  ))
}

# Exact-equality version gate. roxygen2 changes its output formatting between
# releases, so an unpinned runner reports version skew as drift -- and when the
# installed version is the newer one, roxygen2 quietly rewrites
# Config/roxygen2/version in DESCRIPTION, which is itself an unwanted diff.
# Refusing to guess keeps every failure this gate reports a real one.
# scripts/check-toolchain.R (the check-toolchain pre-push hook) reports the
# same skew first, as a machine problem.
field <- "Config/roxygen2/version"
desc <- read.dcf(desc_path)
if (!field %in% colnames(desc)) {
  stop(sprintf(
    paste0(
      "DESCRIPTION has no %s field. This gate needs that pin to tell real doc ",
      "drift apart from roxygen2 version skew; it is written automatically by ",
      "running devtools::document() with the intended roxygen2 version."
    ),
    field
  ))
}
# unname(): indexing a read.dcf() matrix carries the column name along, and a
# named string is never identical() to the plain one from packageVersion().
pinned <- unname(trimws(desc[1L, field]))
installed <- as.character(utils::packageVersion("roxygen2"))
if (!identical(pinned, installed)) {
  stop(sprintf(
    paste0(
      "roxygen2 version skew: DESCRIPTION pins %s = %s, but roxygen2 %s is ",
      "installed. Either install the pinned version ",
      "(pak::pkg_install(\"roxygen2@%s\")), or adopt the newer roxygen2 ",
      "deliberately by running devtools::document() and committing the ",
      "resulting man/, NAMESPACE and DESCRIPTION changes together."
    ),
    field,
    pinned,
    installed,
    pinned
  ))
}

# The generated surface roxygen2 owns, relative to the package root.
watched_files <- function(root) {
  rd <- list.files(
    file.path(root, "man"),
    pattern = "[.]Rd$",
    recursive = TRUE
  )
  c(
    if (file.exists(file.path(root, "NAMESPACE"))) "NAMESPACE",
    if (length(rd) > 0L) file.path("man", rd)
  )
}

# Copy a set of package-relative paths into a flat mirror directory, so the two
# states can be diffed as trees.
mirror <- function(root, files, dest) {
  for (f in files) {
    target <- file.path(dest, f)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    file.copy(file.path(root, f), target)
  }
  dest
}

read_bytes <- function(path) readBin(path, "raw", file.size(path))

committed_files <- watched_files(pkg)
committed_dir <- mirror(pkg, committed_files, tempfile("docs-committed-"))

message(sprintf(
  "Regenerating man/ and NAMESPACE with roxygen2 %s ...",
  installed
))
roxygen2::roxygenise(pkg)

regenerated_files <- watched_files(pkg)
added <- setdiff(regenerated_files, committed_files)
removed <- setdiff(committed_files, regenerated_files)
changed <- Filter(
  function(f) {
    !identical(
      read_bytes(file.path(committed_dir, f)),
      read_bytes(file.path(pkg, f))
    )
  },
  intersect(committed_files, regenerated_files)
)

if (length(added) == 0L && length(removed) == 0L && length(changed) == 0L) {
  message("Docs in sync: man/ and NAMESPACE match the roxygen comments in R/.")
  quit(status = 0L)
}

regenerated_dir <- mirror(pkg, regenerated_files, tempfile("docs-regenerated-"))

report_paths <- function(label, paths) {
  if (length(paths) > 0L) {
    message(sprintf("  %s (%d):", label, length(paths)))
    message(paste0("    ", paths, collapse = "\n"))
  }
}

message("")
message("Generated documentation is out of date.")
report_paths("Changed", changed)
report_paths("Missing (roxygen would create)", added)
report_paths("Stale (roxygen would delete)", removed)

# git diff --no-index works outside a repository, which matters because this
# runs against a git-archive export that is not one. Exit status 1 just means
# "differences found", so the non-zero status warning is expected.
diff_out <- tryCatch(
  suppressWarnings(system2(
    "git",
    c(
      "diff",
      "--no-index",
      "--src-prefix=committed/",
      "--dst-prefix=regenerated/",
      "--",
      shQuote(committed_dir),
      shQuote(regenerated_dir)
    ),
    stdout = TRUE,
    stderr = TRUE
  )),
  error = function(e) character()
)
if (length(diff_out) > 0L) {
  # git renders a --no-index path as <prefix><absolute path minus its leading
  # slash>, so the temp directory sits between the side label and the
  # package-relative path. Strip it to leave "committed/man/foo.Rd".
  strip_dir <- function(x, dir) {
    gsub(paste0(sub("^/", "", dir), "/"), "", x, fixed = TRUE)
  }
  diff_out <- strip_dir(diff_out, committed_dir)
  diff_out <- strip_dir(diff_out, regenerated_dir)
  message("")
  message(paste(diff_out, collapse = "\n"))
}

message("")
message(
  "Fix: run devtools::document() and commit the resulting man/ and NAMESPACE ",
  "changes."
)
quit(status = 1L)
