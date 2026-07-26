# Versioned freshness record schemas (freshness v2).
#
# The freshness subsystem keeps immutable snapshot identity separate from
# mutable knowledge about a remote endpoint. Four record types carry that
# split, and every one of them is versioned so a later release can branch on
# the recorded schema instead of guessing:
#
#   * snapshot descriptor      -- immutable identity and provenance of bytes;
#   * source-state generation  -- mutable knowledge about one request URL;
#   * cache-selection generation -- which snapshot `psl_use("cache")` picks;
#   * reminder-preference generation -- the opt-in attach reminder config.
#
# This file is schemas only: constructors, strict validators, and the shared
# primitives they need (checksum identity, UTC RFC 3339 time, source-stream
# naming). It performs no I/O, takes no locks, and makes no network request;
# the persistence, HTTP, and status layers build on top of it.

# ---------------------------------------------------------------------------
# Checksum identity
# ---------------------------------------------------------------------------

# SHA-256 over bytes, returned as lowercase hex without an algorithm prefix.
# Accepts a raw vector or a single string (hashed as its UTF-8 bytes), so the
# same helper covers file contents and normalized URLs.
psl_sha256_bytes <- function(bytes) {
  if (is.character(bytes)) {
    if (length(bytes) != 1L || is.na(bytes)) {
      stop("`bytes` must be a single non-missing string.", call. = FALSE)
    }
    bytes <- charToRaw(enc2utf8(bytes))
  }
  if (!is.raw(bytes)) {
    stop("`bytes` must be a raw vector or a single string.", call. = FALSE)
  }
  digest::digest(bytes, algo = "sha256", serialize = FALSE)
}

# SHA-256 over a file's exact bytes, as lowercase hex without a prefix.
psl_sha256_file <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single non-missing file path.", call. = FALSE)
  }
  hex <- digest::digest(file = path, algo = "sha256")
  if (is.null(hex)) {
    stop(sprintf("could not read file for hashing: %s", path), call. = FALSE)
  }
  hex
}

# Is `x` a checksum reference this release writes? SHA-256 is the sole identity
# for newly published bytes, so only the `sha256:` form qualifies.
psl_valid_sha256_ref <- function(x) {
  is.character(x) &&
    length(x) == 1L &&
    !is.na(x) &&
    grepl("^sha256:[0-9a-f]{64}$", x)
}

# Compatibility reader: split any checksum reference pslr has ever recorded
# into its algorithm and lowercase hex digest. Legacy caches carry `md5:<hex>`
# and legacy `sha256:<hex>` values that must stay readable and verifiable; only
# writing new MD5 identities is forbidden. Returns NULL for anything else, so
# callers can classify unreadable metadata rather than trust it.
psl_parse_checksum <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    return(NULL)
  }
  algorithm <- sub(":.*$", "", x)
  hex <- tolower(sub("^[^:]+:", "", x))
  width <- switch(algorithm, sha256 = 64L, md5 = 32L, NULL)
  if (is.null(width) || !grepl(sprintf("^[0-9a-f]{%d}$", width), hex)) {
    return(NULL)
  }
  list(algorithm = algorithm, hex = hex)
}

# Normalize a SHA-256 digest to the canonical `sha256:<lowercase hex>` identity
# used by every v2 record. Accepts a bare hex digest or an already-prefixed
# value; an MD5 value is rejected here on purpose -- new identities must never
# be MD5, even when the caller read one from a legacy cache.
psl_checksum_id <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    stop("`x` must be a single non-missing checksum string.", call. = FALSE)
  }
  value <- tolower(x)
  if (grepl("^[0-9a-f]{64}$", value)) {
    value <- paste0("sha256:", value)
  }
  if (!psl_valid_sha256_ref(value)) {
    stop(
      "New checksums must be SHA-256, as \"sha256:<hex>\" or a bare digest.",
      call. = FALSE
    )
  }
  value
}

