# `psl_reminder()` and the attach-time message are pure local state: every test
# here runs offline, against a private cache AND config directory, and the
# attach path is driven by publishing records directly.

# Reset the once-per-session emission flag for one test, and restore it after,
# so ordering between test files can never make a reminder test pass or fail.
local_reminder_session <- function(env = parent.frame()) {
  previous <- psl_reminder_session$emitted
  psl_reminder_session$emitted <- FALSE
  withr::defer(psl_reminder_session$emitted <- previous, envir = env)
  invisible(NULL)
}

# Publish one complete list as cache bytes and return its checksum identity.
# `extra` adds ICANN rules, which is how a test produces a second, distinct
# snapshot without touching the network.
publish_reminder_bytes <- function(extra = character()) {
  psl_with_publish_lock(
    psl_publish_snapshot(write_test_list(extra))
  )$checksum
}

# Seed a cache the active engine can resolve to, confirmed `days` ago against
# the official source. A `source_checksum` that differs from the selected
# snapshot is how a test produces `update_available` offline.
seed_reminder_cache <- function(
  days = 1,
  extra = character(),
  source_checksum = NULL
) {
  checksum <- publish_reminder_bytes(extra)
  checked_at <- psl_format_time(psl_now() - days * 86400)
  psl_with_publish_lock(
    psl_publish_source_state(
      psl_official_url,
      checksum = if (is.null(source_checksum)) checksum else source_checksum,
      checked_at = checked_at,
      retrieved_at = checked_at
    )
  )
  psl_with_publish_lock(
    psl_publish_selection(checksum, request_url = psl_official_url)
  )
  checksum
}

# Everything the attach hook would print, as one string.
reminder_message <- function() {
  paste(testthat::capture_messages(psl_reminder_attach()), collapse = "")
}

# Replace the newest generation of a stream with unreadable bytes.
corrupt_reminder_stream <- function(dir) {
  generations <- psl_generation_numbers(dir)
  target <- if (length(generations)) max(generations) else 1L
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  writeLines("not an rds file", file.path(dir, psl_generation_name(target)))
  invisible(dir)
}

test_that("querying reports the documented defaults and writes nothing", {
  local_pslr_clean()
  preference <- psl_reminder()
  expect_s3_class(preference, "psl_reminder")
  expect_s3_class(preference, "data.frame")
  expect_identical(nrow(preference), 1L)
  expect_named(preference, c("enabled", "interval", "stored"))
  expect_false(preference$enabled)
  expect_identical(preference$interval, 7L)
  expect_false(preference$stored)
  expect_false(dir.exists(psl_reminder_stream_dir()))
})

test_that("querying an existing preference still writes no generation", {
  local_pslr_clean()
  psl_reminder(enable = TRUE, every = 3)
  before <- psl_generation_numbers(psl_reminder_stream_dir())
  psl_reminder()
  psl_reminder()
  expect_identical(psl_generation_numbers(psl_reminder_stream_dir()), before)
})

test_that("enable, disable, and query round-trip through the config stream", {
  local_pslr_clean()
  enabled <- psl_reminder(enable = TRUE, every = 3)
  expect_true(enabled$enabled)
  expect_identical(enabled$interval, 3L)
  expect_true(enabled$stored)
  expect_true(psl_reminder()$enabled)

  disabled <- psl_reminder(enable = FALSE)
  expect_false(disabled$enabled)
  expect_false(psl_reminder()$enabled)
  expect_true(psl_reminder()$stored)
})

test_that("writing a preference returns it invisibly", {
  local_pslr_clean()
  expect_invisible(psl_reminder(enable = TRUE))
  expect_visible(psl_reminder())
})

test_that("enabling without `every` defaults to seven days", {
  local_pslr_clean()
  expect_identical(psl_reminder(enable = TRUE)$interval, 7L)
})

