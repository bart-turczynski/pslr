# Offline freshness status (freshness v2).
#
# `psl_status()` is the read-only half of the freshness subsystem. It reports
# the strongest claim LOCAL EVIDENCE supports about one snapshot, and it does
# so without a network request, without a write, and without a migration --
# not even a lazy one. A v1 marker may be read; it is never rewritten.
#
# Three rules shape everything below.
#
#   1. ELAPSED TIME IS NOT AN UPDATE. `update_available` means a successful
#      prior check observed a DIFFERENT checksum for the source. Age alone is
#      only ever `check_due`, which is offline advice. The print method is held
#      to the same standard: it never turns an age into "outdated".
#   2. UNPROVABLE STATE IS `unknown`, NOT AN ERROR. A corrupt selection, an
#      unreadable source stream, bytes that no longer match their checksum, an
#      ambiguous association, or a backwards clock all degrade to `unknown`
#      with remediation, so a usable active engine stays inspectable.
#   3. ONE CLOCK READ PER CALL, threaded through every comparison, and
#      injectable so the whole state machine is testable offline.

# ---------------------------------------------------------------------------
# Return schema
# ---------------------------------------------------------------------------

# The stable column contract: name, order, and storage type. `"time"` columns
# are POSIXct in UTC. Owned in one place so construction and validation of the
# one-row result can never drift apart.
psl_status_columns <- c(
  state = "character",
  snapshot = "character",
  source_kind = "character",
  request_url = "character",
  checksum = "character",
  source_checksum = "character",
  content_date = "time",
  retrieved_at = "time",
  checked_at = "time",
  next_check_at = "time",
  snapshot_age_days = "double",
  check_age_days = "double",
  check_due = "logical",
  message = "character"
)

# One column's value, coerced to its declared storage type. An absent field is
# a typed `NA`, never a dropped column.
psl_status_value <- function(value, type) {
  if (is.null(value)) {
    value <- NA
  }
  switch(
    type,
    character = as.character(value),
    double = as.numeric(value),
    logical = as.logical(value),
    time = psl_as_time(value)
  )
}

# Assemble the one-row result from a flat list of resolved fields.
new_psl_status <- function(fields) {
  cols <- Map(
    function(name, type) psl_status_value(fields[[name]], type),
    names(psl_status_columns),
    psl_status_columns
  )
  structure(
    data.frame(cols, stringsAsFactors = FALSE, row.names = NULL),
    class = c("psl_status", "data.frame")
  )
}

# ---------------------------------------------------------------------------
# Remediation messages
# ---------------------------------------------------------------------------

psl_status_corrupt_message <- function(what) {
  sprintf(
    paste0(
      "pslr could not read %s in %s, so no freshness claim can be made. ",
      "Run psl_refresh(force = TRUE) to rebuild it."
    ),
    what,
    psl_cache_dir()
  )
}

psl_status_integrity_message <- function(integrity) {
  sprintf(
    paste0(
      "The selected cache snapshot cannot be trusted because %s. ",
      "Run psl_refresh(force = TRUE) to republish it."
    ),
    switch(
      integrity,
      missing = "its bytes or descriptor are not published",
      checksum_mismatch = "its bytes no longer match their checksum",
      unknown_schema = "its descriptor is unreadable or unsupported",
      integrity
    )
  )
}

psl_status_ambiguous_message <- function() {
  paste(
    "More than one source records these exact bytes, so no single source",
    "claim applies. Run psl_refresh() against the source you rely on."
  )
}

psl_status_skew_message <- function() {
  paste(
    "The local clock is behind the last recorded check, so the age of that",
    "check is unknown. Correct the clock, then run psl_refresh(force = TRUE)."
  )
}

psl_status_missing_message <- function() {
  paste(
    "No Public Suffix List snapshot has been cached yet.",
    "Run psl_refresh(activate = TRUE) to download one."
  )
}

# ---------------------------------------------------------------------------
# The inspected snapshot
# ---------------------------------------------------------------------------

