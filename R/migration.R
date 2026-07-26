# Legacy (v1) cache migration into v2 generations.
#
# A pslr cache written before the freshness redesign is flat: one commit marker
# (`current.rds`) plus content-addressed `psl-<hex>.dat` files, with no source
# stream, no selection stream, and no record of a remote check. This file turns
# that state into v2 generations without destroying anything.
#
# Five rules shape the whole design:
#
#   1. Offline inspection stays read-only. Nothing here runs from a read path;
#      migration happens only when an explicit mutator calls it.
#   2. It runs under the publish lock, so two processes cannot both import the
#      same legacy state.
#   3. Legacy bytes are imported only after their recorded checksum verifies
#      AND the bytes pass full PSL validation. Either check failing means the
#      cache is unprovable and nothing is imported.
#   4. SHA-256 identity is retained; verified MD5-era bytes are re-identified by
#      SHA-256. The original file is never modified -- a copy is published.
#   5. The v1 `retrieved_at` is preserved, `checked_at` stays `NA`, and no
#      validator is invented. A migrated cache therefore never reports as
#      remotely confirmed before its first real refresh.
#
# Every legacy file survives migration untouched, including `current.rds`: v1
# state is evidence, not scratch space, and leaving it in place keeps a
# downgrade and a manual repair possible.

# ---------------------------------------------------------------------------
# Source attribution
# ---------------------------------------------------------------------------

# The request URL a migrated v1 cache is attributed to.
#
# v1 recorded no request URL per snapshot, so attribution has to be inferred.
# The canonical endpoint is the only defensible choice: it is what v1's
# `psl_refresh()` used by default. Attribution is safe even for a cache that
# actually came from a custom URL, because migration carries no validator and
# no `checked_at`: the first v2 refresh of this source is unconditional, so a
# mis-attributed cache can never produce a false `304` or a false freshness
# claim. The snapshot descriptor's `origin_url` stays `NA`, which records the
# honest fact that the true origin of the bytes is unknown.
psl_legacy_request_url <- "https://publicsuffix.org/list/public_suffix_list.dat"

# ---------------------------------------------------------------------------
# Reading legacy state
# ---------------------------------------------------------------------------

# Parse a v1 `retrieved_at`, which is `format(Sys.time(), tz = "UTC", usetz =
# TRUE)` -- not RFC 3339. Returns the persisted v2 timestamp, or `NA` when the
# recorded value cannot be parsed; an unreadable time is reported as unknown
# rather than replaced with "now", which would invent freshness v1 never had.
psl_legacy_retrieved_at <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    return(NA_character_)
  }
  parsed <- as.POSIXct(x, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
  if (is.na(parsed)) {
    parsed <- psl_parse_time(x)
  }
  if (is.na(parsed)) NA_character_ else psl_format_time(parsed)
}

# Is any v2 generation stream already published in this cache?
#
# Both streams count. A selection generation means `psl_use("cache")` already
# resolves through v2, and a source stream means some source already has v2
# knowledge; in either case the legacy marker is history and importing it would
# either duplicate a snapshot or move the selection backwards.
psl_v2_state_present <- function() {
  if (length(psl_generation_numbers(psl_selection_stream_dir()))) {
    return(TRUE)
  }
  sources <- file.path(psl_cache_dir(), "sources")
  if (!dir.exists(sources)) {
    return(FALSE)
  }
  streams <- list.dirs(sources, recursive = FALSE)
  any(vapply(streams, \(d) length(psl_generation_numbers(d)) > 0L, logical(1L)))
}

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

# One migration outcome. `status` is the coarse result a caller branches on:
#
#   * `absent`      -- no v1 marker; nothing to do.
#   * `skipped`     -- v2 generations already exist; migration is a no-op.
#   * `migrated`    -- the legacy snapshot was imported.
#   * `unprovable`  -- a v1 marker exists but its data cannot be proven sound;
#                      nothing was imported and nothing was touched.
#   * `busy`        -- the publish lock was held elsewhere; nothing was done.
#
# `reason` names the specific fault behind `unprovable`, and `message` carries
# the remediation text a caller surfaces to the user.
psl_migration_result <- function(
  status,
  ...,
  reason = NA_character_,
  checksum = NA_character_,
  retrieved_at = NA_character_,
  request_url = NA_character_,
  path = NA_character_,
  message = NA_character_
) {
  psl_check_empty_dots(...)
  list(
    status = status,
    reason = reason,
    checksum = checksum,
    retrieved_at = retrieved_at,
    request_url = request_url,
    path = path,
    message = message
  )
}

# Human-readable detail for each way legacy data can fail to prove itself.
psl_migration_faults <- c(
  marker_malformed = "its commit marker is unreadable or malformed",
  bytes_missing = "the snapshot file it names is missing",
  checksum_unreadable = "its recorded checksum is not a checksum pslr wrote",
  checksum_mismatch = "the snapshot file does not match its recorded checksum",
  invalid_list = "the snapshot file is not a valid Public Suffix List"
)

