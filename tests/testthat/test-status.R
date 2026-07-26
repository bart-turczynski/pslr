# `psl_status()` is pure inspection: every test here runs offline, against a
# private cache directory, with an injected clock. Nothing in this file makes a
# request, and the state machine is driven by publishing records directly.

status_now <- as.POSIXct("2026-07-20 12:00:00", tz = "UTC")

# Publish snapshot bytes and return their checksum identity. The bytes are
# opaque here -- status never parses a list -- unless a test activates them.
publish_status_bytes <- function(text = "// psl bytes\n", ...) {
  path <- tempfile("pslr-status-", fileext = ".dat")
  con <- file(path, open = "wb")
  writeBin(charToRaw(text), con)
  close(con)
  psl_with_publish_lock(psl_publish_snapshot(path, ...))$checksum
}

publish_status_source <- function(checksum, ..., url = psl_official_url) {
  psl_with_publish_lock(
    psl_publish_source_state(url, checksum = checksum, ...)
  )
}

publish_status_selection <- function(checksum, url = psl_official_url) {
  psl_with_publish_lock(psl_publish_selection(checksum, request_url = url))
}

# Seed the ordinary healthy shape: one published snapshot, one source record
# confirming it `days` ago, and a selection naming it.
seed_confirmed_cache <- function(days = 1, text = "// psl bytes\n") {
  checksum <- publish_status_bytes(text)
  checked_at <- psl_format_time(status_now - days * 86400)
  publish_status_source(
    checksum,
    checked_at = checked_at,
    retrieved_at = checked_at,
    next_check_at = psl_format_time(psl_next_check_at(checked_at))
  )
  publish_status_selection(checksum)
  checksum
}

# Replace the newest generation of a stream with unreadable bytes.
corrupt_stream <- function(dir) {
  generations <- psl_generation_numbers(dir)
  target <- if (length(generations)) max(generations) else 1L
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  writeLines("not an rds file", file.path(dir, psl_generation_name(target)))
  invisible(dir)
}

status_lines <- function(x) paste(format(x), collapse = "\n")

test_that("the status row has the documented columns, types, and shape", {
  local_pslr_clean()
  status <- psl_status("bundled", now = status_now)
  expect_s3_class(status, "psl_status")
  expect_s3_class(status, "data.frame")
  expect_identical(nrow(status), 1L)
  expect_named(
    status,
    c(
      "state",
      "snapshot",
      "source_kind",
      "request_url",
      "checksum",
      "source_checksum",
      "content_date",
      "retrieved_at",
      "checked_at",
      "next_check_at",
      "snapshot_age_days",
      "check_age_days",
      "check_due",
      "message"
    )
  )
  expect_type(status$state, "character")
  expect_type(status$snapshot, "character")
  expect_type(status$source_kind, "character")
  expect_type(status$request_url, "character")
  expect_type(status$checksum, "character")
  expect_type(status$source_checksum, "character")
  expect_s3_class(status$content_date, "POSIXct")
  expect_s3_class(status$retrieved_at, "POSIXct")
  expect_s3_class(status$checked_at, "POSIXct")
  expect_s3_class(status$next_check_at, "POSIXct")
  expect_type(status$snapshot_age_days, "double")
  expect_type(status$check_age_days, "double")
  expect_type(status$check_due, "logical")
  expect_type(status$message, "character")
})

test_that("every snapshot selector returns the same one-row schema", {
  local_pslr_clean()
  seed_confirmed_cache()
  rows <- lapply(c("active", "cache", "bundled"), psl_status, now = status_now)
  expect_identical(vapply(rows, nrow, integer(1L)), c(1L, 1L, 1L))
  expect_identical(
    vapply(rows, \(row) row$snapshot, character(1L)),
    c("active", "cache", "bundled")
  )
  expect_named(rows[[2L]], names(rows[[1L]]))
  expect_named(rows[[3L]], names(rows[[1L]]))
})

test_that("an invalid snapshot selector is an error", {
  local_pslr_clean()
  expect_error(psl_status("everything"), "`snapshot` must be one of")
  expect_error(psl_status(c("cache", "bundled")), "`snapshot` must be one of")
  expect_error(psl_status(1L), "`snapshot` must be one of")
})

test_that("unexpected arguments and a bad clock are errors", {
  local_pslr_clean()
  expect_error(psl_status("bundled", nonsense = TRUE), "Unexpected argument")
  expect_error(psl_status("bundled", now = "2026-07-20"), "`now` must be")
  expect_error(psl_status("bundled", now = NA), "`now` must be")
})

test_that("a missing cache is a status, not an error", {
  local_pslr_clean()
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "missing")
  expect_identical(status$source_kind, "missing")
  expect_identical(status$checksum, NA_character_)
  expect_match(status$message, "psl_refresh")
  expect_match(status_lines(status), "No cached snapshot")
})