# Everything the inspected snapshot itself contributes. `state` is `NA` unless
# inspection already decided the answer (`missing` or `unknown`), in which case
# no source is consulted at all.
psl_status_snapshot_fields <- function(
  kind,
  checksum,
  ...,
  content_date = NA,
  retrieved_at = NA,
  state = NA_character_,
  message = NA_character_
) {
  psl_check_empty_dots(...)
  list(
    kind = kind,
    checksum = checksum,
    content_date = content_date,
    retrieved_at = retrieved_at,
    state = state,
    message = message
  )
}

psl_status_inspect <- function(selector) {
  switch(
    selector,
    active = psl_status_inspect_active(),
    cache = psl_status_inspect_cache(),
    bundled = psl_status_inspect_bundled()
  )
}

# The installed snapshot. Read from the shipped metadata rather than through
# `bundled_snapshot()`, so inspection never builds a rule table.
psl_status_inspect_bundled <- function() {
  meta <- pslr_bundled$meta
  psl_status_snapshot_fields(
    "bundled",
    meta$checksum,
    content_date = psl_parse_list_date(meta$list_date),
    retrieved_at = psl_parse_list_date(meta$retrieved_at)
  )
}

# The default engine's snapshot. Reading it lazily initialises the bundled
# engine in this process, which is memory only -- no file is written.
psl_status_inspect_active <- function() {
  meta <- active_meta()
  if (identical(meta$source, "bundled")) {
    return(psl_status_inspect_bundled())
  }
  if (identical(meta$source, "path")) {
    return(psl_status_snapshot_fields("path", meta$checksum))
  }
  psl_status_cache_snapshot(meta$checksum, fallback = meta$retrieved_at)
}

# Provenance of one cached snapshot, from its published descriptor. A legacy
# (v1) cache has no descriptor and may carry an MD5 identity, which is not a
# v2 checksum reference -- so the descriptor lookup is guarded and the marker's
# own retrieval time is the fallback.
psl_status_cache_snapshot <- function(checksum, fallback = NA_character_) {
  descriptor <- if (psl_valid_sha256_ref(checksum)) {
    psl_read_snapshot_descriptor(checksum)
  }
  if (is.null(descriptor)) {
    return(psl_status_snapshot_fields(
      "cache",
      checksum,
      retrieved_at = psl_parse_list_date(fallback)
    ))
  }
  psl_status_snapshot_fields(
    "cache",
    checksum,
    content_date = psl_parse_list_date(descriptor$content_date),
    retrieved_at = psl_as_time(descriptor$first_retrieved_at)
  )
}

# The snapshot `psl_use("cache")` would resolve to. The selection stream is the
# requested state here, so a stream that cannot be read is `unknown` rather
# than something to route around.
psl_status_inspect_cache <- function() {
  selection <- psl_read_selection()
  if (selection$status %in% c("corrupt", "recovered")) {
    return(psl_status_snapshot_fields(
      "cache",
      NA_character_,
      state = "unknown",
      message = psl_status_corrupt_message("the cache selection record")
    ))
  }
  if (identical(selection$status, "empty")) {
    return(psl_status_inspect_legacy())
  }
  checksum <- selection$record$checksum
  integrity <- psl_snapshot_integrity(checksum, verify = TRUE)
  if (!identical(integrity, "ok")) {
    return(psl_status_snapshot_fields(
      "cache",
      checksum,
      state = "unknown",
      message = psl_status_integrity_message(integrity)
    ))
  }
  psl_status_cache_snapshot(checksum)
}

# A v1 cache that has not been migrated, read strictly read-only: no marker is
# rewritten and no generation stream is created. With no selection and no
# legacy marker, the requested cache selection simply does not exist.
psl_status_inspect_legacy <- function() {
  current <- psl_status_legacy_marker()
  if (is.null(current)) {
    return(psl_status_snapshot_fields(
      "missing",
      NA_character_,
      state = "missing",
      message = psl_status_missing_message()
    ))
  }
  psl_status_snapshot_fields(
    "cache",
    current$meta$checksum,
    retrieved_at = psl_parse_list_date(current$meta$retrieved_at)
  )
}

