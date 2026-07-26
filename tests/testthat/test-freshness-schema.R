test_that("sha256 hashing covers raw bytes and single strings alike", {
  # The canonical SHA-256 of "abc"; hashing the string must equal hashing its
  # bytes, so URL naming and byte identity share one implementation.
  abc <- "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  expect_identical(psl_sha256_bytes("abc"), abc)
  expect_identical(psl_sha256_bytes(charToRaw("abc")), abc)
})

test_that("sha256 hashing rejects non-byte inputs", {
  expect_error(psl_sha256_bytes(c("a", "b")), "single non-missing string")
  expect_error(psl_sha256_bytes(NA_character_), "single non-missing string")
  expect_error(psl_sha256_bytes(1L), "raw vector or a single string")
  expect_error(psl_sha256_file(c("a", "b")), "single non-missing file path")
})

test_that("file hashing matches the recorded source checksum", {
  path <- bundled_dat_path()
  expect_identical(
    paste0("sha256:", psl_sha256_file(path)),
    psl_source_checksum(path)
  )
})

test_that("checksum identity normalizes to lowercase sha256 form", {
  hex <- strrep("A", 64L)
  expect_identical(psl_checksum_id(hex), paste0("sha256:", strrep("a", 64L)))
  expect_identical(
    psl_checksum_id(paste0("SHA256:", hex)),
    paste0("sha256:", strrep("a", 64L))
  )
})

test_that("new checksum identities can never be md5", {
  expect_error(
    psl_checksum_id(paste0("md5:", strrep("a", 32L))),
    "must be SHA-256"
  )
  expect_error(psl_checksum_id(strrep("a", 32L)), "must be SHA-256")
  expect_error(psl_checksum_id("sha256:nothex"), "must be SHA-256")
  expect_error(psl_checksum_id(NA_character_), "single non-missing checksum")
})

test_that("the compatibility reader accepts legacy md5 and sha256 values", {
  expect_identical(
    psl_parse_checksum(paste0("md5:", strrep("A", 32L))),
    list(algorithm = "md5", hex = strrep("a", 32L))
  )
  expect_identical(
    psl_parse_checksum(paste0("sha256:", strrep("b", 64L))),
    list(algorithm = "sha256", hex = strrep("b", 64L))
  )
})

test_that("the compatibility reader returns NULL for unreadable values", {
  expect_null(psl_parse_checksum("sha1:abc"))
  expect_null(psl_parse_checksum(paste0("md5:", strrep("a", 31L))))
  expect_null(psl_parse_checksum(strrep("a", 64L)))
  expect_null(psl_parse_checksum(NA_character_))
})

test_that("source stream names hash the url and never contain url text", {
  url <- "https://publicsuffix.org/list/public_suffix_list.dat"
  name <- psl_source_stream_name(url)
  expect_identical(name, paste0("sha256-", psl_sha256_bytes(url)))
  expect_no_match(name, "publicsuffix", fixed = TRUE)
  expect_false(identical(name, psl_source_stream_name(paste0(url, "x"))))
})

test_that("source stream naming rejects an unusable url", {
  expect_error(psl_source_stream_name(""), "single non-empty string")
  expect_error(psl_source_stream_name(NA_character_), "single non-empty string")
})

test_that("times serialize to UTC RFC 3339 with seconds precision", {
  moment <- as.POSIXct("2026-01-02 03:04:05", tz = "America/New_York")
  expect_identical(psl_format_time(moment), "2026-01-02T08:04:05Z")
  expect_identical(psl_format_time(as.POSIXct(NA)), NA_character_)
})

test_that("persisted times round-trip through parsing", {
  stamp <- "2026-07-26T12:34:56Z"
  parsed <- psl_parse_time(stamp)
  expect_s3_class(parsed, "POSIXct")
  expect_identical(attr(parsed, "tzone"), "UTC")
  expect_identical(psl_format_time(parsed), stamp)
})

test_that("time serialization rejects non-time inputs", {
  expect_error(psl_format_time("2026-07-26T12:34:56Z"), "must be a POSIXct")
  expect_error(psl_format_time(Sys.time() + c(0, 1)), "single time")
  expect_error(psl_parse_time(Sys.time()), "character timestamp")
})

