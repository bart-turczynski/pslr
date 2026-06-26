# Tests for the bundled PSL snapshot, index, and metadata (PRD s8.3, s11.3).

bundled_dat <- function() {
  system.file("extdata", "public_suffix_list.dat", package = "pslr")
}

test_that("the bundled source snapshot ships and is the MPL-2.0 list", {
  path <- bundled_dat()
  skip_if(identical(path, ""), "bundled snapshot not installed")
  head_lines <- readLines(path, n = 3L, encoding = "UTF-8")
  expect_match(head_lines[1], "Mozilla Public", fixed = TRUE)

  license <- system.file("extdata", "PSL-LICENSE", package = "pslr")
  expect_true(nzchar(license))
  expect_match(readLines(license, n = 1L), "Mozilla Public License")
})

test_that("bundled metadata has the documented fields and types", {
  meta <- pslr_bundled$meta
  expect_named(
    meta,
    c("source", "url", "commit", "retrieved_at", "list_date", "size",
      "checksum", "normalizer", "normalizer_version",
      "normalization_profile", "unicode_version")
  )
  expect_identical(meta$source, "bundled")
  expect_identical(meta$normalizer, "punycoder")
  expect_match(meta$commit, "^[0-9a-f]{40}$")
  expect_match(meta$checksum, "^sha256:[0-9a-f]{64}$")
  expect_type(meta$size, "integer")
  expect_true(nzchar(meta$normalization_profile))
  expect_true(nzchar(meta$unicode_version))
})

test_that("the bundled .dat reproduces the stored index exactly", {
  path <- bundled_dat()
  skip_if(identical(path, ""), "bundled snapshot not installed")
  rebuilt <- apply_duplicate_policy(read_psl_file(path), mode = "strict")
  expect_identical(rebuilt, pslr_bundled$rules)
})

test_that("the recorded checksum and size match the shipped file", {
  path <- bundled_dat()
  skip_if(identical(path, ""), "bundled snapshot not installed")
  expect_identical(as.integer(file.size(path)), pslr_bundled$meta$size)

  skip_if_not_installed("digest")
  recomputed <- paste0("sha256:", digest::digest(file = path, algo = "sha256"))
  expect_identical(recomputed, pslr_bundled$meta$checksum)
})

test_that("the real list parses cleanly under the strict build policy", {
  path <- bundled_dat()
  skip_if(identical(path, ""), "bundled snapshot not installed")
  # No exact same-section duplicates and no conflicting kinds in real data.
  expect_no_error(apply_duplicate_policy(read_psl_file(path), mode = "strict"))
  rules <- pslr_bundled$rules
  expect_true(all(rules$section %in% c("icann", "private")))
  expect_true(all(rules$kind %in% c("normal", "wildcard", "exception")))
  expect_gt(nrow(rules), 1000L)
})
