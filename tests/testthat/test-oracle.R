# Differential oracle + shape pins (PSLR-dmhuazyj, P1 safety net).
#
# The heavy test ("current outputs match the pinned baseline") replays the full
# function x option matrix (see helper-oracle.R) over a broad host corpus and
# compares byte-for-byte against a checked-in RDS. Its whole purpose is to give
# P2-P5 (the columnar rewrite) a fixed reference: if any pinned value changes,
# the rewrite changed observable behaviour and must justify it (and regenerate).
#
# The shape pins below lock the frame/vector contracts (PRD s7.1 name
# preservation, s7.2 zero-length / all-invalid shapes) that are easy to break in
# a columnar rewrite. They overlap intentionally with test-query.R /
# test-extract.R but are gathered here as an explicit rewrite safety net.

# ---------------------------------------------------------------------------
# 1. Differential oracle: pinned baseline
# ---------------------------------------------------------------------------

test_that("the oracle corpus covers every ticket category and is stable", {
  corpus <- oracle_corpus()
  # Order-stable, includes the official vectors + generated hosts, plus one NA.
  expect_gt(length(corpus), 80L)
  expect_true(anyNA(corpus))
  expect_null(names(corpus)) # unnamed so RDS/data.frame shape stays clean
  # A few representative anchors from each category must be present.
  expect_true(all(
    c(
      "a.b.c.d.e.example.com", # deep subdomain
      "foo.ck", # wildcard rule on the ck suffix
      "www.ck", # exception !www.ck
      "foo.github.io", # private section
      "foo.madeuptld", # unknown TLD
      "example.com.", # root dot
      "xn--85x722f.com.cn", # A-label
      "1.2.3.4", # IPv4 literal (invalid)
      "a..b", # empty label (invalid)
      "[::1]" # IPv6 literal (invalid)
    ) %in%
      corpus
  ))
})

test_that("the option matrix spans all five functions and every option", {
  res <- oracle_run(oracle_corpus())
  # 3 sections x 2 unknown x (2 output x 3 output-taking fns + 2 non-output fns)
  #   = 6 x (6 + 2) = 48 pinned results.
  expect_length(res, 48L)
  fns <- sub("\\|.*$", "", names(res))
  expect_identical(
    sort(unique(fns)),
    sort(c(
      "public_suffix",
      "registrable_domain",
      "is_public_suffix",
      "suffix_extract",
      "public_suffix_rule"
    ))
  )
  # Output-taking functions get 12 combos each; the two non-output ones get 6.
  expect_identical(sum(fns == "public_suffix"), 12L)
  expect_identical(sum(fns == "registrable_domain"), 12L)
  expect_identical(sum(fns == "suffix_extract"), 12L)
  expect_identical(sum(fns == "is_public_suffix"), 6L)
  expect_identical(sum(fns == "public_suffix_rule"), 6L)
})

test_that("current outputs match the pinned baseline (byte-identical)", {
  path <- test_path("fixtures", "oracle-baseline.rds")
  skip_if(
    !file.exists(path),
    "oracle baseline RDS not generated; see helper-oracle.R"
  )
  baseline <- readRDS(path)
  current <- oracle_run(oracle_corpus())

  # Same keys, same order: a drift in the matrix itself is a failure.
  expect_identical(names(current), names(baseline))

  # Every pinned result must be identical (values, types, names, frame shape).
  for (key in names(baseline)) {
    expect_identical(current[[key]], baseline[[key]], info = key)
  }
})

# ---------------------------------------------------------------------------
# 2. Shape pins: name preservation (PRD s7.1)
# ---------------------------------------------------------------------------

test_that("vector functions flow input names through to the output", {
  x <- c(a = "www.example.com", b = "x.co.uk", c = "madeuptld", d = NA)
  for (fn in list(public_suffix, registrable_domain, is_public_suffix)) {
    out <- fn(x)
    expect_length(out, 4L)
    expect_named(out, c("a", "b", "c", "d"))
  }
  # Names survive across the section/output/unknown options too.
  expect_named(
    public_suffix(x, section = "icann", output = "unicode", unknown = "na"),
    c("a", "b", "c", "d")
  )
  expect_named(registrable_domain(x, unknown = "na"), c("a", "b", "c", "d"))
  expect_named(is_public_suffix(x, section = "private"), c("a", "b", "c", "d"))
})

test_that("frame functions never turn input names into row names", {
  x <- c(a = "www.example.com", b = "x.co.uk", c = NA)
  ex <- suffix_extract(x)
  expect_identical(row.names(ex), c("1", "2", "3"))
  expect_null(names(ex$input))
  expect_identical(ex$input, c("www.example.com", "x.co.uk", NA))

  ru <- public_suffix_rule(x)
  expect_identical(row.names(ru), c("1", "2", "3"))
  expect_null(names(ru$input))
  expect_identical(ru$input, c("www.example.com", "x.co.uk", NA))
})

# ---------------------------------------------------------------------------
# 3. Shape pins: zero-length + all-invalid frame shapes (PRD s7.2)
# ---------------------------------------------------------------------------

oracle_extract_cols <- c(
  "input",
  "host",
  "subdomain",
  "domain",
  "suffix",
  "registrable_domain"
)
oracle_rule_cols <- c(
  "input",
  "host_ascii",
  "rule",
  "kind",
  "rule_section",
  "public_suffix_ascii"
)

test_that("zero-length input returns typed, zero-length / zero-row results", {
  expect_identical(public_suffix(character(0)), character(0))
  expect_identical(registrable_domain(character(0)), character(0))
  expect_identical(is_public_suffix(character(0)), logical(0))

  ex <- suffix_extract(character(0))
  expect_s3_class(ex, "data.frame")
  expect_identical(nrow(ex), 0L)
  expect_named(ex, oracle_extract_cols)
  expect_true(all(vapply(ex, is.character, logical(1))))

  ru <- public_suffix_rule(character(0))
  expect_s3_class(ru, "data.frame")
  expect_identical(nrow(ru), 0L)
  expect_named(ru, oracle_rule_cols)
  expect_true(all(vapply(ru, is.character, logical(1))))
})

test_that("all-invalid input keeps one row per input with NA derived columns", {
  bad <- c("a..b", "[::1]", "1.2.3.4", "")

  ex <- suffix_extract(bad)
  expect_identical(nrow(ex), length(bad))
  expect_identical(ex$input, bad)
  expect_true(all(is.na(ex$host)))
  expect_true(all(is.na(ex$suffix)))
  expect_true(all(is.na(ex$registrable_domain)))

  ru <- public_suffix_rule(bad)
  expect_identical(nrow(ru), length(bad))
  expect_identical(ru$input, bad)
  expect_true(all(is.na(ru$host_ascii)))
  expect_true(all(is.na(ru$rule)))
  expect_true(all(is.na(ru$public_suffix_ascii)))

  # Vector functions likewise return all-NA (typed) for all-invalid input.
  expect_identical(public_suffix(bad), rep(NA_character_, length(bad)))
  expect_identical(registrable_domain(bad), rep(NA_character_, length(bad)))
  expect_identical(is_public_suffix(bad), rep(NA, length(bad)))
})
