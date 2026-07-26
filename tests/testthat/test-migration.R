# Legacy (v1) cache migration into v2 generations. Every test builds a real v1
# cache directory in a temp dir and migrates it; nothing here touches the
# network or writes outside its own temp directory.

local_migration_cache <- function(.env = parent.frame()) {
  cache <- withr::local_tempdir(.local_envir = .env)
  withr::local_options(pslr.cache_dir = cache, .local_envir = .env)
  withr::defer(psl_lock_state$held <- character(), envir = .env)
  cache
}

# A minimal but complete PSL: both official sections, one rule each.
legacy_list_lines <- function(extra = character()) {
  c(
    "// ===BEGIN ICANN DOMAINS===",
    "com",
    "co.uk",
    extra,
    "// ===END ICANN DOMAINS===",
    "// ===BEGIN PRIVATE DOMAINS===",
    "example.test",
    "// ===END PRIVATE DOMAINS==="
  )
}

# Build a v1 cache: a content-addressed `psl-<hex>.dat` plus the `current.rds`
# commit marker exactly as pslr wrote them before the redesign.
write_legacy_cache <- function(
  cache,
  lines = legacy_list_lines(),
  algorithm = c("sha256", "md5"),
  retrieved_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  checksum = NULL,
  manifest_version = 1L
) {
  algorithm <- match.arg(algorithm)
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)
  staged <- tempfile("legacy-", fileext = ".dat")
  writeLines(lines, staged)
  computed <- psl_checksum(staged, algorithm)
  recorded <- if (is.null(checksum)) computed else checksum
  hex <- sub("^[^:]+:", "", computed)
  dat <- file.path(cache, paste0("psl-", hex, ".dat"))
  file.copy(staged, dat, overwrite = TRUE)
  unlink(staged)
  marker <- list(
    dat_file = basename(dat),
    meta = psl_meta(
      source = "cache",
      path = dat,
      retrieved_at = retrieved_at,
      size = as.integer(file.size(dat)),
      checksum = recorded
    )
  )
  if (!is.na(manifest_version)) {
    marker <- c(list(manifest_version = manifest_version), marker)
  }
  saveRDS(marker, file.path(cache, "current.rds"))
  list(dat = dat, marker = file.path(cache, "current.rds"), checksum = recorded)
}

# Every legacy artifact of a cache directory, with its bytes, for an
# "untouched" assertion.
legacy_fingerprint <- function(cache) {
  files <- sort(list.files(cache, pattern = "^(current\\.rds|psl-.*\\.dat)$"))
  vapply(files, \(f) psl_sha256_file(file.path(cache, f)), character(1L))
}

test_that("an empty cache directory has nothing to migrate", {
  local_migration_cache()
  result <- psl_migrate_legacy_cache()
  expect_identical(result$status, "absent")
  expect_identical(result$message, NA_character_)
})

test_that("a valid sha256 legacy cache migrates into v2 generations", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache, retrieved_at = "2024-03-04 05:06:07 UTC")

  result <- psl_migrate_legacy_cache()

  expect_identical(result$status, "migrated")
  expect_identical(result$checksum, legacy$checksum)
  expect_identical(result$retrieved_at, "2024-03-04T05:06:07Z")
  expect_identical(result$request_url, psl_legacy_request_url)
  expect_identical(psl_snapshot_integrity(result$checksum, verify = TRUE), "ok")

  selection <- psl_read_selection()
  expect_identical(selection$status, "ok")
  expect_identical(selection$record$checksum, legacy$checksum)
  expect_identical(selection$record$request_url, psl_legacy_request_url)
  expect_identical(selection$generation, 1L)
})