# The v1 commit marker, when it exists and names a snapshot file that is still
# there. `psl_cache_current()` defaults to treating a corrupt marker as no
# cache, which keeps this path free of both errors and writes.
psl_status_legacy_marker <- function() {
  current <- psl_cache_current()
  if (is.null(current)) {
    return(NULL)
  }
  dat <- file.path(psl_cache_dir(), basename(current$dat_file))
  if (file.exists(dat)) current else NULL
}

# ---------------------------------------------------------------------------
# Source association
# ---------------------------------------------------------------------------

# The canonical refresh source for the bundled bytes -- claimed only when build
# provenance states that those bytes correspond to it.
#
# The build records an immutable raw-commit origin URL, which pins WHICH bytes
# shipped but says nothing about the canonical endpoint's current response. So
# the association is withheld and the bundled snapshot reports `untracked`
# until build provenance names the canonical endpoint explicitly.
psl_bundled_source_url <- function() {
  if (identical(pslr_bundled$meta$canonical_url, psl_official_url)) {
    psl_official_url
  } else {
    NA_character_
  }
}

# The source half of the answer: which source the claim is made against, and
# that source's current record. `state` is `NA` unless association or the
# stream itself is unprovable.
psl_status_source_result <- function(
  request_url = NA_character_,
  ...,
  record = NULL,
  state = NA_character_,
  message = NA_character_
) {
  psl_check_empty_dots(...)
  list(
    request_url = request_url,
    record = record,
    state = state,
    message = message
  )
}

# Read one source's current state. An unreadable stream is `unknown`: a
# recovered or corrupt stream must never be presented as confirmation.
psl_status_read_source <- function(request_url) {
  if (is.na(request_url)) {
    return(psl_status_source_result())
  }
  read <- psl_read_source_state(request_url)
  if (read$status %in% c("corrupt", "recovered")) {
    return(psl_status_source_result(
      request_url,
      state = "unknown",
      message = psl_status_corrupt_message("the source record")
    ))
  }
  psl_status_source_result(request_url, record = read$record)
}

psl_status_source <- function(inspected) {
  if (!is.na(inspected$state)) {
    return(psl_status_source_result())
  }
  switch(
    inspected$kind,
    bundled = psl_status_read_source(psl_bundled_source_url()),
    cache = psl_status_cache_source(inspected$checksum),
    psl_status_source_result()
  )
}

# Sources whose current record names exactly these bytes. Used only when the
# selection carries no source, so a remotely derived snapshot still resolves.
psl_status_source_scan <- function(checksum) {
  root <- file.path(psl_cache_dir(), "sources")
  if (!dir.exists(root)) {
    return(character())
  }
  streams <- list.dirs(root, recursive = FALSE)
  urls <- vapply(
    streams,
    function(dir) {
      read <- psl_store_read(dir, validate_psl_source_state)
      if (!identical(read$status, "ok")) {
        return(NA_character_)
      }
      if (identical(read$record$checksum, checksum)) {
        read$record$request_url
      } else {
        NA_character_
      }
    },
    character(1L)
  )
  unique(unname(urls[!is.na(urls)]))
}

# Does the v1 marker name exactly these bytes? v1 recorded no request URL, so
# a marker match attributes the snapshot to the canonical endpoint -- the same
# attribution migration makes, and safe for the same reason: there is no
# `checked_at`, so the answer can only ever be `never_checked`.
psl_status_legacy_match <- function(checksum) {
  current <- psl_status_legacy_marker()
  !is.null(current) && identical(current$meta$checksum, checksum)
}

