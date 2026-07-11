# Refresh and list activation (PRD s7.4, s8.3, s9).
#
# `psl_use()` switches the active list between the bundled snapshot, the user
# cache, and a custom path; `psl_refresh()` performs the only network access in
# the package -- an explicit, validated, https-only download published into the
# user cache under an atomic commit protocol. Both validate fully before they
# change any session state, and a failure leaves the previous cache and active
# matcher usable.

# Documented maximum source size accepted before parsing (PRD s7.4). The real
# list is well under 1 MB; the ceiling guards against a pathological or wrong
# download without rejecting plausible upstream growth. Exposed as an option so
# tests can drive the size guard without a multi-megabyte fixture.
psl_max_source_bytes <- function() {
  getOption("pslr.max_bytes", 16777216L) # 16 MiB
}

# User cache directory. `tools::R_user_dir()` is an R-approved location, so
# writing here is allowed under `R CMD check --as-cran` (PRD s11.3). Tests point
# `pslr.cache_dir` at a temporary directory to stay hermetic.
psl_cache_dir <- function() {
  getOption("pslr.cache_dir", tools::R_user_dir("pslr", "cache"))
}

# Path of the single commit marker that names the active cache snapshot.
psl_cache_marker <- function() file.path(psl_cache_dir(), "current.rds")

# Schema version stamped into newly written commit markers. It gives future
# releases a migration seam: a reader can branch on the recorded version.
# Markers written by earlier pslr releases omit the field entirely; the manifest
# validator treats an absent version as a compatible legacy marker, so upgrading
# never rejects a real cache already on disk.
psl_manifest_version <- 1L

# Source checksum with an algorithm prefix (PRD s7.4). Prefers SHA-256 via
# `digest` to match the bundled snapshot; falls back to base-R MD5 so the cache
# path works on a clean install without optional packages. The prefix
# disambiguates the algorithm either way.
psl_source_checksum <- function(path) {
  if (requireNamespace("digest", quietly = TRUE)) {
    paste0("sha256:", digest::digest(file = path, algo = "sha256"))
  } else {
    paste0("md5:", unname(tools::md5sum(path)))
  }
}

# Compute one specific checksum algorithm for algorithm-directed verification.
# Unlike `psl_source_checksum()` -- which picks whatever hash is available when
# RECORDING -- this reproduces the exact algorithm a checksum was recorded with,
# so verification compares like with like. "sha256" needs the optional `digest`
# package; verifying a sha256-recorded cache on a machine that lacks `digest` is
# a missing dependency, not corruption, so raise an actionable install error
# rather than a spurious mismatch.
psl_checksum <- function(path, algorithm) {
  if (identical(algorithm, "sha256")) {
    if (!requireNamespace("digest", quietly = TRUE)) {
      stop(
        "This PSL cache recorded a sha256 checksum, which needs the 'digest' ",
        "package to verify; install it with install.packages(\"digest\").",
        call. = FALSE
      )
    }
    paste0("sha256:", digest::digest(file = path, algo = "sha256"))
  } else if (identical(algorithm, "md5")) {
    paste0("md5:", unname(tools::md5sum(path)))
  } else {
    stop(
      sprintf("unsupported checksum algorithm: %s", algorithm),
      call. = FALSE
    )
  }
}

# Verify a file against a recorded, algorithm-prefixed checksum. Recomputes the
# SAME algorithm named by the prefix and compares, so a match/mismatch reflects
# genuine content -- never which optional package happens to be installed. When
# the recorded algorithm's implementation is unavailable, `psl_checksum()`
# raises the actionable dependency error rather than reporting a false mismatch.
psl_verify_checksum <- function(path, expected) {
  algorithm <- sub(":.*$", "", expected)
  identical(psl_checksum(path, algorithm), expected)
}

# Atomic-as-possible rename within the cache directory. A same-filesystem rename
# is atomic on POSIX; if the destination exists (Windows cannot rename onto an
# existing file) it is removed first and the rename retried.
psl_atomic_rename <- function(from, to) {
  if (file.rename(from, to)) {
    return(invisible(to))
  }
  unlink(to)
  if (!file.rename(from, to)) {
    stop(sprintf("could not publish cache file to %s", to), call. = FALSE)
  }
  invisible(to)
}

