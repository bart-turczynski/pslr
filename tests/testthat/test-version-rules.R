# psl_version() and psl_rules() metadata APIs (PRD s7.4, s11.3).

test_that("psl_version reports the documented columns and types", {
  local_pslr_clean()
  v <- psl_version()
  expect_s3_class(v, "data.frame")
  expect_identical(nrow(v), 1L)
  expect_identical(
    names(v),
    c("source", "path", "retrieved_at", "list_date", "commit", "size",
      "checksum", "normalizer", "normalizer_version",
      "normalization_profile", "unicode_version")
  )
  expect_type(v$size, "integer")
  expect_true(is.character(v$checksum))
})

test_that("the bundled list reports runtime normalizer identifiers", {
  local_pslr_clean()
  psl_use("bundled")
  v <- psl_version()
  expect_identical(v$source, "bundled")
  expect_identical(v$normalizer, "punycoder")
  prof <- punycoder::normalization_profile_info()
  expect_identical(v$normalization_profile, as.character(prof$profile))
  expect_identical(v$unicode_version, as.character(prof$unicode_version))
  expect_identical(
    v$normalizer_version, as.character(utils::packageVersion("punycoder"))
  )
})

test_that("checksum carries an algorithm prefix and path is typed NA", {
  local_pslr_clean()
  v <- psl_version()
  expect_match(v$checksum, "^(sha256|md5):[0-9a-f]+$")
  expect_true(is.na(v$path))
  expect_type(v$path, "character")
})

test_that("psl_rules returns the documented schema, ordered", {
  local_pslr_clean()
  r <- psl_rules()
  expect_identical(
    names(r), c("rule", "canonical_rule", "kind", "section", "labels")
  )
  expect_type(r$labels, "integer")
  expect_true(all(r$kind %in% c("normal", "wildcard", "exception")))
  expect_true(all(r$section %in% c("icann", "private")))
  # ICANN rows come before PRIVATE rows.
  sec_run <- rle(r$section)$values
  expect_identical(sec_run, c("icann", "private"))
})

test_that("psl_rules filters by section and never includes the default rule", {
  local_pslr_clean()
  icann <- psl_rules("icann")
  private <- psl_rules("private")
  expect_true(all(icann$section == "icann"))
  expect_true(all(private$section == "private"))
  expect_identical(nrow(psl_rules("all")), nrow(icann) + nrow(private))
  expect_false(any(psl_rules()$canonical_rule == "*"))
})

test_that("canonical_rule keeps wildcard and exception markers", {
  local_pslr_clean()
  r <- psl_rules()
  wild <- r[r$kind == "wildcard", , drop = FALSE]
  exc <- r[r$kind == "exception", , drop = FALSE]
  expect_true(all(startsWith(wild$canonical_rule, "*.")))
  expect_true(all(startsWith(exc$canonical_rule, "!")))
})
