# psl_refresh() on the v2 freshness path: source locking, the conditional HTTP
# protocol, generation publication, cache selection, and optional activation
# (freshness v2, "Acceptance scenarios").
#
# Every test here is fully offline and clock-injected: the transport is a
# scripted double installed through `pslr.transport`, and `now` comes from the
# `pslr.clock` seam whenever a timestamp matters. Nothing opens a socket.

refresh_url <- "https://psl.example/list.dat"
other_url <- "https://other.example/list.dat"

# Freeze the clock every persisted timestamp derives from.
local_clock <- function(stamp = "2026-07-01T00:00:00Z", .env = parent.frame()) {
  instant <- psl_parse_time(stamp)
  withr::local_options(
    pslr.clock = function() instant,
    .local_envir = .env
  )
  instant
}

# The current source-state record for a request URL.
source_state <- function(url = refresh_url) psl_read_source_state(url)$record

selected_checksum <- function() psl_read_selection()$record$checksum

# ---------------------------------------------------------------------------
# First refresh, publication, and selection
# ---------------------------------------------------------------------------

test_that("a first refresh from an unseeded cache makes one plain GET", {
  local_pslr_clean()
  local_clock()
  transport <- local_fake_transport(list(list(path = write_test_list())))

  result <- psl_refresh(refresh_url)

  expect_s3_class(result, "psl_refresh_result")
  expect_identical(result$outcome, "updated")
  expect_identical(result$http_status, 200L)
  expect_identical(result$validator, "none")
  expect_identical(result$request_url, refresh_url)
  expect_identical(result$previous_checksum, NA_character_)
  expect_false(result$activated)
  expect_identical(request_count(transport), 1L)
  # No validator can exist yet, so the request carries no conditional header.
  expect_length(request_headers(transport), 0L)
})

test_that("a successful refresh publishes bytes, state, and a selection", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(list(path = write_test_list())))

  result <- psl_refresh(refresh_url)

  expect_identical(psl_snapshot_integrity(result$checksum, TRUE), "ok")
  expect_identical(result$snapshot$checksum, result$checksum)
  expect_identical(selected_checksum(), result$checksum)
  state <- source_state()
  expect_identical(state$checksum, result$checksum)
  expect_identical(state$checked_at, "2026-07-01T00:00:00Z")
  expect_identical(state$retrieved_at, "2026-07-01T00:00:00Z")
  expect_identical(state$last_result, "updated")
  # The courtesy floor is 24 hours from the confirmation time.
  expect_identical(state$next_check_at, "2026-07-02T00:00:00Z")
})

test_that("psl_refresh returns its result invisibly", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(list(path = write_test_list())))

  visible <- withVisible(psl_refresh(refresh_url))
  expect_false(visible$visible)
  expect_s3_class(visible$value, "psl_refresh_result")
})

# ---------------------------------------------------------------------------
# Courtesy skip
# ---------------------------------------------------------------------------

test_that("a check inside the courtesy window makes zero requests", {
  local_pslr_clean()
  local_clock()
  transport <- local_fake_transport(list(list(path = write_test_list())))
  first <- psl_refresh(refresh_url)

  skipped <- psl_refresh(refresh_url)

  expect_identical(skipped$outcome, "skipped_recently")
  expect_identical(request_count(transport), 1L)
  # A local skip made no request, and keeps the confirmation that justified it.
  expect_identical(skipped$http_status, NA_integer_)
  expect_identical(skipped$bytes_downloaded, NA_integer_)
  expect_identical(skipped$checked_at, first$checked_at)
  expect_identical(skipped$checksum, first$checksum)
})

test_that("a skip appends a selection without changing source state", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(list(path = write_test_list())))
  psl_refresh(refresh_url)
  generation <- psl_read_source_state(refresh_url)$generation

  psl_refresh(refresh_url)

  # The skip observed nothing, so no source-state generation is due...
  expect_identical(psl_read_source_state(refresh_url)$generation, generation)
  # ...but the refreshed source is still the cache choice.
  expect_identical(psl_read_selection()$generation, 2L)
  expect_identical(selected_checksum(), source_state()$checksum)
})

test_that("a skip activates when asked to", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(list(path = write_test_list())))
  psl_refresh(refresh_url)
  psl_use("bundled")

  skipped <- psl_refresh(refresh_url, activate = TRUE)

  expect_identical(skipped$outcome, "skipped_recently")
  expect_true(skipped$activated)
  expect_identical(psl_version()$source, "cache")
  expect_identical(psl_version()$checksum, skipped$checksum)
})

