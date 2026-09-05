#!/usr/bin/env Rscript
# Deterministic bundled-snapshot update for pslr (PRD s8.3, s8.4).
#
# Maintainer-run. Regenerates, from a PINNED upstream commit:
#   * inst/extdata/public_suffix_list.dat  - exact MPL-2.0 source snapshot
#   * inst/extdata/PSL-LICENSE             - upstream MPL-2.0 license text
#   * inst/NOTICE                          - bundled-data notice / license split
#   * R/sysdata.rda                        - internal index + metadata
#   * README.md                            - only if a renderer is available
#
# README.md is on that list because its `psl_status()` block prints the snapshot
# metadata written above, so it is derived from the same pinned commit.
#
# Usage (from the package root):
#   Rscript data-raw/update_psl.R [<40-char-commit-sha>]
#
# The script prints the exact source URL and checksum it used. A bundled-data
# update changes query results, so it must land as a new package version with a
# changelog entry, and the upstream diff must be reviewed before committing the
# regenerated artifacts.

# --- configuration ----------------------------------------------------------

# Pinned upstream commit. Override on the command line to bump the snapshot.
default_commit <- "46ae48ceff01716409d78d38c2bbb36489cce68e"

cli_args <- commandArgs(trailingOnly = TRUE)
commit <- if (length(cli_args) >= 1L && nzchar(cli_args[1])) {
  cli_args[1]
} else {
  default_commit
}
if (!grepl("^[0-9a-f]{40}$", commit)) {
  stop("commit must be a full 40-character lowercase SHA", call. = FALSE)
}

raw_base <- "https://raw.githubusercontent.com/publicsuffix/list"
dat_url <- sprintf("%s/%s/public_suffix_list.dat", raw_base, commit)
# The canonical refresh endpoint the snapshot is associated with (see `meta`).
canonical_url <- "https://publicsuffix.org/list/public_suffix_list.dat"
license_url <- sprintf("%s/%s/LICENSE", raw_base, commit)
tests_url <- sprintf("%s/%s/tests/tests.txt", raw_base, commit)
api_url <- sprintf(
  "https://api.github.com/repos/publicsuffix/list/commits/%s",
  commit
)

dat_path <- "inst/extdata/public_suffix_list.dat"
psl_license_path <- "inst/extdata/PSL-LICENSE"
notice_path <- "inst/NOTICE"
sysdata_path <- "R/sysdata.rda"
# Official CC0 test vectors, kept in lockstep with the bundled snapshot. Lives
# under tests/testthat/fixtures/ so it ships with the package tests; the name
# avoids the `test*` pattern testthat would otherwise execute as a test file.
tests_path <- "tests/testthat/fixtures/psl-vectors.txt"

dir.create("inst/extdata", recursive = TRUE, showWarnings = FALSE)
dir.create("tests/testthat/fixtures", recursive = TRUE, showWarnings = FALSE)

# --- load the in-tree parser + policy ---------------------------------------

pkgload::load_all(".", quiet = TRUE)

# --- download the pinned snapshot -------------------------------------------

download_text <- function(url, dest) {
  utils::download.file(url, dest, mode = "wb", quiet = TRUE)
  invisible(dest)
}

download_text(dat_url, dat_path)
download_text(license_url, psl_license_path)
download_text(tests_url, tests_path)

# Commit date drives the recorded list_date; deterministic given the SHA.
commit_meta <- jsonlite::fromJSON(api_url)
list_date <- commit_meta$commit$committer$date

# --- validate + build the index ---------------------------------------------

rules <- read_psl_file(dat_path)
# Maintainer build pipeline rejects exact same-section duplicates (PRD s8.1).
rules <- apply_duplicate_policy(rules, mode = "strict")

dat_bytes <- file.size(dat_path)
checksum <- paste0("sha256:", digest::digest(file = dat_path, algo = "sha256"))

# The bundled-snapshot record. Its source-identity fields are bundled-specific:
# it carries `url` (the exact source URL) and, unlike the active `psl_meta()`
# schema, omits `path`. The normalization identifiers are the same runtime
# identifiers the package reports, so they are sourced from the shared
# `runtime_normalizer_meta()` helper (R/matcher.R) rather than re-spelled here.
# The url/no-path skew from `new_psl_meta()` is intentional (PSLR-bnrbjhur).
#
# `url` and `canonical_url` are recorded separately and mean different things.
# `url` is the immutable raw-commit origin: it pins exactly WHICH bytes shipped.
# `canonical_url` is an ASSOCIATION -- it states that those bytes came from the
# canonical refresh endpoint, which is what lets `psl_status()` name a source
# for the bundled snapshot. It does NOT assert byte-equality with what that
# endpoint serves now, so no validator and no `checked_at` are recorded here:
# the first refresh stays unconditional and a fresh install reports
# `never_checked`, never `confirmed_current`.
meta <- c(
  list(
    source = "bundled",
    url = dat_url,
    canonical_url = canonical_url,
    commit = commit,
    retrieved_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
    list_date = list_date,
    size = as.integer(dat_bytes),
    checksum = checksum
  ),
  runtime_normalizer_meta()
)

# Single internal object: the validated rule table (the index that the P3
# cpp11 matcher will consume) plus generation-time provenance metadata.
pslr_bundled <- list(rules = rules, meta = meta)

save(
  pslr_bundled,
  file = sysdata_path,
  version = 3,
  compress = "xz"
)

# --- bundled-data NOTICE ----------------------------------------------------

