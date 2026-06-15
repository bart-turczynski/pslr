# Tests for the duplicate / conflict policy (PRD s8.1, s11.1).

# Build a parsed rule table directly so these tests are independent of the
# parser's source-line handling; mirrors the columns parse_psl_lines() emits.
make_rules <- function(...) {
  rows <- list(...)
  data.frame(
    line = vapply(rows, `[[`, integer(1), "line"),
    raw = vapply(rows, `[[`, character(1), "raw"),
    section = vapply(rows, `[[`, character(1), "section"),
    kind = vapply(rows, `[[`, character(1), "kind"),
    canonical_rule = vapply(rows, `[[`, character(1), "canonical_rule"),
    canonical_key = vapply(rows, `[[`, character(1), "canonical_key"),
    labels = vapply(rows, `[[`, integer(1), "labels"),
    stringsAsFactors = FALSE
  )
}

rule <- function(line, section, kind, canonical_rule, canonical_key, labels) {
  list(
    line = as.integer(line), raw = canonical_rule, section = section,
    kind = kind, canonical_rule = canonical_rule, canonical_key = canonical_key,
    labels = as.integer(labels)
  )
}

normal <- function(line, section, host) {
  rule(line, section, "normal", host, host, lengths(strsplit(host, ".", TRUE)))
}

test_that("a clean rule set is returned unchanged in both modes", {
  rules <- make_rules(
    normal(2, "icann", "com"),
    normal(3, "icann", "net"),
    normal(6, "private", "googleapis.com")
  )
  expect_identical(apply_duplicate_policy(rules, "strict"), rules)
  expect_identical(apply_duplicate_policy(rules, "lenient"), rules)
})

test_that("the same rule may appear once per section", {
  rules <- make_rules(
    normal(2, "icann", "example"),
    normal(5, "private", "example")
  )
  expect_silent(out <- apply_duplicate_policy(rules, "strict"))
  expect_identical(nrow(out), 2L)
})

test_that("strict mode rejects exact same-section duplicates", {
  rules <- make_rules(
    normal(2, "icann", "com"),
    normal(4, "icann", "com")
  )
  expect_error(
    apply_duplicate_policy(rules, "strict"),
    class = "pslr_parse_error"
  )
})

test_that("lenient mode warns once and keeps the first occurrence", {
  rules <- make_rules(
    normal(2, "icann", "com"),
    normal(4, "icann", "com"),
    normal(7, "icann", "net"),
    normal(9, "icann", "net")
  )
  expect_warning(
    out <- apply_duplicate_policy(rules, "lenient"),
    "dropped 2 duplicate"
  )
  expect_identical(out$canonical_rule, c("com", "net"))
  # First source occurrences are retained.
  expect_identical(out$line, c(2L, 7L))
  expect_identical(rownames(out), c("1", "2"))
})

test_that("conflicting rule kinds for the same labels are fatal in all modes", {
  # 'com' as both a normal rule and a wildcard parent share canonical_key 'com'.
  rules <- make_rules(
    normal(2, "icann", "com"),
    rule(3, "icann", "wildcard", "*.com", "com", 2)
  )
  expect_error(
    apply_duplicate_policy(rules, "strict"),
    class = "pslr_parse_error"
  )
  expect_error(
    apply_duplicate_policy(rules, "lenient"),
    class = "pslr_parse_error"
  )
})

test_that("conflict detection is per-section, not cross-section", {
  # Same labels, different kinds, but in different sections -> not a conflict.
  rules <- make_rules(
    normal(2, "icann", "com"),
    rule(6, "private", "wildcard", "*.com", "com", 2)
  )
  expect_silent(out <- apply_duplicate_policy(rules, "strict"))
  expect_identical(nrow(out), 2L)
})

test_that("wildcard and exception with distinct keys do not conflict", {
  # The real-list pattern: *.ck (key 'ck') and !www.ck (key 'www.ck').
  rules <- make_rules(
    rule(2, "icann", "wildcard", "*.ck", "ck", 2),
    rule(3, "icann", "exception", "!www.ck", "www.ck", 2)
  )
  expect_silent(out <- apply_duplicate_policy(rules, "strict"))
  expect_identical(nrow(out), 2L)
})

test_that("conflict is reported before deduplication", {
  # A set containing both a conflict and an exact duplicate errors on the
  # conflict regardless of mode.
  rules <- make_rules(
    normal(2, "icann", "com"),
    rule(3, "icann", "wildcard", "*.com", "com", 2),
    normal(5, "icann", "net"),
    normal(7, "icann", "net")
  )
  expect_error(
    apply_duplicate_policy(rules, "lenient"),
    class = "pslr_parse_error"
  )
})

test_that("the conflict error carries the first offending line", {
  rules <- make_rules(
    normal(2, "icann", "com"),
    rule(4, "icann", "wildcard", "*.com", "com", 2)
  )
  err <- tryCatch(
    apply_duplicate_policy(rules, "strict"),
    pslr_parse_error = function(e) e
  )
  expect_identical(err$line, 2L)
})

test_that("zero-row input is returned unchanged", {
  empty <- parse_psl_lines(character(0))
  expect_identical(apply_duplicate_policy(empty, "strict"), empty)
  expect_identical(apply_duplicate_policy(empty, "lenient"), empty)
})

test_that("it integrates with the parser output", {
  lines <- c(
    "// ===BEGIN ICANN DOMAINS===",
    "com",
    "com",
    "// ===END ICANN DOMAINS===",
    "// ===BEGIN PRIVATE DOMAINS===",
    "com",
    "// ===END PRIVATE DOMAINS==="
  )
  parsed <- parse_psl_lines(lines)
  expect_identical(nrow(parsed), 3L)
  # Strict rejects the same-section duplicate; the cross-section one is fine.
  expect_error(
    apply_duplicate_policy(parsed, "strict"),
    class = "pslr_parse_error"
  )
  expect_warning(out <- apply_duplicate_policy(parsed, "lenient"))
  expect_identical(out$section, c("icann", "private"))
})
