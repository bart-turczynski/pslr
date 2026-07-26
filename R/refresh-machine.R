# Conditional-refresh transition state machine (freshness v2).
#
# This is the decision core of `psl_refresh()`: given the current source state,
# the `force` flag, an injected `now`, and the transport in force, it decides
# WHAT HAPPENS and returns a plan -- or signals a classed refresh error. It
# never publishes, never selects a cache generation, and never activates an
# engine; the publication layer consumes the plan and performs those steps.
#
# The transitions it implements are exactly the ones in the protocol diagram:
#
#   * inside the courtesy window with a snapshot that verifies -> zero
#     requests, `skipped_recently`. `force = TRUE` bypasses ONLY that local
#     boundary; the request it then makes still carries a usable validator;
#   * `304` with verified local bytes -> `not_modified`: `checked_at` advances,
#     `retrieved_at` and the checksum do not, and a rotated validator is kept;
#   * `304` with missing or invalid local bytes -> EXACTLY ONE unconditional
#     repair GET, whose bytes are validated before anything references them, so
#     corrupt bytes are never activated;
#   * `200` -> validate, parse, and hash the bytes, then compare SHA-256:
#     equal is `downloaded_unchanged` and creates no snapshot, different is
#     `updated` and requires one;
#   * any failure -> a classed error. The machine returns no success-shaped
#     result on a failure, and the coarse attempt fields it offers for the
#     failure record carry every freshness field forward unchanged.
#
# Byte acceptance is deliberately not reimplemented here: the downloaded body
# goes through the same `psl_load_source()` path a cache or custom-path list
# does, so "valid PSL" means one thing in the whole package. Its diagnostics
# are dropped rather than interpolated, because a parser message can quote the
# response body and a refresh error must not.

# ---------------------------------------------------------------------------
# State reading
# ---------------------------------------------------------------------------

# One field of a source-state record, as a single string, with an absent record
# or an absent field reported as `NA` rather than `NULL`. Every read of prior
# state goes through here so a first-ever refresh (no record at all) and a
# record with an empty field take the same code path.
psl_state_field <- function(state, name) {
  if (!is.list(state)) {
    return(NA_character_)
  }
  value <- state[[name]]
  if (!is.character(value) || length(value) != 1L) {
    return(NA_character_)
  }
  value
}

