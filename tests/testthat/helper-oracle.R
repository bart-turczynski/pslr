# Differential-oracle corpus + runner (PSLR-dmhuazyj, P1 safety net).
#
# This helper is the single source of truth for BOTH:
#   * generating the pinned baseline RDS (fixtures/oracle-baseline.rds), and
#   * the differential-oracle test (test-oracle.R).
# Keeping the corpus and the runner here — deterministic, ASCII-authored via
# intToUtf8() for non-ASCII hosts — means regeneration is byte-stable and the
# test compares the *values* the current code produces against the pinned RDS.
# To regenerate after a *sanctioned* behaviour change: load the package, then
#   saveRDS(oracle_run(oracle_corpus()),
#           testthat::test_path("fixtures", "oracle-baseline.rds"))
#
# The oracle pins whatever the code does TODAY. It must be GREEN on current
# main; P2-P5 (columnar rewrite) prove they did not change behaviour by keeping
# this suite green. Do NOT "improve" any pinned output.

# Non-ASCII host fragments, built from code points so this file stays ASCII
# (matching the convention in test-query.R).
oracle_unicode_fragments <- function() {
  list(
    shi_zi = intToUtf8(c(0x98DFL, 0x72EEL)), # two CJK labels, A-label 85x722f
    zhongguo = intToUtf8(c(0x4E2DL, 0x56FDL)), # China, A-label fiqs8s
    bucher = intToUtf8(c(0x62L, 0x00FCL, 0x63L, 0x68L, 0x65L, 0x72L)), # bücher
    cafe_nfc = intToUtf8(c(0x63L, 0x61L, 0x66L, 0x00E9L)), # precomposed café
    cafe_nfd = intToUtf8(c(0x63L, 0x61L, 0x66L, 0x65L, 0x0301L)) # decomposed
  )
}

# Inputs from the official Mozilla PSL test vectors fixture (reused per the
# ticket). Returns character(0) if the fixture is not resolvable.
oracle_psl_vector_inputs <- function() {
  path <- testthat::test_path("fixtures", "psl-vectors.txt")
  if (!file.exists(path)) {
    return(character(0))
  }
  lines <- trimws(readLines(path, encoding = "UTF-8", warn = FALSE))
  lines <- lines[nzchar(lines) & !startsWith(lines, "//")]
  parts <- strsplit(lines, "[[:space:]]+")
  vapply(parts, `[`, character(1), 1L)
}

# Hand-authored corpus covering every category the ticket enumerates. Kept
# deterministic and order-stable.
oracle_generated_hosts <- function() {
  u <- oracle_unicode_fragments()
  c(
    # --- deep subdomains ---
    "a.b.c.d.e.example.com",
    "one.two.three.four.example.co.uk",
    "deep.sub.domain.github.io",

    # --- wildcard rules (*.ck) ---
    "foo.ck",
    "a.b.ck",
    "sub.example.ck",

    # --- exceptions (!www.ck) ---
    "www.ck",

    # --- wildcard + exception on kobe.jp ---
    "a.b.kobe.jp",
    "city.kobe.jp",

    # --- private-section hosts (github.io, blogspot.com) ---
    "github.io",
    "foo.github.io",
    "a.b.github.io",
    "myblog.blogspot.com",

    # --- unknown TLDs (exercise unknown = "default" vs "na") ---
    "madeuptld",
    "foo.madeuptld",
    "a.b.madeuptld",
    "single",

    # --- root-dot hosts ---
    "example.com.",
    "www.example.co.uk.",
    "com.",
    "foo.github.io.",

    # --- A-label + Unicode spellings of the same host ---
    "xn--85x722f.com.cn",
    paste0(u$shi_zi, ".com.cn"),
    "a.xn--fiqs8s",
    paste0("a.", u$zhongguo),
    "xn--bcher-kva.com",
    paste0(u$bucher, ".com"),
    paste0(u$cafe_nfc, ".com"), # NFC café.com
    paste0(u$cafe_nfd, ".com"), # NFD café.com (canonically equal)

    # --- mixed-case hosts (canonicalization lowercases) ---
    "WWW.Example.COM",
    "EXAMPLE.CO.UK",
    "FoO.GitHub.IO",

    # --- suffixes queried directly ---
    "com",
    "co.uk",
    "uk",
    "jp",
    "kobe.jp",
    "ck",

    # --- invalid: IPv4 literals ---
    "1.2.3.4",
    "255.255.255.255",
    "192.168.0.1",

    # --- invalid: empty / malformed labels ---
    "a..b",
    ".leading",
    "..",
    " ",
    "",

    # --- invalid: IPv6 literal + URL syntax ---
    "[::1]",
    "http://example.com/path",
    "user@example.com",

    # --- missing ---
    NA_character_
  )
}

# The full oracle corpus: official vectors first, then the generated hosts.
# Deliberately unnamed so a named element can never leak into RDS/data.frame
# structure; name preservation is pinned separately in test-oracle.R.
oracle_corpus <- function() {
  unname(c(oracle_psl_vector_inputs(), oracle_generated_hosts()))
}

# The full function x option matrix. Runs all five public functions across
# section x output x unknown (output only where the function accepts it),
# holding invalid = "na" so invalid hosts pin as NA rather than aborting.
# Returns a named list keyed "<fn>|section=..|output=..|unknown=..".
oracle_run <- function(corpus) {
  sections <- c("all", "icann", "private")
  outputs <- c("ascii", "unicode")
  unknowns <- c("default", "na")

  res <- list()
  for (sec in sections) {
    for (unk in unknowns) {
      for (out in outputs) {
        k <- sprintf(
          "public_suffix|section=%s|output=%s|unknown=%s",
          sec,
          out,
          unk
        )
        res[[k]] <- public_suffix(
          corpus,
          section = sec,
          output = out,
          unknown = unk
        )
        k <- sprintf(
          "registrable_domain|section=%s|output=%s|unknown=%s",
          sec,
          out,
          unk
        )
        res[[k]] <- registrable_domain(
          corpus,
          section = sec,
          output = out,
          unknown = unk
        )
        k <- sprintf(
          "suffix_extract|section=%s|output=%s|unknown=%s",
          sec,
          out,
          unk
        )
        res[[k]] <- suffix_extract(
          corpus,
          section = sec,
          output = out,
          unknown = unk
        )
      }
      k <- sprintf("is_public_suffix|section=%s|unknown=%s", sec, unk)
      res[[k]] <- is_public_suffix(corpus, section = sec, unknown = unk)
      k <- sprintf("public_suffix_rule|section=%s|unknown=%s", sec, unk)
      res[[k]] <- public_suffix_rule(corpus, section = sec, unknown = unk)
    }
  }
  res
}