test_that("force bypasses the courtesy window and still sends a validator", {
  local_pslr_clean()
  local_clock()
  transport <- local_fake_transport(list(
    list(headers = c(ETag = "\"v1\""), path = write_test_list()),
    list(status = 304L)
  ))
  psl_refresh(refresh_url)

  forced <- psl_refresh(refresh_url, force = TRUE)

  expect_identical(forced$outcome, "not_modified")
  expect_identical(request_count(transport), 2L)
  expect_identical(
    unname(request_headers(transport, 2L)[["if-none-match"]]),
    "\"v1\""
  )
})

# ---------------------------------------------------------------------------
# Conditional revalidation
# ---------------------------------------------------------------------------

test_that("a stored ETag that still matches yields not_modified", {
  local_pslr_clean()
  instant <- local_clock()
  transport <- local_fake_transport(list(
    list(headers = c(ETag = "W/\"weak\""), path = write_test_list()),
    list(status = 304L)
  ))
  first <- psl_refresh(refresh_url)

  # A day later the window has elapsed, so an ordinary check goes out.
  withr::local_options(
    pslr.clock = function() instant + as.difftime(25, units = "hours")
  )
  again <- psl_refresh(refresh_url)

  expect_identical(again$outcome, "not_modified")
  expect_identical(again$http_status, 304L)
  expect_identical(again$validator, "etag")
  expect_identical(request_count(transport), 2L)
  # A weak ETag is preserved and sent byte for byte.
  expect_identical(
    unname(request_headers(transport, 2L)[["if-none-match"]]),
    "W/\"weak\""
  )
  # The checksum and acquisition time stand; only the confirmation advances.
  expect_identical(again$checksum, first$checksum)
  state <- source_state()
  expect_identical(state$retrieved_at, "2026-07-01T00:00:00Z")
  expect_identical(state$checked_at, "2026-07-02T01:00:00Z")
})

test_that("Last-Modified is used when no ETag exists", {
  local_pslr_clean()
  local_clock()
  stamp <- "Wed, 01 Jul 2026 00:00:00 GMT"
  transport <- local_fake_transport(list(
    list(headers = c(`Last-Modified` = stamp), path = write_test_list()),
    list(status = 304L)
  ))
  psl_refresh(refresh_url)

  again <- psl_refresh(refresh_url, force = TRUE)

  expect_identical(again$outcome, "not_modified")
  expect_identical(again$validator, "last_modified")
  sent <- request_headers(transport, 2L)
  expect_identical(unname(sent[["if-modified-since"]]), stamp)
  expect_false("if-none-match" %in% names(sent))
})

test_that("a rotated validator with identical bytes is downloaded_unchanged", {
  local_pslr_clean()
  local_clock()
  body <- write_test_list()
  local_fake_transport(list(
    list(headers = c(ETag = "\"v1\""), path = body),
    list(headers = c(ETag = "\"v2\""), path = body)
  ))
  first <- psl_refresh(refresh_url)

  again <- psl_refresh(refresh_url, force = TRUE)

  expect_identical(again$outcome, "downloaded_unchanged")
  expect_identical(again$http_status, 200L)
  expect_identical(again$checksum, first$checksum)
  expect_identical(again$previous_checksum, first$checksum)
  # No new snapshot was created, and the rotated validator was stored.
  expect_length(
    list.files(psl_snapshot_dir(), pattern = "\\.dat$"),
    1L
  )
  expect_identical(source_state()$etag, "\"v2\"")
})

# ---------------------------------------------------------------------------
# Changed content and activation
# ---------------------------------------------------------------------------

test_that("changed content with activate = FALSE leaves the engine alone", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("nowhere.example"))
  ))
  first <- psl_refresh(refresh_url)
  psl_use("bundled")
  before <- psl_version()

  updated <- psl_refresh(refresh_url, force = TRUE)

  expect_identical(updated$outcome, "updated")
  expect_false(identical(updated$checksum, first$checksum))
  expect_identical(updated$previous_checksum, first$checksum)
  expect_false(updated$activated)
  expect_identical(psl_version(), before)
  # The new snapshot is nonetheless the cache choice.
  expect_identical(selected_checksum(), updated$checksum)
})

test_that("changed content with activate = TRUE activates the new snapshot", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("nowhere.example"))
  ))
  psl_refresh(refresh_url, activate = TRUE)
  expect_identical(public_suffix("a.nowhere.example"), "example")

  updated <- psl_refresh(refresh_url, activate = TRUE, force = TRUE)

  expect_true(updated$activated)
  expect_identical(psl_version()$checksum, updated$checksum)
  expect_identical(public_suffix("a.nowhere.example"), "nowhere.example")
})