# Associate cached bytes with a source, in normative order: the selection's
# own source identity, then the unique source that records these exact bytes,
# then an unmigrated v1 cache. Several sources recording the same bytes is
# ambiguous, and ambiguity is `unknown`.
psl_status_cache_source <- function(checksum) {
  selection <- psl_read_selection()
  selected <- if (identical(selection$status, "ok")) {
    selection$record$request_url
  } else {
    NA_character_
  }
  if (!is.na(selected)) {
    return(psl_status_read_source(selected))
  }
  matches <- psl_status_source_scan(checksum)
  if (length(matches) > 1L) {
    return(psl_status_source_result(
      state = "unknown",
      message = psl_status_ambiguous_message()
    ))
  }
  if (length(matches) == 1L) {
    return(psl_status_read_source(matches))
  }
  if (psl_status_legacy_match(checksum)) {
    return(psl_status_read_source(psl_legacy_request_url))
  }
  psl_status_source_result()
}

# ---------------------------------------------------------------------------
# State precedence
# ---------------------------------------------------------------------------

# The retained reminder interval, in whole days; the documented default when no
# preference has been stored or the stored one cannot be read.
psl_status_interval <- function() {
  read <- psl_store_read(psl_reminder_stream_dir(), validate_psl_reminder_pref)
  if (identical(read$status, "ok")) {
    read$record$interval
  } else {
    psl_reminder_default_interval
  }
}

# The freshness claim for a snapshot that IS associated with a source. Order
# here is the normative precedence: unknown, then update_available, then
# never_checked, then check_due, then confirmed_current.
psl_status_claim <- function(checksum, source, now, interval) {
  record <- source$record
  fields <- list(request_url = source$request_url)
  if (is.null(record) || is.na(psl_as_time(record$checked_at))) {
    return(c(
      fields,
      list(
        source_checksum = record$checksum,
        checked_at = record$checked_at,
        next_check_at = record$next_check_at,
        state = "never_checked"
      )
    ))
  }
  fields$source_checksum <- record$checksum
  fields$checked_at <- psl_as_time(record$checked_at)
  fields$next_check_at <- psl_as_time(record$next_check_at)
  fields$check_age_days <- psl_elapsed_days(record$checked_at, now)
  fields$check_due <- psl_check_due(record$checked_at, now, interval)
  if (is.na(fields$check_age_days) || is.na(fields$check_due)) {
    return(c(
      fields,
      list(
        state = "unknown",
        message = psl_status_skew_message()
      )
    ))
  }
  if (is.na(fields$source_checksum)) {
    return(c(
      fields,
      list(
        state = "unknown",
        message = psl_status_corrupt_message("the source record")
      )
    ))
  }
  c(fields, list(state = psl_status_confirmed(checksum, fields)))
}

# The three states that a readable, unskewed source record can produce.
psl_status_confirmed <- function(checksum, fields) {
  if (!identical(fields$source_checksum, checksum)) {
    "update_available"
  } else if (isTRUE(fields$check_due)) {
    "check_due"
  } else {
    "confirmed_current"
  }
}

# Combine the snapshot half and the source half into the resolved row fields.
psl_status_resolve <- function(inspected, source, now, interval) {
  base <- list(
    source_kind = inspected$kind,
    checksum = inspected$checksum,
    content_date = inspected$content_date,
    retrieved_at = inspected$retrieved_at,
    snapshot_age_days = psl_elapsed_days(inspected$content_date, now)
  )
  if (!is.na(inspected$state)) {
    return(c(base, list(state = inspected$state, message = inspected$message)))
  }
  if (!is.na(source$state)) {
    return(c(
      base,
      list(
        request_url = source$request_url,
        state = source$state,
        message = source$message
      )
    ))
  }
  if (is.na(source$request_url)) {
    return(c(base, list(state = "untracked")))
  }
  c(base, psl_status_claim(inspected$checksum, source, now, interval))
}

# The injectable clock argument: a single non-missing time.
psl_status_now <- function(now) {
  ok <- inherits(now, "POSIXt") && length(now) == 1L && !is.na(now)
  if (!ok) {
    stop("`now` must be a single non-missing POSIXct time.", call. = FALSE)
  }
  as.POSIXct(now, tz = "UTC")
}