# Validate, parse, and index a PSL source file under the runtime normalizer.
# Enforces the size ceiling, applies the lenient runtime duplicate policy (warn
# and deduplicate exact same-section duplicates; conflicting kinds are fatal),
# and requires both official sections (PRD s7.4, s8.1). Returns the rule table.
psl_load_source <- function(path, what = "list") {
  size <- file.size(path)
  if (is.na(size)) {
    stop(sprintf("%s source file not readable: %s", what, path), call. = FALSE)
  }
  max_bytes <- psl_max_source_bytes()
  if (size > max_bytes) {
    stop(
      sprintf(
        "%s source is %.0f bytes, over the %.0f-byte maximum.",
        what,
        size,
        max_bytes
      ),
      call. = FALSE
    )
  }
  rules <- apply_duplicate_policy(read_psl_file(path), mode = "lenient")
  have <- unique(rules$section)
  if (!all(c("icann", "private") %in% have)) {
    stop(
      sprintf(
        "%s needs both an ICANN and a PRIVATE section (official markers).",
        what
      ),
      call. = FALSE
    )
  }
  rules
}

# A current marker can be reused only when it is still within the upstream
# courtesy window and still names an existing source file with the recorded
# checksum.
psl_reusable_cache_path <- function(current, cache_dir) {
  if (is.null(current) || is.na(current$meta$retrieved_at)) {
    return(NA_character_)
  }
  retrieved_at <- as.POSIXct(current$meta$retrieved_at, tz = "UTC")
  fresh <- difftime(Sys.time(), retrieved_at, units = "hours") < 24
  dat <- file.path(cache_dir, current$dat_file)
  valid <- file.exists(dat) &&
    psl_verify_checksum(dat, current$meta$checksum)
  if (fresh && valid) dat else NA_character_
}

psl_cache_meta <- function(dat, current) {
  psl_meta(
    source = "cache",
    path = dat,
    retrieved_at = current$meta$retrieved_at,
    size = current$meta$size,
    checksum = current$meta$checksum
  )
}

# Build the snapshot descriptor for a validated cached source: read and validate
# the cached `.dat`, pair it with the marker-derived metadata. The shared loader
# behind both cache-activation paths.
psl_load_cached_snapshot <- function(dat, current) {
  new_psl_snapshot(psl_load_source(dat, "cache"), psl_cache_meta(dat, current))
}

psl_cache_version <- function(dat, current, activate = FALSE) {
  meta <- psl_cache_meta(dat, current)
  if (activate) {
    psl_activate_snapshot(psl_load_cached_snapshot(dat, current))
  }
  psl_version_df(meta)
}

psl_reused_cache_version <- function(force, current, cache_dir, activate) {
  if (force || is.null(current)) {
    return(NULL)
  }
  dat <- psl_reusable_cache_path(current, cache_dir)
  if (is.na(dat)) {
    return(NULL)
  }
  psl_cache_version(dat, current, activate)
}

psl_publish_download <- function(tmp, rules, cache_dir) {
  checksum <- psl_source_checksum(tmp)
  size <- as.integer(file.size(tmp))
  retrieved_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)

  # Publish: content-addressed source first (immutable, never overwritten), then
  # the commit marker as the single atomic commit point.
  hex <- sub("^[^:]+:", "", checksum)
  dat_final <- file.path(cache_dir, paste0("psl-", hex, ".dat"))
  if (
    file.exists(dat_final) &&
      psl_verify_checksum(dat_final, checksum)
  ) {
    unlink(tmp)
  } else {
    psl_atomic_rename(tmp, dat_final)
  }

  meta <- psl_meta(
    source = "cache",
    path = dat_final,
    retrieved_at = retrieved_at,
    size = size,
    checksum = checksum
  )
  tmp_marker <- tempfile("pslr-cur-", tmpdir = cache_dir, fileext = ".rds")
  saveRDS(
    list(
      manifest_version = psl_manifest_version,
      dat_file = basename(dat_final),
      meta = meta
    ),
    tmp_marker
  )
  psl_atomic_rename(tmp_marker, psl_cache_marker())
  list(rules = rules, meta = meta)
}

