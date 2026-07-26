# HTTP validator selection and courtesy-window arithmetic (freshness v2).
#
# Everything here is pure: no clock, no filesystem, no network. Every function
# that needs the current time takes it as an explicit `now` argument, so a
# production call reads the clock once and passes it down while a test injects
# a fixed instant. That is what makes the freshness rules testable at all.
#
# Two policies live here.
#
#   * VALIDATORS. Which conditional-request header to send, what a stored or
#     received validator must look like to be usable at all, and what to do
#     with a `304`. A validator is an opaque token: pslr never parses an ETag,
#     never compares two of them for ordering, and never derives meaning from
#     its shape beyond "is it safe to store and to put on the wire".
#
#     A validator establishes HTTP REPRESENTATION EQUIVALENCE ONLY. It is not
#     an integrity check and not an authenticity check: it says the origin
#     believes the representation is unchanged, and nothing about whether the
#     bytes pslr holds are the bytes the origin means. TLS, the SHA-256
#     identity of the stored snapshot, and full PSL validation all remain
#     required regardless of what a validator says. A `304` is therefore only
#     ever a licence to keep using bytes that independently verify.
#
#   * COURTESY. How long to wait before the next ordinary source check. The
#     official PSL asks clients not to download more than once a day, so
#     24 hours is a hard floor that server metadata can lengthen but never
#     shorten, and 30 days is a hard cap so hostile or broken metadata cannot
#     suppress checking indefinitely. An explicit `force = TRUE` is the only
#     override.
#
# Where scope lives, and where this does not go: `R/url-policy.R` decides
# WHERE a validator may be sent (only to the exact URL that issued it); this
# file decides WHICH validator to send and WHETHER it is usable. Deciding an
# outcome from a response is the refresh state machine's job, not this file's.

# ---------------------------------------------------------------------------
# Limits
# ---------------------------------------------------------------------------

# Longest validator pslr will store or send, in bytes. Matches the request
# header ceiling in the transport layer, so a value that survives this check
# can never be rejected later by header assembly.
psl_max_validator_bytes <- 8192L

# Hard floor between ordinary source checks: the PSL asks for no more than one
# download a day.
psl_courtesy_floor_seconds <- 86400L

# Ceiling on the server-declared lifetime pslr will honour: 30 days. Anything
# longer is treated as 30 days, so a malformed or hostile `max-age` cannot park
# `next_check_at` in the far future.
psl_courtesy_cap_seconds <- 2592000L

# ---------------------------------------------------------------------------
# Validator sanitization
# ---------------------------------------------------------------------------

# Does `value` contain a byte no HTTP field value may carry? The test is done
# on raw bytes rather than with a character class, so it is independent of the
# session locale and of any multi-byte encoding: every ASCII control byte
# (including CR, LF, NUL, and DEL) is rejected, and bytes at or above 0x80 are
# left alone -- they are non-ASCII text, not control characters.
#
# NUL cannot appear in an R character string at all (R refuses to build one),
# so in practice a NUL is rejected earlier, by whatever tried to construct the
# string; the check below is still written to cover it because these values
# come off the wire and out of files.
psl_has_control_bytes <- function(value) {
  bytes <- as.integer(charToRaw(value))
  any(bytes < 32L | bytes == 127L)
}

# Is `value` a validator pslr may store and send? Applied in BOTH directions:
# a hostile response header is refused before it is persisted, and a corrupt
# stored value is refused before it is put on the wire. A rejected validator is
# not an error -- it simply means there is no usable validator, and the refresh
# falls back to an ordinary GET.
psl_validator_usable <- function(value) {
  ok <- is.character(value) &&
    length(value) == 1L &&
    !is.na(value) &&
    nzchar(value)
  if (!ok) {
    return(FALSE)
  }
  if (nchar(value, type = "bytes") > psl_max_validator_bytes) {
    return(FALSE)
  }
  !psl_has_control_bytes(value)
}

# The storable form of a validator: the value itself when usable, `NA` when
# not. Byte-exact -- a weak prefix (`W/`), the quotes, and the inner bytes are
# all preserved, because the origin compares the token it issued and any
# rewriting would silently break conditional requests.
psl_clean_validator <- function(value) {
  if (psl_validator_usable(value)) value else NA_character_
}

