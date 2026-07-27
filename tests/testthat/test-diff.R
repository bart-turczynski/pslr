# `psl_diff()` compares two materialized snapshots (PSLR-aeuaykkf). Every test
# here is offline: no test installs a transport, and the one test that resolves
# `"cache"` publishes the bytes itself into a private cache directory.

# A complete PSL with chosen ICANN and PRIVATE rules, written to a temp file.
# Unlike `write_test_list()` this fixes neither section, because a diff has to
# be able to move a rule between them.
write_diff_list <- function(icann = "com", private = "example.com") {
  path <- tempfile("pslr-diff-", fileext = ".dat")
  writeLines(
    c(
      "// ===BEGIN ICANN DOMAINS===",
      icann,
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      private,
      "// ===END PRIVATE DOMAINS==="
    ),
    path
  )
  path
}

# The diff of two lists that differ only in their PRIVATE section, as a compact
# `identity=change` vector -- the shape most assertions here want.
diff_private <- function(old, new) {
  d <- psl_diff(
    write_diff_list(private = old),
    write_diff_list(private = new)
  )
  stats::setNames(d$change, d$rule)
}

# The columns and types every result carries, in order.
diff_schema <- c(
  change = "character",
  rule = "character",
  old_rule = "character",
  new_rule = "character",
  old_kind = "character",
  new_kind = "character",
  old_section = "character",
  new_section = "character"
)

expect_diff_schema <- function(d) {
  expect_named(d, names(diff_schema))
  expect_equal(vapply(d, class, character(1L)), diff_schema)
}

# ---------------------------------------------------------------------------
# Change classification
# ---------------------------------------------------------------------------

test_that("psl_diff() reports added, removed, and unchanged identities", {
  expect_equal(
    diff_private(c("a.example.com", "b.example.com"), "b.example.com"),
    c(a.example.com = "removed")
  )
  expect_equal(
    diff_private("b.example.com", c("b.example.com", "c.example.com")),
    c(c.example.com = "added")
  )
})

test_that("psl_diff() reports a rule kind change as one `changed` row", {
  d <- psl_diff(
    write_diff_list(private = "*.b.example.com"),
    write_diff_list(private = "b.example.com")
  )
  expect_equal(d$rule, "b.example.com")
  expect_equal(d$change, "changed")
  expect_equal(d$old_rule, "*.b.example.com")
  expect_equal(d$new_rule, "b.example.com")
  expect_equal(d$old_kind, "wildcard")
  expect_equal(d$new_kind, "normal")
})

test_that("psl_diff() reports every rule-kind transition", {
  expect_equal(
    diff_private("*.b.example.com", "!b.example.com"),
    c(b.example.com = "changed")
  )
  expect_equal(
    diff_private("!b.example.com", "b.example.com"),
    c(b.example.com = "changed")
  )
})

test_that("psl_diff() reports an ICANN/PRIVATE move as one `changed` row", {
  d <- psl_diff(
    write_diff_list(icann = c("com", "moved.com"), private = "example.com"),
    write_diff_list(icann = "com", private = c("example.com", "moved.com"))
  )
  expect_equal(d$rule, "moved.com")
  expect_equal(d$change, "changed")
  expect_equal(d$old_section, "icann")
  expect_equal(d$new_section, "private")
  expect_equal(d$old_kind, d$new_kind)
})

test_that("psl_diff() leaves the side an identity is absent from as NA", {
  d <- psl_diff(
    write_diff_list(private = "gone.example.com"),
    write_diff_list(private = "new.example.com")
  )
  removed <- d[d$change == "removed", ]
  added <- d[d$change == "added", ]
  expect_equal(
    unlist(
      removed[c("new_rule", "new_kind", "new_section")],
      use.names = FALSE
    ),
    rep(NA_character_, 3L)
  )
  expect_equal(
    unlist(added[c("old_rule", "old_kind", "old_section")], use.names = FALSE),
    rep(NA_character_, 3L)
  )
})

# ---------------------------------------------------------------------------
# Canonical, not textual
# ---------------------------------------------------------------------------

test_that("psl_diff() ignores comments, blank lines, and source order", {
  old <- tempfile(fileext = ".dat")
  writeLines(
    c(
      "// ===BEGIN ICANN DOMAINS===",
      "// a comment",
      "com",
      "",
      "co.uk",
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      "example.com",
      "// ===END PRIVATE DOMAINS==="
    ),
    old
  )
  expect_equal(
    nrow(psl_diff(old, write_diff_list(icann = c("co.uk", "com")))),
    0L
  )
})

test_that("psl_diff() ignores letter case and raw Unicode spelling", {
  expect_length(diff_private("BÜCHER.example.com", "bücher.example.com"), 0L)
  expect_length(
    diff_private("bücher.example.com", "xn--bcher-kva.example.com"),
    0L
  )
})

# ---------------------------------------------------------------------------
# Identical snapshots and ordering
# ---------------------------------------------------------------------------

