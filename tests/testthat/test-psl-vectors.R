# Official Public Suffix List test vectors (PRD s11.1).
#
# The fixture tests/testthat/fixtures/psl-vectors.txt is the upstream CC0
# tests.txt, pinned in lockstep with the bundled snapshot by data-raw. Each
# active line is "<input> <expected>", where <expected> is the registrable
# domain (eTLD+1) or "null" when there is none. Comments start with "//".
#
# We match the bundled list and compare ASCII registrable domains: the engine
# returns ASCII, and each expected value is normalized to ASCII so Unicode and
# punycoded vector blocks are compared on equal footing.

# Element-wise equality treating NA == NA as a match.
identical_na <- function(a, b) {
  (is.na(a) & is.na(b)) | (!is.na(a) & !is.na(b) & a == b)
}

read_psl_vectors <- function() {
  path <- test_path("fixtures", "psl-vectors.txt")
  skip_if(!file.exists(path), "PSL vectors fixture not installed")

  lines <- trimws(readLines(path, encoding = "UTF-8", warn = FALSE))
  lines <- lines[nzchar(lines) & !startsWith(lines, "//")]
  parts <- strsplit(lines, "[[:space:]]+")

  input <- vapply(parts, `[`, character(1), 1L)
  expected_raw <- vapply(parts, `[`, character(1), 2L)
  expected <- ifelse(expected_raw == "null", NA_character_, expected_raw)
  data.frame(input = input, expected = expected, stringsAsFactors = FALSE)
}

test_that("the official PSL test vectors fixture is present and parsable", {
  vec <- read_psl_vectors()
  expect_gt(nrow(vec), 40L)
  expect_false(anyNA(vec$input))
})

test_that("all official PSL test vectors pass on the bundled snapshot", {
  vec <- read_psl_vectors()

  expected_ascii <- ifelse(
    is.na(vec$expected),
    NA_character_,
    punycoder::host_normalize(vec$expected)
  )
  got <- psl_match_hosts(vec$input)$registrable_domain

  mismatch <- which(!identical_na(got, expected_ascii))
  if (length(mismatch)) {
    report <- sprintf(
      "  %s -> got %s, expected %s",
      vec$input[mismatch],
      ifelse(is.na(got[mismatch]), "null", got[mismatch]),
      ifelse(is.na(expected_ascii[mismatch]), "null", expected_ascii[mismatch])
    )
    fail(paste0(
      length(mismatch), " vector(s) failed:\n", paste(report, collapse = "\n")
    ))
  } else {
    succeed()
  }
})

test_that("default ICANN+PRIVATE section is what the official vectors assume", {
  # The upstream vectors are defined for the combined list; the default section
  # is "all", so an explicit section = "all" must give the same results.
  vec <- read_psl_vectors()
  default <- psl_match_hosts(vec$input)$registrable_domain
  all_sec <- psl_match_hosts(vec$input, section = "all")$registrable_domain
  expect_identical(default, all_sec)
})