test_that("named force and activate both take effect in one call", {
  local_pslr_clean()
  local_clock()
  transport <- local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("nowhere.example"))
  ))
  first <- psl_refresh(refresh_url)
  expect_false(first$activated)

  # Same courtesy window, so only `force = TRUE` makes the second request, and
  # only `activate = TRUE` makes its snapshot the session's list.
  updated <- psl_refresh(refresh_url, force = TRUE, activate = TRUE)

  expect_identical(request_count(transport), 2L)
  expect_identical(updated$outcome, "updated")
  expect_true(updated$activated)
  expect_identical(psl_version()$checksum, updated$checksum)
})

test_that("both published snapshots survive an update", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("nowhere.example"))
  ))
  first <- psl_refresh(refresh_url)
  updated <- psl_refresh(refresh_url, force = TRUE)

  # Each distinct validated download is preserved until explicit pruning.
  expect_identical(psl_snapshot_integrity(first$checksum, TRUE), "ok")
  expect_identical(psl_snapshot_integrity(updated$checksum, TRUE), "ok")
})

test_that("exact same-section duplicates warn once and are deduplicated", {
  local_pslr_clean()
  local_clock()
  dup <- write_test_list(c("com", "duplicate.example"))
  local_fake_transport(list(list(path = dup)))

  expect_warning(psl_refresh(refresh_url, activate = TRUE), "duplicate")
  expect_identical(
    anyDuplicated(paste(psl_rules()$section, psl_rules()$canonical_rule)),
    0L
  )
})

# ---------------------------------------------------------------------------
# Repair
# ---------------------------------------------------------------------------

test_that("a 304 over corrupt local bytes triggers one repair download", {
  local_pslr_clean()
  local_clock()
  body <- write_test_list()
  transport <- local_fake_transport(list(
    list(headers = c(ETag = "\"v1\""), path = body),
    list(status = 304L),
    list(path = body)
  ))
  first <- psl_refresh(refresh_url)
  writeLines("corrupted", psl_snapshot_bytes_path(first$checksum))

  repaired <- psl_refresh(refresh_url, activate = TRUE, force = TRUE)

  # Exactly one conditional request plus exactly one unconditional repair.
  expect_identical(request_count(transport), 3L)
  expect_length(request_headers(transport, 3L), 0L)
  expect_identical(repaired$outcome, "downloaded_unchanged")
  expect_identical(repaired$checksum, first$checksum)
  # The corrupt bytes were replaced, not activated.
  expect_identical(psl_snapshot_integrity(first$checksum, TRUE), "ok")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})

# ---------------------------------------------------------------------------
# Failures
# ---------------------------------------------------------------------------

test_that("an unreachable server leaves queries and state byte-identical", {
  local_pslr_clean()
  instant <- local_clock()
  local_fake_transport(list(list(path = write_test_list())))
  first <- psl_refresh(refresh_url, activate = TRUE)
  before <- psl_version()
  answers <- public_suffix(c("www.example.co.uk", "a.example.com"))

  withr::local_options(
    pslr.clock = function() instant + as.difftime(25, units = "hours"),
    pslr.transport = function(request) {
      stop(psl_refresh_transport_error("down", reason = "connect"))
    }
  )
  failure <- tryCatch(psl_refresh(refresh_url), error = \(e) e)

  expect_s3_class(failure, "pslr_refresh_transport_error")
  expect_s3_class(failure, "pslr_refresh_error")
  expect_identical(psl_version(), before)
  hosts <- c("www.example.co.uk", "a.example.com")
  expect_identical(public_suffix(hosts), answers)
  # No freshness field and no selection moved; only the attempt was recorded.
  state <- source_state()
  expect_identical(state$checked_at, first$checked_at)
  expect_identical(state$retrieved_at, "2026-07-01T00:00:00Z")
  expect_identical(state$checksum, first$checksum)
  expect_identical(state$last_result, "transport_error")
  expect_identical(state$last_attempt_at, "2026-07-02T01:00:00Z")
  expect_identical(selected_checksum(), first$checksum)
})

test_that("an HTTP error status is a classed failure with its status", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(list(
    status = 503L,
    headers = c(
      `Retry-After` = "120"
    )
  )))

  failure <- tryCatch(psl_refresh(refresh_url), error = \(e) e)

  expect_s3_class(failure, "pslr_refresh_http_status_error")
  expect_identical(failure$status, 503L)
  expect_identical(failure$retry_after, 120L)
  expect_identical(psl_read_selection()$status, "empty")
  expect_identical(source_state()$last_result, "http_status_error")
})

