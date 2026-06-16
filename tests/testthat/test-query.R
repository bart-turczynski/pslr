# Public query API: core functions, section/unknown/output/invalid matrix,
# terminal dot, IDN equality, NA/zero-length handling (PRD s6, s7.1, s11.1).

test_that("public_suffix and registrable_domain resolve normal rules", {
  expect_identical(public_suffix("www.example.com"), "com")
  expect_identical(public_suffix("a.b.example.co.uk"), "co.uk")
  expect_identical(registrable_domain("www.example.com"), "example.com")
  expect_identical(registrable_domain("a.b.example.co.uk"), "example.co.uk")
})

test_that("wildcard, exception, and default rules behave per spec", {
  expect_identical(public_suffix("x.ck"), "x.ck") # *.ck
  expect_identical(public_suffix("www.ck"), "ck") # !www.ck exception
  expect_identical(public_suffix("a.b.kobe.jp"), "b.kobe.jp") # wildcard
  expect_identical(public_suffix("city.kobe.jp"), "kobe.jp") # exception
  expect_identical(public_suffix("madeuptld"), "madeuptld") # implicit default
})

test_that("section filters before prevailing-rule selection", {
  # foo.github.io: PRIVATE rule github.io, but ICANN only sees 'io'.
  expect_identical(public_suffix("foo.github.io", section = "all"), "github.io")
  expect_identical(public_suffix("foo.github.io", section = "icann"), "io")
  expect_identical(
    public_suffix("foo.github.io", section = "private"), "github.io"
  )
  # An ICANN host under section = "private" falls through to the default rule.
  expect_identical(public_suffix("example.com", section = "private"), "com")
  expect_identical(
    public_suffix("example.com", section = "private", unknown = "na"),
    NA_character_
  )
})

test_that("unknown policy toggles the implicit default rule", {
  expect_identical(public_suffix("madeuptld", unknown = "na"), NA_character_)
  expect_identical(registrable_domain("foo.madeuptld"), "foo.madeuptld")
  expect_identical(
    registrable_domain("foo.madeuptld", unknown = "na"), NA_character_
  )
  expect_identical(registrable_domain("madeuptld"), NA_character_)
})

# Non-ASCII fixtures are built from code points to keep this file ASCII.
shi_zi <- intToUtf8(c(0x98DFL, 0x72EEL)) # two CJK labels, A-label xn--85x722f
zhongguo <- intToUtf8(c(0x4E2DL, 0x56FDL)) # "China", A-label xn--fiqs8s
cafe_nfc <- intToUtf8(c(0x63L, 0x61L, 0x66L, 0x00E9L)) # precomposed e-acute
cafe_nfd <- intToUtf8(c(0x63L, 0x61L, 0x66L, 0x65L, 0x0301L)) # decomposed

test_that("output = unicode decodes A-labels; ascii is the default", {
  expect_identical(public_suffix("xn--85x722f.com.cn"), "com.cn")
  expect_identical(
    public_suffix("a.xn--fiqs8s", output = "unicode"), zhongguo
  )
  # U-label input, unicode output round-trips to the original script.
  expect_identical(
    registrable_domain(paste0(shi_zi, ".com.cn"), output = "unicode"),
    paste0(shi_zi, ".com.cn")
  )
})

test_that("the terminal root dot is preserved on hostname-shaped outputs", {
  expect_identical(public_suffix("example.com."), "com.")
  expect_identical(registrable_domain("www.example.com."), "example.com.")
  expect_identical(public_suffix("example.com.", output = "unicode"), "com.")
})

test_that("U-label, A-label, and NFC-equivalent inputs give equal ASCII", {
  expect_identical(
    public_suffix(paste0(shi_zi, ".com.cn")),
    public_suffix("xn--85x722f.com.cn")
  )
  # NFC: precomposed e-acute vs decomposed e + combining acute accent.
  nfc <- paste0(cafe_nfc, ".com")
  nfd <- paste0(cafe_nfd, ".com")
  expect_identical(registrable_domain(nfc), registrable_domain(nfd))
  expect_identical(registrable_domain(nfc), "xn--caf-dma.com")
})

test_that("is_public_suffix is TRUE exactly when host equals its suffix", {
  expect_true(is_public_suffix("com"))
  expect_true(is_public_suffix("co.uk"))
  expect_false(is_public_suffix("example.com"))
  expect_true(is_public_suffix("madeuptld")) # implicit default rule
  expect_identical(is_public_suffix("madeuptld", unknown = "na"), NA)
  expect_identical(is_public_suffix(c(NA, "a..b", "ok.com")), c(NA, NA, FALSE))
})

test_that("invalid policy returns NA by default and aborts on error", {
  out <- public_suffix(c("ok.com", "1.2.3.4", "[::1]", "a..b", NA))
  expect_identical(out, c("com", NA, NA, NA, NA))
  expect_error(
    public_suffix(c("ok.com", "1.2.3.4"), invalid = "error"), "position 2"
  )
  # invalid never suppresses programming errors.
  expect_error(public_suffix("ok.com", section = "nope"), "must be one of")
  expect_error(
    public_suffix("ok.com", output = c("ascii", "unicode", "x")),
    "must be one of"
  )
})

test_that("explicit non-scalar option aborts even when equal to the default", {
  # Repro: passing the full default vector explicitly must not be mistaken for
  # the untouched default; option arguments must be scalar (PRD s5.2).
  expect_error(
    public_suffix("ok.com", invalid = c("na", "error")), "must be one of"
  )
  expect_error(
    public_suffix("ok.com", section = c("all", "icann", "private")),
    "must be one of"
  )
  expect_error(
    registrable_domain("ok.com", output = c("ascii", "unicode")),
    "must be one of"
  )
  expect_error(
    is_public_suffix("ok.com", unknown = c("default", "na")), "must be one of"
  )
  expect_error(
    public_suffix_rule("ok.com", section = c("all", "icann", "private")),
    "must be one of"
  )
})

test_that("omitted options use their first choice as the default", {
  # The untouched default must still resolve, across every wrapper and option.
  expect_identical(public_suffix("example.com"), "com")
  expect_identical(registrable_domain("www.example.co.uk"), "example.co.uk")
  expect_identical(is_public_suffix("com"), TRUE)
  expect_identical(public_suffix_rule("example.com")$rule, "com")
})

test_that("vector functions are length-preserving and name-preserving", {
  x <- c(a = "example.com", b = "x.co.uk", c = NA)
  ps <- public_suffix(x)
  expect_length(ps, 3L)
  expect_identical(names(ps), c("a", "b", "c"))
  expect_identical(unname(ps), c("com", "co.uk", NA))
  expect_named(is_public_suffix(x), c("a", "b", "c"))
})

test_that("attributes other than names are dropped", {
  x <- structure(c("example.com", "x.co.uk"), class = "weird", extra = 1)
  out <- public_suffix(x)
  expect_null(attr(out, "extra"))
  expect_null(attr(out, "class"))
})

test_that("zero-length input returns a zero-length typed vector", {
  expect_identical(public_suffix(character(0)), character(0))
  expect_identical(registrable_domain(character(0)), character(0))
  expect_identical(is_public_suffix(character(0)), logical(0))
})

test_that("zero-length non-character input is a type error, not empty output", {
  expect_error(public_suffix(numeric(0)), "must be a character vector")
  expect_error(registrable_domain(integer(0)), "must be a character vector")
  expect_error(is_public_suffix(NULL), "must be a character vector")
  expect_error(suffix_extract(numeric(0)), "must be a character vector")
  expect_error(public_suffix_rule(logical(0)), "must be a character vector")
})
