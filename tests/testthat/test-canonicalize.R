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
