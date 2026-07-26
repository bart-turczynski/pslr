# Every test here is fully offline and clock-free: validator selection and
# courtesy arithmetic are pure functions, and every one of them takes `now`
# explicitly, so no test reads the real clock or opens a socket.

# A fixed instant to hang the time tests on.
fixed_now <- function(x = "2026-07-01T00:00:00Z") {
  psl_parse_time(x)
}

test_that("a usable ETag is preferred over a usable Last-Modified", {
  request <- psl_validator_request(
    "\"abc\"",
    "Wed, 01 Jul 2026 00:00:00 GMT"
  )
  expect_equal(request$validator, "etag")
  expect_named(request$headers, "If-None-Match")
  expect_equal(unname(request$headers), "\"abc\"")
})

test_that("a weak ETag is sent byte-exactly, prefix and quotes intact", {
  request <- psl_validator_request("W/\"abc\"", NA_character_)
  expect_equal(request$validator, "etag")
  expect_equal(unname(request$headers[["If-None-Match"]]), "W/\"abc\"")
})

test_that("Last-Modified is used only when no usable ETag exists", {
  request <- psl_validator_request(
    NA_character_,
    "Wed, 01 Jul 2026 00:00:00 GMT"
  )
  expect_equal(request$validator, "last_modified")
  expect_named(request$headers, "If-Modified-Since")
  expect_equal(
    unname(request$headers[["If-Modified-Since"]]),
    "Wed, 01 Jul 2026 00:00:00 GMT"
  )
})

test_that("an unusable ETag falls back to Last-Modified", {
  request <- psl_validator_request(
    "\"abc\rX-Evil: 1\"",
    "Wed, 01 Jul 2026 00:00:00 GMT"
  )
  expect_equal(request$validator, "last_modified")
})

test_that("no usable validator means an unconditional GET", {
  request <- psl_validator_request(NA_character_, NA_character_)
  expect_equal(request$validator, "none")
  expect_length(request$headers, 0L)

  unusable <- psl_validator_request("", "\n")
  expect_equal(unusable$validator, "none")
  expect_length(unusable$headers, 0L)
})

test_that("validators carrying control bytes are rejected", {
  # NUL cannot be embedded in an R character string at all, so the byte check
  # below stands in for it with the other C0 controls plus DEL.
  expect_false(psl_validator_usable("\"a\rb\""))
  expect_false(psl_validator_usable("\"a\nb\""))
  expect_false(psl_validator_usable("\"a\tb\""))
  expect_false(psl_validator_usable("\"a\x01b\""))
  expect_false(psl_validator_usable("\"a\x7fb\""))
  expect_equal(psl_clean_validator("\"a\r\nb\""), NA_character_)
})

test_that("non-control, non-ASCII bytes stay usable", {
  expect_true(psl_validator_usable("\"café\""))
})

test_that("a validator is capped at 8 KiB", {
  expect_true(psl_validator_usable(strrep("a", 8192L)))
  expect_false(psl_validator_usable(strrep("a", 8193L)))
  expect_equal(psl_clean_validator(strrep("a", 8193L)), NA_character_)
})

test_that("a non-string validator is never usable", {
  expect_false(psl_validator_usable(NA_character_))
  expect_false(psl_validator_usable(NA))
  expect_false(psl_validator_usable(character()))
  expect_false(psl_validator_usable(c("\"a\"", "\"b\"")))
  expect_false(psl_validator_usable(1L))
})

test_that("a rotated ETag on a 304 replaces the stored one", {
  updated <- psl_validator_update(
    "\"old\"",
    NA_character_,
    c(ETag = "W/\"new\"")
  )
  expect_equal(updated$etag, "W/\"new\"")
  expect_equal(updated$last_modified, NA_character_)
})

