# psl_refresh(): validated https-only download + atomic publish (PRD s7.4, s9,
# s11.3). All network access is replaced by an injected downloader.

test_that("the refresh URL must be absolute https without credentials", {
  local_pslr_clean()
  expect_error(psl_refresh("http://psl.example/list.dat"), "absolute https")
  expect_error(psl_refresh("ftp://x/list.dat"), "absolute https")
  expect_error(psl_refresh("https://u:p@x/list.dat"), "embedded credentials")
  expect_error(psl_refresh(url = NA_character_), "single non-missing string")
})

test_that("force/activate must be logical scalars", {
  local_pslr_clean()
  expect_error(psl_refresh(force = "yes"), "single TRUE or FALSE")
  expect_error(psl_refresh(activate = NA), "single TRUE or FALSE")
})

test_that("refresh downloads, validates, and publishes an activatable cache", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  v <- psl_refresh(force = TRUE, activate = TRUE)
  expect_identical(v$source, "cache")
  expect_match(v$checksum, "^(sha256|md5):")
  expect_false(is.na(v$retrieved_at))
  expect_true(file.exists(file.path(dir, "current.rds")))
  expect_identical(psl_version()$source, "cache")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})

test_that("the 24-hour throttle reuses a fresh cache, keeping its timestamp", {
  local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  first <- psl_refresh(force = TRUE)
  # A second call within 24h reuses the snapshot and keeps its timestamp.
  reused <- psl_refresh()
  expect_identical(reused$retrieved_at, first$retrieved_at)
  expect_identical(reused$source, "cache")
})

test_that("force re-downloads even when the cache is fresh", {
  local_pslr_clean()
  state <- new.env(parent = emptyenv())
  state$calls <- 0L
  counting <- function(url, destfile, max_bytes) {
    state$calls <- state$calls + 1L
    file.copy(bundled_dat_path(), destfile, overwrite = TRUE)
    invisible(destfile)
  }
  withr::local_options(pslr.downloader = counting)
  psl_refresh(force = TRUE)
  psl_refresh() # reused, no download
  expect_identical(state$calls, 1L)
  psl_refresh(force = TRUE) # forced download
  expect_identical(state$calls, 2L)
})

test_that("a stale cache triggers a fresh download", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE)
  # Backdate the recorded retrieval timestamp past the 24h window.
  marker <- file.path(dir, "current.rds")
  cur <- readRDS(marker)
  cur$meta$retrieved_at <- format(
    Sys.time() - as.difftime(48, units = "hours"),
    tz = "UTC",
    usetz = TRUE
  )
  saveRDS(cur, marker)
  refreshed <- psl_refresh()
  expect_false(identical(refreshed$retrieved_at, cur$meta$retrieved_at))
})

test_that("a fresh cache with a missing source file is not reused", {
  dir <- local_pslr_clean()
  state <- new.env(parent = emptyenv())
  state$calls <- 0L
  counting <- function(url, destfile, max_bytes) {
    state$calls <- state$calls + 1L
    file.copy(bundled_dat_path(), destfile, overwrite = TRUE)
    invisible(destfile)
  }
  withr::local_options(pslr.downloader = counting)
  psl_refresh(force = TRUE)
  cur <- readRDS(file.path(dir, "current.rds"))
  unlink(file.path(dir, cur$dat_file))

  refreshed <- psl_refresh()
  expect_identical(state$calls, 2L)
  expect_identical(refreshed$source, "cache")
})

test_that("a fresh cache with a checksum mismatch is not reused", {
  dir <- local_pslr_clean()
  state <- new.env(parent = emptyenv())
  state$calls <- 0L
  counting <- function(url, destfile, max_bytes) {
    state$calls <- state$calls + 1L
    file.copy(bundled_dat_path(), destfile, overwrite = TRUE)
    invisible(destfile)
  }
  withr::local_options(pslr.downloader = counting)
  psl_refresh(force = TRUE)
  cur <- readRDS(file.path(dir, "current.rds"))
  writeLines("changed", file.path(dir, cur$dat_file))

  refreshed <- psl_refresh()
  expect_identical(state$calls, 2L)
  expect_identical(refreshed$source, "cache")
})

