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
  calls <- 0L
  counting <- function(url, destfile, max_bytes) {
    calls <<- calls + 1L
    file.copy(bundled_dat_path(), destfile, overwrite = TRUE)
    invisible(destfile)
  }
  withr::local_options(pslr.downloader = counting)
  psl_refresh(force = TRUE)
  psl_refresh() # reused, no download
  expect_identical(calls, 1L)
  psl_refresh(force = TRUE) # forced download
  expect_identical(calls, 2L)
})

test_that("a stale cache triggers a fresh download", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE)
  # Backdate the recorded retrieval timestamp past the 24h window.
  marker <- file.path(dir, "current.rds")
  cur <- readRDS(marker)
  cur$meta$retrieved_at <- format(Sys.time() - as.difftime(48, units = "hours"),
    tz = "UTC", usetz = TRUE
  )
  saveRDS(cur, marker)
  refreshed <- psl_refresh()
  expect_false(identical(refreshed$retrieved_at, cur$meta$retrieved_at))
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

test_that("an oversized download is rejected before publication", {
  dir <- local_pslr_clean()
  withr::local_options(
    pslr.downloader = fake_downloader(), pslr.max_bytes = 1024L
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
      "// ===BEGIN ICANN DOMAINS===", "com", "com",
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===", "example.com",
      "// ===END PRIVATE DOMAINS==="
    ),
    dup
  )
  withr::local_options(pslr.downloader = fake_downloader(dup))
  expect_warning(psl_refresh(force = TRUE, activate = TRUE), "duplicate")
  expect_false(any(duplicated(
    paste(psl_rules()$section, psl_rules()$canonical_rule)
  )))
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