# Does the snapshot named by `checksum` exist, describe itself readably, and
# still hash to its own name? This is the one place the machine touches the
# published cache, and it is an argument of the entry point so a test can drive
# every transition without building a cache.
psl_snapshot_verified <- function(checksum) {
  if (!psl_valid_sha256_ref(checksum)) {
    return(FALSE)
  }
  identical(psl_snapshot_integrity(checksum, verify = TRUE), "ok")
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

# The machine's answer: everything the publication layer needs, and nothing it
# has to re-derive.
#
#   * `path` names validated bytes staged on disk, or `NA` when no body was
#     accepted (a skip or a `304`);
#   * `publish_snapshot` says whether those bytes still have to become a
#     snapshot -- `FALSE` when the exact snapshot is already published and
#     verifies, which is what makes `downloaded_unchanged` create nothing;
#   * `publish_state` says whether a new source-state generation is due at all;
#     a skip made no observation, so it changes no state;
#   * `state` and `descriptor` are constructor field lists, ready to be handed
#     to the publication layer verbatim;
#   * `requests` is the number of HTTP requests actually made, which is part of
#     the contract for both the zero-request skip and the one-request repair.
new_psl_refresh_plan <- function(
  outcome,
  request_url,
  ...,
  effective_url = NA_character_,
  http_status = NA_integer_,
  validator = "none",
  bytes_downloaded = NA_integer_,
  checksum = NA_character_,
  previous_checksum = NA_character_,
  checked_at = NA_character_,
  path = NA_character_,
  publish_snapshot = FALSE,
  publish_state = FALSE,
  select = TRUE,
  requests = 0L,
  state = NULL,
  descriptor = list()
) {
  psl_check_empty_dots(...)
  plan <- list(
    outcome = outcome,
    request_url = request_url,
    effective_url = effective_url,
    http_status = psl_as_count(http_status),
    validator = validator,
    bytes_downloaded = psl_as_count(bytes_downloaded),
    checksum = checksum,
    previous_checksum = previous_checksum,
    checked_at = checked_at,
    path = path,
    publish_snapshot = publish_snapshot,
    publish_state = publish_state,
    select = select,
    requests = as.integer(requests),
    state = state,
    descriptor = descriptor
  )
  structure(plan, class = "psl_refresh_plan")
}

# ---------------------------------------------------------------------------
# Body acceptance
# ---------------------------------------------------------------------------

# Accept a response body, or refuse it. A body must exist, stay inside the
# documented size ceiling, and parse as a complete PSL under the runtime
# normalizer; anything else is a refusal BEFORE the bytes are referenced, and
# the staged file is removed on the way out. Returns the staged path.
psl_accept_body <- function(response, request_url) {
  path <- response$body_path
  usable <- is.character(path) &&
    length(path) == 1L &&
    !is.na(path) &&
    file.exists(path)
  if (!usable) {
    stop(psl_refresh_validation_error(
      "Refresh failed: the response carried no body to validate.",
      request_url = request_url
    ))
  }
  size <- file.size(path)
  limit <- psl_max_source_bytes()
  if (length(size) != 1L || is.na(size)) {
    unlink(path)
    stop(psl_refresh_validation_error(
      "Refresh failed: the downloaded body could not be read.",
      request_url = request_url
    ))
  }
  if (size > limit) {
    unlink(path)
    stop(psl_refresh_response_limit_error(
      size,
      limit,
      request_url = request_url
    ))
  }
  valid <- tryCatch(
    {
      psl_load_source(path, "downloaded list")
      TRUE
    },
    error = \(cnd) FALSE
  )
  if (!valid) {
    unlink(path)
    stop(psl_refresh_validation_error(
      "Refresh refused: the downloaded list is not a valid Public Suffix List.",
      request_url = request_url
    ))
  }
  path
}

# ---------------------------------------------------------------------------
# Derived state fields
# ---------------------------------------------------------------------------

# The validators to persist after a response. A stored validator is carried
# forward only when the response came from the URL that issued it: a redirect
# to a different target invalidates the scope, so keeping the old token under
# the new issuer would be a lie about who minted it.
psl_plan_validators <- function(state, fetched) {
  issuer <- psl_state_field(state, "validator_url")
  same <- identical(fetched$effective_url, issuer)
  psl_validator_update(
    if (same) psl_state_field(state, "etag") else NA_character_,
    if (same) psl_state_field(state, "last_modified") else NA_character_,
    fetched$response$headers
  )
}

# The next courtesy boundary implied by one response, as a persisted timestamp.
psl_plan_next_check_at <- function(response, now) {
  psl_format_time(psl_next_check_at(
    now,
    cache_control = psl_response_header(response, "cache-control"),
    age = psl_response_header(response, "age")
  ))
}

# Source-state fields for an outcome that observed the source. `retrieved_at`
# is the caller's business: only accepted bytes advance it, so a `304` passes
# the stored value straight through.
psl_plan_state <- function(
  state,
  fetched,
  now,
  ...,
  outcome,
  checksum,
  retrieved_at
) {
  psl_check_empty_dots(...)
  validators <- psl_plan_validators(state, fetched)
  stamp <- psl_format_time(now)
  list(
    effective_url = fetched$effective_url,
    validator_url = fetched$effective_url,
    checksum = checksum,
    etag = validators$etag,
    last_modified = validators$last_modified,
    retrieved_at = retrieved_at,
    checked_at = stamp,
    next_check_at = psl_plan_next_check_at(fetched$response, now),
    last_attempt_at = stamp,
    last_result = outcome
  )
}

# Source-state fields for a failed attempt: every freshness field carried
# forward byte for byte, and only the two diagnostic fields advanced. A
# condition from outside the refresh hierarchy records no category rather than
# being filed under a category it does not belong to.
psl_refresh_failure_state <- function(state, cnd, now) {
  list(
    effective_url = psl_state_field(state, "effective_url"),
    validator_url = psl_state_field(state, "validator_url"),
    checksum = psl_state_field(state, "checksum"),
    etag = psl_state_field(state, "etag"),
    last_modified = psl_state_field(state, "last_modified"),
    retrieved_at = psl_state_field(state, "retrieved_at"),
    checked_at = psl_state_field(state, "checked_at"),
    next_check_at = psl_state_field(state, "next_check_at"),
    last_attempt_at = psl_format_time(now),
    last_result = psl_refresh_attempt_result(cnd)
  )
}

# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------

# May this refresh answer from local state alone? Only when the courtesy
# boundary has not been reached AND the snapshot that state references still
# verifies -- an unverifiable snapshot is exactly the case a skip must not
# paper over. `force = TRUE` bypasses the boundary and nothing else.
psl_refresh_skips <- function(state, now, force, verify) {
  if (!is.list(state)) {
    return(FALSE)
  }
  allowed <- psl_check_allowed(
    psl_state_field(state, "next_check_at"),
    now,
    force
  )
  if (allowed) {
    return(FALSE)
  }
  isTRUE(verify(psl_state_field(state, "checksum")))
}

# Zero requests: the existing successful check still stands. `checked_at`
# retains the confirmation time that justified the skip, and no generation is
# written, so nothing about the source's freshness changes.
psl_skip_plan <- function(request_url, state) {
  new_psl_refresh_plan(
    "skipped_recently",
    request_url,
    effective_url = psl_state_field(state, "effective_url"),
    checksum = psl_state_field(state, "checksum"),
    checked_at = psl_state_field(state, "checked_at")
  )
}

# A `304` backed by bytes that verify: the licence to keep using them. The
# checksum and `retrieved_at` are untouched, `checked_at` advances, and a
# rotated validator is accepted.
psl_not_modified_plan <- function(request_url, state, fetched, validator, now) {
  checksum <- psl_state_field(state, "checksum")
  new_psl_refresh_plan(
    "not_modified",
    request_url,
    effective_url = fetched$effective_url,
    http_status = fetched$response$status,
    validator = validator,
    checksum = checksum,
    checked_at = psl_format_time(now),
    publish_state = TRUE,
    requests = 1L,
    state = psl_plan_state(
      state,
      fetched,
      now,
      outcome = "not_modified",
      checksum = checksum,
      retrieved_at = psl_state_field(state, "retrieved_at")
    )
  )
}

# A `200` whose bytes were accepted. The outcome is decided by SHA-256 alone:
# equal to what the source already references is `downloaded_unchanged`,
# anything else is `updated`. Whether a snapshot still has to be WRITTEN is a
# separate question -- these exact bytes may already be published and verify,
# in which case there is nothing to create, and that is also what makes a
# repair download republish bytes whose local copy was corrupt.
psl_downloaded_plan <- function(
  request_url,
  state,
  fetched,
  validator,
  now,
  ...,
  verify,
  requests
) {
  psl_check_empty_dots(...)
  response <- fetched$response
  path <- psl_accept_body(response, request_url)
  checksum <- psl_source_checksum(path)
  previous <- psl_state_field(state, "checksum")
  unchanged <- !is.na(previous) && identical(checksum, previous)
  outcome <- if (unchanged) "downloaded_unchanged" else "updated"
  stamp <- psl_format_time(now)
  new_psl_refresh_plan(
    outcome,
    request_url,
    effective_url = fetched$effective_url,
    http_status = response$status,
    validator = validator,
    bytes_downloaded = response$bytes_downloaded,
    checksum = checksum,
    previous_checksum = previous,
    checked_at = stamp,
    path = path,
    publish_snapshot = !isTRUE(verify(checksum)),
    publish_state = TRUE,
    requests = requests,
    state = psl_plan_state(
      state,
      fetched,
      now,
      outcome = outcome,
      checksum = checksum,
      retrieved_at = stamp
    ),
    descriptor = list(
      origin_url = fetched$effective_url,
      first_retrieved_at = stamp
    )
  )
}

# The single unconditional repair GET a `304` over unusable local bytes earns.
# It is unconditional by construction -- no validator headers are passed -- so
# a `304` in reply is a protocol violation and is refused rather than read as a
# second freshness claim.
psl_repair_fetch <- function(request_url, destfile, max_redirects) {
  repaired <- psl_fetch_with_policy(
    request_url,
    destfile,
    max_redirects = max_redirects
  )
  psl_require_response_status(repaired$response, request_url)
  if (identical(psl_response_class(repaired$response), "not_modified")) {
    psl_check_not_modified(repaired$validator_sent, request_url)
  }
  repaired
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Decide one conditional refresh.
#
# `state` is the current source-state record (or `NULL` for a source never seen
# before), `now` is the injected instant every timestamp is derived from,
# `destfile` is where a response body may be staged, and `verify` reports
# whether a published snapshot still verifies. Returns a `psl_refresh_plan`, or
# signals a classed `pslr_refresh_error`; it never returns a success-shaped
# answer for a failure.
psl_refresh_transition <- function(
  request_url,
  destfile,
  ...,
  state = NULL,
  now = psl_now(),
  force = FALSE,
  verify = psl_snapshot_verified,
  max_redirects = psl_max_redirects
) {
  psl_check_empty_dots(...)
  psl_check_flag(force, "force")
  url <- psl_normalize_source_url(request_url)
  if (psl_refresh_skips(state, now, force, verify)) {
    return(psl_skip_plan(url, state))
  }
  request <- psl_validator_request(
    psl_state_field(state, "etag"),
    psl_state_field(state, "last_modified")
  )
  fetched <- psl_fetch_with_policy(
    url,
    destfile,
    validator_headers = request$headers,
    validator_issuer = psl_state_field(state, "validator_url"),
    max_redirects = max_redirects
  )
  classification <- psl_require_response_status(fetched$response, url)
  validator <- if (isTRUE(fetched$validator_sent)) request$validator else "none"
  if (identical(classification, "ok")) {
    return(psl_downloaded_plan(
      url,
      state,
      fetched,
      validator,
      now,
      verify = verify,
      requests = 1L
    ))
  }
  psl_check_not_modified(fetched$validator_sent, url)
  if (isTRUE(verify(psl_state_field(state, "checksum")))) {
    return(psl_not_modified_plan(url, state, fetched, validator, now))
  }
  psl_downloaded_plan(
    url,
    state,
    psl_repair_fetch(url, destfile, max_redirects),
    "none",
    now,
    verify = verify,
    requests = 2L
  )
}