test_that("timestamp validation rejects malformed and impossible times", {
  expect_true(psl_valid_rfc3339("2026-07-26T12:34:56Z"))
  # Right shape, impossible calendar date.
  expect_false(psl_valid_rfc3339("2026-06-31T00:00:00Z"))
  expect_false(psl_valid_rfc3339("2026-07-26 12:34:56"))
  expect_false(psl_valid_rfc3339("2026-07-26T12:34:56+02:00"))
  expect_false(psl_valid_rfc3339(NA_character_))
  expect_false(psl_valid_rfc3339(c("2026-07-26T12:34:56Z", "x")))
})

# --- snapshot descriptor ---------------------------------------------------

test_that("a snapshot descriptor round-trips through its validator", {
  record <- new_psl_snapshot_descriptor(
    checksum = strrep("a", 64L),
    size = 1024,
    storage = "cache",
    path = "snapshots/sha256-a.dat",
    content_date = as.POSIXct("2026-07-01 00:00:00", tz = "UTC"),
    commit = "0123456789abcdef",
    origin_url = "https://example.org/list.dat",
    first_retrieved_at = "2026-07-26T12:34:56Z"
  )
  expect_identical(record$schema_version, psl_snapshot_schema_version)
  expect_identical(record$checksum, paste0("sha256:", strrep("a", 64L)))
  expect_identical(record$size, 1024L)
  expect_identical(record$content_date, "2026-07-01T00:00:00Z")
  expect_named(record, names(psl_snapshot_fields))
  expect_identical(validate_psl_snapshot_descriptor(record), record)
})

test_that("a snapshot descriptor defaults unknown provenance to typed NA", {
  record <- new_psl_snapshot_descriptor(
    checksum = strrep("a", 64L),
    size = 0L,
    storage = "bundled",
    path = "extdata/psl.dat"
  )
  expect_identical(record$commit, NA_character_)
  expect_identical(record$origin_url, NA_character_)
  expect_identical(record$content_date, NA_character_)
  expect_identical(record$first_retrieved_at, NA_character_)
  expect_identical(record$validation_schema, psl_validation_schema_id)
})

test_that("a snapshot descriptor rejects malformed scalar fields", {
  ok <- new_psl_snapshot_descriptor(
    checksum = strrep("a", 64L),
    size = 10L,
    storage = "cache",
    path = "snapshots/sha256-a.dat"
  )
  bad_storage <- ok
  bad_storage$storage <- "elsewhere"
  expect_error(
    validate_psl_snapshot_descriptor(bad_storage),
    "`storage` must be one of"
  )
  bad_size <- ok
  bad_size$size <- -1L
  expect_error(
    validate_psl_snapshot_descriptor(bad_size),
    "`size` must not be negative"
  )
  bad_checksum <- ok
  bad_checksum$checksum <- paste0("md5:", strrep("a", 32L))
  expect_error(
    validate_psl_snapshot_descriptor(bad_checksum),
    "`checksum` must be a \"sha256:<hex>\" identity"
  )
  bad_path <- ok
  bad_path$path <- c("a", "b")
  expect_error(
    validate_psl_snapshot_descriptor(bad_path),
    "`path` must be a single value"
  )
  bad_date <- ok
  bad_date$content_date <- "yesterday"
  expect_error(
    validate_psl_snapshot_descriptor(bad_date),
    "`content_date` must be a UTC RFC 3339 timestamp"
  )
})

test_that("a snapshot descriptor rejects missing and unknown fields", {
  ok <- new_psl_snapshot_descriptor(
    checksum = strrep("a", 64L),
    size = 10L,
    storage = "cache",
    path = "snapshots/sha256-a.dat"
  )
  short <- ok[setdiff(names(ok), "parser")]
  expect_error(
    validate_psl_snapshot_descriptor(short),
    "missing field\\(s\\): parser"
  )
  extra <- c(ok, list(etag = "\"x\""))
  expect_error(
    validate_psl_snapshot_descriptor(extra),
    "unknown field\\(s\\): etag"
  )
  expect_error(validate_psl_snapshot_descriptor("nope"), "must be a named list")
})