test_that("a download failure rolls back, leaving cache and matcher intact", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE, activate = TRUE)
  before <- psl_version()
  marker_before <- readRDS(file.path(dir, "current.rds"))

  failing <- function(url, destfile, max_bytes) {
    stop("refresh refused: redirected to a non-HTTPS URL.", call. = FALSE)
  }
  withr::local_options(pslr.downloader = failing)
  expect_error(psl_refresh(force = TRUE), "non-HTTPS")
  expect_identical(readRDS(file.path(dir, "current.rds")), marker_before)
  expect_identical(psl_version(), before)
})

test_that("a forced refresh recovers from a corrupt cache marker", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE)
  marker <- file.path(dir, "current.rds")
  writeBin(as.raw(0:7), marker) # not a valid serialized R object

  # Forced refresh ignores the unreadable marker instead of leaking the raw
  # readRDS "unknown input format" error, and republishes a readable marker.
  v <- psl_refresh(force = TRUE, activate = TRUE)
  expect_identical(v$source, "cache")
  expect_identical(psl_version()$source, "cache")
  expect_type(readRDS(marker), "list")
})

test_that("psl_use('cache') reports a corrupt marker with remediation", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE)
  writeBin(as.raw(0:7), file.path(dir, "current.rds"))

  expect_error(psl_use("cache"), "cache is corrupt")
  expect_error(psl_use("cache"), "psl_refresh\\(force = TRUE\\)")
})

test_that("an oversized download is rejected before publication", {
  dir <- local_pslr_clean()
  withr::local_options(
    pslr.downloader = fake_downloader(),
    pslr.max_bytes = 1024L
  )
  expect_error(psl_refresh(force = TRUE), "over the .* maximum")
  expect_false(file.exists(file.path(dir, "current.rds")))
})

test_that("invalid downloaded source is rejected before publication", {
  dir <- local_pslr_clean()
  bad <- tempfile(fileext = ".dat")
  writeLines(c("// ===BEGIN ICANN DOMAINS===", "com"), bad) # never closed
  withr::local_options(pslr.downloader = fake_downloader(bad))
  expect_error(psl_refresh(force = TRUE))
  expect_false(file.exists(file.path(dir, "current.rds")))
})

test_that("exact same-section duplicates warn once and are deduplicated", {
  local_pslr_clean()
  dup <- tempfile(fileext = ".dat")
  writeLines(
    c(
      "// ===BEGIN ICANN DOMAINS===",
      "com",
      "com",
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      "example.com",
      "// ===END PRIVATE DOMAINS==="
    ),
    dup
  )
  withr::local_options(pslr.downloader = fake_downloader(dup))
  expect_warning(psl_refresh(force = TRUE, activate = TRUE), "duplicate")
  expect_identical(
    anyDuplicated(
      paste(psl_rules()$section, psl_rules()$canonical_rule)
    ),
    0L
  )
})

test_that("the default downloader refuses a non-HTTPS redirect", {
  skip_if_not_installed("curl")
  testthat::local_mocked_bindings(
    curl_fetch_disk = function(url, path, handle) {
      list(url = "http://downgraded.example/list.dat", status_code = 200L)
    },
    new_handle = function(...) NULL,
    .package = "curl"
  )
  expect_error(
    psl_default_download("https://x/list.dat", tempfile(), 1e6),
    "non-HTTPS"
  )
})

test_that("the default downloader requires the curl package", {
  # With curl absent the downloader must abort with install guidance rather
  # than attempting a fetch.
  testthat::local_mocked_bindings(
    requireNamespace = function(package, ...) FALSE,
    .package = "base"
  )
  expect_error(
    psl_default_download("https://x/list.dat", tempfile(), 1e6),
    "'curl' package"
  )
})

test_that("the default downloader rejects an HTTP error status", {
  skip_if_not_installed("curl")
  testthat::local_mocked_bindings(
    curl_fetch_disk = function(url, path, handle) {
      list(url = "https://publicsuffix.example/list.dat", status_code = 404L)
    },
    new_handle = function(...) NULL,
    .package = "curl"
  )
  expect_error(
    psl_default_download("https://x/list.dat", tempfile(), 1e6),
    "HTTP status 404"
  )
})