test_that("a response without validators keeps the stored ones", {
  updated <- psl_validator_update(
    "\"old\"",
    "Wed, 01 Jul 2026 00:00:00 GMT",
    psl_empty_headers()
  )
  expect_equal(updated$etag, "\"old\"")
  expect_equal(updated$last_modified, "Wed, 01 Jul 2026 00:00:00 GMT")
})

test_that("an unusable rotated validator does not clobber the stored one", {
  updated <- psl_validator_update(
    "\"old\"",
    NA_character_,
    c(etag = strrep("a", 8193L))
  )
  expect_equal(updated$etag, "\"old\"")
})

test_that("an unusable stored validator is dropped on update", {
  updated <- psl_validator_update(
    "\"bad\r\"",
    NA_character_,
    psl_empty_headers()
  )
  expect_equal(updated$etag, NA_character_)
})

test_that("a 304 answering a conditional request is accepted", {
  expect_null(psl_check_not_modified(TRUE, "https://example.com/list.dat"))
})

test_that("a 304 without a request validator is a protocol error", {
  expect_error(
    psl_check_not_modified(FALSE, "https://example.com/list.dat"),
    "carried no validator"
  )
  cnd <- tryCatch(
    psl_check_not_modified(FALSE, "https://example.com/list.dat"),
    pslr_refresh_error = identity
  )
  expect_s3_class(cnd, "pslr_refresh_transport_error")
  expect_equal(cnd$reason, "unsolicited_not_modified")
})

test_that("max-age is parsed case-insensitively and only as a directive", {
  expect_equal(psl_cache_max_age("max-age=600"), 600L)
  expect_equal(psl_cache_max_age("public, MAX-AGE = 600"), 600L)
  expect_equal(psl_cache_max_age("public, max-age=\"600\""), 600L)
  expect_equal(psl_cache_max_age("s-maxage=600"), NA_integer_)
  expect_equal(psl_cache_max_age("no-cache"), NA_integer_)
  expect_equal(psl_cache_max_age(NA_character_), NA_integer_)
})

test_that("malformed max-age values do not parse", {
  expect_equal(psl_cache_max_age("max-age=-600"), NA_integer_)
  expect_equal(psl_cache_max_age("max-age=6.5"), NA_integer_)
  expect_equal(psl_cache_max_age("max-age=abc"), NA_integer_)
  expect_equal(psl_cache_max_age("max-age="), NA_integer_)
})

test_that("delta-seconds accepts only non-negative integers", {
  expect_equal(psl_delta_seconds("0"), 0L)
  expect_equal(psl_delta_seconds(" 42 "), 42L)
  expect_equal(psl_delta_seconds("-1"), NA_integer_)
  expect_equal(psl_delta_seconds("1.5"), NA_integer_)
  expect_equal(psl_delta_seconds("one"), NA_integer_)
  expect_equal(psl_delta_seconds(NA_character_), NA_integer_)
})

test_that("remaining freshness is max-age minus Age", {
  expect_equal(psl_remaining_freshness("max-age=600", "100"), 500)
  expect_equal(psl_remaining_freshness("max-age=600", NA_character_), 600)
  expect_equal(psl_remaining_freshness("max-age=600", "900"), 0)
  expect_equal(psl_remaining_freshness("max-age=600", "600"), 0)
})

test_that("malformed cache metadata leaves no remaining freshness", {
  expect_equal(psl_remaining_freshness(NA_character_, NA_character_), 0)
  expect_equal(psl_remaining_freshness("no-store", "10"), 0)
  expect_equal(psl_remaining_freshness("max-age=-1", NA_character_), 0)
  # A malformed `Age` counts as zero rather than poisoning the arithmetic.
  expect_equal(psl_remaining_freshness("max-age=600", "-100"), 600)
  expect_equal(psl_remaining_freshness("max-age=600", "1.5"), 600)
})

test_that("remaining freshness is capped at 30 days", {
  expect_equal(
    psl_remaining_freshness("max-age=999999999", NA_character_),
    psl_courtesy_cap_seconds
  )
})