# Directory name for one source-state stream: a SHA-256 digest of the already
# normalized request URL. Filenames never contain URL text, so a persisted
# cache layout cannot leak a private source URL through a directory listing.
# URL normalization itself belongs to the URL-policy layer; this helper hashes
# whatever normalized string it is handed.
psl_source_stream_name <- function(normalized_url) {
  if (
    !is.character(normalized_url) ||
      length(normalized_url) != 1L ||
      is.na(normalized_url) ||
      !nzchar(normalized_url)
  ) {
    stop("`normalized_url` must be a single non-empty string.", call. = FALSE)
  }
  paste0("sha256-", psl_sha256_bytes(normalized_url))
}

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

# The single persisted time format: UTC RFC 3339 with seconds precision.
psl_rfc3339_format <- "%Y-%m-%dT%H:%M:%SZ"

# Serialize one time to the persisted format. POSIXct in, string out; `NA` in,
# `NA_character_` out. Every record field that stores a time goes through here,
# so no caller re-spells the format or leaks a local time zone.
psl_format_time <- function(x = Sys.time()) {
  if (!inherits(x, "POSIXt")) {
    stop("`x` must be a POSIXct time.", call. = FALSE)
  }
  if (length(x) != 1L) {
    stop("`x` must be a single time.", call. = FALSE)
  }
  if (is.na(x)) {
    return(NA_character_)
  }
  format(x, format = psl_rfc3339_format, tz = "UTC")
}

# Parse persisted times back to POSIXct in UTC. Vectorized; anything that is
# not exactly the persisted format yields `NA`, which the status layer reports
# as unknown rather than as a freshness claim.
psl_parse_time <- function(x) {
  if (!is.character(x)) {
    stop("`x` must be a character timestamp.", call. = FALSE)
  }
  as.POSIXct(x, format = psl_rfc3339_format, tz = "UTC")
}

# Is `x` a single well-formed persisted timestamp? Shape first (so a value like
# "2026-06-31T00:00:00Z" is not merely shape-checked), then a real parse.
psl_valid_rfc3339 <- function(x) {
  shaped <- is.character(x) &&
    length(x) == 1L &&
    !is.na(x) &&
    grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", x)
  shaped && !is.na(psl_parse_time(x))
}

# Accept a time argument as either POSIXct or an already-serialized string and
# return the persisted representation. Non-time values pass through untouched
# so the record validator -- not this coercion -- produces the error.
psl_as_rfc3339 <- function(x) {
  if (inherits(x, "POSIXt")) {
    return(psl_format_time(x))
  }
  if (is.character(x) || (is.logical(x) && length(x) == 1L && is.na(x))) {
    return(as.character(x))
  }
  x
}

# ---------------------------------------------------------------------------
# Generic record machinery
# ---------------------------------------------------------------------------

# One field's contract: storage type, whether a typed `NA` is allowed, an
# optional closed set of values, and an optional predicate with the message to
# report when it fails. The four record schemas below are pure data built from
# this, so construction, defaults, and validation never drift apart.
psl_schema_field <- function(
  type,
  optional = FALSE,
  choices = NULL,
  check = NULL,
  message = NULL
) {
  list(
    type = type,
    optional = optional,
    choices = choices,
    check = check,
    message = message
  )
}

# Typed `NA` for a storage type; the default value of every optional field.
psl_schema_na <- function(type) {
  switch(type, character = NA_character_, integer = NA_integer_, logical = NA)
}

# Coerce a whole-number argument to integer, leaving anything else untouched so
# the validator reports it as a type problem instead of silently accepting it.
psl_as_count <- function(x) {
  whole <- is.numeric(x) && length(x) == 1L && !is.na(x) && x == trunc(x)
  if (whole) as.integer(x) else x
}

