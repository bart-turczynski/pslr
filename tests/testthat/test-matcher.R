# Tests for the cpp11 core matcher and the R engine layer (PRD s6, s8.2).

# A small synthetic matcher exercising every rule kind and both sections,
# independent of the bundled snapshot.
synthetic_matcher <- function() {
  keys <- c(
    "com", "a.com", "co.uk", "jp",
    "ck", "www.ck",          # *.ck + !www.ck
    "kobe.jp", "city.kobe.jp", # *.kobe.jp + !city.kobe.jp
    "example.priv"           # PRIVATE-only
  )
  kinds <- c(
    "normal", "normal", "normal", "normal",
    "wildcard", "exception",
    "wildcard", "exception",
    "normal"
  )
  sections <- c(0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 1L)
  psl_build_matcher(keys, kinds, sections)
}

# Convenience: match canonical hosts and return a tidy data frame of the raw
# (ps_depth, kind, section) the C++ layer produced.
core_match <- function(m, hosts, section = "all") {
  res <- psl_match(m, hosts, psl_section_code(section))
  data.frame(
    host = hosts, ps_depth = res$ps_depth, kind = res$kind,
    section = res$section, stringsAsFactors = FALSE
  )
}

test_that("a normal rule matches equal labels; longest rule prevails", {
  m <- synthetic_matcher()
  out <- core_match(m, c("com", "foo.com", "x.a.com"))
  # x.a.com matches both 'com' and 'a.com'; the longer 'a.com' (depth 2) wins.
  expect_identical(out$ps_depth, c(1L, 1L, 2L))
  expect_identical(out$kind, c(0L, 0L, 0L))
  expect_identical(out$section, c(0L, 0L, 0L))
})

test_that("an unknown label falls through to the implicit default '*' rule", {
  m <- synthetic_matcher()
  out <- core_match(m, c("madeuptld", "foo.madeuptld"))
  expect_identical(out$ps_depth, c(1L, 1L))
  expect_identical(out$kind, c(3L, 3L)) # default
  expect_identical(out$section, c(NA_integer_, NA_integer_))
})

test_that("a wildcard matches one leftmost label and implies no parent rule", {
  m <- synthetic_matcher()
  out <- core_match(m, c("test.ck", "b.test.ck", "ck"))
  # *.ck makes test.ck a public suffix (depth 2); 'ck' itself is NOT implied,
  # so it falls through to the default rule.
  expect_identical(out$ps_depth, c(2L, 2L, 1L))
  expect_identical(out$kind, c(1L, 1L, 3L))
})

test_that("an exception rule takes precedence and strips its leftmost label", {
  m <- synthetic_matcher()
  out <- core_match(m, c("www.ck", "city.kobe.jp", "a.city.kobe.jp"))
  # !www.ck -> public suffix 'ck' (depth 1); !city.kobe.jp -> 'kobe.jp' (2).
  expect_identical(out$ps_depth, c(1L, 2L, 2L))
  expect_identical(out$kind, c(2L, 2L, 2L))
})

test_that("section filtering happens before prevailing-rule selection", {
  m <- synthetic_matcher()
  host <- "x.example.priv"
  expect_identical(core_match(m, host, "private")$ps_depth, 2L) # explicit rule
  expect_identical(core_match(m, host, "all")$ps_depth, 2L)
  # No ICANN rule -> falls through to the default '*' rule, not the PRIVATE one.
  icann <- core_match(m, host, "icann")
  expect_identical(icann$ps_depth, 1L)
  expect_identical(icann$kind, 3L)
})

# ---- engine layer: normalization, terminal dot, IDN, NA --------------------

test_that("the engine resolves suffix and registrable domain (bundled)", {
  out <- psl_match_hosts(c("example.com", "a.b.example.com", "com"))
  expect_identical(out$public_suffix, c("com", "com", "com"))
  expect_identical(
    out$registrable_domain,
    c("example.com", "example.com", NA_character_)
  )
  expect_identical(out$kind[1], "normal")
})

test_that("mixed case and equivalent A-labels give equal ASCII results", {
  a <- psl_match_hosts("WwW.Example.COM")
  b <- psl_match_hosts("www.example.com")
  expect_identical(a$registrable_domain, b$registrable_domain)
  expect_identical(a$registrable_domain, "example.com")
})

test_that("Unicode and punycode inputs produce equal ASCII results", {
  u <- psl_match_hosts("食狮.com.cn") # IDN labels
  p <- psl_match_hosts("xn--85x722f.com.cn")
  expect_identical(u$host, "xn--85x722f.com.cn")
  expect_identical(u$registrable_domain, p$registrable_domain)
  expect_identical(u$public_suffix, "com.cn")
})

test_that("the terminal root dot is preserved on hostname-shaped outputs", {
  out <- psl_match_hosts("example.com.")
  expect_identical(out$host, "example.com.")
  expect_identical(out$public_suffix, "com.")
  expect_identical(out$registrable_domain, "example.com.")
  expect_identical(out$rule, "com") # rule text stays canonical, no dot
})

test_that("invalid and NA inputs yield NA rows", {
  out <- psl_match_hosts(c(".com", "a..b", "", NA_character_, "ok.com"))
  expect_identical(is.na(out$public_suffix), c(TRUE, TRUE, TRUE, TRUE, FALSE))
  expect_identical(out$registrable_domain[5], "ok.com")
})

test_that("zero-length input returns zero-length vectors", {
  out <- psl_match_hosts(character(0))
  expect_length(out$public_suffix, 0L)
  expect_length(out$registrable_domain, 0L)
})

test_that("repeated hosts are deduplicated yet expand to full length", {
  out <- psl_match_hosts(c("a.example.com", "a.example.com", "b.example.org"))
  expect_length(out$registrable_domain, 3L)
  expect_identical(
    out$registrable_domain,
    c("example.com", "example.com", "example.org")
  )
})