psl_validate_refresh_args <- function(force, activate) {
  if (!is.logical(force) || length(force) != 1L || is.na(force)) {
    stop("`force` must be a single TRUE or FALSE.", call. = FALSE)
  }
  if (!is.logical(activate) || length(activate) != 1L || is.na(activate)) {
    stop("`activate` must be a single TRUE or FALSE.", call. = FALSE)
  }
  invisible(NULL)
}

psl_stage_download <- function(url, downloader, cache_dir) {
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile("pslr-dl-", tmpdir = cache_dir, fileext = ".part")
  staged <- FALSE
  on.exit(if (!staged) unlink(tmp), add = TRUE)
  downloader(url, tmp, psl_max_source_bytes())
  staged <- TRUE
  tmp
}

psl_activate_published <- function(published, activate) {
  if (activate) {
    psl_set_active(published$rules, published$meta)
  }
  invisible(NULL)
}

# Handle a corrupt commit marker per `on_corrupt`: "error" raises the pslr
# cache-corruption error (base `stop(call. = FALSE)`, with remediation) used by
# activation paths; "null" treats the marker as no cache so a forced refresh can
# overwrite it. `detail` names the specific fault.
psl_cache_corrupt <- function(on_corrupt, detail) {
  if (identical(on_corrupt, "error")) {
    stop(
      sprintf(
        "PSL cache is corrupt: %s. Run psl_refresh(force = TRUE).",
        detail
      ),
      call. = FALSE
    )
  }
  NULL
}

# A well-formed commit marker deserializes to a list naming an existing source
# file (`dat_file`) plus a `meta` list carrying the identity fields the cache
# reader consumes unchecked (`checksum`, `retrieved_at`, `size`). A readable but
# structurally wrong marker -- missing `dat_file`, a short/absent `meta`, wrong
# types -- would otherwise pass silently and turn into NULL `$` reads
# downstream; validating here turns those into a clean corruption error. The
# `manifest_version` field is intentionally not required: markers written by
# earlier pslr releases omit it and stay valid.
valid_psl_manifest <- function(x) {
  is_scalar_string <- function(s) {
    is.character(s) && length(s) == 1L && !is.na(s) && nzchar(s)
  }
  is_scalar_of <- function(v, pred) pred(v) && length(v) == 1L
  if (!is.list(x) || !is.list(x$meta)) {
    return(FALSE)
  }
  # Each field must be present with the right scalar shape; `all()` keeps the
  # per-field checks flat rather than one long `&&` chain.
  all(
    is_scalar_string(x$dat_file),
    is_scalar_string(x$meta$checksum),
    is_scalar_of(x$meta$retrieved_at, is.character),
    is_scalar_of(x$meta$size, is.numeric)
  )
}

# Read the cache commit marker, or NULL when no cache has been published.
# A marker that exists but cannot be deserialized (corrupt/truncated bytes) or
# that deserializes to a structurally malformed manifest is handled per
# `on_corrupt`: "null" treats it as no cache (so a forced refresh overwrites it
# instead of leaking a raw readRDS error or a later NULL `$` read), while
# "error" raises a pslr cache-corruption error with remediation for activation
# paths. Both faults funnel through the one `on_corrupt` handler.
psl_cache_current <- function(on_corrupt = c("null", "error")) {
  on_corrupt <- match.arg(on_corrupt)
  marker <- psl_cache_marker()
  if (!file.exists(marker)) {
    return(NULL)
  }
  # Distinct by-reference sentinel: a real marker never deserializes to it, so
  # `identical()` tells an unreadable marker apart from a merely malformed one
  # without a `<<-` flag out of the error handler.
  unreadable <- new.env()
  manifest <- tryCatch(readRDS(marker), error = function(e) unreadable)
  if (identical(manifest, unreadable)) {
    return(psl_cache_corrupt(on_corrupt, "marker metadata is unreadable"))
  }
  if (!valid_psl_manifest(manifest)) {
    return(psl_cache_corrupt(on_corrupt, "marker metadata is malformed"))
  }
  manifest
}

