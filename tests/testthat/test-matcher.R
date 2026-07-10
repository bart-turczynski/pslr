# Tests for the cpp11 core matcher and the R engine layer (PRD s6, s8.2).

# A small synthetic matcher exercising every rule kind and both sections,
# independent of the bundled snapshot.
synthetic_matcher <- function() {
  keys <- c(
    "com",
    "a.com",
    "co.uk",
    "jp",
    "ck",
    "www.ck", # *.ck + !www.ck
    "kobe.jp",
    "city.kobe.jp", # *.kobe.jp + !city.kobe.jp
    "example.priv" # PRIVATE-only
  )
  kinds <- c(
    "normal",
    "normal",
    "normal",
    "normal",
    "wildcard",
    "exception",
    "wildcard",
    "exception",
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
    host = hosts,
    ps_depth = res$ps_depth,
    kind = res$kind,
    section = res$section,
    stringsAsFactors = FALSE
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
  domain <- c("example.com", "a.b.example.com", "com")
  expect_identical(public_suffix(domain), c("com", "com", "com"))
  expect_identical(
    registrable_domain(domain),
    c("example.com", "example.com", NA_character_)
  )
  expect_identical(public_suffix_rule(domain[1])$kind, "normal")
})

test_that("mixed case and equivalent A-labels give equal ASCII results", {
  a <- registrable_domain("WwW.Example.COM")
  b <- registrable_domain("www.example.com")
  expect_identical(a, b)
  expect_identical(a, "example.com")
})

test_that("Unicode and punycode inputs produce equal ASCII results", {
  u <- public_suffix_rule("食狮.com.cn") # IDN labels
  p <- public_suffix_rule("xn--85x722f.com.cn")
  expect_identical(u$host_ascii, "xn--85x722f.com.cn")
  expect_identical(
    registrable_domain("食狮.com.cn"),
    registrable_domain(p$input)
  )
  expect_identical(u$public_suffix_ascii, "com.cn")
})

test_that("the terminal root dot is preserved on hostname-shaped outputs", {
  expect_identical(public_suffix("example.com."), "com.")
  expect_identical(registrable_domain("example.com."), "example.com.")
  expect_identical(
    public_suffix_rule("example.com.")$host_ascii,
    "example.com."
  )
  expect_identical(public_suffix_rule("example.com.")$rule, "com")
})

test_that("invalid and NA inputs yield NA rows", {
  domain <- c(".com", "a..b", "", NA_character_, "ok.com")
  expect_identical(
    is.na(public_suffix(domain)),
    c(TRUE, TRUE, TRUE, TRUE, FALSE)
  )
  expect_identical(registrable_domain(domain)[5], "ok.com")
})

test_that("zero-length input returns zero-length vectors", {
  expect_length(public_suffix(character(0)), 0L)
  expect_length(registrable_domain(character(0)), 0L)
})

test_that("repeated hosts are deduplicated yet expand to full length", {
  out <- registrable_domain(c(
    "a.example.com",
    "a.example.com",
    "b.example.org"
  ))
  expect_length(out, 3L)
  expect_identical(
    out,
    c("example.com", "example.com", "example.org")
  )
})

test_that("resolving zero cores returns empty, typed match columns", {
  res <- psl_resolve_cores(psl_default_engine(), character(0), "all")
  expect_named(res, psl_cache_cols)
  expect_true(all(vapply(res, length, integer(1)) == 0L))
  expect_type(res$public_suffix, "character")
  expect_type(res$ps_depth, "integer")
})

test_that("the bundled rules rebuild falls back when the source is missing", {
  # When system.file() cannot resolve the shipped .dat (e.g. a stripped
  # install), the rebuild path returns the pinned generated index unchanged.
  testthat::local_mocked_bindings(
    system.file = function(...) "",
    .package = "base"
  )
  expect_identical(rebuild_bundled_rules(), pslr_bundled$rules)
})

# --- snapshot-metadata constructor / validator (PSLR-bnrbjhur) ---------------

test_that("new_psl_meta carries the documented schema, order, and defaults", {
  m <- new_psl_meta()
  expect_named(m, names(psl_meta_fields))
  # Source-identity fields default to typed NA; size is integer NA.
  expect_identical(m$source, NA_character_)
  expect_identical(m$checksum, NA_character_)
  expect_identical(m$size, NA_integer_)
  # Normalization identifiers default to the runtime normalizer.
  expect_identical(m$normalizer, "punycoder")
  expect_identical(
    m$normalizer_version,
    as.character(utils::packageVersion("punycoder"))
  )
  # psl_meta() is the same constructor under its historical name.
  expect_identical(psl_meta(source = "path"), new_psl_meta(source = "path"))
})

test_that("validate_psl_meta accepts a well-formed meta and returns it", {
  m <- new_psl_meta(source = "bundled", size = 10L)
  expect_identical(validate_psl_meta(m), m)
})

test_that("validate_psl_meta rejects a missing or wrong-typed field", {
  m <- new_psl_meta(source = "bundled", size = 10L)

  missing <- m[setdiff(names(m), "checksum")]
  expect_error(validate_psl_meta(missing), "missing required field")

  wrong_type <- m
  wrong_type$size <- "10" # should be integer
  expect_error(validate_psl_meta(wrong_type), "`size` must be a length-1")

  not_scalar <- m
  not_scalar$source <- c("a", "b")
  expect_error(validate_psl_meta(not_scalar), "`source` must be a length-1")
})

test_that("as_psl_version_df derives the documented one-row version frame", {
  m <- new_psl_meta(
    source = "bundled",
    size = 42L,
    checksum = "sha256:abc"
  )
  v <- as_psl_version_df(m)
  expect_s3_class(v, "data.frame")
  expect_identical(nrow(v), 1L)
  expect_named(v, names(psl_meta_fields))
  expect_type(v$size, "integer")
  expect_identical(v$size, 42L)
  expect_identical(v$checksum, "sha256:abc")
  # Byte-identical to feeding the meta through the psl_version_df alias.
  expect_identical(v, psl_version_df(m))
})
