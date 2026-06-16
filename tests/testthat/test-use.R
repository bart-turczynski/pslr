# psl_use() active-list state management (PRD s7.4, s9).

test_that("psl_use validates the source and the path argument", {
  local_pslr_clean()
  expect_error(psl_use("nope"), "must be one of")
  # An explicit non-scalar source aborts, even when equal to the default vector.
  expect_error(
    psl_use(c("bundled", "cache", "path")), "must be one of"
  )
  expect_error(psl_use("bundled", path = "x"), "only used when")
  expect_error(psl_use("path"), "single file path")
  expect_error(psl_use("path", path = tempfile()), "not found")
})

test_that("psl_use('cache') errors with remediation when no cache exists", {
  local_pslr_clean()
  expect_error(psl_use("cache"), "No validated PSL cache")
})

test_that("psl_use('bundled') is the offline default and returns metadata", {
  local_pslr_clean()
  meta <- withVisible(psl_use("bundled"))
  expect_false(meta$visible)
  expect_identical(meta$value$source, "bundled")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})

test_that("psl_use('path') loads a custom list and indexes it at runtime", {
  local_pslr_clean()
  v <- psl_use("path", path = bundled_dat_path())
  expect_identical(v$source, "path")
  expect_false(is.na(v$path))
  expect_match(v$checksum, "^(sha256|md5):")
  # The custom list resolves the same as the bundled snapshot it copies.
  expect_identical(public_suffix("foo.github.io"), "github.io")
})

test_that("psl_use('path') rejects a file missing an official section", {
  local_pslr_clean()
  only_icann <- tempfile(fileext = ".dat")
  writeLines(
    c("// ===BEGIN ICANN DOMAINS===", "com", "// ===END ICANN DOMAINS==="),
    only_icann
  )
  expect_error(
    psl_use("path", path = only_icann), "both an ICANN and a PRIVATE section"
  )
})

test_that("psl_use('path') rejects a file with a repeated section", {
  local_pslr_clean()
  repeated <- tempfile(fileext = ".dat")
  writeLines(
    c(
      "// ===BEGIN ICANN DOMAINS===", "com", "// ===END ICANN DOMAINS===",
      "// ===BEGIN ICANN DOMAINS===", "net", "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===", "github.io",
      "// ===END PRIVATE DOMAINS==="
    ),
    repeated
  )
  expect_error(
    psl_use("path", path = repeated), "appears more than once"
  )
})

test_that("a failed path activation leaves the previous list usable", {
  local_pslr_clean()
  psl_use("path", path = bundled_dat_path())
  before <- psl_version()
  bad <- tempfile(fileext = ".dat")
  writeLines(c("// ===BEGIN ICANN DOMAINS===", "com"), bad) # unclosed section
  expect_error(psl_use("path", path = bad))
  expect_identical(psl_version(), before)
  expect_identical(public_suffix("www.example.com"), "com")
})

test_that("switching lists clears the match-result cache", {
  local_pslr_clean()
  psl_use("bundled")
  public_suffix("www.example.com") # populate the cache
  expect_gt(psl_cache_env$n, 0L)
  psl_use("path", path = bundled_dat_path())
  expect_identical(psl_cache_env$n, 0L)
})
