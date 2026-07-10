# Tests for the PSL-format parser (PRD s8.1, s11.1).

psl_cols <- c(
  "line",
  "raw",
  "section",
  "kind",
  "canonical_rule",
  "canonical_key",
  "labels"
)

# Wrap rule bodies in the two official sections so fixtures stay compact.
psl_doc <- function(icann = character(0), private = character(0)) {
  c(
    "// ===BEGIN ICANN DOMAINS===",
    icann,
    "// ===END ICANN DOMAINS===",
    "// ===BEGIN PRIVATE DOMAINS===",
    private,
    "// ===END PRIVATE DOMAINS==="
  )
}

test_that("parses normal, wildcard, and exception rules", {
  rules <- parse_psl_lines(psl_doc(
    icann = c("com", "*.kawasaki.jp", "!city.kawasaki.jp"),
    private = "googleapis.com"
  ))

  expect_s3_class(rules, "data.frame")
  expect_identical(nrow(rules), 4L)
  expect_named(rules, psl_cols)

  expect_identical(rules$kind, c("normal", "wildcard", "exception", "normal"))
  expect_identical(rules$section, c("icann", "icann", "icann", "private"))
  expect_identical(
    rules$canonical_rule,
    c("com", "*.kawasaki.jp", "!city.kawasaki.jp", "googleapis.com")
  )
  expect_identical(
    rules$canonical_key,
    c("com", "kawasaki.jp", "city.kawasaki.jp", "googleapis.com")
  )
  # Depth includes the wildcard label; '!' is not a label.
  expect_identical(rules$labels, c(1L, 3L, 3L, 2L))
})

test_that("rule content is read only up to the first whitespace", {
  rules <- parse_psl_lines(psl_doc(icann = "com // trailing comment ignored"))
  expect_identical(rules$canonical_rule, "com")
  expect_identical(rules$raw, "com")
})

test_that("comments, blank lines, and indented lines produce no rules", {
  rules <- parse_psl_lines(psl_doc(
    icann = c(
      "// a full line comment",
      "",
      "   ",
      "  indented-is-not-a-rule",
      "com"
    )
  ))
  expect_identical(rules$canonical_rule, "com")
})

test_that("preallocated storage matches explicit construction", {
  # Guards the schema single-source-of-truth refactor: the finalized frame must
  # match a hand-written data.frame in column names, order, and types.
  rules <- parse_psl_lines(psl_doc(
    icann = c("com", "*.kawasaki.jp"),
    private = "!city.kawasaki.jp"
  ))
  expected <- data.frame(
    line = c(2L, 3L, 6L),
    raw = c("com", "*.kawasaki.jp", "!city.kawasaki.jp"),
    section = c("icann", "icann", "private"),
    kind = c("normal", "wildcard", "exception"),
    canonical_rule = c("com", "*.kawasaki.jp", "!city.kawasaki.jp"),
    canonical_key = c("com", "kawasaki.jp", "city.kawasaki.jp"),
    labels = c(1L, 3L, 3L),
    stringsAsFactors = FALSE
  )
  expect_identical(rules, expected)
})

test_that("zero-rule input yields the empty typed frame", {
  empty <- parse_psl_lines(character(0))
  expect_identical(empty, parse_psl_lines(psl_doc()))
  expect_named(empty, psl_cols)
  expect_identical(nrow(empty), 0L)
  expect_type(empty$line, "integer")
  expect_type(empty$labels, "integer")
  expect_type(empty$raw, "character")
})

test_that("source order and line numbers are preserved", {
  rules <- parse_psl_lines(psl_doc(icann = c("", "com", "", "net")))
  expect_identical(rules$canonical_rule, c("com", "net"))
  expect_identical(rules$line, c(3L, 5L))
})

test_that("IDN literal rules canonicalize to A-labels", {
  rules <- parse_psl_lines(psl_doc(icann = c("中国", "*.中国")))
  expect_identical(rules$canonical_key, c("xn--fiqs8s", "xn--fiqs8s"))
  expect_identical(rules$canonical_rule, c("xn--fiqs8s", "*.xn--fiqs8s"))
  expect_identical(rules$kind, c("normal", "wildcard"))
})

test_that("the same rule may appear once per section (no dedup here)", {
  rules <- parse_psl_lines(psl_doc(icann = "example", private = "example"))
  expect_identical(nrow(rules), 2L)
  expect_identical(rules$section, c("icann", "private"))
})

test_that("empty and section-only input yields a typed zero-row table", {
  expect_identical(nrow(parse_psl_lines(character(0))), 0L)
  empty <- parse_psl_lines(psl_doc())
  expect_identical(nrow(empty), 0L)
  expect_named(empty, psl_cols)
  expect_type(empty$labels, "integer")
})

# ---- structural / grammar errors -------------------------------------------