test_that("build provenance associates the bundled bytes with their source", {
  local_pslr_clean()
  status <- psl_status("bundled", now = status_now)
  # The association names a source but proves nothing about its current bytes,
  # so the strongest claim available is `never_checked`.
  expect_identical(status$state, "never_checked")
  expect_identical(status$source_kind, "bundled")
  expect_identical(status$request_url, psl_official_url)
  expect_identical(status$checksum, pslr_bundled$meta$checksum)
  expect_identical(status$source_checksum, NA_character_)
  expect_identical(status$checked_at, psl_as_time(NA))
  expect_false(is.na(status$content_date))
  printed <- status_lines(status)
  expect_match(printed, "Never checked against its source")
  expect_no_match(printed, "No remote source")
})

test_that("bundled metadata without a canonical url stays untracked", {
  local_pslr_clean()
  legacy <- pslr_bundled
  legacy$meta$canonical_url <- NULL
  local_mocked_bindings(pslr_bundled = legacy)
  status <- psl_status("bundled", now = status_now)
  expect_identical(status$state, "untracked")
  expect_identical(status$request_url, NA_character_)
  expect_match(status_lines(status), "No remote source")
})

test_that("a custom path snapshot is untracked", {
  local_pslr_clean()
  psl_use("path", path = write_test_list())
  status <- psl_status("active", now = status_now)
  expect_identical(status$state, "untracked")
  expect_identical(status$source_kind, "path")
  expect_identical(status$request_url, NA_character_)
})

test_that("a known source with no successful check is never_checked", {
  local_pslr_clean()
  checksum <- publish_status_bytes()
  publish_status_source(checksum, retrieved_at = "2026-07-01T00:00:00Z")
  publish_status_selection(checksum)
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "never_checked")
  expect_identical(status$source_kind, "cache")
  expect_identical(status$request_url, psl_official_url)
  expect_identical(status$checksum, checksum)
  expect_true(is.na(status$checked_at))
  expect_true(is.na(status$check_age_days))
  expect_match(status_lines(status), "Never checked")
})

test_that("a confirmed checksum inside the interval is confirmed_current", {
  local_pslr_clean()
  checksum <- seed_confirmed_cache(days = 2)
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "confirmed_current")
  expect_identical(status$source_checksum, checksum)
  expect_false(status$check_due)
  expect_equal(status$check_age_days, 2)
  expect_false(is.na(status$next_check_at))
  expect_identical(status$message, NA_character_)
  expect_match(status_lines(status), "Confirmed current")
})

test_that("an elapsed interval is check_due and never reads as an update", {
  local_pslr_clean()
  seed_confirmed_cache(days = 9)
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "check_due")
  expect_true(status$check_due)
  expect_equal(status$check_age_days, 9)
  printed <- status_lines(status)
  expect_match(printed, "Freshness check due")
  # The whole point of the redesign: age alone is never phrased as an update.
  expect_no_match(printed, "outdated", ignore.case = TRUE)
  expect_no_match(printed, "update available", ignore.case = TRUE)
  expect_identical(status$message, NA_character_)
})

test_that("check_due honours a retained reminder interval", {
  local_pslr_clean()
  psl_store_append(
    psl_reminder_stream_dir(),
    \(g) new_psl_reminder_pref(TRUE, interval = 30L, generation = g),
    validate_psl_reminder_pref
  )
  seed_confirmed_cache(days = 9)
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "confirmed_current")
  expect_false(status$check_due)
})

test_that("an observed different source checksum is update_available", {
  local_pslr_clean()
  selected <- publish_status_bytes("// selected bytes\n")
  newer <- publish_status_bytes("// newer bytes\n")
  publish_status_selection(selected)
  publish_status_source(
    newer,
    checked_at = psl_format_time(status_now - 3600)
  )
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "update_available")
  expect_identical(status$checksum, selected)
  expect_identical(status$source_checksum, newer)
  expect_false(status$check_due)
  printed <- status_lines(status)
  expect_match(printed, "A newer snapshot was downloaded")
  expect_no_match(printed, "outdated", ignore.case = TRUE)
})

test_that("the active engine reports its own cached snapshot", {
  local_pslr_clean()
  path <- write_test_list()
  checksum <- psl_source_checksum(path)
  checked_at <- psl_format_time(status_now - 86400)
  psl_with_publish_lock(psl_publish_snapshot(path, checksum = checksum))
  publish_status_source(checksum, checked_at = checked_at)
  publish_status_selection(checksum)
  psl_use("cache")
  status <- psl_status("active", now = status_now)
  expect_identical(status$state, "confirmed_current")
  expect_identical(status$source_kind, "cache")
  expect_identical(status$checksum, checksum)
  expect_identical(status$request_url, psl_official_url)
})

