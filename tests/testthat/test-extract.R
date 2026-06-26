# Data.frame APIs: suffix_extract + public_suffix_rule schema, types, row
# counts, NA propagation, root-dot placement (PRD s7.2, s7.3, s11.1).

ps_extract_cols <- c(
  "input", "host", "subdomain", "domain", "suffix", "registrable_domain"
)
ps_rule_cols <- c(
  "input", "host_ascii", "rule", "kind", "rule_section", "public_suffix_ascii"
)

test_that("suffix_extract has the exact column schema, order, and types", {
  out <- suffix_extract("www.example.co.uk")
  expect_s3_class(out, "data.frame")
  expect_named(out, ps_extract_cols)
  expect_true(all(vapply(out, is.character, logical(1))))
  expect_identical(nrow(out), 1L)
  expect_identical(
    unlist(out[1, ], use.names = FALSE),
    c("www.example.co.uk", "www.example.co.uk", "www", "example",
      "co.uk", "example.co.uk")
  )
})

test_that("suffix_extract subdomain is empty (not NA) when none exists", {
  out <- suffix_extract("example.com")
  expect_identical(out$subdomain, "")
  expect_identical(out$domain, "example")
})

test_that("suffix_extract unicode output keeps empty subdomain as ''", {
  out <- suffix_extract("example.com", output = "unicode")
  expect_identical(out$subdomain, "")
  expect_identical(out$domain, "example")
  expect_identical(out$registrable_domain, "example.com")
})

test_that("suffix_extract unicode output decodes A-labels (IDN path)", {
  # xn--bcher-kva decodes to "bücher"; unicode output round-trips the A-label.
  out <- suffix_extract("www.xn--bcher-kva.com", output = "unicode")
  expect_identical(out$subdomain, "www")
  expect_identical(out$domain, "bücher")
  expect_identical(out$registrable_domain, "bücher.com")
  expect_identical(out$suffix, "com")
})

test_that("suffix_extract NAs derived columns when host is a public suffix", {
  out <- suffix_extract("co.uk")
  expect_identical(out$host, "co.uk")
  expect_identical(out$suffix, "co.uk")
  expect_identical(out$domain, NA_character_)
  expect_identical(out$subdomain, NA_character_)
  expect_identical(out$registrable_domain, NA_character_)
})

test_that("suffix_extract keeps host but NAs the rest for unresolved hosts", {
  out <- suffix_extract("foo.madeuptld", unknown = "na")
  expect_identical(out$host, "foo.madeuptld")
  expect_identical(out$suffix, NA_character_)
  expect_identical(out$domain, NA_character_)
  expect_identical(out$registrable_domain, NA_character_)
})

test_that("suffix_extract NAs host for invalid input but keeps the row", {
  out <- suffix_extract(c("ok.com", "a..b", NA))
  expect_identical(nrow(out), 3L)
  expect_identical(out$input, c("ok.com", "a..b", NA))
  expect_identical(out$host, c("ok.com", NA, NA))
  expect_identical(out$suffix, c("com", NA, NA))
})

test_that("suffix_extract keeps the root dot on host/suffix/registrable", {
  out <- suffix_extract("www.example.com.")
  expect_identical(out$host, "www.example.com.")
  expect_identical(out$suffix, "com.")
  expect_identical(out$registrable_domain, "example.com.")
  expect_identical(out$domain, "example") # label-only, no dot
  expect_identical(out$subdomain, "www") # label-only, no dot
})

test_that("suffix_extract zero-length is a zero-row typed frame", {
  out <- suffix_extract(character(0))
  expect_identical(nrow(out), 0L)
  expect_named(out, ps_extract_cols)
  expect_true(all(vapply(out, is.character, logical(1))))
})

test_that("suffix_extract all-invalid keeps one row per input", {
  out <- suffix_extract(c("a..b", "[::1]"))
  expect_identical(nrow(out), 2L)
  expect_true(all(is.na(out$host)))
})

test_that("suffix_extract does not turn input names into row names", {
  out <- suffix_extract(c(a = "example.com", b = "x.co.uk"))
  expect_identical(row.names(out), c("1", "2"))
})

test_that("public_suffix_rule has the exact column schema, order, and types", {
  out <- public_suffix_rule("www.example.co.uk")
  expect_named(out, ps_rule_cols)
  expect_true(all(vapply(out, is.character, logical(1))))
  expect_identical(
    unlist(out[1, ], use.names = FALSE),
    c("www.example.co.uk", "www.example.co.uk", "co.uk", "normal",
      "icann", "co.uk")
  )
})

test_that("public_suffix_rule reports each rule kind with its markers", {
  out <- public_suffix_rule(c("x.ck", "www.ck", "a.b.kobe.jp", "madeuptld"))
  expect_identical(out$rule, c("*.ck", "!www.ck", "*.kobe.jp", "*"))
  expect_identical(
    out$kind, c("wildcard", "exception", "wildcard", "default")
  )
  expect_identical(out$rule_section, c("icann", "icann", "icann", NA))
  # Exception strips its leftmost label for the suffix but keeps '!' in rule.
  expect_identical(out$public_suffix_ascii[2], "ck")
})

test_that("public_suffix_rule keeps host_ascii but NAs rule for unresolved", {
  out <- public_suffix_rule(c("example.com", "foo.madeuptld"), unknown = "na")
  expect_identical(out$host_ascii, c("example.com", "foo.madeuptld"))
  expect_identical(out$rule, c("com", NA))
  expect_identical(out$kind, c("normal", NA))
  expect_identical(out$public_suffix_ascii, c("com", NA))
})

test_that("public_suffix_rule zero-length and all-invalid row counts", {
  z <- public_suffix_rule(character(0))
  expect_identical(nrow(z), 0L)
  expect_named(z, ps_rule_cols)
  inv <- public_suffix_rule(c("a..b", "[::1]"))
  expect_identical(nrow(inv), 2L)
  expect_true(all(is.na(inv$rule)))
})