test_that("an unknown snapshot schema version is rejected deterministically", {
  ok <- new_psl_snapshot_descriptor(
    checksum = strrep("a", 64L),
    size = 10L,
    storage = "cache",
    path = "snapshots/sha256-a.dat"
  )
  future <- ok
  future$schema_version <- psl_snapshot_schema_version + 1L
  expect_error(
    validate_psl_snapshot_descriptor(future),
    "Unsupported snapshot descriptor schema version"
  )
  absent <- ok[setdiff(names(ok), "schema_version")]
  expect_error(
    validate_psl_snapshot_descriptor(absent),
    "Unsupported snapshot descriptor schema version"
  )
})

test_that("snapshot construction guards misspelled optional arguments", {
  expect_error(
    new_psl_snapshot_descriptor(
      checksum = strrep("a", 64L),
      size = 10L,
      storage = "cache",
      path = "snapshots/sha256-a.dat",
      comit = "abc"
    ),
    "Unexpected argument\\(s\\): comit"
  )
})

# --- source state ----------------------------------------------------------

test_that("a source-state generation round-trips through its validator", {
  record <- new_psl_source_state(
    request_url = "https://publicsuffix.org/list/public_suffix_list.dat",
    generation = 2,
    effective_url = "https://publicsuffix.org/list/public_suffix_list.dat",
    validator_url = "https://publicsuffix.org/list/public_suffix_list.dat",
    checksum = strrep("c", 64L),
    etag = "W/\"abc\"",
    last_modified = "Sat, 25 Jul 2026 10:00:00 GMT",
    retrieved_at = "2026-07-25T10:00:00Z",
    checked_at = as.POSIXct("2026-07-26 10:00:00", tz = "UTC"),
    next_check_at = "2026-07-27T10:00:00Z",
    last_attempt_at = "2026-07-26T10:00:00Z",
    last_result = "not_modified"
  )
  expect_identical(record$schema_version, psl_source_state_schema_version)
  expect_identical(record$generation, 2L)
  expect_identical(record$checksum, paste0("sha256:", strrep("c", 64L)))
  expect_identical(record$checked_at, "2026-07-26T10:00:00Z")
  expect_named(record, names(psl_source_state_fields))
  expect_identical(validate_psl_source_state(record), record)
})

test_that("a never-checked source state carries NA freshness timestamps", {
  record <- new_psl_source_state(request_url = "https://example.org/list.dat")
  expect_identical(record$generation, 1L)
  expect_identical(record$checked_at, NA_character_)
  expect_identical(record$retrieved_at, NA_character_)
  expect_identical(record$checksum, NA_character_)
  expect_identical(record$last_result, NA_character_)
})

test_that("a source-state generation rejects malformed scalar fields", {
  ok <- new_psl_source_state(request_url = "https://example.org/list.dat")
  bad_generation <- ok
  bad_generation$generation <- 0L
  expect_error(
    validate_psl_source_state(bad_generation),
    "`generation` must be a positive generation number"
  )
  bad_url <- ok
  bad_url$request_url <- NA_character_
  expect_error(
    validate_psl_source_state(bad_url),
    "`request_url` must not be NA"
  )
  empty_url <- ok
  empty_url$request_url <- ""
  expect_error(
    validate_psl_source_state(empty_url),
    "`request_url` must not be an empty string"
  )
  bad_result <- ok
  bad_result$last_result <- "sort_of_worked"
  expect_error(
    validate_psl_source_state(bad_result),
    "`last_result` must be one of"
  )
  bad_checked <- ok
  bad_checked$checked_at <- "26/07/2026"
  expect_error(
    validate_psl_source_state(bad_checked),
    "`checked_at` must be a UTC RFC 3339 timestamp"
  )
})

test_that("an unknown source-state schema version is rejected", {
  future <- new_psl_source_state(request_url = "https://example.org/list.dat")
  future$schema_version <- psl_source_state_schema_version + 1L
  expect_error(
    validate_psl_source_state(future),
    "Unsupported source-state generation schema version"
  )
})

