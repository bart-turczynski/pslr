# The success object and the classed error family. No network, no clock
# dependence: every value here is constructed directly.

test_checksum <- function(char = "a") paste0("sha256:", strrep(char, 64L))

test_result <- function(...) {
  new_psl_refresh_result(
    outcome = "updated",
    request_url = "https://example.org/list.dat",
    checksum = test_checksum(),
    ...
  )
}

test_that("a refresh result carries the documented stable fields", {
  result <- test_result(
    effective_url = "https://cdn.example.org/list.dat",
    http_status = 200L,
    checked_at = "2026-01-02T03:04:05Z",
    previous_checksum = test_checksum("b"),
    activated = TRUE,
    validator = "etag",
    bytes_downloaded = 1234L
  )

  expect_s3_class(result, "psl_refresh_result")
  expect_named(
    result,
    c(
      "outcome",
      "request_url",
      "effective_url",
      "http_status",
      "checked_at",
      "previous_checksum",
      "checksum",
      "activated",
      "validator",
      "bytes_downloaded",
      "snapshot"
    )
  )
  expect_equal(result$http_status, 200L)
  expect_equal(result$bytes_downloaded, 1234L)
  expect_true(result$activated)
})

test_that("a local skip has no HTTP status but keeps its confirmation time", {
  result <- new_psl_refresh_result(
    outcome = "skipped_recently",
    request_url = "https://example.org/list.dat",
    checksum = test_checksum(),
    checked_at = "2026-01-02T03:04:05Z"
  )

  expect_equal(result$outcome, "skipped_recently")
  expect_equal(result$http_status, NA_integer_)
  expect_equal(result$checked_at, "2026-01-02T03:04:05Z")
  expect_equal(result$bytes_downloaded, NA_integer_)
  expect_equal(result$validator, "none")
  expect_false(result$activated)
})

test_that("a refresh result accepts a POSIXct confirmation time", {
  result <- test_result(
    checked_at = as.POSIXct("2026-01-02 03:04:05", tz = "UTC")
  )

  expect_equal(result$checked_at, "2026-01-02T03:04:05Z")
})

test_that("a refresh result normalizes a bare checksum digest", {
  result <- new_psl_refresh_result(
    outcome = "updated",
    request_url = "https://example.org/list.dat",
    checksum = strrep("A", 64L)
  )

  expect_equal(result$checksum, test_checksum())
})

test_that("a refresh result rejects values outside its contract", {
  expect_error(test_result(validator = "if-none-match"), "must be one of")
  expect_error(
    new_psl_refresh_result("nope", "https://example.org", test_checksum()),
    "must be one of"
  )
  expect_error(test_result(http_status = 42L), "HTTP status code")
  expect_error(test_result(bytes_downloaded = -1L), "must not be negative")
  expect_error(test_result(activated = NA), "must not be NA")
  expect_error(test_result(nonsense = 1), "Unexpected argument")
  expect_error(
    new_psl_refresh_result("updated", "https://example.org", "md5:abc"),
    "SHA-256"
  )
})

test_that("a refresh result validates its nested snapshot descriptor", {
  descriptor <- new_psl_snapshot_descriptor(
    checksum = test_checksum(),
    size = 10L,
    storage = "cache",
    path = "snapshots/sha256-aaa.dat"
  )
  result <- test_result(snapshot = descriptor)

  expect_equal(result$snapshot$checksum, test_checksum())
  expect_error(test_result(snapshot = list(bogus = TRUE)), "snapshot")
})

test_that("the refresh result validator rejects a malformed record", {
  result <- test_result()
  result$outcome <- NULL

  expect_error(validate_psl_refresh_result(result), "missing field")

  extra <- test_result()
  extra$body <- "leaked"
  expect_error(validate_psl_refresh_result(extra), "unknown field")
})

