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

# Path of the single legacy (v1) commit marker that named the active cache
# snapshot. Nothing writes it any more -- publication is append-only generations
# -- but migration, pruning, and the legacy activation fallback still read it.
psl_cache_marker <- function() file.path(psl_cache_dir(), "current.rds")

# Source checksum with an algorithm prefix (PRD s7.4). SHA-256 is the sole
# identity for newly recorded bytes -- `digest` is a hard dependency, so there
# is no MD5-writing fallback and no way to mint a new MD5 identity. The prefix
# still names the algorithm, because legacy caches recorded MD5.
psl_source_checksum <- function(path) {
  paste0("sha256:", psl_sha256_file(path))
}

# Compute one specific checksum algorithm for algorithm-directed verification.
# Unlike `psl_source_checksum()` -- which always RECORDS SHA-256 -- this
# reproduces the exact algorithm a checksum was recorded with, so verification
# compares like with like. MD5 stays supported for verification only: a cache
# published by an older pslr recorded an MD5 identity and must keep verifying
# against it until migration re-identifies it by SHA-256.
psl_checksum <- function(path, algorithm) {
  if (identical(algorithm, "sha256")) {
    paste0("sha256:", psl_sha256_file(path))
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
# genuine content -- a legacy MD5-recorded cache verifies against MD5, while
# every newly recorded identity verifies against SHA-256.
psl_verify_checksum <- function(path, expected) {
  algorithm <- sub(":.*$", "", expected)
  identical(psl_checksum(path, algorithm), expected)
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

# ---------------------------------------------------------------------------
# Conditional refresh (freshness v2)
# ---------------------------------------------------------------------------
#
# `psl_refresh()` is the composition point of the v2 freshness subsystem, and
# the order of its steps is the contract:
#
#   1. take the per-source lock and hold it from the first state read through
#      the commit, INCLUDING the network time -- that is what serializes
#      same-source refreshes and stops an older concurrent response from
#      overwriting newer state;
#   2. migrate any legacy v1 cache, then read the current source state;
#   3. run the transition machine, which decides the outcome and validates any
#      response body before it is referenced;
#   4. build the complete candidate engine when `activate = TRUE`, BEFORE the
#      persistence commit;
#   5. commit under the publish lock (source lock, then publish lock, always);
#   6. activate with one non-failing assignment;
#   7. return one `psl_refresh_result`, invisibly.
#
# A failure records only a coarse attempt -- no freshness timestamp, checksum,
# or selection moves -- and re-signals the classed error, so no failure ever
# returns a success-shaped answer.

# The canonical endpoint. v2 keeps it a documented literal default owned by an
# internal constant rather than a public accessor.
psl_official_url <- "https://publicsuffix.org/list/public_suffix_list.dat"

# The current source-state record, or NULL when this source has never been
# refreshed (or its whole stream is unreadable, which is the same thing for a
# freshness claim: nothing local can be trusted to confirm anything).
psl_current_source_state <- function(request_url) {
  psl_read_source_state(request_url)$record
}

# Where a response body is staged: inside the cache directory, so publication
# can move it into `snapshots/` with a same-file-system rename. The caller owns
# the path and unlinks it on every exit; a body becomes a snapshot only after
# full validation.
psl_refresh_destfile <- function() {
  dir.create(psl_cache_dir(), recursive = TRUE, showWarnings = FALSE)
  tempfile("pslr-body-", tmpdir = psl_cache_dir(), fileext = ".part")
}

# Record one failed attempt against a source: `last_attempt_at` and the coarse
# `last_result` category advance, and every freshness field is carried forward
# byte for byte. Best effort by construction -- if the publish lock is busy or
# the append itself fails, the original refresh error is still what the caller
# sees, because a diagnostic write must never mask the fault it describes.
psl_record_failed_attempt <- function(request_url, state, cnd, now) {
  tryCatch(
    psl_with_publish_lock(
      do.call(
        psl_publish_source_state,
        c(
          list(request_url = request_url),
          psl_refresh_failure_state(state, cnd, now)
        )
      ),
      on_busy = "null"
    ),
    error = \(e) NULL
  )
  invisible(NULL)
}

# Where the bytes for this plan's snapshot can be read right now: freshly
# downloaded and validated bytes when the response carried a body, and the
# already-published snapshot otherwise (a skip or a `304`).
psl_plan_bytes_path <- function(plan) {
  if (!is.na(plan$path)) plan$path else psl_snapshot_bytes_path(plan$checksum)
}

# Build the COMPLETE candidate engine for a plan, before anything is committed.
# Everything that can fail -- reading, parsing, validating, and compiling the
# matcher -- happens here, so the post-commit activation is a single assignment
# that cannot fail. The recorded path is the snapshot's published location,
# which is content-addressed and therefore known before publication.
psl_refresh_engine <- function(plan, state) {
  path <- psl_plan_bytes_path(plan)
  rules <- if (is.na(plan$path)) {
    psl_load_source(path, "cache")
  } else {
    # Accepting the response already parsed these exact bytes and emitted any
    # duplicate-rule warning; re-parsing them to build the engine must not
    # repeat it, or one refresh would warn twice about one list.
    suppressWarnings(psl_load_source(path, "cache"))
  }
  retrieved_at <- if (is.null(plan$state)) {
    psl_state_field(state, "retrieved_at")
  } else {
    plan$state$retrieved_at
  }
  meta <- psl_meta(
    source = "cache",
    path = psl_snapshot_bytes_path(plan$checksum),
    retrieved_at = retrieved_at,
    size = as.integer(file.size(path)),
    checksum = plan$checksum
  )
  new_psl_engine(new_psl_snapshot(rules, meta))
}

# Commit one plan. A skip observed nothing, so it appends no source-state
# generation -- but it still appends a cache selection, because every
# successful outcome makes the refreshed source the cache choice.
psl_commit_plan <- function(request_url, plan) {
  if (!plan$publish_state) {
    if (plan$select) {
      psl_with_publish_lock(
        psl_publish_selection(plan$checksum, request_url = request_url)
      )
    }
    return(invisible(plan$checksum))
  }
  psl_publish_refresh(
    request_url,
    path = if (plan$publish_snapshot) plan$path else NULL,
    checksum = plan$checksum,
    descriptor = plan$descriptor,
    state = plan$state,
    select = plan$select
  )
  invisible(plan$checksum)
}

# Turn a committed plan into the single public success value.
psl_refresh_result_of <- function(plan, activated) {
  new_psl_refresh_result(
    outcome = plan$outcome,
    request_url = plan$request_url,
    checksum = plan$checksum,
    effective_url = plan$effective_url,
    http_status = plan$http_status,
    checked_at = plan$checked_at,
    previous_checksum = plan$previous_checksum,
    activated = activated,
    validator = plan$validator,
    bytes_downloaded = plan$bytes_downloaded,
    snapshot = psl_read_snapshot_descriptor(plan$checksum)
  )
}

# One refresh, from the transition decision through commit and activation. The
# caller holds the source lock around this for its whole duration.
psl_refresh_commit <- function(request_url, state, ..., now, force, activate) {
  psl_check_empty_dots(...)
  destfile <- psl_refresh_destfile()
  on.exit(unlink(destfile), add = TRUE)
  plan <- psl_refresh_transition(
    request_url,
    destfile,
    state = state,
    now = now,
    force = force
  )
  engine <- if (activate) psl_refresh_engine(plan, state) else NULL
  psl_commit_plan(request_url, plan)
  if (!is.null(engine)) {
    psl_activate_engine(engine)
  }
  psl_refresh_result_of(plan, activate)
}

# Everything that happens while the source lock is held.
psl_refresh_locked <- function(request_url, ..., now, force, activate) {
  psl_check_empty_dots(...)
  psl_migrate_legacy_cache(quiet = TRUE)
  state <- psl_current_source_state(request_url)
  withCallingHandlers(
    psl_refresh_commit(
      request_url,
      state,
      now = now,
      force = force,
      activate = activate
    ),
    pslr_refresh_error = function(cnd) {
      psl_record_failed_attempt(request_url, state, cnd, now)
    }
  )
}

# Dots guard for the public refresh entry point. The shared
# `psl_check_empty_dots()` answers a stale positional call with "unnamed", which
# tells the caller nothing -- and the caller most likely to land here is an
# existing one, because the previously released signature was
# `(url, force, activate)` and their positional flag has just stopped working.
# So name both flags and show the fix; a misspelled named argument still reports
# the name that was not recognized.
psl_check_refresh_dots <- function(...) {
  if (!...length()) {
    return(invisible(NULL))
  }
  named <- ...names()
  unknown <- if (is.null(named)) character(0) else named[nzchar(named)]
  detail <- if (length(unknown)) {
    sprintf("`psl_refresh()` got unknown argument(s): %s.", toString(unknown))
  } else {
    "`psl_refresh()` takes only `url` positionally."
  }
  stop(
    detail,
    " Name `activate` and `force`, as in psl_refresh(url, activate = TRUE)",
    " or psl_refresh(url, force = TRUE).",
    call. = FALSE
  )
}

#' Refresh the cached Public Suffix List from upstream
#'
#' Revalidates the Public Suffix List against its source and publishes any
#' changed bytes into the user cache. This is the only function in the package
#' that accesses the network, and only when you call it explicitly.
#'
#' @param url Absolute `https` URL of the list source. Defaults to the official
#'   list. URLs with another scheme, embedded credentials, a query string, or a
#'   fragment are rejected, and a redirect that leaves `https` or the original
#'   origin is refused.
#' @param ... These dots are for future extensions and must be empty. They also
#'   make `activate` and `force` named-only. The two flags are easy to confuse
#'   -- both logical, both about doing more than a bare check -- so
#'   `psl_refresh(url, TRUE)` is unreadable whichever order it means. Naming
#'   them makes every call self-documenting, and the old positional form is now
#'   a clear error instead of a silent change of meaning.
#' @param activate When `TRUE`, the snapshot the source now points at becomes
#'   the active list for the session, exactly as [psl_use()] would activate it
#'   -- after *every* successful outcome, including a skip and a `304`. When
#'   `FALSE` (default), the cache is updated but the active list is unchanged.
#' @param force When `FALSE` (default), a check whose courtesy window has not
#'   elapsed makes no request at all, respecting upstream download guidance.
#'   `TRUE` bypasses that local window only; the request it then makes still
#'   carries a validator when one is available.
#'
#' @details
#' A refresh has exactly four successful outcomes:
#'
#' \describe{
#'   \item{`skipped_recently`}{No request: the last successful check is still
#'     inside its courtesy window (at least 24 hours).}
#'   \item{`not_modified`}{One conditional request answered `304`; the local
#'     bytes were verified and remain current.}
#'   \item{`downloaded_unchanged`}{One `200` whose validated bytes hash to the
#'     snapshot already held, so no new snapshot is created.}
#'   \item{`updated`}{One `200` whose validated bytes are a new snapshot.}
#' }
#'
#' Downloaded bytes are fully validated -- size ceiling, UTF-8, official section
#' markers, rule grammar, and canonicalization of every rule -- before anything
#' references them, and exact same-section duplicates warn once and are
#' deduplicated. Publication is append-only: snapshot bytes and their descriptor
#' are written before any reference to them, so an interrupted refresh never
#' exposes a dangling reference. Refreshes of one source are serialized across
#' processes; a second concurrent refresh of the same source makes no request
#' and signals a busy error. A failed refresh records only a coarse attempt and
#' leaves the cache, the selected snapshot, and the active matcher untouched.
#'
#' @return Invisibly, a `psl_refresh_result` with stable fields `outcome`,
#'   `request_url`, `effective_url`, `http_status`, `checked_at`,
#'   `previous_checksum`, `checksum`, `activated`, `validator`,
#'   `bytes_downloaded`, and `snapshot`. Operational failures signal a classed
#'   error rooted at `pslr_refresh_error` instead.
#' @seealso [psl_use()], [psl_version()]
#' @examples
#' if (interactive()) {
#'   psl_refresh()
#'   psl_refresh(force = TRUE, activate = TRUE)
#' }
#' @export
psl_refresh <- function(
  url = "https://publicsuffix.org/list/public_suffix_list.dat",
  ...,
  activate = FALSE,
  force = FALSE
) {
  psl_check_refresh_dots(...)
  psl_check_flag(activate, "activate")
  psl_check_flag(force, "force")
  request_url <- psl_normalize_source_url(url)
  # One clock read per public call; every persisted timestamp derives from it.
  now <- psl_now()
  result <- psl_refresh_with_busy(psl_with_source_lock(
    request_url,
    psl_refresh_locked(
      request_url,
      now = now,
      force = force,
      activate = activate
    )
  ))
  invisible(result)
}

# Activate the snapshot named by the highest valid cache-selection generation.
# Returns NULL when no selection exists, so the caller can fall back to a legacy
# v1 cache that has not been migrated yet; a selection that exists but does not
# resolve is corruption and is reported with remediation rather than skipped.
psl_activate_selected_cache <- function() {
  checksum <- psl_read_selection()$record$checksum
  if (is.null(checksum)) {
    return(NULL)
  }
  integrity <- psl_snapshot_integrity(checksum, verify = TRUE)
  if (!identical(integrity, "ok")) {
    psl_cache_corrupt(
      "error",
      switch(
        integrity,
        missing = "source file is missing",
        checksum_mismatch = "checksum mismatch",
        "snapshot metadata is unreadable"
      )
    )
  }
  descriptor <- psl_read_snapshot_descriptor(checksum)
  path <- psl_snapshot_bytes_path(checksum)
  meta <- psl_meta(
    source = "cache",
    path = path,
    retrieved_at = descriptor$first_retrieved_at,
    size = descriptor$size,
    checksum = checksum
  )
  psl_activate_snapshot(new_psl_snapshot(psl_load_source(path, "cache"), meta))
  invisible(psl_version())
}

psl_activate_cache <- function() {
  selected <- psl_activate_selected_cache()
  if (!is.null(selected)) {
    return(selected)
  }
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
