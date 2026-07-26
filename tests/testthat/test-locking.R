# A clock that advances by `step` seconds on every read, so a bounded wait can
# be driven to its deadline without any wall-clock time passing.
local_fake_clock <- function(step = 1, .env = parent.frame()) {
  state <- new.env(parent = emptyenv())
  state$now <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  withr::local_options(
    pslr.clock = function() {
      state$now <- state$now + step
      state$now
    },
    .local_envir = .env
  )
  state
}

# Record sleep requests instead of performing them.
local_recording_sleep <- function(.env = parent.frame()) {
  state <- new.env(parent = emptyenv())
  state$calls <- numeric()
  withr::local_options(
    pslr.lock_sleep = function(seconds) {
      state$calls <- c(state$calls, seconds)
      invisible(NULL)
    },
    .local_envir = .env
  )
  state
}

# Point the cache at a temporary directory and guarantee the in-process lock
# registry is empty again afterwards, whatever a test does to it.
local_lock_cache <- function(.env = parent.frame()) {
  cache <- withr::local_tempdir(.local_envir = .env)
  withr::local_options(pslr.cache_dir = cache, .local_envir = .env)
  withr::defer(psl_lock_state$held <- character(), envir = .env)
  cache
}

test_that("lock artifacts live under the cache locks directory", {
  cache <- local_lock_cache()
  url <- "https://example.test/list.dat"
  expect_identical(psl_lock_dir(), file.path(cache, "locks"))
  expect_identical(
    psl_lock_path(psl_publish_lock_name),
    file.path(cache, "locks", "publish.lock")
  )
  expect_identical(
    psl_lock_path(psl_source_lock_name(url)),
    file.path(cache, "locks", paste0(psl_source_stream_name(url), ".lock"))
  )
  # A lock name never carries URL text, so a lock listing leaks no source URL.
  expect_no_match(psl_source_lock_name(url), "example", fixed = TRUE)
})

test_that("acquiring creates the artifact and releasing removes it", {
  local_lock_cache()
  lock <- psl_lock_acquire("publish")
  expect_s3_class(lock, "psl_lock")
  expect_true(dir.exists(lock$path))
  expect_identical(psl_locks_held(), "publish")
  expect_identical(psl_lock_release(lock), "publish")
  expect_false(dir.exists(lock$path))
  expect_length(psl_locks_held(), 0L)
})

test_that("psl_with_lock releases the lock even when the body fails", {
  local_lock_cache()
  expect_error(psl_with_lock("publish", stop("body failed")), "body failed")
  expect_length(psl_locks_held(), 0L)
  expect_false(dir.exists(psl_lock_path("publish")))
})

test_that("a bounded wait gives up and reports busy without blocking", {
  local_lock_cache()
  local_fake_clock()
  sleeps <- local_recording_sleep()
  withr::local_options(
    pslr.lock_try_create = function(path) FALSE,
    pslr.lock_timeout = 5
  )
  expect_null(psl_lock_acquire("publish"))
  expect_gt(length(sleeps$calls), 0L)
  expect_length(psl_locks_held(), 0L)
})

test_that("a busy lock is a classed condition or NULL, as the caller asks", {
  local_lock_cache()
  local_fake_clock()
  local_recording_sleep()
  withr::local_options(
    pslr.lock_try_create = function(path) FALSE,
    pslr.lock_timeout = 3
  )
  busy <- tryCatch(
    psl_with_lock("publish", "never runs"),
    pslr_lock_busy = function(e) e
  )
  expect_s3_class(busy, "pslr_lock_busy")
  expect_identical(busy$lock, "publish")
  expect_null(psl_with_lock("publish", "never runs", on_busy = "null"))
})

test_that("the body is skipped entirely when the lock is busy", {
  local_lock_cache()
  local_fake_clock()
  local_recording_sleep()
  withr::local_options(
    pslr.lock_try_create = function(path) FALSE,
    pslr.lock_timeout = 3
  )
  ran <- new.env(parent = emptyenv())
  ran$value <- FALSE
  psl_with_lock("publish", ran$value <- TRUE, on_busy = "null")
  expect_false(ran$value)
})

test_that("the normative order is source lock, then publish lock", {
  local_lock_cache()
  url <- "https://example.test/list.dat"
  result <- psl_with_source_lock(url, psl_with_publish_lock("committed"))
  expect_identical(result, "committed")
  expect_length(psl_locks_held(), 0L)
})

test_that("taking a source lock under the publish lock is refused", {
  local_lock_cache()
  url <- "https://example.test/list.dat"
  expect_error(
    psl_with_publish_lock(psl_with_source_lock(url, "unreachable")),
    "Lock order violation"
  )
  expect_length(psl_locks_held(), 0L)
})

test_that("re-entering a lock this process already holds is refused", {
  local_lock_cache()
  expect_error(
    psl_with_publish_lock(psl_with_publish_lock("unreachable")),
    "already held by this process"
  )
  expect_length(psl_locks_held(), 0L)
})

test_that("a publication guard names the lock it requires", {
  local_lock_cache()
  expect_error(
    psl_lock_assert_held("publish", "Publishing"),
    "Publishing requires the \"publish\" lock"
  )
  expect_null(psl_with_publish_lock(psl_lock_assert_held("publish", "X")))
})

test_that("a stale lock artifact does not by itself imply ownership", {
  local_lock_cache()
  withr::local_options(pslr.lock_stale_seconds = 60, pslr.lock_timeout = 0)
  path <- psl_lock_path("publish")
  dir.create(path, recursive = TRUE)

  # A fresh artifact is respected: the bounded wait expires busy.
  expect_null(psl_lock_acquire("publish"))

  # An artifact older than the staleness horizon is reclaimed, once.
  Sys.setFileTime(path, Sys.time() - 3600)
  lock <- psl_lock_acquire("publish")
  expect_s3_class(lock, "psl_lock")
  psl_lock_release(lock)
})

test_that("the clock seam must supply a real time", {
  local_lock_cache()
  withr::local_options(pslr.clock = function() 0)
  expect_error(psl_now(), "must return a POSIXct time")
})
