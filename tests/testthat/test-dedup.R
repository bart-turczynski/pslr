# Canonical-host deduplication: a repeated host must cost a single normalization
# (punycoder) and a single C++ match call regardless of multiplicity, while
# still returning one result per input element (PRD s8.2, s11.4).

# Count the elements passed across the two expensive crossings -- the punycoder
# canonicalization and the cpp11 matcher -- during `expr`, by wrapping the live
# bindings. Restores them afterwards. Returns list(norm =, match =).
count_crossings <- function(expr) {
  counts <- new.env(parent = emptyenv())
  counts$norm <- 0L
  counts$match <- 0L
  pkg_ns <- asNamespace("pslr")
  puny_ns <- asNamespace("punycoder")
  orig_match <- get("psl_match", envir = pkg_ns)
  orig_norm <- get("host_normalize", envir = puny_ns)

  withr::defer({
    assign("psl_match", orig_match, envir = pkg_ns)
    assign("host_normalize", orig_norm, envir = puny_ns)
    lockBinding("psl_match", pkg_ns)
    lockBinding("host_normalize", puny_ns)
  })

  unlockBinding("psl_match", pkg_ns)
  unlockBinding("host_normalize", puny_ns)
  assign("psl_match", function(ptr, hosts, section) {
    counts$match <- counts$match + length(hosts)
    orig_match(ptr, hosts, section)
  }, envir = pkg_ns)
  assign("host_normalize", function(x, ...) {
    counts$norm <- counts$norm + length(x)
    orig_norm(x, ...)
  }, envir = puny_ns)

  force(expr)
  list(norm = counts$norm, match = counts$match)
}

test_that("a repeated host is normalized and matched exactly once", {
  local_pslr_clean()
  n <- 1000L
  c <- count_crossings(out <- public_suffix(rep("www.example.co.uk", n)))

  expect_identical(c$norm, 1L)
  expect_identical(c$match, 1L)
  # ...but every input element still gets its own result.
  expect_identical(out, rep("co.uk", n))
})

test_that("dedup collapses to the number of distinct hosts, not inputs", {
  local_pslr_clean()
  hosts <- c("a.example.com", "b.co.uk", "x.kobe.jp")
  c <- count_crossings(out <- public_suffix(rep(hosts, 500L)))

  expect_identical(c$norm, length(hosts))
  expect_identical(c$match, length(hosts))
  # x.kobe.jp matches the *.kobe.jp wildcard, so it is its own public suffix.
  expect_identical(out, rep(c("com", "co.uk", "x.kobe.jp"), 500L))
})

test_that("distinct inputs that canonicalize equal share one match call", {
  local_pslr_clean()
  # Mixed-case and Unicode/A-label spellings collapse to one canonical host, so
  # the matcher is crossed once even though normalization sees each spelling.
  inputs <- c("EXAMPLE.CO.UK", "example.co.uk", "Example.Co.Uk")
  c <- count_crossings(out <- public_suffix(inputs))

  expect_identical(c$norm, length(inputs)) # distinct raw spellings
  expect_identical(c$match, 1L) # one canonical host
  expect_identical(out, rep("co.uk", length(inputs)))
})