test_that("psl_diff() of agreeing snapshots is a typed zero-row frame", {
  d <- psl_diff("bundled", "bundled")
  expect_s3_class(d, "data.frame")
  expect_equal(nrow(d), 0L)
  expect_diff_schema(d)
})

test_that("psl_diff() keeps the full schema on a non-empty result", {
  expect_diff_schema(psl_diff(
    write_diff_list(private = "a.example.com"),
    write_diff_list(private = "b.example.com")
  ))
})

test_that("psl_diff() orders rows by logical identity, not by change", {
  d <- diff_private(
    c("b.example.com", "d.example.com"),
    c("a.example.com", "c.example.com")
  )
  expect_named(
    d,
    c("a.example.com", "b.example.com", "c.example.com", "d.example.com")
  )
  # The order is a radix sort, so it does not depend on the collation locale.
  withr::with_collate(
    "C",
    expect_named(
      diff_private("A.example.com", "b.example.com"),
      c("a.example.com", "b.example.com")
    )
  )
})

test_that("psl_diff() row names are the default sequence", {
  d <- psl_diff(
    write_diff_list(private = "a.example.com"),
    write_diff_list(private = c("b.example.com", "c.example.com"))
  )
  expect_equal(rownames(d), c("1", "2", "3"))
})

# ---------------------------------------------------------------------------
# Input forms
# ---------------------------------------------------------------------------

test_that("psl_diff() accepts \"bundled\" on either side", {
  bundled <- system.file("extdata", "public_suffix_list.dat", package = "pslr")
  expect_equal(nrow(psl_diff("bundled", bundled)), 0L)
  expect_equal(nrow(psl_diff(bundled, "bundled")), 0L)
})

test_that("psl_diff() accepts a psl_engine on either side", {
  path <- write_diff_list(private = "a.example.com")
  engine <- psl_engine("path", path = path)
  expect_equal(nrow(psl_diff(engine, path)), 0L)
  expect_equal(
    psl_diff(engine, psl_engine("bundled"))$change[[1L]],
    "added"
  )
})

test_that("psl_diff() accepts a psl_rules() table on either side", {
  # The bundled rule table reproduces the bundled snapshot exactly, so a table
  # input is held to the same canonicalization as a parsed file.
  expect_equal(nrow(psl_diff(psl_rules(), "bundled")), 0L)
  expect_equal(nrow(psl_diff("bundled", psl_rules())), 0L)
})

test_that("psl_diff() canonicalizes a hand-built rule table", {
  # Mixed case and a Unicode spelling of the same two rules `write_diff_list()`
  # writes: canonicalization has to make the two sides agree exactly.
  table <- data.frame(
    rule = c("COM", "Bücher.example.com"),
    canonical_rule = c("COM", "Bücher.example.com"),
    kind = "normal",
    section = c("icann", "private"),
    labels = c(1L, 3L),
    stringsAsFactors = FALSE
  )
  expect_equal(
    nrow(psl_diff(table, write_diff_list(private = "bücher.example.com"))),
    0L
  )
})

test_that("psl_diff() treats an empty rule table as an empty snapshot", {
  d <- psl_diff(psl_rules()[0L, ], write_diff_list())
  expect_equal(sort(d$rule), c("com", "example.com"))
  expect_equal(unique(d$change), "added")
})

test_that("psl_diff() deduplicates repeated rules in a rule table", {
  duplicated <- psl_rules()[c(1L, 1L, 2L), ]
  once <- psl_rules()[c(1L, 2L), ]
  expect_warning(d <- psl_diff(duplicated, once), "duplicate rule")
  expect_equal(nrow(d), 0L)
})

test_that("psl_diff() accepts the cache and does not activate it", {
  local_pslr_clean()
  path <- write_diff_list(private = "cached.example.com")
  checksum <- psl_with_publish_lock(psl_publish_snapshot(path))$checksum
  psl_with_publish_lock(psl_publish_selection(checksum))

  before <- psl_version()$checksum
  d <- psl_diff("bundled", "cache")
  expect_equal(psl_version()$checksum, before)
  expect_equal(attr(d, "new_version")$checksum, checksum)
  expect_true("cached.example.com" %in% d$rule)
})

# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------

test_that("psl_diff() attaches a psl_version() row per resolved snapshot", {
  path <- write_diff_list(private = "a.example.com")
  d <- psl_diff("bundled", path)
  expect_named(attr(d, "old_version"), names(psl_version()))
  expect_equal(attr(d, "old_version")$source, "bundled")
  expect_equal(attr(d, "new_version")$source, "path")
  expect_equal(attr(d, "new_version")$path, normalizePath(path))
})

test_that("psl_diff() reports a rule table as unknown provenance", {
  d <- psl_diff(psl_rules(), "bundled")
  expect_null(attr(d, "old_version"))
  expect_equal(attr(d, "new_version")$source, "bundled")
})

# ---------------------------------------------------------------------------
# Session isolation and offline behavior
# ---------------------------------------------------------------------------