test_that("malformed and mismatched section markers are rejected", {
  expect_error(
    parse_psl_lines(c(
      "// ===BEGIN ICANN DOMAINS===",
      "com",
      "// ===END PRIVATE DOMAINS==="
    )),
    class = "pslr_parse_error"
  )
  # A marker-like typo.
  expect_error(
    parse_psl_lines(c(
      "// ===BEGIN COFFEE DOMAINS===",
      "com",
      "// ===END COFFEE DOMAINS==="
    )),
    class = "pslr_parse_error"
  )
  # Nested BEGIN.
  expect_error(
    parse_psl_lines(c(
      "// ===BEGIN ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS==="
    )),
    class = "pslr_parse_error"
  )
  # END with no open section.
  expect_error(
    parse_psl_lines("// ===END ICANN DOMAINS==="),
    class = "pslr_parse_error"
  )
  # Section never closed.
  expect_error(
    parse_psl_lines(c("// ===BEGIN ICANN DOMAINS===", "com")),
    class = "pslr_parse_error"
  )
})

test_that("rules outside any section are rejected", {
  expect_error(parse_psl_lines("com"), class = "pslr_parse_error")
})

test_that("a repeated ICANN or PRIVATE section is rejected", {
  # Two complete ICANN sections: each is well-formed on its own, but the
  # official format carries exactly one of each (PRD s8.1).
  expect_error(
    parse_psl_lines(c(
      "// ===BEGIN ICANN DOMAINS===",
      "com",
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN ICANN DOMAINS===",
      "net",
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      "github.io",
      "// ===END PRIVATE DOMAINS==="
    )),
    "appears more than once"
  )
  # A repeated PRIVATE section is rejected the same way.
  expect_error(
    parse_psl_lines(c(
      "// ===BEGIN ICANN DOMAINS===",
      "com",
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      "github.io",
      "// ===END PRIVATE DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      "example.com",
      "// ===END PRIVATE DOMAINS==="
    )),
    "appears more than once"
  )
})

test_that("the abort condition carries the offending line number", {
  err <- tryCatch(
    parse_psl_lines(c(
      "// ===BEGIN ICANN DOMAINS===",
      "a..b",
      "// ===END ICANN DOMAINS==="
    )),
    pslr_parse_error = function(e) e
  )
  expect_identical(err$line, 2L)
})

test_that("invalid wildcard placement is rejected", {
  for (rule in c("a.*.b", "*.*.jp", "fo*o.jp", "*")) {
    expect_error(
      parse_psl_lines(psl_doc(icann = rule)),
      class = "pslr_parse_error",
      info = rule
    )
  }
})

test_that("invalid exception markers are rejected", {
  for (rule in c("!", "a!b", "!*.foo")) {
    expect_error(
      parse_psl_lines(psl_doc(icann = rule)),
      class = "pslr_parse_error",
      info = rule
    )
  }
})

test_that("empty labels are rejected", {
  for (rule in c("a..b", ".foo", "foo.")) {
    expect_error(
      parse_psl_lines(psl_doc(icann = rule)),
      class = "pslr_parse_error",
      info = rule
    )
  }
})

test_that("rules that fail canonicalization are rejected", {
  # Structurally valid but rejected by the STD3/IDNA contract.
  expect_error(
    parse_psl_lines(psl_doc(icann = "_under.example")),
    class = "pslr_parse_error"
  )
})

test_that("invalid UTF-8 source is rejected", {
  bad <- c(
    "// ===BEGIN ICANN DOMAINS===",
    rawToChar(as.raw(c(0x63, 0xff, 0x6d))),
    "// ===END ICANN DOMAINS==="
  )
  expect_error(parse_psl_lines(bad), class = "pslr_parse_error")
})

test_that("non-character / NA line input is rejected", {
  expect_error(
    parse_psl_lines(c("com", NA_character_)),
    class = "pslr_parse_error"
  )
})

test_that("validating an empty line vector is a no-op", {
  # parse_psl_lines() returns before validating, so exercise the guard directly.
  expect_null(psl_validate_source_lines(character(0)))
})

# ---- file reader ------------------------------------------------------------

test_that("read_psl_file reads UTF-8 and delegates to the line parser", {
  path <- tempfile(fileext = ".dat")
  on.exit(unlink(path), add = TRUE)
  writeLines(psl_doc(icann = c("com", "*.kawasaki.jp")), path, useBytes = TRUE)
  rules <- read_psl_file(path)
  expect_identical(rules$canonical_rule, c("com", "*.kawasaki.jp"))
})

test_that("read_psl_file rejects a missing path and bad path argument", {
  expect_error(read_psl_file(tempfile()), class = "pslr_parse_error")
  expect_error(read_psl_file(c("a", "b")), class = "pslr_parse_error")
  expect_error(read_psl_file(NA_character_), class = "pslr_parse_error")
})