# ---------------------------------------------------------------------------
# Validator selection
# ---------------------------------------------------------------------------

# The conditional-request headers for one refresh, and the name of the
# validator they carry (matching `psl_refresh_validators`).
#
# ETag wins whenever it is usable: it is the strong validator and the only one
# with sub-second resolution. `Last-Modified` is the fallback and is used only
# when no usable ETag exists -- never both, so a server that disagrees with
# itself cannot produce an ambiguous request. With neither, the request goes
# out unconditionally and the response is compared by SHA-256 instead.
psl_validator_request <- function(etag, last_modified) {
  if (psl_validator_usable(etag)) {
    return(list(
      headers = c("If-None-Match" = etag),
      validator = "etag"
    ))
  }
  if (psl_validator_usable(last_modified)) {
    return(list(
      headers = c("If-Modified-Since" = last_modified),
      validator = "last_modified"
    ))
  }
  list(headers = psl_empty_headers(), validator = "none")
}

# The validators to persist after a response. A server may rotate a validator
# on any response, including a `304`, so a usable value in the response wins;
# an absent or unusable one leaves the stored value untouched rather than
# clearing it, because a single malformed header should not cost the next
# request its conditional.
psl_validator_update <- function(etag, last_modified, headers) {
  headers <- psl_normalize_headers(headers)
  list(
    etag = psl_rotated_validator(etag, headers, "etag"),
    last_modified = psl_rotated_validator(
      last_modified,
      headers,
      "last-modified"
    )
  )
}

# One header field of an already-normalized header vector, or `NA` when the
# field is absent.
psl_header_value <- function(headers, name) {
  if (!length(headers) || !name %in% names(headers)) {
    return(NA_character_)
  }
  unname(headers[[name]])
}

# The value to keep for one validator: the response's when it is usable, the
# stored one otherwise.
psl_rotated_validator <- function(stored, headers, name) {
  received <- psl_clean_validator(psl_header_value(headers, name))
  if (is.na(received)) psl_clean_validator(stored) else received
}

# A `304` is only meaningful as the answer to a conditional request. One that
# arrives when pslr sent no validator is a protocol violation, not a freshness
# claim, and must never be read as "your bytes are current" -- so it is refused
# here rather than allowed to advance `checked_at`.
psl_check_not_modified <- function(
  validator_sent,
  request_url = NA_character_
) {
  if (isTRUE(validator_sent)) {
    return(invisible(NULL))
  }
  stop(psl_refresh_transport_error(
    paste(
      "Refresh failed: the server answered HTTP 304 to a request that",
      "carried no validator."
    ),
    reason = "unsolicited_not_modified",
    request_url = request_url
  ))
}

# ---------------------------------------------------------------------------
# Courtesy window
# ---------------------------------------------------------------------------

# A non-negative integer number of seconds, or `NA` when the value is absent,
# negative, fractional, or otherwise not a delta-seconds integer. Only the
# integer form is honoured, which keeps parsing exact and free of any locale
# dependency (no month or weekday names are ever involved).
psl_delta_seconds <- function(value) {
  if (!is.character(value) || length(value) != 1L || is.na(value)) {
    return(NA_integer_)
  }
  value <- trimws(value)
  if (!grepl("^[0-9]{1,9}$", value)) {
    return(NA_integer_)
  }
  as.integer(value)
}

# `max-age` from a `Cache-Control` field, or `NA` when it is absent or
# malformed. Directive names are case-insensitive per HTTP, and the match is
# anchored to both ends of a directive, so neither `s-maxage` nor a partly
# numeric value such as `max-age=6.5` can be mistaken for it. A quoted value is
# accepted because some origins emit one. Every other directive, and `Expires`
# entirely, is ignored in v2.
psl_cache_max_age <- function(cache_control) {
  if (
    !is.character(cache_control) ||
      length(cache_control) != 1L ||
      is.na(cache_control)
  ) {
    return(NA_integer_)
  }
  match <- regmatches(
    cache_control,
    regexec(
      "(^|,)[ \t]*max-age[ \t]*=[ \t]*\"?([0-9]+)\"?[ \t]*($|,)",
      cache_control,
      ignore.case = TRUE
    )
  )[[1L]]
  if (!length(match)) {
    return(NA_integer_)
  }
  psl_delta_seconds(match[[3L]])
}