test_that("printing a refresh result is concise and names the outcome", {
  result <- test_result(
    http_status = 200L,
    previous_checksum = test_checksum("b"),
    activated = TRUE,
    validator = "etag",
    bytes_downloaded = 1234L,
    checked_at = "2026-01-02T03:04:05Z"
  )
  lines <- format(result)

  expect_length(lines, 5L)
  expect_match(lines[[1L]], "<psl_refresh_result: updated>")
  expect_match(lines[[2L]], "HTTP 200", fixed = TRUE)
  expect_match(lines[[3L]], "sha256:aaaaaaaaaaaa...", fixed = TRUE)
  expect_match(lines[[4L]], "etag; 1234 bytes; activated", fixed = TRUE)
  expect_match(lines[[5L]], "2026-01-02T03:04:05Z", fixed = TRUE)
  expect_output(print(result), "psl_refresh_result")
})

test_that("a skip prints without inventing a status or a body", {
  lines <- format(new_psl_refresh_result(
    outcome = "skipped_recently",
    request_url = "https://example.org/list.dat",
    checksum = test_checksum()
  ))

  expect_match(lines[[2L]], "no request", fixed = TRUE)
  expect_match(lines[[4L]], "none; no body; not activated", fixed = TRUE)
})

test_that("every refresh error family is rooted at pslr_refresh_error", {
  errors <- list(
    psl_refresh_url_policy_error("bad url"),
    psl_refresh_busy_error("busy", lock = "sha256-x", timeout = 10),
    psl_refresh_transport_error("boom", reason = "timeout"),
    psl_refresh_http_status_error(500L),
    psl_refresh_response_limit_error(100, 64),
    psl_refresh_validation_error("not a PSL"),
    psl_refresh_local_corruption_error("checksum mismatch"),
    psl_refresh_schema_error("unknown schema"),
    psl_refresh_publication_error("could not publish")
  )

  for (cnd in errors) {
    expect_s3_class(cnd, "pslr_refresh_error")
    expect_s3_class(cnd, "error")
    expect_s3_class(cnd, "condition")
  }
})

test_that("each error family maps to one coarse attempt category", {
  expect_equal(
    psl_refresh_attempt_result(psl_refresh_url_policy_error("x")),
    "url_policy_error"
  )
  expect_equal(
    psl_refresh_attempt_result(psl_refresh_http_status_error(500L)),
    "http_status_error"
  )
  expect_equal(
    psl_refresh_attempt_result(psl_refresh_response_limit_error(1, 1)),
    "response_limit_error"
  )
  expect_equal(
    psl_refresh_attempt_result(simpleError("unrelated")),
    NA_character_
  )
})

test_that("every attempt category has a matching error class", {
  expect_setequal(
    unname(psl_refresh_error_classes),
    setdiff(psl_source_attempt_results, psl_refresh_outcomes)
  )
})

test_that("errors refuse to carry bodies, headers, or traces", {
  expect_error(
    psl_refresh_error("x", "pslr_refresh_transport_error", body = "secret"),
    "must not carry field"
  )
  expect_error(
    psl_refresh_error("x", "pslr_refresh_transport_error", headers = "a"),
    "must not carry field"
  )
  expect_error(
    psl_refresh_error("x", "pslr_refresh_transport_error", trace = "..."),
    "must not carry field"
  )
})

test_that("error fields must be named, scalar, and coarse", {
  expect_error(
    psl_refresh_error("x", "pslr_refresh_transport_error", "unnamed"),
    "must all be named"
  )
  expect_error(
    psl_refresh_error("x", "pslr_refresh_transport_error", status = c(1L, 2L)),
    "must be a single value"
  )
  expect_error(
    psl_refresh_transport_error("x", reason = "Timeout was reached: host"),
    "short lowercase token"
  )
})

test_that("credentials in a URL are redacted before they reach an error", {
  cnd <- psl_refresh_url_policy_error(
    "bad url",
    request_url = "https://user:secret@example.org/list.dat"
  )

  expect_no_match(cnd$request_url, "secret")
  expect_equal(cnd$request_url, "https://<redacted>@example.org/list.dat")
})