#' Offline freshness status of a Public Suffix List snapshot
#'
#' Reports the strongest freshness claim the locally available evidence
#' supports about one snapshot: whether it is confirmed current against its
#' source, whether a check is merely due, whether a newer snapshot has actually
#' been observed, or whether the local state cannot support any claim at all.
#'
#' The call is strictly offline and read-only. It makes no request, writes
#' nothing, and performs no cache migration; unreadable local state is reported
#' as `"unknown"` with remediation rather than raised as an error, so a usable
#' active list always stays inspectable.
#'
#' @details
#' `state` is one of, in precedence order:
#'
#' \describe{
#'   \item{`missing`}{The requested cache selection does not exist.}
#'   \item{`unknown`}{Required local state is corrupt, ambiguous, or affected
#'     by clock skew; `message` carries the remediation.}
#'   \item{`untracked`}{The snapshot has no applicable remote source, so no
#'     freshness claim can be made about it.}
#'   \item{`update_available`}{A successful earlier check observed a
#'     *different* checksum for the source. This is an observation, never an
#'     inference from age.}
#'   \item{`never_checked`}{The source is known but nothing has ever confirmed
#'     the snapshot against it.}
#'   \item{`check_due`}{The snapshot was confirmed current, but the retained
#'     reminder interval (7 days by default) has since elapsed. This is offline
#'     advice, not evidence that anything upstream changed.}
#'   \item{`confirmed_current`}{The snapshot was confirmed current and the
#'     interval has not elapsed.}
#' }
#'
#' Elapsed time alone never produces `"update_available"`: an interval that has
#' passed is `"check_due"` and nothing more.
#'
#' @param snapshot Which snapshot to inspect: `"active"` (the list active in
#'   this session), `"cache"` (the snapshot `psl_use("cache")` would resolve
#'   to), or `"bundled"` (the snapshot installed with the package).
#' @param ... These dots are for future extension and must be empty.
#' @param now The instant to evaluate freshness against, as a single POSIXct
#'   time. Defaults to the current time, read once per call. Mainly useful for
#'   testing.
#'
#' @return A one-row base [data.frame] of class `psl_status` with the columns,
#'   in order: `state` (character), `snapshot` (character, the requested
#'   selector), `source_kind` (character: `"bundled"`, `"cache"`, `"path"`, or
#'   `"missing"`), `request_url` (character), `checksum` (character, the
#'   inspected snapshot's identity), `source_checksum` (character, the newest
#'   checksum observed for the source), `content_date` (POSIXct upstream
#'   provenance date), `retrieved_at` (POSIXct), `checked_at` (POSIXct),
#'   `next_check_at` (POSIXct courtesy boundary), `snapshot_age_days`
#'   (double), `check_age_days` (double), `check_due` (logical), and `message`
#'   (character remediation for `"missing"` and `"unknown"`). Unavailable
#'   values are a typed `NA`; ages are `NA` when the local clock is behind a
#'   recorded time.
#' @seealso [psl_refresh()], [psl_use()], [psl_version()]
#' @examples
#' # The snapshot installed with the package:
#' psl_status("bundled")
#'
#' # The list active in this session:
#' psl_status()
#'
#' # A cache that was never populated is a status, not an error:
#' psl_status("cache")$state
#' @export
psl_status <- function(snapshot = "active", ..., now = psl_now()) {
  psl_check_empty_dots(...)
  selector <- check_choice(
    snapshot,
    c("active", "cache", "bundled"),
    "snapshot"
  )
  now <- psl_status_now(now)
  inspected <- psl_status_inspect(selector)
  source <- psl_status_source(inspected)
  fields <- psl_status_resolve(inspected, source, now, psl_status_interval())
  new_psl_status(c(list(snapshot = selector), fields))
}

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

# One headline per state. The wording is the contract: no state is ever
# described as "outdated", and only an observed checksum difference is ever
# described as an available update.
psl_status_headlines <- c(
  missing = "No cached snapshot.",
  unknown = "Freshness unknown.",
  untracked = "No remote source for this snapshot.",
  never_checked = "Never checked against its source.",
  check_due = "Freshness check due.",
  confirmed_current = "Confirmed current."
)