# Default network downloader (PRD s7.4). Requires `curl` so the package can
# enforce the https-only, no-downgrade-redirect policy: redirects are followed
# but the effective URL must remain https, and the size ceiling caps the
# transfer. Tests and advanced callers inject their own downloader instead.
psl_default_download <- function(url, destfile, max_bytes) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop(
      "psl_refresh() needs the 'curl' package to download lists over https; ",
      "install it or pass a custom downloader.",
      call. = FALSE
    )
  }
  h <- curl::new_handle(
    followlocation = TRUE,
    maxfilesize_large = as.numeric(max_bytes)
  )
  res <- curl::curl_fetch_disk(url, destfile, handle = h)
  if (!startsWith(tolower(res$url), "https://")) {
    stop(
      "refresh refused: download redirected to a non-HTTPS URL.",
      call. = FALSE
    )
  }
  if (res$status_code >= 400L) {
    stop(
      sprintf("refresh failed: HTTP status %d.", res$status_code),
      call. = FALSE
    )
  }
  invisible(destfile)
}

# Validate a refresh URL: absolute https, no embedded credentials (PRD s7.4).
psl_validate_refresh_url <- function(url) {
  if (!is.character(url) || length(url) != 1L || is.na(url) || !nzchar(url)) {
    stop("`url` must be a single non-missing string.", call. = FALSE)
  }
  if (!grepl("^https://", url, ignore.case = TRUE)) {
    stop("`url` must be an absolute https URL.", call. = FALSE)
  }
  authority <- sub("^https://", "", url, ignore.case = TRUE)
  authority <- sub("[/?#].*$", "", authority)
  if (grepl("@", authority, fixed = TRUE)) {
    stop("`url` must not contain embedded credentials.", call. = FALSE)
  }
  invisible(url)
}

#' Refresh the cached Public Suffix List from upstream
#'
#' Downloads, validates, and publishes a fresh Public Suffix List into the user
#' cache. This is the only function in the package that accesses the network,
#' and only when you call it explicitly.
#'
#' @param url Absolute `https` URL of the list source. Defaults to the official
#'   list. URLs with another scheme or embedded credentials are rejected, and a
#'   redirect to a non-HTTPS URL is refused.
#' @param force When `FALSE` (default), a successfully validated cache younger
#'   than 24 hours is reused without a download, respecting upstream download
#'   guidance. `TRUE` forces a fresh download.
#' @param activate When `TRUE`, the resulting snapshot becomes the active list
#'   for the session, exactly as [psl_use()] would activate it. When `FALSE`
#'   (default), the cache is updated but the active list is unchanged.
#'
#' @details
#' Cache age is measured from the successful network retrieval timestamp;
#' reusing a fresh cache does not advance that timestamp. The download goes to a
#' temporary file in binary mode and must be no larger than a documented maximum
#' (16 MiB). The source is then fully validated -- UTF-8, section markers, rule
#' grammar, conflicting rules, and successful canonicalization of every rule --
#' and exact same-section duplicates warn once and are deduplicated. Source and
#' metadata are published only after validation succeeds, using an atomic commit
#' that never exposes a partial or mismatched snapshot. A failed refresh never
#' replaces a valid cache or the active matcher.
#'
#' @return Invisibly, a one-row [data.frame] shaped like [psl_version()]
#'   describing the selected cache snapshot, whether or not it was activated.
#' @seealso [psl_use()], [psl_version()]
#' @examples
#' if (interactive()) {
#'   psl_refresh()
#'   psl_refresh(force = TRUE, activate = TRUE)
#' }
#' @export
psl_refresh <- function(
  url = "https://publicsuffix.org/list/public_suffix_list.dat",
  force = FALSE,
  activate = FALSE
) {
  psl_validate_refresh_url(url)
  psl_validate_refresh_args(force, activate)
  # Internal seam for tests: an injected downloader replaces the network call.
  downloader <- getOption("pslr.downloader", psl_default_download)

  cache_dir <- psl_cache_dir()
  current <- psl_cache_current()
  reused <- psl_reused_cache_version(force, current, cache_dir, activate)
  if (!is.null(reused)) {
    return(invisible(reused))
  }

  tmp <- psl_stage_download(url, downloader, cache_dir)
  on.exit(unlink(tmp), add = TRUE)
  rules <- psl_load_source(tmp, "downloaded list")
  published <- psl_publish_download(tmp, rules, cache_dir)
  psl_activate_published(published, activate)
  invisible(psl_version_df(published$meta))
}