# Describe the first contract violation in one field, or NULL when it holds.
psl_field_problem <- function(value, spec) {
  if (length(value) != 1L) {
    return("must be a single value")
  }
  ok_type <- switch(
    spec$type,
    character = is.character(value),
    integer = is.integer(value),
    logical = is.logical(value)
  )
  if (!ok_type) {
    return(sprintf("must be a single %s value", spec$type))
  }
  if (is.na(value)) {
    return(if (spec$optional) NULL else "must not be NA")
  }
  if (identical(spec$type, "character") && !nzchar(value)) {
    return("must not be an empty string")
  }
  if (!is.null(spec$choices) && !value %in% spec$choices) {
    return(sprintf("must be one of: %s", toString(spec$choices)))
  }
  if (!is.null(spec$check) && !isTRUE(spec$check(value))) {
    return(spec$message)
  }
  NULL
}

# Strictly validate one record against its schema. Rejects, in order: a
# non-list; a missing or unknown schema version; missing fields; unknown
# fields; and any field violating its contract. Returns `x` invisibly on
# success. Every rejection is deterministic and names the offending field, so a
# corrupt or future-versioned record on disk degrades to a reported fault
# instead of a silent NULL read downstream.
psl_validate_record <- function(x, fields, version, what) {
  if (!is.list(x) || is.null(names(x))) {
    stop(sprintf("A %s must be a named list.", what), call. = FALSE)
  }
  if (!identical(x$schema_version, version)) {
    stop(
      sprintf(
        "Unsupported %s schema version; this pslr supports version %d.",
        what,
        version
      ),
      call. = FALSE
    )
  }
  missing <- setdiff(names(fields), names(x))
  if (length(missing)) {
    stop(
      sprintf("A %s is missing field(s): %s.", what, toString(missing)),
      call. = FALSE
    )
  }
  unknown <- setdiff(names(x), names(fields))
  if (length(unknown)) {
    stop(
      sprintf("A %s has unknown field(s): %s.", what, toString(unknown)),
      call. = FALSE
    )
  }
  for (field in names(fields)) {
    problem <- psl_field_problem(x[[field]], fields[[field]])
    if (!is.null(problem)) {
      stop(
        sprintf("A %s field `%s` %s.", what, field, problem),
        call. = FALSE
      )
    }
  }
  invisible(x)
}

# Guard the optional-argument boundary of a constructor: everything after `...`
# must be named, so a misspelled optional argument aborts instead of being
# silently dropped into `...`.
psl_check_empty_dots <- function(...) {
  if (...length()) {
    named <- ...names()
    stop(
      sprintf(
        "Unexpected argument(s): %s.",
        if (is.null(named)) "unnamed" else toString(named)
      ),
      call. = FALSE
    )
  }
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# Snapshot descriptor
# ---------------------------------------------------------------------------

psl_snapshot_schema_version <- 1L

# Identifier of the validation rules a snapshot's bytes were accepted under
# (UTF-8, both official section markers, rule grammar, canonicalization).
psl_validation_schema_id <- "psl-sections-1"

psl_snapshot_fields <- list(
  schema_version = psl_schema_field("integer"),
  checksum = psl_schema_field(
    "character",
    check = psl_valid_sha256_ref,
    message = "must be a \"sha256:<hex>\" identity"
  ),
  size = psl_schema_field(
    "integer",
    check = \(v) v >= 0L,
    message = "must not be negative"
  ),
  storage = psl_schema_field("character", choices = c("bundled", "cache")),
  path = psl_schema_field("character"),
  content_date = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  ),
  commit = psl_schema_field("character", optional = TRUE),
  origin_url = psl_schema_field("character", optional = TRUE),
  parser = psl_schema_field("character"),
  normalization_profile = psl_schema_field("character"),
  unicode_version = psl_schema_field("character"),
  validation_schema = psl_schema_field("character"),
  first_retrieved_at = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  )
)

