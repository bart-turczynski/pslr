# Refresh result and error conditions (freshness v2).
#
# `psl_refresh()` has exactly two shapes of answer: one success object and one
# family of classed errors. This file owns both.
#
#   * `psl_refresh_result` is the single success value. Its fields are stable
#     across every successful outcome -- `skipped_recently`, `not_modified`,
#     `downloaded_unchanged`, and `updated` -- so a caller reads the same names
#     whether or not a request was made. Fields that are genuinely unknowable
#     for an outcome (an HTTP status for a local skip, say) are a typed `NA`
#     rather than being invented.
#
#   * Every operational failure signals an error rooted at
#     `pslr_refresh_error`, with one subclass per failure family. No failure
#     ever returns a success-shaped result.
#
# Errors carry only coarse, safe metadata: a status code, a `Retry-After`
# delay, a byte count, a redacted URL, a short reason token. The constructor
# enforces this with an allow-list rather than trusting call sites, so a
# response body, a credential, or a raw transport trace cannot reach a
# condition object by accident -- these objects are printed, logged, and (in
# coarse form) persisted as attempt diagnostics.

# ---------------------------------------------------------------------------
# URL redaction
# ---------------------------------------------------------------------------

# Remove any userinfo from a URL before it is interpolated into a message or
# stored on a condition. Full URL policy lives in the URL layer; this is the
# last-line guarantee that a credential a caller supplied never reaches a
# printed error. Over-long values are truncated so a pathological URL cannot
# turn an error into a wall of text.
psl_redact_url <- function(url) {
  if (!is.character(url) || length(url) != 1L || is.na(url)) {
    return(NA_character_)
  }
  redacted <- sub(
    "^([A-Za-z][A-Za-z0-9+.-]*://)[^/?#]*@",
    "\\1<redacted>@",
    url
  )
  if (nchar(redacted) > 2048L) {
    redacted <- paste0(substr(redacted, 1L, 2045L), "...")
  }
  redacted
}

# ---------------------------------------------------------------------------
# Error hierarchy
# ---------------------------------------------------------------------------

# The only fields a refresh error may carry, and the coarse attempt category
# each subclass records. Anything outside the allow-list is a construction
# error, so widening what an error can leak is a deliberate edit here.
psl_refresh_error_data_fields <- c(
  "request_url",
  "effective_url",
  "status",
  "retry_after",
  "limit_bytes",
  "bytes_downloaded",
  "checksum",
  "reason",
  "lock",
  "timeout"
)

psl_refresh_error_classes <- c(
  pslr_refresh_url_policy_error = "url_policy_error",
  pslr_refresh_busy = "busy_error",
  pslr_refresh_transport_error = "transport_error",
  pslr_refresh_http_status_error = "http_status_error",
  pslr_refresh_response_limit_error = "response_limit_error",
  pslr_refresh_validation_error = "validation_error",
  pslr_refresh_local_corruption_error = "local_corruption_error",
  pslr_refresh_schema_error = "schema_error",
  pslr_refresh_publication_error = "publication_error"
)

# Short lowercase token naming *why* a transport or protocol step failed, with
# no free text from the network layer. Keeping the vocabulary closed is what
# makes "errors carry no transport traces" checkable.
psl_refresh_reason_pattern <- "^[a-z][a-z0-9_]{0,31}$"

# Validate and normalize the data fields of one refresh error.
psl_refresh_error_data <- function(...) {
  data <- list(...)
  if (!length(data)) {
    return(list())
  }
  fields <- names(data)
  if (is.null(fields) || !all(nzchar(fields))) {
    stop("Refresh error fields must all be named.", call. = FALSE)
  }
  unknown <- setdiff(fields, psl_refresh_error_data_fields)
  if (length(unknown)) {
    stop(
      sprintf(
        "A refresh error must not carry field(s): %s.",
        toString(unknown)
      ),
      call. = FALSE
    )
  }
  for (field in fields) {
    if (length(data[[field]]) != 1L) {
      stop(
        sprintf("Refresh error field `%s` must be a single value.", field),
        call. = FALSE
      )
    }
  }
  if (
    !is.null(data$reason) && !grepl(psl_refresh_reason_pattern, data$reason)
  ) {
    stop(
      "Refresh error field `reason` must be a short lowercase token.",
      call. = FALSE
    )
  }
  for (field in intersect(fields, c("request_url", "effective_url"))) {
    data[[field]] <- psl_redact_url(data[[field]])
  }
  data
}