# Seconds of server-declared freshness still left, from `Cache-Control` and
# `Age`. `max(0, max-age - Age)`; a missing `Age` counts as zero, an `Age` past
# `max-age` leaves nothing, and anything malformed, negative, or non-integer
# yields zero rather than an error -- the 24-hour floor then decides the
# window on its own. The result is capped at 30 days.
psl_remaining_freshness <- function(cache_control, age) {
  max_age <- psl_cache_max_age(cache_control)
  if (is.na(max_age)) {
    return(0)
  }
  seconds <- psl_delta_seconds(age)
  elapsed <- if (is.na(seconds)) 0L else seconds
  min(max(0, max_age - elapsed), psl_courtesy_cap_seconds)
}

# The courtesy boundary: `checked_at + max(24 hours, remaining freshness)`.
# `checked_at` may be a POSIXct or a persisted timestamp; the answer is always
# POSIXct in UTC, and `NA` in means `NA` out.
psl_next_check_at <- function(
  checked_at,
  ...,
  cache_control = NA_character_,
  age = NA_character_
) {
  psl_check_empty_dots(...)
  checked_at <- psl_as_time(checked_at)
  if (is.na(checked_at)) {
    return(psl_na_time())
  }
  window <- max(
    psl_courtesy_floor_seconds,
    psl_remaining_freshness(cache_control, age)
  )
  checked_at + window
}

# May an ordinary check make a request now? `force = TRUE` is the explicit
# override and always wins; an unknown boundary means nothing is being
# suppressed, so the check proceeds. Otherwise the window holds until `now`
# reaches the boundary.
psl_check_allowed <- function(next_check_at, now, force = FALSE) {
  if (isTRUE(force)) {
    return(TRUE)
  }
  next_check_at <- psl_as_time(next_check_at)
  now <- psl_as_time(now)
  if (is.na(next_check_at) || is.na(now)) {
    return(TRUE)
  }
  now >= next_check_at
}

# ---------------------------------------------------------------------------
# Age, due, and clock skew
# ---------------------------------------------------------------------------

# Typed missing time, so an unknown answer keeps the POSIXct type instead of
# degrading to a bare logical `NA`.
psl_na_time <- function() {
  as.POSIXct(NA_character_, tz = "UTC")
}

# Accept a time as POSIXct or as a persisted RFC 3339 string and return
# POSIXct in UTC. Anything unparseable -- including a bare `NA` -- becomes the
# typed missing time, which callers report as unknown rather than as a
# freshness claim.
psl_as_time <- function(x) {
  if (inherits(x, "POSIXt")) {
    if (length(x) != 1L) {
      return(psl_na_time())
    }
    return(as.POSIXct(x, tz = "UTC"))
  }
  if (is.character(x) && length(x) == 1L && !is.na(x)) {
    return(psl_parse_time(x))
  }
  psl_na_time()
}

# Seconds from `from` to `now`, or `NA` when either time is unknown OR the
# result would be negative. A backwards clock is the whole reason for the
# second case: the honest answer is "the age is unknown", and reporting `NA`
# keeps the status layer from turning a skewed clock into a freshness claim it
# cannot support.
psl_elapsed_seconds <- function(from, now) {
  from <- psl_as_time(from)
  now <- psl_as_time(now)
  if (is.na(from) || is.na(now)) {
    return(NA_real_)
  }
  seconds <- as.numeric(difftime(now, from, units = "secs"))
  if (seconds < 0) NA_real_ else seconds
}

psl_elapsed_days <- function(from, now) {
  psl_elapsed_seconds(from, now) / 86400
}

# Is a freshness check due? `TRUE` when nothing has ever confirmed the source
# (`checked_at` absent) or the retained reminder interval has elapsed; `FALSE`
# while it has not; and `NA` under backwards clock skew, where the age is
# unknown and neither answer would be honest.
#
# This is offline advice derived from local timestamps alone. It says the
# configured interval has passed, never that an update exists upstream.
psl_check_due <- function(
  checked_at,
  now,
  interval_days = psl_reminder_default_interval
) {
  checked_at <- psl_as_time(checked_at)
  if (is.na(checked_at)) {
    return(TRUE)
  }
  elapsed <- psl_elapsed_days(checked_at, now)
  if (is.na(elapsed)) {
    return(NA)
  }
  elapsed >= interval_days
}