notice <- sprintf(
  paste(
    "pslr bundled data NOTICE",
    "========================",
    "",
    "The pslr package SOURCE CODE is licensed under the MIT License (see the",
    "top-level LICENSE file and the DESCRIPTION License field).",
    "",
    "This package additionally BUNDLES the Public Suffix List as data:",
    "",
    "  Source file: inst/extdata/public_suffix_list.dat",
    "  Project:     https://github.com/publicsuffix/list",
    "  Source URL:  %s",
    "  Commit:      %s",
    "  Checksum:    %s",
    "",
    "The Public Suffix List source above and every derived representation",
    "bundled in this package (the internal index in R/sysdata.rda) are",
    "licensed under the Mozilla Public License 2.0 (MPL-2.0), NOT the MIT",
    "license. The full MPL-2.0 text is included at inst/extdata/PSL-LICENSE.",
    "",
    "The package-code license (MIT) and the bundled-data license (MPL-2.0) are",
    "separate; use of the bundled list data is governed by MPL-2.0.",
    sep = "\n"
  ),
  dat_url,
  commit,
  checksum
)
writeLines(notice, notice_path)

# --- report -----------------------------------------------------------------

message("Bundled PSL snapshot regenerated:")
message("  source URL: ", dat_url)
message("  commit:     ", commit)
message("  list_date:  ", list_date)
message("  size:       ", dat_bytes, " bytes")
message("  checksum:   ", checksum)
message(
  "  rules:      ",
  nrow(rules),
  " (icann: ",
  sum(rules$section == "icann"),
  ", private: ",
  sum(rules$section == "private"),
  ")"
)
message(
  "  profile:    ",
  meta$normalization_profile,
  " / Unicode ",
  meta$unicode_version
)
message("  vectors:    ", tests_path)
message("Review the upstream diff before committing the regenerated artifacts.")

# --- README.md --------------------------------------------------------------

# README.md is generated from README.Rmd, whose `freshness` chunk prints live
# `psl_status()` output -- the checksum, content date and retrieval time this
# script has just written into R/sysdata.rda. The README is therefore derived
# from the same pinned commit as the artifacts above, and a snapshot bump that
# leaves it behind puts the previous snapshot's provenance on the package's
# front page (PSLR-qjsszyig, after PSLR-ucvugmsw did exactly that). Regenerating
# it here means it moves in the same working tree as the data it describes.
#
# Nothing below may abort. The data artifacts are already written, correct and
# reported above; turning a rendering problem into a stack trace would bury that
# report under a failure that has nothing to do with the snapshot. Every path
# that cannot render says so and exits normally, so the operator is never left
# to discover the staleness from a CI diff weeks later.

readme_is_stale <- function(reason) {
  message("")
  message("WARNING: ", reason)
  message(
    "WARNING: ",
    "README.md is now stale — run devtools::build_readme() and commit it."
  )
}

# The pandoc version CI pins, read from .gitlab-ci.yml exactly the way
# tools/verify.sh's run_readme reads it, so the two cannot drift apart.
pinned_pandoc_version <- function(path = ".gitlab-ci.yml") {
  if (!file.exists(path)) {
    return(NA_character_)
  }
  pattern <- '^  PANDOC_VERSION: "(.+)"'
  hit <- grep(pattern, readLines(path, warn = FALSE), value = TRUE)
  if (length(hit) == 0L) {
    return(NA_character_)
  }
  sub(pattern, "\\1", hit[1])
}

# `pandoc --version` opens with `pandoc <version>`; run_readme takes the same
# second field of the same first line.
local_pandoc_version <- function() {
  out <- tryCatch(
    suppressWarnings(system2("pandoc", "--version", stdout = TRUE)),
    error = function(e) character()
  )
  if (length(out) == 0L || !nzchar(out[1])) {
    return(NA_character_)
  }
  strsplit(trimws(out[1]), "[[:space:]]+")[[1]][2]
}

# Returns the reason README.md cannot be regenerated here, or NULL to go ahead.
readme_render_blocker <- function() {
  # PATH pandoc, not RSTUDIO_PANDOC: this is the version run_readme compares and
  # the one a plain `Rscript` render picks up, so both halves see one binary.
  if (!nzchar(Sys.which("pandoc"))) {
    return("pandoc is not on PATH, so README.Rmd cannot be rendered here.")
  }

  # devtools drives the render, but rmarkdown and callr are only Suggests of
  # devtools -- `requireNamespace("devtools")` alone does not prove the renderer
  # is installed, and build_readme() would abort inside check_installed().
  needed <- c("devtools", "rmarkdown", "callr")
  absent <- needed[
    !vapply(needed, requireNamespace, logical(1), quietly = TRUE)
  ]
  if (length(absent) > 0L) {
    return(sprintf(
      "%s not installed, so README.Rmd cannot be rendered here.",
      toString(absent)
    ))
  }

  # run_readme only warns on a version skew, because it renders and then diffs.
  # Here the render lands in the working tree, so a skew blocks it outright:
  # pandoc versions disagree about pipe-table cell padding, and a
  # whitespace-only diff that has to be told apart from a real content change by
  # hand is worse than a message naming the version to install.
  want <- pinned_pandoc_version()
  have <- local_pandoc_version()
  if (!is.na(want) && !is.na(have) && !identical(want, have)) {
    return(sprintf(
      paste0(
        "local pandoc is %s but .gitlab-ci.yml pins %s; not rendering, ",
        "because a mismatched pandoc reflows the tables."
      ),
      have,
      want
    ))
  }

  NULL
}

readme_blocker <- readme_render_blocker()
if (is.null(readme_blocker)) {
  readme_blocker <- tryCatch(
    {
      devtools::build_readme()
      NULL
    },
    error = function(e) {
      paste0("devtools::build_readme() failed: ", conditionMessage(e))
    }
  )
}
if (is.null(readme_blocker)) {
  message("  README.md:  regenerated from README.Rmd")
} else {
  readme_is_stale(readme_blocker)
}