test_that("psl_diff() never changes the active engine", {
  local_pslr_clean()
  psl_use("bundled")
  active <- psl_default_engine()
  psl_diff(
    write_diff_list(private = "a.example.com"),
    write_diff_list(private = "b.example.com")
  )
  expect_identical(psl_default_engine(), active)
})

test_that("psl_diff() makes no request", {
  # A transport that aborts on use: reaching it at all is the failure.
  withr::local_options(
    pslr.transport = function(request) stop("psl_diff() made a request")
  )
  expect_equal(nrow(psl_diff("bundled", "bundled")), 0L)
})

# ---------------------------------------------------------------------------
# Invalid inputs
# ---------------------------------------------------------------------------

test_that("psl_diff() rejects unsupported input types", {
  # One message naming every accepted form, whatever the unsupported value was.
  forms <- paste0(
    'must be "bundled", "cache", a path to a PSL source file, a ',
    "`psl_engine`, or a rule table with the `psl_rules\\(\\)` schema."
  )
  expect_error(psl_diff(1L, "bundled"), forms)
  expect_error(psl_diff("bundled", NULL), forms)
  expect_error(psl_diff(c("bundled", "cache"), "bundled"), forms)
  expect_error(psl_diff(NA_character_, "bundled"), forms)
  expect_error(psl_diff(list("bundled"), "bundled"), forms)
})

test_that("psl_diff() rejects a path that does not exist", {
  expect_error(
    psl_diff("no-such-list.dat", "bundled"),
    "neither \"bundled\", \"cache\", nor an existing PSL source file"
  )
})

test_that("psl_diff() reports which side was invalid", {
  expect_error(psl_diff("bundled", "no-such-list.dat"), "^`new`")
  expect_error(psl_diff("no-such-list.dat", "bundled"), "^`old`")
})

test_that("psl_diff() rejects a rule table missing psl_rules() columns", {
  expect_error(
    psl_diff(psl_rules()[c("rule", "kind")], "bundled"),
    "missing the `psl_rules\\(\\)` column\\(s\\): canonical_rule, section"
  )
})

test_that("psl_diff() rejects unsupported rule-table column values", {
  expect_error(
    psl_diff(transform(psl_rules()[1L, ], kind = "sometimes"), "bundled"),
    "column `kind` has the unsupported value \"sometimes\""
  )
  expect_error(
    psl_diff(transform(psl_rules()[1L, ], section = "other"), "bundled"),
    "column `section` has the unsupported value \"other\""
  )
  expect_error(
    psl_diff(
      transform(psl_rules()[1L, ], canonical_rule = NA_character_),
      "bundled"
    ),
    "column `canonical_rule` must be a character vector with no `NA`"
  )
})

test_that("psl_diff() rejects a rule kind its canonical text contradicts", {
  # `kind` decides which marker is stripped to recover the logical identity, so
  # a table where the two disagree would silently key rows on the wrong labels.
  expect_error(
    psl_diff(transform(psl_rules()[1L, ], kind = "wildcard"), "bundled"),
    "does not match its `kind` \"wildcard\""
  )
  expect_error(
    psl_diff(transform(psl_rules()[1L, ], canonical_rule = "!!"), "bundled"),
    "row 1 has `canonical_rule` \"!!\", which does not match its `kind`"
  )
})

test_that("psl_diff() rejects rule text that cannot be canonicalized", {
  table <- transform(psl_rules()[1L, ], canonical_rule = "exa mple.com")
  expect_error(psl_diff(table, "bundled"), "could not be canonicalized")
})

test_that("psl_diff() rejects a source file that is not a complete PSL", {
  icann_only <- tempfile(fileext = ".dat")
  writeLines(
    c("// ===BEGIN ICANN DOMAINS===", "com", "// ===END ICANN DOMAINS==="),
    icann_only
  )
  expect_error(psl_diff(icann_only, "bundled"), "ICANN and a PRIVATE section")

  sectionless <- tempfile(fileext = ".dat")
  writeLines("com", sectionless)
  expect_error(psl_diff(sectionless, "bundled"), "outside any ICANN or PRIVATE")
})

test_that("psl_diff() rejects unexpected arguments", {
  expect_error(
    psl_diff("bundled", "bundled", verbose = TRUE),
    "Unexpected argument\\(s\\): verbose"
  )
})

# ---------------------------------------------------------------------------
# Cross-section duplicates
# ---------------------------------------------------------------------------

test_that("psl_diff() collapses the same labels in both sections", {
  both <- write_diff_list(
    icann = c("com", "shared.com"),
    private = c("example.com", "shared.com")
  )
  d <- psl_diff(both, write_diff_list(icann = "com"))
  shared <- d[d$rule == "shared.com", ]
  expect_equal(nrow(shared), 1L)
  expect_equal(shared$change, "removed")
  expect_equal(shared$old_section, "icann, private")
  expect_equal(shared$old_rule, "shared.com, shared.com")
})