test_that("a migrated source state records retrieval but no remote check", {
  cache <- local_migration_cache()
  write_legacy_cache(cache, retrieved_at = "2024-03-04 05:06:07 UTC")

  psl_migrate_legacy_cache()

  state <- psl_read_source_state(psl_legacy_request_url)
  expect_identical(state$status, "ok")
  expect_identical(state$generation, 1L)
  expect_identical(state$record$retrieved_at, "2024-03-04T05:06:07Z")
  expect_identical(state$record$checked_at, NA_character_)
  expect_identical(state$record$etag, NA_character_)
  expect_identical(state$record$last_modified, NA_character_)
  expect_identical(state$record$validator_url, NA_character_)
  expect_identical(state$record$next_check_at, NA_character_)
  expect_identical(state$record$last_result, NA_character_)
})

test_that("an unparseable legacy retrieval time migrates as unknown", {
  cache <- local_migration_cache()
  write_legacy_cache(cache, retrieved_at = "some time last Tuesday")

  result <- psl_migrate_legacy_cache()

  expect_identical(result$status, "migrated")
  expect_identical(result$retrieved_at, NA_character_)
  state <- psl_read_source_state(psl_legacy_request_url)
  expect_identical(state$record$retrieved_at, NA_character_)
})

test_that("a pre-1.1 marker without a manifest version still migrates", {
  cache <- local_migration_cache()
  write_legacy_cache(cache, manifest_version = NA)
  expect_identical(psl_migrate_legacy_cache()$status, "migrated")
})

test_that("md5-era bytes are re-identified by sha256 without being changed", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache, algorithm = "md5")
  before <- legacy_fingerprint(cache)
  expect_match(legacy$checksum, "^md5:")

  result <- psl_migrate_legacy_cache()

  expect_identical(
    result$checksum,
    paste0("sha256:", psl_sha256_file(legacy$dat))
  )
  expect_identical(psl_read_selection()$record$checksum, result$checksum)
  expect_identical(legacy_fingerprint(cache), before)
})

test_that("migration leaves every legacy file in place and unmodified", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache)
  before <- legacy_fingerprint(cache)

  psl_migrate_legacy_cache()

  expect_identical(legacy_fingerprint(cache), before)
  expect_identical(readRDS(legacy$marker)$dat_file, basename(legacy$dat))
})

test_that("the imported snapshot is a copy, not the legacy file", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache)
  result <- psl_migrate_legacy_cache()
  bytes <- psl_snapshot_bytes_path(result$checksum)
  expect_false(identical(normalizePath(bytes), normalizePath(legacy$dat)))
  expect_identical(psl_sha256_file(bytes), psl_sha256_file(legacy$dat))
})

test_that("migration is idempotent", {
  cache <- local_migration_cache()
  write_legacy_cache(cache)

  first <- psl_migrate_legacy_cache()
  second <- psl_migrate_legacy_cache()

  expect_identical(second$status, "skipped")
  expect_identical(
    psl_generation_numbers(psl_selection_stream_dir()),
    1L
  )
  expect_identical(
    psl_generation_numbers(psl_source_stream_dir(psl_legacy_request_url)),
    1L
  )
  expect_length(
    list.files(psl_snapshot_dir(), pattern = "\\.dat$"),
    1L
  )
  expect_identical(first$checksum, psl_read_selection()$record$checksum)
})

test_that("migration is a no-op once any v2 selection exists", {
  cache <- local_migration_cache()
  write_legacy_cache(cache)
  other <- tempfile("other-", fileext = ".dat")
  writeLines(legacy_list_lines("net"), other)
  published <- psl_with_publish_lock({
    descriptor <- psl_publish_snapshot(other)
    psl_publish_selection(descriptor$checksum)
    descriptor$checksum
  })

  expect_identical(psl_migrate_legacy_cache()$status, "skipped")
  expect_identical(psl_read_selection()$record$checksum, published)
})

test_that("migration is a no-op once any v2 source stream exists", {
  cache <- local_migration_cache()
  write_legacy_cache(cache)
  psl_with_publish_lock(
    psl_publish_source_state("https://psl.example/list.dat")
  )
  expect_identical(psl_migrate_legacy_cache()$status, "skipped")
  expect_identical(psl_read_selection()$status, "empty")
})