test_that("an oversized response is refused before publication", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(list(path = write_test_list())))
  withr::local_options(pslr.max_bytes = 8L)

  failure <- tryCatch(psl_refresh(refresh_url), error = \(e) e)

  expect_s3_class(failure, "pslr_refresh_response_limit_error")
  expect_identical(psl_read_selection()$status, "empty")
  expect_length(list.files(psl_snapshot_dir(), pattern = "\\.dat$"), 0L)
})

test_that("an invalid downloaded list is refused before publication", {
  local_pslr_clean()
  local_clock()
  bad <- tempfile(fileext = ".dat")
  writeLines(c("// ===BEGIN ICANN DOMAINS===", "com"), bad) # never closed
  local_fake_transport(list(list(path = bad)))

  failure <- tryCatch(psl_refresh(refresh_url), error = \(e) e)

  expect_s3_class(failure, "pslr_refresh_validation_error")
  expect_identical(psl_read_selection()$status, "empty")
  expect_length(list.files(psl_snapshot_dir(), pattern = "\\.dat$"), 0L)
})

test_that("a failed refresh leaves an existing cache selection intact", {
  local_pslr_clean()
  local_clock()
  local_fake_transport(list(
    list(path = write_test_list()),
    list(status = 500L)
  ))
  first <- psl_refresh(refresh_url)

  expect_error(psl_refresh(refresh_url, force = TRUE))

  expect_identical(selected_checksum(), first$checksum)
  expect_identical(psl_snapshot_integrity(first$checksum, TRUE), "ok")
  expect_identical(psl_use("cache")$checksum, first$checksum)
})

test_that("a busy same-source lock makes no request", {
  local_pslr_clean()
  local_clock()
  transport <- local_fake_transport(list(list(path = write_test_list())))
  # Another process holds the source lock: acquisition never succeeds and the
  # bounded wait expires immediately.
  withr::local_options(
    pslr.lock_try_create = function(path) FALSE,
    pslr.lock_timeout = 0
  )

  failure <- tryCatch(psl_refresh(refresh_url), error = \(e) e)

  expect_s3_class(failure, "pslr_refresh_busy")
  expect_s3_class(failure, "pslr_refresh_error")
  expect_identical(request_count(transport), 0L)
})

# ---------------------------------------------------------------------------
# Source isolation and migration
# ---------------------------------------------------------------------------

test_that("each source keeps its own validators and courtesy window", {
  local_pslr_clean()
  local_clock()
  transport <- local_fake_transport(list(
    list(headers = c(ETag = "\"first\""), path = write_test_list()),
    list(headers = c(ETag = "\"second\""), path = write_test_list("b.example"))
  ))
  first <- psl_refresh(refresh_url)

  # A different source is inside no window of its own, so it checks and, having
  # no validator of its own, sends none.
  second <- psl_refresh(other_url)

  expect_identical(second$outcome, "updated")
  expect_length(request_headers(transport, 2L), 0L)
  expect_identical(source_state(refresh_url)$etag, "\"first\"")
  expect_identical(source_state(other_url)$etag, "\"second\"")
  expect_false(identical(first$checksum, second$checksum))
  # The most recently refreshed source is the cache choice.
  expect_identical(selected_checksum(), second$checksum)
})

test_that("the first refresh migrates a legacy v1 cache", {
  dir <- local_pslr_clean()
  local_clock()
  seed_legacy_cache(dir)
  legacy <- psl_source_checksum(bundled_dat_path())
  local_fake_transport(list(list(path = write_test_list())))

  result <- psl_refresh(refresh_url)

  # The legacy snapshot was imported and its files left untouched...
  expect_identical(psl_snapshot_integrity(legacy, TRUE), "ok")
  expect_true(file.exists(file.path(dir, "current.rds")))
  # ...and the refreshed source is now the selection.
  expect_identical(selected_checksum(), result$checksum)
})

test_that("a refresh of the legacy source revalidates the migrated snapshot", {
  dir <- local_pslr_clean()
  local_clock()
  seed_legacy_cache(dir)
  legacy <- psl_source_checksum(bundled_dat_path())
  transport <- local_fake_transport(list(
    list(path = bundled_dat_path())
  ))

  # Migration carries no validator and no `checked_at`, so the first v2 refresh
  # of the legacy source is unconditional and cannot produce a false 304.
  result <- psl_refresh()

  expect_identical(request_count(transport), 1L)
  expect_length(request_headers(transport), 0L)
  expect_identical(result$outcome, "downloaded_unchanged")
  expect_identical(result$checksum, legacy)
})