psl_status_headline <- function(x) {
  if (identical(x$state, "update_available")) {
    return(
      if (identical(x$snapshot, "active")) {
        "A newer snapshot was downloaded but is not active."
      } else {
        "A newer snapshot was downloaded for this source."
      }
    )
  }
  psl_status_headlines[[x$state]]
}

# An age in days, phrased for prose.
psl_status_days <- function(days) {
  if (is.na(days)) {
    return("an unknown time")
  }
  sprintf("%.1f days", days)
}

psl_status_detail <- function(x) {
  switch(
    x$state,
    missing = x$message,
    unknown = x$message,
    untracked = paste(
      "These bytes are not associated with a remote source, so no freshness",
      "claim can be made about them."
    ),
    update_available = paste(
      "The last successful check observed different bytes for this source.",
      "Run psl_refresh(activate = TRUE) to fetch and use them."
    ),
    never_checked = paste(
      "No successful check has confirmed these bytes against the source.",
      "Run psl_refresh() to check."
    ),
    check_due = sprintf(
      paste(
        "The source last confirmed these bytes %s ago and the reminder",
        "interval has since elapsed. Run psl_refresh() to check again."
      ),
      psl_status_days(x$check_age_days)
    ),
    confirmed_current = sprintf(
      "The source confirmed these exact bytes %s ago.",
      psl_status_days(x$check_age_days)
    )
  )
}

# Abbreviate a checksum identity for display: the algorithm plus the first 12
# hex characters, which is plenty to recognise a snapshot by eye.
psl_status_short_checksum <- function(checksum) {
  if (is.na(checksum)) {
    return(NA_character_)
  }
  parsed <- psl_parse_checksum(checksum)
  if (is.null(parsed)) {
    return(checksum)
  }
  sprintf("%s:%s...", parsed$algorithm, substr(parsed$hex, 1L, 12L))
}

psl_status_date <- function(x) {
  if (is.na(x)) NA_character_ else format(x, "%Y-%m-%d %H:%M UTC", tz = "UTC")
}

# The labelled field block: every known value, aligned, with unknown values
# omitted rather than printed as NA.
psl_status_field_lines <- function(x) {
  values <- c(
    snapshot = if (identical(x$snapshot, x$source_kind)) {
      x$snapshot
    } else {
      sprintf("%s (%s)", x$snapshot, x$source_kind)
    },
    checksum = psl_status_short_checksum(x$checksum),
    source = x$request_url,
    "source snapshot" = if (identical(x$source_checksum, x$checksum)) {
      NA_character_
    } else {
      psl_status_short_checksum(x$source_checksum)
    },
    "content date" = psl_status_date(x$content_date),
    retrieved = psl_status_date(x$retrieved_at),
    checked = psl_status_date(x$checked_at),
    "next check" = psl_status_date(x$next_check_at)
  )
  values <- values[!is.na(values)]
  labels <- paste0(names(values), ":")
  sprintf("  %s %s", formatC(labels, width = -max(nchar(labels))), values)
}

#' @rdname psl_status
#' @param x A `psl_status` row, as returned by [psl_status()].
#' @return `format()` returns a character vector of display lines and `print()`
#'   returns `x` invisibly.
#' @keywords internal
#' @export
format.psl_status <- function(x, ...) {
  if (nrow(x) != 1L) {
    return(format.data.frame(x, ...))
  }
  c(
    sprintf("<psl_status: %s>", x$state),
    strwrap(psl_status_headline(x), width = 76L, prefix = "  "),
    strwrap(psl_status_detail(x), width = 76L, prefix = "  "),
    psl_status_field_lines(x)
  )
}

#' @rdname psl_status
#' @keywords internal
#' @export
print.psl_status <- function(x, ...) {
  if (nrow(x) != 1L) {
    print.data.frame(x, ...)
    return(invisible(x))
  }
  cat(format(x, ...), sep = "\n")
  invisible(x)
}
