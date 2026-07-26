# Input contract + canonicalization layer (PRD s5).

test_that("NA is missing, not invalid", {
  canon <- psl_canonicalize(c("example.com", NA, ""), invalid = "na")
  expect_identical(canon$status, c("ok", "na", "invalid"))
  # invalid = "error" ignores the NA and aborts only on the "" element.
  expect_error(
    psl_canonicalize(c("example.com", NA, ""), invalid = "error"),
    "position 3"
  )
})

test_that("the documented invalid host shapes are rejected", {
  bad <- c(
    "",
    "   ",
    ".com",
    "a..b",
    "a.b..",
    "example.com..",
    "http://example.com",
    "user@example.com",
    "example.com:80",
    "example.com/path",
    "[::1]",
    "::1",
    "a b.com",
    "foo_bar.com"
  )
  status <- psl_canonicalize(bad, invalid = "na")$status
  expect_true(all(status == "invalid"))
})

test_that("canonical dotted-decimal IPv4 literals are invalid", {
  ipv4 <- psl_canonicalize(
    c("1.2.3.4", "1.2.3.4.", "0.0.0.0", "255.255.255.255")
  )
  expect_true(all(ipv4$status == "invalid"))
})

test_that("non-canonical or non-IPv4 dotted forms stay valid hostnames", {
  # 999 > 255, a leading zero, and a 5th label each fail the literal predicate
  # and continue through ordinary hostname validation.
  ok <- psl_canonicalize(c("999.1.1.1", "01.2.3.4", "1.2.3.4.example"))
  expect_true(all(ok$status == "ok"))
})

test_that("the terminal root dot is recorded and stripped from the core", {
  canon <- psl_canonicalize(c("example.com.", "example.com"))
  expect_identical(canon$had_dot, c(TRUE, FALSE))
  expect_identical(canon$host, c("example.com.", "example.com"))
  expect_identical(canon$core, c("example.com", "example.com"))
})

test_that("mixed case, U-labels, A-labels canonicalize to lowercase ASCII", {
  canon <- psl_canonicalize(c("WwW.Example.COM", "food.com.cn"))
  expect_identical(canon$core[1], "www.example.com")
  u <- psl_canonicalize("食狮.com.cn")$core # IDN labels
  a <- psl_canonicalize("xn--85x722f.com.cn")$core
  expect_identical(u, a)
})

test_that("non-character domain aborts regardless of length", {
  expect_error(psl_canonicalize(1:3), "must be a character vector")
  # Zero-length non-character is still a type error, not an empty result.
  expect_error(psl_canonicalize(numeric(0)), "must be a character vector")
  expect_error(psl_canonicalize(NULL), "must be a character vector")
  # The valid empty character vector passes through.
  expect_identical(psl_canonicalize(character(0))$status, character(0))
})

test_that("invalid = \"error\" reports the first invalid one-based index", {
  expect_error(
    psl_canonicalize(c("ok.com", "ok.org", "[::1]"), invalid = "error"),
    "position 3"
  )
})

test_that("the error-message helper renders NA and truncates long values", {
  # An NA element collapses to the literal "NA" rather than propagating.
  expect_identical(trunc_for_msg(NA_character_), "NA")
  # A short value is echoed verbatim; a value over 60 chars is truncated.
  expect_identical(trunc_for_msg("short.example"), "short.example")
  long <- strrep("a", 70L)
  expect_identical(trunc_for_msg(long), paste0(substr(long, 1L, 60L), "..."))
})

test_that("invalid = \"error\" truncates a pathological host in the message", {
  # A >60-char invalid host must not dump an unbounded string into the abort.
  long_bad <- paste0(strrep("_", 70L), ".example") # underscores are invalid
  expect_error(
    psl_canonicalize(long_bad, invalid = "error"),
    "\\.\\.\\.$" # the truncation ellipsis closes the message
  )
})

test_that("an all-missing vector skips the IPv4-literal scan", {
  # is_ipv4_literal short-circuits when no element is present.
  expect_identical(
    is_ipv4_literal(c(NA_character_, NA_character_)),
    c(FALSE, FALSE)
  )
  canon <- psl_canonicalize(c(NA_character_, NA_character_))
  expect_identical(canon$status, c("na", "na"))
})

test_that("aborting on invalid hosts is a no-op when none are invalid", {
  expect_null(psl_abort_invalid_host("ok.com", FALSE))
})

# Encoding resolution (PSLR-jzdhhugc). Hosts are built from explicit UTF-8
# bytes rather than source literals so the fixtures mean the same thing in any
# locale -- a literal in this file would itself be reinterpreted.
utf8_host <- function() {
  # "www.bucher.de" with U+00FC in place of the first "u".
  bytes <- as.raw(c(
    0x77,
    0x77,
    0x77,
    0x2e,
    0x62,
    0xc3,
    0xbc,
    0x63,
    0x68,
    0x65,
    0x72,
    0x2e,
    0x64,
    0x65
  ))
  rawToChar(bytes)
}

test_that("an unmarked UTF-8 host canonicalizes like a marked one", {
  unmarked <- utf8_host()
  marked <- unmarked
  Encoding(marked) <- "UTF-8"
  # Same bytes, different declared encoding: the answer must not depend on it.
  expect_identical(Encoding(unmarked), "unknown")
  expect_identical(
    psl_canonicalize(unmarked)$host,
    psl_canonicalize(marked)$host
  )
  expect_identical(psl_canonicalize(unmarked)$status, "ok")
})

test_that("psl_declare_utf8 marks non-ASCII and leaves ASCII alone", {
  marked <- psl_declare_utf8(c("example.com", utf8_host(), NA_character_))
  expect_identical(Encoding(marked), c("unknown", "UTF-8", "unknown"))
  # Already-marked input is returned untouched.
  already <- utf8_host()
  Encoding(already) <- "UTF-8"
  expect_identical(psl_declare_utf8(already), already)
})

test_that("undecodable bytes are invalid input, not an error", {
  # A lone 0xFC is valid Latin-1 but not valid UTF-8.
  undecodable <- rawToChar(as.raw(c(0x62, 0xfc, 0x2e, 0x64, 0x65)))
  expect_false(validUTF8(undecodable))
  canon <- psl_canonicalize(undecodable)
  expect_identical(canon$status, "invalid")
  expect_identical(canon$host, NA_character_)
  # It is malformed input, not absent input, so `invalid = "error"` aborts.
  expect_error(
    psl_canonicalize(undecodable, invalid = "error"),
    "Invalid host at position 1"
  )
})

test_that("trunc_for_msg renders undecodable bytes as a fixed stand-in", {
  # nchar()/substr() abort on such a string, and the raw bytes would render
  # differently per locale.
  undecodable <- rawToChar(as.raw(c(0x62, 0xfc)))
  expect_identical(trunc_for_msg(undecodable), "<undecodable bytes>")
})