psl_activate_cache <- function() {
  current <- psl_cache_current(on_corrupt = "error")
  if (is.null(current)) {
    stop(
      "No validated PSL cache found. Run psl_refresh(activate = TRUE) ",
      "first, or use psl_use(\"bundled\").",
      call. = FALSE
    )
  }
  dat <- file.path(psl_cache_dir(), current$dat_file)
  if (!file.exists(dat)) {
    stop(
      "PSL cache is corrupt: source file is missing. ",
      "Run psl_refresh(force = TRUE).",
      call. = FALSE
    )
  }
  if (!psl_verify_checksum(dat, current$meta$checksum)) {
    stop(
      "PSL cache is corrupt: checksum mismatch. ",
      "Run psl_refresh(force = TRUE).",
      call. = FALSE
    )
  }
  psl_activate_snapshot(psl_load_cached_snapshot(dat, current))
  invisible(psl_version())
}

# Build the snapshot descriptor for a custom PSL source file. Validates the
# path, loads and validates the source under the runtime normalizer, and pairs
# it with the path-source metadata. Pure: builds and returns the snapshot
# without touching session state; errors on a missing/NULL path exactly as
# `psl_use("path")` does today.
# @noRd
path_snapshot <- function(path) {
  bad_path <- is.null(path) ||
    !is.character(path) ||
    length(path) != 1L ||
    is.na(path)
  if (bad_path) {
    stop(
      "`path` must be a single file path when `source = \"path\"`.",
      call. = FALSE
    )
  }
  if (!file.exists(path)) {
    stop(sprintf("PSL source file not found: %s", path), call. = FALSE)
  }
  rules <- psl_load_source(path, "custom path list")
  meta <- psl_meta(
    source = "path",
    path = normalizePath(path),
    size = as.integer(file.size(path)),
    checksum = psl_source_checksum(path)
  )
  new_psl_snapshot(rules, meta)
}

psl_activate_path <- function(path) {
  psl_activate_snapshot(path_snapshot(path))
  invisible(psl_version())
}

#' Choose the active Public Suffix List for this session
#'
#' Switches the list backing every query in the current R session. The change is
#' session-only and is validated before any session state changes; a failure
#' leaves the previously active list usable. A successful switch invalidates the
#' match-result cache.
#'
#' @param source Where to load the list from: `"bundled"` (the pinned package
#'   snapshot), `"cache"` (the latest successfully validated snapshot from
#'   [psl_refresh()]), or `"path"` (a custom file).
#' @param path For `source = "path"`, a single readable PSL-format UTF-8 file
#'   containing one complete ICANN section and one complete PRIVATE section,
#'   using official markers. Must be `NULL` for any other source.
#'
#' @details
#' A custom path is held to the same runtime duplicate policy as
#' [psl_refresh()]: exact same-section duplicates warn once and are
#' deduplicated, while conflicting rule kinds for the same labels are fatal.
#' Cache and custom-path sources are read in source form and indexed under the
#' runtime normalizer; they never reuse the bundled generated index.
#'
#' @return Invisibly, the [psl_version()] row for the newly active list.
#' @seealso [psl_refresh()], [psl_version()], [psl_rules()]
#' @examples
#' psl_use("bundled")
#' if (interactive()) {
#'   psl_use("cache")
#'   psl_use("path", path = "my_list.dat")
#' }
#' @export
psl_use <- function(source = "bundled", path = NULL) {
  source <- check_choice(source, c("bundled", "cache", "path"), "source")
  if (!identical(source, "path") && !is.null(path)) {
    stop("`path` is only used when `source = \"path\"`.", call. = FALSE)
  }

  if (identical(source, "bundled")) {
    activate_bundled()
    return(invisible(psl_version()))
  }

  if (identical(source, "cache")) {
    return(psl_activate_cache())
  }

  # The remaining source is "path".
  psl_activate_path(path)
}