test_that("source-state construction guards misspelled optional arguments", {
  expect_error(
    new_psl_source_state(
      request_url = "https://example.org/list.dat",
      etagg = "\"x\""
    ),
    "Unexpected argument\\(s\\): etagg"
  )
})

# --- cache selection -------------------------------------------------------

test_that("a cache-selection generation round-trips through its validator", {
  record <- new_psl_selection(
    checksum = strrep("d", 64L),
    generation = 3L,
    request_url = "https://example.org/list.dat",
    selected_at = "2026-07-26T10:00:00Z"
  )
  expect_identical(record$schema_version, psl_selection_schema_version)
  expect_identical(record$checksum, paste0("sha256:", strrep("d", 64L)))
  expect_identical(record$generation, 3L)
  expect_named(record, names(psl_selection_fields))
  expect_identical(validate_psl_selection(record), record)
})

test_that("a cache selection may have no recorded source url", {
  record <- new_psl_selection(checksum = strrep("d", 64L))
  expect_identical(record$request_url, NA_character_)
  expect_identical(record$selected_at, NA_character_)
})

test_that("a cache-selection generation rejects malformed fields", {
  ok <- new_psl_selection(checksum = strrep("d", 64L))
  bad_checksum <- ok
  bad_checksum$checksum <- NA_character_
  expect_error(
    validate_psl_selection(bad_checksum),
    "`checksum` must not be NA"
  )
  bad_generation <- ok
  bad_generation$generation <- 1.5
  expect_error(
    validate_psl_selection(bad_generation),
    "`generation` must be a single integer value"
  )
  expect_error(
    new_psl_selection(checksum = paste0("md5:", strrep("a", 32L))),
    "must be SHA-256"
  )
})

test_that("an unknown cache-selection schema version is rejected", {
  future <- new_psl_selection(checksum = strrep("d", 64L))
  future$schema_version <- psl_selection_schema_version + 1L
  expect_error(
    validate_psl_selection(future),
    "Unsupported cache-selection generation schema version"
  )
})

# --- reminder preference ---------------------------------------------------

test_that("a reminder preference round-trips through its validator", {
  record <- new_psl_reminder_pref(enabled = TRUE, interval = 14, generation = 2)
  expect_identical(record$schema_version, psl_reminder_schema_version)
  expect_true(record$enabled)
  expect_identical(record$interval, 14L)
  expect_identical(record$generation, 2L)
  expect_named(record, names(psl_reminder_fields))
  expect_identical(validate_psl_reminder_pref(record), record)
})

test_that("a reminder preference defaults to a weekly interval", {
  record <- new_psl_reminder_pref(enabled = FALSE)
  expect_false(record$enabled)
  expect_identical(record$interval, psl_reminder_default_interval)
  expect_identical(record$interval, 7L)
  expect_identical(record$generation, 1L)
})

test_that("a reminder preference rejects malformed fields", {
  expect_error(
    new_psl_reminder_pref(enabled = NA),
    "`enabled` must not be NA"
  )
  expect_error(
    new_psl_reminder_pref(enabled = TRUE, interval = 0L),
    "`interval` must be a whole number of days of at least one"
  )
  expect_error(
    new_psl_reminder_pref(enabled = TRUE, interval = 2.5),
    "`interval` must be a single integer value"
  )
  expect_error(
    new_psl_reminder_pref(enabled = "yes"),
    "`enabled` must be a single logical value"
  )
})

test_that("an unknown reminder schema version is rejected", {
  future <- new_psl_reminder_pref(enabled = TRUE)
  future$schema_version <- psl_reminder_schema_version + 1L
  expect_error(
    validate_psl_reminder_pref(future),
    "Unsupported reminder-preference generation schema version"
  )
})

test_that("reminder construction guards misspelled optional arguments", {
  expect_error(
    new_psl_reminder_pref(enabled = TRUE, evry = 7L),
    "Unexpected argument\\(s\\): evry"
  )
})
