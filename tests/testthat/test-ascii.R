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