test_that("the default downloader accepts an https 200 response", {
  skip_if_not_installed("curl")
  dest <- tempfile()
  testthat::local_mocked_bindings(
    curl_fetch_disk = function(url, path, handle) {
      list(url = "https://publicsuffix.example/list.dat", status_code = 200L)
    },
    new_handle = function(...) NULL,
    .package = "curl"
  )
  expect_identical(
    psl_default_download("https://x/list.dat", dest, 1e6),
    dest
  )
})

test_that("the source checksum falls back to md5 when digest is absent", {
  # A clean install without the optional 'digest' package still gets a
  # prefixed checksum, via base-R md5sum.
  testthat::local_mocked_bindings(
    requireNamespace = function(package, ...) FALSE,
    .package = "base"
  )
  expect_match(psl_source_checksum(bundled_dat_path()), "^md5:")
})

test_that("an md5-recorded checksum verifies against md5 with digest present", {
  # The recorded algorithm drives verification, so a cache recorded as md5 on a
  # digest-less machine still verifies TRUE where digest is now available --
  # rather than being spuriously rejected because digest would prefer sha256.
  path <- bundled_dat_path()
  recorded <- paste0("md5:", unname(tools::md5sum(path)))
  expect_true(requireNamespace("digest", quietly = TRUE))
  expect_true(psl_verify_checksum(path, recorded))
})

test_that("verifying an sha256 record without digest is an actionable error", {
  # A sha256-recorded cache verified where digest is unavailable is a missing
  # dependency, not corruption: it must ask the user to install digest.
  testthat::local_mocked_bindings(
    requireNamespace = function(package, ...) FALSE,
    .package = "base"
  )
  recorded <- paste0("sha256:", strrep("0", 64L))
  expect_error(
    psl_verify_checksum(bundled_dat_path(), recorded),
    "needs the 'digest' package"
  )
})

test_that("psl_use('cache') reports genuine content tampering as corruption", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE)
  cur <- readRDS(file.path(dir, "current.rds"))
  # Tamper with the source bytes so the recorded checksum no longer matches.
  writeLines("changed", file.path(dir, cur$dat_file))

  expect_error(psl_use("cache"), "cache is corrupt: checksum mismatch")
})

test_that("an unreadable source file is rejected before parsing", {
  expect_error(
    psl_load_source(tempfile(), "custom path list"),
    "not readable"
  )
})

test_that("a cache marker with no retrieval timestamp is not reusable", {
  current <- list(
    dat_file = "psl-x.dat",
    meta = list(retrieved_at = NA_character_, checksum = "sha256:x")
  )
  expect_identical(psl_reusable_cache_path(current, tempdir()), NA_character_)
})

test_that("atomic rename removes an existing destination and retries", {
  dir <- withr::local_tempdir()
  from <- file.path(dir, "from")
  to <- file.path(dir, "to")
  writeLines("new", from)
  writeLines("old", to)
  calls <- new.env(parent = emptyenv())
  calls$n <- 0L
  testthat::local_mocked_bindings(
    # The first rename fails (as onto an existing dest on Windows); the retry
    # performs the move via copy+remove so it cannot recurse into the mock.
    file.rename = function(from, to) {
      calls$n <- calls$n + 1L
      if (calls$n == 1L) {
        return(FALSE)
      }
      file.copy(from, to, overwrite = TRUE) && file.remove(from)
    },
    .package = "base"
  )
  expect_identical(psl_atomic_rename(from, to), to)
  expect_identical(calls$n, 2L)
  expect_identical(readLines(to), "new")
})

test_that("atomic rename aborts when the retried rename also fails", {
  dir <- withr::local_tempdir()
  from <- file.path(dir, "from")
  writeLines("new", from)
  testthat::local_mocked_bindings(
    file.rename = function(from, to) FALSE,
    .package = "base"
  )
  expect_error(
    psl_atomic_rename(from, file.path(dir, "to")),
    "could not publish cache file"
  )
})

test_that("reusing a fresh cache can activate it", {
  local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE) # publish, but leave the active list unchanged
  v <- psl_refresh(activate = TRUE) # reused within 24h and activated
  expect_identical(v$source, "cache")
  expect_identical(psl_version()$source, "cache")
})

test_that("psl_use('cache') activates a validated cache snapshot", {
  local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE)
  v <- psl_use("cache")
  expect_identical(v$source, "cache")
  expect_identical(psl_version()$source, "cache")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})
