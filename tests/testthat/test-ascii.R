# Tests for psl_ascii_lower() (PSLR-yomylzid).

test_that("only A-Z are lowercased", {
  expect_identical(
    psl_ascii_lower("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
    "abcdefghijklmnopqrstuvwxyz"
  )
  expect_identical(psl_ascii_lower("Sha256:AB-09_z"), "sha256:ab-09_z")
  others <- intToUtf8(c(0xC4, 0x131, 0x130), multiple = TRUE)
  expect_identical(psl_ascii_lower(others), others)
  expect_identical(psl_ascii_lower(c("ICANN", NA)), c("icann", NA))
  expect_identical(psl_ascii_lower(character()), character())
})

test_that("bytes that are not valid UTF-8 pass through unchanged", {
  # A header field name can hold any byte a server sends. chartr() fails on
  # such input with "invalid input multibyte string" under a UTF-8 ctype, so
  # only A-Z are rewritten, byte for byte (PSLR-mlnfdltl).
  local_utf8_ctype()
  invalid <- "X-B\xffD\xfe"
  expect_false(validUTF8(invalid))

  expect_no_condition(lowered <- psl_ascii_lower(c(invalid, "ETag", NA)))
  expect_identical(charToRaw(lowered[[1L]]), charToRaw("x-b\xffd\xfe"))
  expect_identical(lowered[-1L], c("etag", NA))
})

test_that("a string keeps its declared encoding", {
  marked <- intToUtf8(c(0x41, 0xC4, 0x130))
  expect_identical(Encoding(marked), "UTF-8")

  lowered <- psl_ascii_lower(marked)

  expect_identical(Encoding(lowered), "UTF-8")
  expect_identical(lowered, intToUtf8(c(0x61, 0xC4, 0x130)))
})