test_that("URL redaction leaves an ordinary URL alone and caps length", {
  expect_equal(
    psl_redact_url("https://example.org/list.dat"),
    "https://example.org/list.dat"
  )
  expect_equal(psl_redact_url(NA_character_), NA_character_)
  long <- paste0("https://example.org/", strrep("a", 4000L))

  expect_lte(nchar(psl_redact_url(long)), 2048L)
})

test_that("an HTTP status error states the status and preserves Retry-After", {
  cnd <- psl_refresh_http_status_error(
    503L,
    retry_after = 42L,
    request_url = "https://example.org/list.dat"
  )

  expect_equal(cnd$status, 503L)
  expect_equal(cnd$retry_after, 42L)
  expect_match(conditionMessage(cnd), "HTTP 503")
  expect_match(conditionMessage(cnd), "Retry after 42 seconds")
})

test_that("Retry-After parses delta-seconds and rejects anything else", {
  expect_equal(psl_retry_after_seconds("120"), 120L)
  expect_equal(psl_retry_after_seconds(" 30 "), 30L)
  expect_equal(
    psl_retry_after_seconds("Wed, 21 Oct 2026 07:28:00 GMT"),
    NA_integer_
  )
  expect_equal(psl_retry_after_seconds("-5"), NA_integer_)
  expect_equal(psl_retry_after_seconds("1.5"), NA_integer_)
  expect_equal(psl_retry_after_seconds(NA_character_), NA_integer_)
  expect_equal(psl_retry_after_seconds(NULL), NA_integer_)
})

test_that("a lock-busy condition maps onto the refresh busy error", {
  busy <- psl_as_refresh_busy(psl_lock_busy_condition("sha256-source", 10))

  expect_s3_class(busy, "pslr_refresh_busy")
  expect_s3_class(busy, "pslr_lock_busy")
  expect_s3_class(busy, "pslr_busy_error")
  expect_s3_class(busy, "pslr_refresh_error")
  expect_equal(busy$lock, "sha256-source")
  expect_equal(busy$timeout, 10)
  expect_equal(psl_refresh_attempt_result(busy), "busy_error")
})

test_that("mapping an already-mapped or foreign condition is well defined", {
  busy <- psl_refresh_busy_error("busy", lock = "x", timeout = 1)

  expect_identical(psl_as_refresh_busy(busy), busy)
  expect_error(psl_as_refresh_busy(simpleError("nope")), "pslr_lock_busy")
})

test_that("a contended lock surfaces as a refresh busy error", {
  cache <- withr::local_tempdir()
  withr::local_options(
    pslr.cache_dir = cache,
    pslr.lock_try_create = \(path) FALSE,
    pslr.lock_timeout = 0
  )
  withr::defer(psl_lock_state$held <- character())

  cnd <- tryCatch(
    psl_refresh_with_busy(psl_with_lock("sha256-source", TRUE)),
    condition = identity
  )

  expect_s3_class(cnd, "pslr_refresh_busy")
  expect_equal(cnd$lock, "sha256-source")
})

test_that("a successful locked section passes its value through untouched", {
  cache <- withr::local_tempdir()
  withr::local_options(pslr.cache_dir = cache)
  withr::defer(psl_lock_state$held <- character())

  expect_equal(
    psl_refresh_with_busy(psl_with_lock("sha256-source", "done")),
    "done"
  )
})

test_that("printing an error is concise and shows only coarse fields", {
  cnd <- psl_refresh_http_status_error(
    503L,
    retry_after = 42L,
    request_url = "https://user:secret@example.org/list.dat"
  )
  lines <- format(cnd)

  expect_length(lines, 3L)
  expect_match(lines[[1L]], "<pslr_refresh_http_status_error>")
  expect_match(lines[[2L]], "HTTP 503")
  expect_match(lines[[3L]], "status: 503")
  expect_match(lines[[3L]], "retry_after: 42")
  expect_no_match(lines[[3L]], "secret")
  expect_output(print(cnd), "pslr_refresh_http_status_error")
})

test_that("an error with no coarse fields prints just its heading", {
  expect_length(format(psl_refresh_schema_error("unknown schema")), 2L)
})