test_that("an active snapshot older than the source is update_available", {
  local_pslr_clean()
  path <- write_test_list()
  active_checksum <- psl_source_checksum(path)
  psl_with_publish_lock(
    psl_publish_snapshot(path, checksum = active_checksum)
  )
  publish_status_selection(active_checksum)
  psl_use("cache")
  newer <- publish_status_bytes("// newer bytes\n")
  publish_status_source(
    newer,
    checked_at = psl_format_time(status_now - 3600)
  )
  status <- psl_status("active", now = status_now)
  expect_identical(status$state, "update_available")
  expect_identical(status$source_checksum, newer)
  expect_match(status_lines(status), "is not active")
})

test_that("a corrupt selection record degrades to unknown, not an error", {
  local_pslr_clean()
  seed_confirmed_cache()
  corrupt_stream(psl_selection_stream_dir())
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "unknown")
  expect_match(status$message, "psl_refresh\\(force = TRUE\\)")
  expect_match(status_lines(status), "Freshness unknown")
})

test_that("a corrupt source record leaves the active engine inspectable", {
  local_pslr_clean()
  path <- write_test_list()
  checksum <- psl_source_checksum(path)
  psl_with_publish_lock(psl_publish_snapshot(path, checksum = checksum))
  publish_status_source(checksum, checked_at = psl_format_time(status_now))
  publish_status_selection(checksum)
  psl_use("cache")
  corrupt_stream(psl_source_stream_dir(psl_official_url))
  status <- psl_status("active", now = status_now)
  expect_identical(status$state, "unknown")
  expect_identical(status$source_kind, "cache")
  expect_identical(status$checksum, checksum)
  expect_match(status$message, "could not read")
  # The engine itself keeps working; inspection never took it away.
  expect_identical(public_suffix("a.co.uk"), "co.uk")
})

test_that("a selected snapshot whose bytes are gone is unknown", {
  local_pslr_clean()
  checksum <- seed_confirmed_cache()
  unlink(psl_snapshot_bytes_path(checksum))
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "unknown")
  expect_match(status$message, "not published")
})

test_that("tampered snapshot bytes are unknown rather than confirmed", {
  local_pslr_clean()
  checksum <- seed_confirmed_cache()
  writeLines("// tampered", psl_snapshot_bytes_path(checksum))
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "unknown")
  expect_match(status$message, "no longer match their checksum")
})

test_that("a backwards clock yields NA ages and unknown, not a claim", {
  local_pslr_clean()
  checksum <- publish_status_bytes()
  publish_status_source(
    checksum,
    checked_at = psl_format_time(status_now + 86400)
  )
  publish_status_selection(checksum)
  skewed <- psl_status("cache", now = status_now)
  expect_identical(skewed$state, "unknown")
  expect_true(is.na(skewed$check_age_days))
  expect_true(is.na(skewed$check_due))
  expect_match(skewed$message, "clock")
})

test_that("a future content date reports an unknown snapshot age", {
  local_pslr_clean()
  checksum <- publish_status_bytes(
    content_date = psl_format_time(status_now + 86400)
  )
  publish_status_selection(checksum)
  status <- psl_status("cache", now = status_now)
  expect_true(is.na(status$snapshot_age_days))
  expect_false(is.na(status$content_date))
})

test_that("an unmigrated v1 cache reports never_checked and is not rewritten", {
  cache <- local_pslr_clean()
  seed_legacy_cache(cache)
  marker <- psl_cache_marker()
  before <- file.mtime(marker)
  status <- psl_status("cache", now = status_now)
  expect_identical(status$state, "never_checked")
  expect_identical(status$source_kind, "cache")
  expect_identical(status$request_url, psl_legacy_request_url)
  expect_identical(file.mtime(marker), before)
  # Read-only: inspection published no v2 generation stream of its own.
  expect_false(dir.exists(psl_selection_stream_dir()))
  expect_false(dir.exists(file.path(cache, "sources")))
  expect_false(dir.exists(psl_snapshot_dir()))
})

test_that("inspection writes nothing to the cache directory", {
  cache <- local_pslr_clean()
  seed_confirmed_cache(days = 9)
  before <- sort(list.files(cache, recursive = TRUE))
  for (selector in c("active", "cache", "bundled")) {
    psl_status(selector, now = status_now)
  }
  expect_identical(sort(list.files(cache, recursive = TRUE)), before)
})

test_that("printing returns the row invisibly and shows the source", {
  local_pslr_clean()
  seed_confirmed_cache(days = 2)
  status <- psl_status("cache", now = status_now)
  printed <- paste(capture.output(result <- print(status)), collapse = "\n")
  expect_identical(result, status)
  expect_match(printed, "<psl_status: confirmed_current>")
  expect_match(printed, "source:", fixed = TRUE)
  expect_match(printed, psl_official_url, fixed = TRUE)
  expect_match(printed, "checked:", fixed = TRUE)
  expect_type(format(status), "character")
})