# Build one classed refresh error. `subclass` may name more than one class when
# a condition belongs to an existing family as well (the busy error keeps its
# lock-layer classes), and `pslr_refresh_error` is always the root.
psl_refresh_error <- function(message, subclass, ...) {
  data <- psl_refresh_error_data(...)
  do.call(
    errorCondition,
    c(
      list(message),
      data,
      list(class = c(subclass, "pslr_refresh_error"), call = NULL)
    )
  )
}

# Coarse attempt category for a condition, for the source-state record. `NA`
# when the condition is not one of ours, so an unexpected error is never
# silently filed under a known category.
psl_refresh_attempt_result <- function(cnd) {
  known <- names(psl_refresh_error_classes)
  hit <- known[known %in% class(cnd)]
  if (!length(hit)) {
    return(NA_character_)
  }
  unname(psl_refresh_error_classes[[hit[[1L]]]])
}

psl_refresh_url_policy_error <- function(message, request_url = NA_character_) {
  psl_refresh_error(
    message,
    "pslr_refresh_url_policy_error",
    request_url = request_url
  )
}

# A bounded wait on the source lock expired. Keeps the lock-layer classes so an
# existing `pslr_lock_busy` handler still fires, and adds the refresh root so a
# refresh caller can handle every failure family in one place.
psl_refresh_busy_error <- function(message, lock, timeout) {
  psl_refresh_error(
    message,
    c("pslr_refresh_busy", "pslr_lock_busy", "pslr_busy_error"),
    lock = lock,
    timeout = timeout
  )
}

# Map the lock layer's busy condition onto the refresh hierarchy. The lock
# primitive knows nothing about refresh, so this is the one place the two meet.
psl_as_refresh_busy <- function(cnd) {
  if (inherits(cnd, "pslr_refresh_busy")) {
    return(cnd)
  }
  if (!inherits(cnd, "pslr_lock_busy")) {
    stop("`cnd` must be a pslr_lock_busy condition.", call. = FALSE)
  }
  psl_refresh_busy_error(
    conditionMessage(cnd),
    lock = cnd$lock,
    timeout = cnd$timeout
  )
}

# Evaluate `expr`, re-signalling any lock-busy condition as a refresh busy
# error. Wrap the whole locked section of a refresh in this.
psl_refresh_with_busy <- function(expr) {
  tryCatch(
    expr,
    pslr_lock_busy = function(cnd) stop(psl_as_refresh_busy(cnd))
  )
}

psl_refresh_transport_error <- function(
  message,
  reason,
  request_url = NA_character_
) {
  psl_refresh_error(
    message,
    "pslr_refresh_transport_error",
    reason = reason,
    request_url = request_url
  )
}

psl_refresh_http_status_error <- function(
  status,
  ...,
  retry_after = NA_integer_,
  request_url = NA_character_,
  effective_url = NA_character_
) {
  psl_check_empty_dots(...)
  message <- sprintf("Refresh failed: the server answered HTTP %d.", status)
  if (!is.na(retry_after)) {
    message <- sprintf(
      "%s Retry after %d seconds.",
      message,
      as.integer(retry_after)
    )
  }
  psl_refresh_error(
    message,
    "pslr_refresh_http_status_error",
    status = as.integer(status),
    retry_after = as.integer(retry_after),
    request_url = request_url,
    effective_url = effective_url
  )
}

psl_refresh_response_limit_error <- function(
  bytes_downloaded,
  limit_bytes,
  request_url = NA_character_
) {
  psl_refresh_error(
    sprintf(
      "Refresh refused: the response is over the %.0f-byte ceiling.",
      as.numeric(limit_bytes)
    ),
    "pslr_refresh_response_limit_error",
    bytes_downloaded = as.numeric(bytes_downloaded),
    limit_bytes = as.numeric(limit_bytes),
    request_url = request_url
  )
}

