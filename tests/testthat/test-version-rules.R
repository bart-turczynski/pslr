# psl_version() and psl_rules() metadata APIs (PRD s7.4, s11.3).

test_that("psl_version reports the documented columns and types", {
  local_pslr_clean()
  v <- psl_version()
  expect_s3_class(v, "data.frame")
  expect_identical(nrow(v), 1L)
  expect_named(
    v,
    c(
      "source",
      "url",
      "path",
      "retrieved_at",
      "list_date",
      "commit",
      "size",
      "checksum",
      "normalizer",
      "normalizer_version",
      "normalization_profile",
      "unicode_version"
    )
  )
  expect_type(v$size, "integer")
  expect_type(v$checksum, "character")
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
    v$normalizer_version,
    as.character(utils::packageVersion("punycoder"))
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
  expect_named(
    r,
    c("rule", "canonical_rule", "kind", "section", "labels")
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
  # An explicit non-scalar section aborts, even when equal to the default.
  expect_error(
    psl_rules(c("all", "icann", "private")),
    "must be one of"
  )
})

# Activate the bundled rule table under a meta whose list_date is `age_days`
# days in the past, so psl_outdated() has a deterministic, time-controlled
# snapshot to judge. A negative/NA `age_days` records the list_date verbatim.
local_active_dated <- function(age_days) {
  psl_use("bundled")
  stamp <- if (is.na(age_days)) {
    NA_character_
  } else {
    format(Sys.time() - age_days * 86400, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  }
  meta <- psl_meta(source = "bundled", list_date = stamp)
  psl_set_active(active_rules(), meta)
}

test_that("psl_outdated flags a stale snapshot and passes a fresh one", {
  local_pslr_clean()

  local_active_dated(400)
  stale <- psl_outdated()
  expect_true(stale)
  expect_equal(attr(stale, "age_days"), 400, tolerance = 0.01)

  local_active_dated(10)
  fresh <- psl_outdated()
  expect_false(fresh)
  expect_equal(attr(fresh, "age_days"), 10, tolerance = 0.01)

  # A stricter threshold flips a 10-day-old snapshot to outdated.
  expect_true(psl_outdated(max_age = 5))
})

test_that("psl_outdated is NA when the list date is unknown", {
  local_pslr_clean()
  local_active_dated(NA)
  unknown <- psl_outdated()
  expect_true(is.na(unknown))
  expect_type(unknown, "logical")
  expect_true(is.na(attr(unknown, "age_days")))
})

test_that("psl_outdated validates max_age", {
  local_pslr_clean()
  expect_error(psl_outdated(0), "single positive number")
  expect_error(psl_outdated(-1), "single positive number")
  expect_error(psl_outdated(c(30, 60)), "single positive number")
  expect_error(psl_outdated(NA_real_), "single positive number")
  expect_error(psl_outdated("30"), "single positive number")
})

test_that("psl_parse_list_date reads ISO, space, and plain-date forms", {
  ref <- as.POSIXct("2026-06-13 21:47:08", tz = "UTC")
  expect_identical(psl_parse_list_date("2026-06-13T21:47:08Z"), ref)
  expect_identical(psl_parse_list_date("2026-06-13 21:47:08"), ref)
  expect_identical(
    psl_parse_list_date("2026-06-13"),
    as.POSIXct("2026-06-13", tz = "UTC")
  )
  expect_true(is.na(psl_parse_list_date(NA_character_)))
  expect_true(is.na(psl_parse_list_date("not a date")))
})

test_that("canonical_rule keeps wildcard and exception markers", {
  local_pslr_clean()
  r <- psl_rules()
  wild <- r[r$kind == "wildcard", , drop = FALSE]
  exc <- r[r$kind == "exception", , drop = FALSE]
  expect_true(all(startsWith(wild$canonical_rule, "*.")))
  expect_true(all(startsWith(exc$canonical_rule, "!")))
})