test_that("enabling without `every` reuses the stored interval", {
  local_pslr_clean()
  psl_reminder(enable = TRUE, every = 21)
  psl_reminder(enable = FALSE)
  expect_identical(psl_reminder(enable = TRUE)$interval, 21L)
})

test_that("disabling retains the interval, an explicit `every` replaces it", {
  local_pslr_clean()
  psl_reminder(enable = TRUE, every = 30)
  expect_identical(psl_reminder(enable = FALSE)$interval, 30L)
  expect_identical(psl_reminder(enable = FALSE, every = 2)$interval, 2L)
  expect_identical(psl_reminder()$interval, 2L)
})

test_that("the preference survives a cache wipe because it is config", {
  cache <- local_pslr_clean()
  psl_reminder(enable = TRUE, every = 5)
  for (stream in c("snapshots", "sources", "selections")) {
    unlink(file.path(cache, stream), recursive = TRUE)
  }
  preference <- psl_reminder()
  expect_true(preference$enabled)
  expect_identical(preference$interval, 5L)
})

test_that("`every` is validated as a whole number of days of at least one", {
  local_pslr_clean()
  expect_error(psl_reminder(enable = TRUE, every = 0), "at least one")
  expect_error(psl_reminder(enable = TRUE, every = -1), "at least one")
  expect_error(psl_reminder(enable = TRUE, every = 1.5), "whole number")
  expect_error(psl_reminder(enable = TRUE, every = c(1, 2)), "single")
  expect_error(psl_reminder(enable = TRUE, every = NA), "whole number")
  expect_error(psl_reminder(enable = TRUE, every = "7"), "whole number")
  expect_error(psl_reminder(enable = TRUE, every = Inf), "whole number")
})

test_that("`enable` is validated and `every` alone is rejected", {
  local_pslr_clean()
  expect_error(psl_reminder(enable = NA), "TRUE, FALSE, or NULL")
  expect_error(psl_reminder(enable = "yes"), "TRUE, FALSE, or NULL")
  expect_error(psl_reminder(enable = c(TRUE, TRUE)), "TRUE, FALSE, or NULL")
  expect_error(psl_reminder(every = 7), "only be set together with")
})

test_that("a rejected argument publishes no generation", {
  local_pslr_clean()
  expect_error(psl_reminder(enable = TRUE, every = 0), "at least one")
  expect_false(dir.exists(psl_reminder_stream_dir()))
})

test_that("an unreadable preference stream reports the silent default", {
  local_pslr_clean()
  psl_reminder(enable = TRUE, every = 4)
  corrupt_reminder_stream(psl_reminder_stream_dir())
  preference <- psl_reminder()
  expect_false(preference$enabled)
  expect_false(preference$stored)
})

test_that("the preference prints its state, interval, and origin", {
  local_pslr_clean()
  disabled <- paste(format(psl_reminder()), collapse = "\n")
  expect_match(disabled, "<psl_reminder: disabled>", fixed = TRUE)
  expect_match(disabled, "prints no freshness reminder", fixed = TRUE)
  expect_match(disabled, "not stored", fixed = TRUE)

  psl_reminder(enable = TRUE, every = 1)
  enabled <- paste(format(psl_reminder()), collapse = "\n")
  expect_match(enabled, "<psl_reminder: enabled>", fixed = TRUE)
  expect_match(enabled, "1 day", fixed = TRUE)
  expect_output(print(psl_reminder()), "psl_reminder: enabled", fixed = TRUE)
})

test_that("a partial preference falls back to data frame display", {
  local_pslr_clean()
  partial <- psl_reminder()["enabled"]
  expect_s3_class(partial, "psl_reminder")
  expect_output(print(partial), "enabled")
})

test_that("no attach message is emitted while reminders are disabled", {
  local_pslr_clean()
  local_reminder_session()
  seed_reminder_cache(days = 99)
  expect_no_message(psl_reminder_attach())
})