# The parser / normalization identifiers this session would stamp onto newly
# published bytes.
psl_runtime_snapshot_profile <- function() {
  norm <- runtime_normalizer_meta()
  list(
    parser = sprintf("pslr/%s", as.character(utils::packageVersion("pslr"))),
    normalization_profile = norm$normalization_profile,
    unicode_version = norm$unicode_version,
    validation_schema = psl_validation_schema_id
  )
}

# Construct a validated snapshot descriptor: the immutable identity and
# provenance of one set of PSL source bytes. `checksum` is normalized to the
# canonical SHA-256 identity, and provenance that is genuinely unknown stays a
# typed `NA` rather than being invented.
new_psl_snapshot_descriptor <- function(
  checksum,
  size,
  storage,
  path,
  ...,
  content_date = NA,
  commit = NA_character_,
  origin_url = NA_character_,
  first_retrieved_at = NA,
  profile = psl_runtime_snapshot_profile()
) {
  psl_check_empty_dots(...)
  record <- list(
    schema_version = psl_snapshot_schema_version,
    checksum = psl_checksum_id(checksum),
    size = psl_as_count(size),
    storage = storage,
    path = path,
    content_date = psl_as_rfc3339(content_date),
    commit = commit,
    origin_url = origin_url,
    parser = profile$parser,
    normalization_profile = profile$normalization_profile,
    unicode_version = profile$unicode_version,
    validation_schema = profile$validation_schema,
    first_retrieved_at = psl_as_rfc3339(first_retrieved_at)
  )
  validate_psl_snapshot_descriptor(record)
  record
}

validate_psl_snapshot_descriptor <- function(x) {
  psl_validate_record(
    x,
    psl_snapshot_fields,
    psl_snapshot_schema_version,
    "snapshot descriptor"
  )
}

# ---------------------------------------------------------------------------
# Source-state generation
# ---------------------------------------------------------------------------

psl_source_state_schema_version <- 1L

# Coarse result category recorded for the last refresh attempt against a
# source. The four successful outcomes plus one category per classed failure
# family; deliberately coarse, so no response body, header, or credential is
# ever persisted as diagnostics.
psl_source_attempt_results <- c(
  "skipped_recently",
  "not_modified",
  "downloaded_unchanged",
  "updated",
  "url_policy_error",
  "busy_error",
  "transport_error",
  "http_status_error",
  "response_limit_error",
  "validation_error",
  "local_corruption_error",
  "schema_error",
  "publication_error"
)

psl_source_state_fields <- list(
  schema_version = psl_schema_field("integer"),
  generation = psl_schema_field(
    "integer",
    check = \(v) v >= 1L,
    message = "must be a positive generation number"
  ),
  request_url = psl_schema_field("character"),
  effective_url = psl_schema_field("character", optional = TRUE),
  validator_url = psl_schema_field("character", optional = TRUE),
  checksum = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_sha256_ref,
    message = "must be a \"sha256:<hex>\" identity"
  ),
  etag = psl_schema_field("character", optional = TRUE),
  last_modified = psl_schema_field("character", optional = TRUE),
  retrieved_at = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  ),
  checked_at = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  ),
  next_check_at = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  ),
  last_attempt_at = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  ),
  last_result = psl_schema_field(
    "character",
    optional = TRUE,
    choices = psl_source_attempt_results
  )
)

# Construct a validated source-state generation: everything mutable pslr knows
# about one normalized request URL at one point in its append-only history.
# `checked_at` and `retrieved_at` are freshness evidence and must be advanced
# only by the refresh state machine; `last_attempt_at` / `last_result` are
# diagnostics a failure may update on its own.
new_psl_source_state <- function(
  request_url,
  generation = 1L,
  ...,
  effective_url = NA_character_,
  validator_url = NA_character_,
  checksum = NA_character_,
  etag = NA_character_,
  last_modified = NA_character_,
  retrieved_at = NA,
  checked_at = NA,
  next_check_at = NA,
  last_attempt_at = NA,
  last_result = NA_character_
) {
  psl_check_empty_dots(...)
  record <- list(
    schema_version = psl_source_state_schema_version,
    generation = psl_as_count(generation),
    request_url = request_url,
    effective_url = effective_url,
    validator_url = validator_url,
    checksum = if (is.character(checksum) && !anyNA(checksum)) {
      psl_checksum_id(checksum)
    } else {
      checksum
    },
    etag = etag,
    last_modified = last_modified,
    retrieved_at = psl_as_rfc3339(retrieved_at),
    checked_at = psl_as_rfc3339(checked_at),
    next_check_at = psl_as_rfc3339(next_check_at),
    last_attempt_at = psl_as_rfc3339(last_attempt_at),
    last_result = last_result
  )
  validate_psl_source_state(record)
  record
}