test_that("Expires and other directives are ignored", {
  expect_equal(
    psl_remaining_freshness("public, must-revalidate", NA_character_),
    0
  )
})

test_that("the courtesy window has a hard 24-hour floor", {
  checked <- fixed_now()
  expect_equal(
    psl_next_check_at(checked),
    checked + psl_courtesy_floor_seconds
  )
  expect_equal(
    psl_next_check_at(checked, cache_control = "max-age=600"),
    checked + psl_courtesy_floor_seconds
  )
})

test_that("a longer server lifetime lengthens the courtesy window", {
  checked <- fixed_now()
  expect_equal(
    psl_next_check_at(checked, cache_control = "max-age=172800"),
    checked + 172800
  )
  expect_equal(
    psl_next_check_at(checked, cache_control = "max-age=172800", age = "3600"),
    checked + 169200
  )
})

test_that("the courtesy window never exceeds the 30-day cap", {
  checked <- fixed_now()
  expect_equal(
    psl_next_check_at(checked, cache_control = "max-age=999999999"),
    checked + psl_courtesy_cap_seconds
  )
})

test_that("the courtesy window accepts a persisted timestamp", {
  expect_equal(
    psl_next_check_at("2026-07-01T00:00:00Z"),
    fixed_now() + psl_courtesy_floor_seconds
  )
})

test_that("an unknown checked_at yields an unknown boundary", {
  expect_true(is.na(psl_next_check_at(NA)))
  expect_s3_class(psl_next_check_at(NA), "POSIXct")
})

test_that("psl_next_check_at guards unexpected arguments", {
  expect_error(psl_next_check_at(fixed_now(), cache_contol = "max-age=1"))
})

test_that("the courtesy window suppresses an ordinary check until it ends", {
  boundary <- fixed_now() + psl_courtesy_floor_seconds
  expect_false(psl_check_allowed(boundary, fixed_now()))
  expect_true(psl_check_allowed(boundary, boundary))
  expect_true(psl_check_allowed(boundary, boundary + 1))
})

test_that("force overrides the courtesy window", {
  boundary <- fixed_now() + psl_courtesy_floor_seconds
  expect_true(psl_check_allowed(boundary, fixed_now(), force = TRUE))
})

test_that("an unknown boundary does not suppress a check", {
  expect_true(psl_check_allowed(NA, fixed_now()))
  expect_true(psl_check_allowed(fixed_now(), NA))
})

test_that("elapsed time is measured forwards only", {
  now <- fixed_now()
  expect_equal(psl_elapsed_seconds(now - 60, now), 60)
  expect_equal(psl_elapsed_seconds(now, now), 0)
  expect_equal(psl_elapsed_days(now - 86400, now), 1)
})

test_that("a backwards clock yields an unknown age, never a freshness claim", {
  now <- fixed_now()
  expect_true(is.na(psl_elapsed_seconds(now + 60, now)))
  expect_true(is.na(psl_elapsed_days(now + 86400, now)))
  expect_true(is.na(psl_elapsed_seconds(NA, now)))
})

test_that("check_due compares the age against the reminder interval", {
  now <- fixed_now()
  expect_false(psl_check_due(now - 86400, now, interval_days = 7L))
  expect_true(psl_check_due(now - 7 * 86400, now, interval_days = 7L))
  expect_true(psl_check_due(now - 8 * 86400, now, interval_days = 7L))
})

test_that("check_due defaults to the package reminder interval", {
  now <- fixed_now()
  expect_true(
    psl_check_due(now - (psl_reminder_default_interval + 1) * 86400, now)
  )
  expect_false(psl_check_due(now - 86400, now))
})

test_that("a source never checked is always due", {
  expect_true(psl_check_due(NA, fixed_now()))
  expect_true(psl_check_due(NA_character_, fixed_now()))
})

test_that("check_due is unknown under backwards clock skew", {
  now <- fixed_now()
  expect_true(is.na(psl_check_due(now + 86400, now)))
})