test_that("an enabled reminder emits at most one message per session", {
  local_pslr_clean()
  local_reminder_session()
  psl_reminder(enable = TRUE, every = 7)
  expect_message(psl_reminder_attach(), "psl_refresh")
  expect_no_message(psl_reminder_attach())
  expect_no_message(psl_reminder_attach())
})

test_that("the attach message is a suppressible startup message", {
  local_pslr_clean()
  local_reminder_session()
  psl_reminder(enable = TRUE)
  expect_condition(psl_reminder_attach(), class = "packageStartupMessage")
  psl_reminder_session$emitted <- FALSE
  expect_no_message(suppressPackageStartupMessages(psl_reminder_attach()))
})

test_that("a never-checked snapshot is reminded about", {
  local_pslr_clean()
  local_reminder_session()
  psl_reminder(enable = TRUE)
  expect_identical(psl_status("active")$state, "never_checked")
  message <- reminder_message()
  expect_match(message, "never confirmed", fixed = TRUE)
  expect_match(message, "psl_refresh()", fixed = TRUE)
  expect_match(message, "psl_reminder(enable = FALSE)", fixed = TRUE)
})

test_that("a due check is reminded about", {
  local_pslr_clean()
  local_reminder_session()
  seed_reminder_cache(days = 9)
  psl_use("cache")
  psl_reminder(enable = TRUE, every = 7)
  expect_identical(psl_status("active")$state, "check_due")
  message <- reminder_message()
  expect_match(message, "last confirmed", fixed = TRUE)
  expect_match(message, "check again", fixed = TRUE)
})

test_that("a confirmed current snapshot is silent", {
  local_pslr_clean()
  local_reminder_session()
  seed_reminder_cache(days = 1)
  psl_use("cache")
  psl_reminder(enable = TRUE, every = 7)
  expect_identical(psl_status("active")$state, "confirmed_current")
  expect_no_message(psl_reminder_attach())
})

test_that("an untracked snapshot is silent", {
  local_pslr_clean()
  local_reminder_session()
  psl_reminder(enable = TRUE)
  psl_use("path", path = write_test_list())
  expect_identical(psl_status("active")$state, "untracked")
  expect_no_message(psl_reminder_attach())
})

test_that("update_available wording suggests activation, not downloading", {
  local_pslr_clean()
  local_reminder_session()
  newer <- publish_reminder_bytes("newer.example")
  seed_reminder_cache(days = 1, source_checksum = newer)
  psl_use("cache")
  psl_reminder(enable = TRUE)
  expect_identical(psl_status("active")$state, "update_available")
  message <- reminder_message()
  expect_match(message, "activate", fixed = TRUE)
  expect_match(message, "psl_use(\"cache\")", fixed = TRUE)
  expect_false(grepl("download", message, fixed = TRUE))
  expect_false(grepl("psl_refresh", message, fixed = TRUE))
})

test_that("a corrupt cache degrades the reminder to silence", {
  local_pslr_clean()
  local_reminder_session()
  seed_reminder_cache(days = 9)
  psl_use("cache")
  psl_reminder(enable = TRUE)
  corrupt_reminder_stream(psl_source_stream_dir(psl_official_url))
  expect_identical(psl_status("active")$state, "unknown")
  expect_no_message(psl_reminder_attach())
})

test_that("a failing status path degrades to silence, not an error", {
  local_pslr_clean()
  local_reminder_session()
  psl_reminder(enable = TRUE)
  local_mocked_bindings(psl_status = function(...) stop("broken cache"))
  expect_no_message(psl_reminder_attach())
  expect_null(psl_reminder_attach())
})

test_that("no reminder path makes a network request", {
  local_pslr_clean()
  local_reminder_session()
  transport <- local_fake_transport()
  psl_reminder()
  psl_reminder(enable = TRUE, every = 2)
  psl_reminder(enable = FALSE)
  psl_reminder(enable = TRUE)
  suppressPackageStartupMessages(psl_reminder_attach())
  suppressPackageStartupMessages(psl_reminder_attach())
  expect_identical(request_count(transport), 0L)
})