validate_psl_source_state <- function(x) {
  psl_validate_record(
    x,
    psl_source_state_fields,
    psl_source_state_schema_version,
    "source-state generation"
  )
}

# ---------------------------------------------------------------------------
# Cache-selection generation
# ---------------------------------------------------------------------------

psl_selection_schema_version <- 1L

psl_selection_fields <- list(
  schema_version = psl_schema_field("integer"),
  generation = psl_schema_field(
    "integer",
    check = \(v) v >= 1L,
    message = "must be a positive generation number"
  ),
  checksum = psl_schema_field(
    "character",
    check = psl_valid_sha256_ref,
    message = "must be a \"sha256:<hex>\" identity"
  ),
  request_url = psl_schema_field("character", optional = TRUE),
  selected_at = psl_schema_field(
    "character",
    optional = TRUE,
    check = psl_valid_rfc3339,
    message = "must be a UTC RFC 3339 timestamp"
  )
)

# Construct a validated cache-selection generation. The highest valid
# generation names the snapshot `psl_use("cache")` resolves to; `request_url`
# records which source's refresh made that choice, and is `NA` for a selection
# derived from a legacy cache with no recorded source.
new_psl_selection <- function(
  checksum,
  generation = 1L,
  ...,
  request_url = NA_character_,
  selected_at = NA
) {
  psl_check_empty_dots(...)
  record <- list(
    schema_version = psl_selection_schema_version,
    generation = psl_as_count(generation),
    checksum = psl_checksum_id(checksum),
    request_url = request_url,
    selected_at = psl_as_rfc3339(selected_at)
  )
  validate_psl_selection(record)
  record
}

validate_psl_selection <- function(x) {
  psl_validate_record(
    x,
    psl_selection_fields,
    psl_selection_schema_version,
    "cache-selection generation"
  )
}

# ---------------------------------------------------------------------------
# Reminder-preference generation
# ---------------------------------------------------------------------------

psl_reminder_schema_version <- 1L

# Default reminder interval in whole days.
psl_reminder_default_interval <- 7L

psl_reminder_fields <- list(
  schema_version = psl_schema_field("integer"),
  generation = psl_schema_field(
    "integer",
    check = \(v) v >= 1L,
    message = "must be a positive generation number"
  ),
  enabled = psl_schema_field("logical"),
  interval = psl_schema_field(
    "integer",
    check = \(v) v >= 1L,
    message = "must be a whole number of days of at least one"
  )
)

# Construct a validated reminder-preference generation. This record is config,
# not cache: disabling retains the interval, so `enabled = FALSE` still carries
# a usable value for a later re-enable.
new_psl_reminder_pref <- function(
  enabled,
  interval = psl_reminder_default_interval,
  generation = 1L,
  ...
) {
  psl_check_empty_dots(...)
  record <- list(
    schema_version = psl_reminder_schema_version,
    generation = psl_as_count(generation),
    enabled = enabled,
    interval = psl_as_count(interval)
  )
  validate_psl_reminder_pref(record)
  record
}

validate_psl_reminder_pref <- function(x) {
  psl_validate_record(
    x,
    psl_reminder_fields,
    psl_reminder_schema_version,
    "reminder-preference generation"
  )
}