# Validate the retention count for psl_cache_prune(): a single non-negative
# whole number. Mirrors the scalar-guard idiom of psl_validate_refresh_args().
psl_validate_keep <- function(keep) {
  # Gate on scalar-numeric-non-missing first (short-circuit), then check the
  # value constraints vectorized so the guard is not one long `||` chain.
  ok <- is.numeric(keep) &&
    length(keep) == 1L &&
    !is.na(keep) &&
    isTRUE(keep >= 0 & keep == trunc(keep))
  if (!ok) {
    stop("`keep` must be a single non-negative whole number.", call. = FALSE)
  }
  invisible(NULL)
}

#' Prune stale on-disk PSL cache snapshots
#'
#' Removes superseded `psl-<hex>.dat` snapshot files from the user cache
#' directory, always keeping the snapshot named by the active commit marker plus
#' the `keep` most-recent other snapshots by modification time.
#'
#' @details
#' Each [psl_refresh()] that finds changed upstream content writes a new
#' content-addressed snapshot and repoints the commit marker at it, but never
#' removes the snapshot it supersedes; across many refreshes these accumulate.
#' `psl_cache_prune()` reclaims that space.
#'
#' This operates on the *on-disk* snapshot files and is distinct from
#' `psl_cache_clear()`, which flushes the in-memory match-result cache for the
#' current session: pruning deletes stale `.dat` files from disk to reclaim
#' space, whereas clearing only discards computed query results. Pruning never
#' changes which list is active and never removes the active snapshot, so the
#' active matcher and a later `psl_use("cache")` keep working.
#'
#' When there is no cache directory or no commit marker (nothing has been
#' published yet), there is no active snapshot to anchor retention on, so the
#' call is a no-op that returns an empty vector rather than an error.
#'
#' @param keep Number of previous snapshots to retain *in addition to* the
#'   active one, as a single non-negative whole number. The default `1` keeps
#'   the current snapshot and one previous snapshot (two `.dat` files). `0`
#'   keeps only the active snapshot; the active snapshot is never removed, even
#'   then.
#'
#' @return Invisibly, a character vector of the removed snapshot file paths,
#'   empty when nothing was pruned.
#' @seealso [psl_refresh()], which writes the snapshots this prunes;
#'   [psl_use()].
#' @examples
#' if (interactive()) {
#'   psl_refresh(force = TRUE)
#'   psl_cache_prune() # keep the current snapshot and one previous
#'   psl_cache_prune(keep = 0) # keep only the active snapshot
#' }
#' @export
psl_cache_prune <- function(keep = 1L) {
  psl_validate_keep(keep)
  keep <- as.integer(keep)

  cache_dir <- psl_cache_dir()
  if (!dir.exists(cache_dir)) {
    return(invisible(character(0)))
  }
  current <- psl_cache_current()
  if (is.null(current)) {
    return(invisible(character(0)))
  }

  snapshots <- list.files(
    cache_dir,
    pattern = "^psl-.*\\.dat$",
    full.names = TRUE
  )
  # Everything except the active snapshot is a pruning candidate.
  others <- snapshots[basename(snapshots) != current$dat_file]
  if (length(others) <= keep) {
    return(invisible(character(0)))
  }
  # Keep the `keep` most-recent candidates by mtime; remove the rest.
  others <- others[order(file.mtime(others), decreasing = TRUE)]
  stale <- others[(keep + 1L):length(others)]
  unlink(stale)
  invisible(stale)
}