psl_refresh_validation_error <- function(message, request_url = NA_character_) {
  psl_refresh_error(
    message,
    "pslr_refresh_validation_error",
    request_url = request_url
  )
}

psl_refresh_local_corruption_error <- function(
  message,
  checksum = NA_character_
) {
  psl_refresh_error(
    message,
    "pslr_refresh_local_corruption_error",
    checksum = checksum
  )
}

psl_refresh_schema_error <- function(message) {
  psl_refresh_error(message, "pslr_refresh_schema_error")
}

psl_refresh_publication_error <- function(message) {
  psl_refresh_error(message, "pslr_refresh_publication_error")
}

# `Retry-After` as a whole number of seconds, or `NA` when absent or malformed.
# Only the delta-seconds form is honoured: the HTTP-date form needs C-locale
# month and weekday names to parse portably, and a wrong answer here would
# either suppress a legitimate retry or invent one. An unparsed value is simply
# dropped -- the error is still raised, it just carries no delay.
psl_retry_after_seconds <- function(value) {
  if (!is.character(value) || length(value) != 1L || is.na(value)) {
    return(NA_integer_)
  }
  value <- trimws(value)
  if (!grepl("^[0-9]{1,9}$", value)) {
    return(NA_integer_)
  }
  as.integer(value)
}

# ---------------------------------------------------------------------------
# Success result
# ---------------------------------------------------------------------------

psl_refresh_outcomes <- c(
  "skipped_recently",
  "not_modified",
  "downloaded_unchanged",
  "updated"
)

# Which validator the request actually sent, not which one is stored.
psl_refresh_validators <- c("etag", "last_modified", "none")

psl_refresh_result_fields <- list(
  outcome = psl_schema_field("character", choices = psl_refresh_outcomes),
  request_url = psl_schema_field("character"),
  effective_url = psl_schema_field("character", optional = TRUE),
  http_status = psl_schema_field(
    "integer",
    optional = TRUE,
    check = \(v) v >= 100L && v <= 599L,
    message = "must be an HTTP status code"
  ),
  checked_at = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  ),
  previous_checksum = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_sha256_ref,
    message = "must be a \"sha256:<hex>\" identity"
  ),
  checksum = psl_schema_field(
    "character",
    check = psl_valid_sha256_ref,
    message = "must be a \"sha256:<hex>\" identity"
  ),
  activated = psl_schema_field("logical"),
  validator = psl_schema_field("character", choices = psl_refresh_validators),
  bytes_downloaded = psl_schema_field(
    "integer",
    optional = TRUE,
    check = \(v) v >= 0L,
    message = "must not be negative"
  )
)

# Normalize a checksum argument that is allowed to be absent: a real value is
# canonicalized, a missing one stays a typed `NA` for the validator to accept.
psl_optional_checksum_id <- function(x) {
  if (length(x) == 1L && is.na(x)) NA_character_ else psl_checksum_id(x)
}

# Construct a validated `psl_refresh_result`: the single success value of
# `psl_refresh()`. The state machine that decides an outcome and fills these in
# lives elsewhere; this owns only the shape.
new_psl_refresh_result <- function(
  outcome,
  request_url,
  checksum,
  ...,
  effective_url = NA_character_,
  http_status = NA_integer_,
  checked_at = NA,
  previous_checksum = NA_character_,
  activated = FALSE,
  validator = "none",
  bytes_downloaded = NA_integer_,
  snapshot = NULL
) {
  psl_check_empty_dots(...)
  result <- list(
    outcome = outcome,
    request_url = request_url,
    effective_url = effective_url,
    http_status = psl_as_count(http_status),
    checked_at = psl_as_rfc3339(checked_at),
    previous_checksum = psl_optional_checksum_id(previous_checksum),
    checksum = psl_checksum_id(checksum),
    activated = activated,
    validator = validator,
    bytes_downloaded = psl_as_count(bytes_downloaded),
    snapshot = snapshot
  )
  validate_psl_refresh_result(structure(result, class = "psl_refresh_result"))
}