test_that("a corrupt marker is reported, left alone, and imports nothing", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache)
  writeBin(as.raw(c(1L, 2L, 3L)), legacy$marker)
  before <- legacy_fingerprint(cache)

  expect_warning(
    result <- psl_migrate_legacy_cache(),
    "could not be migrated"
  )

  expect_identical(result$status, "unprovable")
  expect_identical(result$reason, "marker_malformed")
  expect_match(result$message, "psl_refresh(force = TRUE)", fixed = TRUE)
  expect_identical(legacy_fingerprint(cache), before)
  expect_identical(psl_read_selection()$status, "empty")
})

test_that("a malformed marker manifest is unprovable", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache)
  saveRDS(list(dat_file = basename(legacy$dat)), legacy$marker)
  result <- psl_migrate_legacy_cache(quiet = TRUE)
  expect_identical(result$reason, "marker_malformed")
})

test_that("a marker naming missing bytes is unprovable", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache)
  unlink(legacy$dat)
  result <- psl_migrate_legacy_cache(quiet = TRUE)
  expect_identical(result$status, "unprovable")
  expect_identical(result$reason, "bytes_missing")
  expect_identical(psl_read_selection()$status, "empty")
})

test_that("bytes that fail their recorded checksum are never imported", {
  cache <- local_migration_cache()
  legacy <- write_legacy_cache(cache)
  writeLines(legacy_list_lines("org"), legacy$dat)

  result <- psl_migrate_legacy_cache(quiet = TRUE)

  expect_identical(result$status, "unprovable")
  expect_identical(result$reason, "checksum_mismatch")
  expect_identical(psl_read_selection()$status, "empty")
  expect_length(list.files(psl_snapshot_dir(), pattern = "\\.dat$"), 0L)
})

test_that("an unreadable recorded checksum is unprovable", {
  cache <- local_migration_cache()
  write_legacy_cache(cache, checksum = "crc32:deadbeef")
  result <- psl_migrate_legacy_cache(quiet = TRUE)
  expect_identical(result$reason, "checksum_unreadable")
})

test_that("checksum-clean bytes that are not a valid PSL are not imported", {
  cache <- local_migration_cache()
  # ICANN section only: the checksum verifies, full PSL validation does not.
  write_legacy_cache(
    cache,
    lines = c(
      "// ===BEGIN ICANN DOMAINS===",
      "com",
      "// ===END ICANN DOMAINS==="
    )
  )

  result <- psl_migrate_legacy_cache(quiet = TRUE)

  expect_identical(result$status, "unprovable")
  expect_identical(result$reason, "invalid_list")
  expect_identical(psl_read_selection()$status, "empty")
  expect_length(list.files(psl_snapshot_dir(), pattern = "\\.dat$"), 0L)
})

test_that("migration reports busy rather than waiting on a held publish lock", {
  cache <- local_migration_cache()
  write_legacy_cache(cache)
  withr::local_options(
    pslr.lock_try_create = \(path) FALSE,
    pslr.lock_timeout = 0
  )

  result <- psl_migrate_legacy_cache()

  expect_identical(result$status, "busy")
  expect_identical(psl_read_selection()$status, "empty")
})

test_that("migration runs under the publish lock", {
  cache <- local_migration_cache()
  write_legacy_cache(cache)
  trace <- new.env(parent = emptyenv())
  trace$stages <- character()
  trace$held <- logical()
  withr::local_options(
    pslr.publish_interrupt = function(stage) {
      trace$stages <- c(trace$stages, stage)
      trace$held <- c(trace$held, psl_lock_is_held(psl_publish_lock_name))
    }
  )
  psl_migrate_legacy_cache()
  expect_identical(
    trace$stages,
    c("bytes", "descriptor", "source_state", "selection")
  )
  expect_identical(trace$held, rep(TRUE, 4L))
})