# Build the unprovable outcome, including remediation. The legacy files are
# named so a user can inspect or remove them deliberately; pslr will not.
psl_migration_unprovable <- function(reason, path = NA_character_) {
  psl_migration_result(
    "unprovable",
    reason = reason,
    path = path,
    message = sprintf(
      paste0(
        "A legacy PSL cache in %s could not be migrated because %s. ",
        "Nothing was changed or deleted. Run psl_refresh(force = TRUE) to ",
        "publish a fresh snapshot; the legacy files can then be removed by ",
        "hand."
      ),
      psl_cache_dir(),
      psl_migration_faults[[reason]]
    )
  )
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# Prove a legacy snapshot file, or name the reason it cannot be proven.
#
# Two independent proofs are required and neither substitutes for the other:
# the recorded checksum must reproduce (the bytes are the bytes v1 committed)
# and the bytes must parse and validate as a complete PSL (they are usable).
# Duplicate-rule warnings from the parser are the runtime's lenient policy, not
# a migration fault, so they are muffled here.
psl_migration_verify <- function(path, recorded) {
  if (!file.exists(path)) {
    return("bytes_missing")
  }
  parsed <- psl_parse_checksum(recorded)
  if (is.null(parsed)) {
    return("checksum_unreadable")
  }
  actual <- psl_checksum(path, parsed$algorithm)
  if (!identical(actual, paste0(parsed$algorithm, ":", parsed$hex))) {
    return("checksum_mismatch")
  }
  ok <- tryCatch(
    {
      suppressWarnings(psl_load_source(path, "legacy cache"))
      TRUE
    },
    error = \(e) FALSE
  )
  if (ok) NA_character_ else "invalid_list"
}

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

# Publish a proven legacy snapshot as the first generation of both streams.
#
# The legacy `.dat` is copied first and the copy is what publication consumes,
# because publishing moves or deletes the file it is handed and the original
# must survive untouched. Ordering is the ordinary publication order -- bytes,
# descriptor, source state, selection -- so an interrupt leaves at worst
# unreferenced bytes.
psl_migration_import <- function(path, retrieved_at) {
  staged <- tempfile("pslr-migrate-", fileext = ".dat")
  on.exit(unlink(staged), add = TRUE)
  if (!file.copy(path, staged)) {
    stop(
      sprintf("Could not stage the legacy snapshot for migration: %s", path),
      call. = FALSE
    )
  }
  identity <- psl_checksum_id(psl_sha256_file(staged))
  psl_publish_snapshot(
    staged,
    checksum = identity,
    first_retrieved_at = retrieved_at
  )
  psl_publish_source_state(
    psl_legacy_request_url,
    checksum = identity,
    retrieved_at = retrieved_at,
    checked_at = NA
  )
  psl_publish_selection(identity, request_url = psl_legacy_request_url)
  identity
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Migrate v1 cache state into v2 generations, once.
#
# Call this only from an explicit mutator (`psl_refresh()`,
# `psl_cache_prune()`); status and inspection paths must stay read-only. The
# whole decision -- including the "already migrated?" check -- happens under
# the publish lock, so two mutators racing cannot both import. Contention is
# not a failure: `on_busy = "null"` reports `busy` and lets the caller get on
# with its own work rather than aborting it over an optional import.
#
# `quiet = FALSE` surfaces unprovable legacy state as a warning, which is how
# the mutators are expected to call it.
psl_migrate_legacy_cache <- function(quiet = FALSE) {
  marker <- psl_cache_marker()
  if (!file.exists(marker)) {
    return(psl_migration_result("absent"))
  }
  result <- psl_with_publish_lock(
    psl_migrate_locked(marker),
    on_busy = "null"
  )
  if (is.null(result)) {
    result <- psl_migration_result("busy")
  }
  if (!quiet && !is.na(result$message)) {
    warning(result$message, call. = FALSE)
  }
  result
}

# The migration decision, under the publish lock.
psl_migrate_locked <- function(marker) {
  if (psl_v2_state_present()) {
    return(psl_migration_result("skipped"))
  }
  current <- psl_cache_current()
  if (is.null(current)) {
    return(psl_migration_unprovable("marker_malformed", marker))
  }
  # `basename()` keeps a hand-edited marker from naming a file outside the
  # cache directory; v1 always recorded a bare file name here.
  dat <- file.path(psl_cache_dir(), basename(current$dat_file))
  fault <- psl_migration_verify(dat, current$meta$checksum)
  if (!is.na(fault)) {
    return(psl_migration_unprovable(fault, dat))
  }
  retrieved_at <- psl_legacy_retrieved_at(current$meta$retrieved_at)
  identity <- psl_migration_import(dat, retrieved_at)
  psl_migration_result(
    "migrated",
    checksum = identity,
    retrieved_at = retrieved_at,
    request_url = psl_legacy_request_url,
    path = dat
  )
}