# Validate a refresh result field by field. The scalar fields reuse the shared
# schema machinery; `snapshot` is a nested record and is validated by its own
# validator, so the two never drift apart.
validate_psl_refresh_result <- function(x) {
  if (!is.list(x) || is.null(names(x))) {
    stop("A refresh result must be a named list.", call. = FALSE)
  }
  expected <- c(names(psl_refresh_result_fields), "snapshot")
  missing <- setdiff(expected, names(x))
  if (length(missing)) {
    stop(
      sprintf("A refresh result is missing field(s): %s.", toString(missing)),
      call. = FALSE
    )
  }
  unknown <- setdiff(names(x), expected)
  if (length(unknown)) {
    stop(
      sprintf("A refresh result has unknown field(s): %s.", toString(unknown)),
      call. = FALSE
    )
  }
  for (field in names(psl_refresh_result_fields)) {
    problem <- psl_field_problem(x[[field]], psl_refresh_result_fields[[field]])
    if (!is.null(problem)) {
      stop(
        sprintf("A refresh result field `%s` %s.", field, problem),
        call. = FALSE
      )
    }
  }
  if (!is.null(x$snapshot)) {
    validate_psl_snapshot_descriptor(x$snapshot)
  }
  x
}

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

# Abbreviate a checksum identity for display; the full value stays on the
# object. `NA` renders as a dash so a line never reads "sha256:NA".
psl_short_checksum <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    return("-")
  }
  parsed <- psl_parse_checksum(x)
  if (is.null(parsed)) {
    return("-")
  }
  sprintf("%s:%s...", parsed$algorithm, substr(parsed$hex, 1L, 12L))
}

psl_display <- function(x) if (length(x) == 1L && !is.na(x)) x else "-"

#' @exportS3Method
#' @noRd
format.psl_refresh_result <- function(x, ...) {
  status <- if (is.na(x$http_status)) {
    "no request"
  } else {
    sprintf("HTTP %d", x$http_status)
  }
  bytes <- if (is.na(x$bytes_downloaded)) {
    "no body"
  } else {
    sprintf("%d bytes", x$bytes_downloaded)
  }
  changed <- if (is.na(x$previous_checksum)) {
    ""
  } else {
    sprintf(" (was %s)", psl_short_checksum(x$previous_checksum))
  }
  c(
    sprintf("<psl_refresh_result: %s>", x$outcome),
    sprintf("  source:    %s (%s)", x$request_url, status),
    sprintf(
      "  snapshot:  %s%s",
      psl_short_checksum(x$checksum),
      changed
    ),
    sprintf(
      "  validator: %s; %s; %s",
      x$validator,
      bytes,
      if (isTRUE(x$activated)) "activated" else "not activated"
    ),
    sprintf("  checked:   %s", psl_display(x$checked_at))
  )
}

#' @exportS3Method
#' @noRd
print.psl_refresh_result <- function(x, ...) {
  cat(format(x), sep = "\n")
  invisible(x)
}

# Coarse fields worth showing on a failure, in a fixed order so the print is
# stable. Only fields the object actually carries are rendered.
psl_refresh_error_display <- c(
  "status",
  "retry_after",
  "bytes_downloaded",
  "limit_bytes",
  "reason",
  "lock",
  "timeout",
  "checksum",
  "request_url",
  "effective_url"
)

#' @exportS3Method
#' @noRd
format.pslr_refresh_error <- function(x, ...) {
  shown <- psl_refresh_error_display[psl_refresh_error_display %in% names(x)]
  shown <- shown[
    !vapply(x[shown], \(v) length(v) != 1L || is.na(v), logical(1))
  ]
  detail <- if (length(shown)) {
    sprintf(
      "  %s",
      toString(sprintf("%s: %s", shown, vapply(x[shown], format, character(1))))
    )
  } else {
    character()
  }
  c(
    sprintf("<%s>", class(x)[[1L]]),
    sprintf("  %s", conditionMessage(x)),
    detail
  )
}

#' @exportS3Method
#' @noRd
print.pslr_refresh_error <- function(x, ...) {
  cat(format(x), sep = "\n")
  invisible(x)
}
