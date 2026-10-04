# Locale-independent ASCII lowercase. Base R's tolower() follows the session's
# LC_CTYPE, and under a Turkish or Azeri locale on glibc it maps "I" to the
# dotless "ı": the section marker "ICANN" became "ıcann" and the bundled list
# failed to load. Every string pslr lowercases (section names, hex digests,
# header field names, URL schemes and hosts) is ASCII by definition, so only
# A-Z are mapped and anything else passes through unchanged (PSLR-yomylzid).
#
# Strings that are valid UTF-8 go through one vectorized chartr(), which
# assumes a UTF-8 or single-byte session (in a non-UTF-8 multibyte session
# such as Shift-JIS it can still fail on non-ASCII text). The rest are mapped
# byte by byte: parsed PSL directives and freshness-schema values can hold
# bytes that are not valid UTF-8, and chartr() fails on them with "invalid
# input multibyte string". Every byte of a non-ASCII UTF-8 or Latin-1
# character is 0x80 or above, so rewriting the bytes of A-Z alone leaves every
# other character intact, and a byte-mapped result keeps its input's declared
# encoding (PSLR-mlnfdltl).
psl_ascii_lower <- function(x) {
  if (!is.character(x)) {
    x <- as.character(x)
  }
  fast <- validUTF8(x) & Encoding(x) != "bytes"
  x[fast] <- chartr(
    paste(LETTERS, collapse = ""),
    paste(letters, collapse = ""),
    x[fast]
  )
  slow <- !fast & !is.na(x)
  x[slow] <- vapply(x[slow], psl_ascii_lower_one, character(1))
  x
}

psl_ascii_lower_one <- function(s) {
  bytes <- as.integer(charToRaw(s))
  upper <- bytes >= 65L & bytes <= 90L
  bytes[upper] <- bytes[upper] + 32L
  out <- rawToChar(as.raw(bytes))
  Encoding(out) <- Encoding(s)
  out
}

# `x` with each element that is not valid UTF-8 reduced to ASCII, every byte
# at or above 0x80 written as `<xx>`. The bytes are read as Latin-1, where each
# one is a character, so the result is the same whatever the session's
# encoding. Header bytes come from the server, and trimws() and the regex
# functions fail on such input under a UTF-8 ctype. Valid UTF-8 and NA pass
# through unchanged. psl_curl_reason() writes bytes in the same `<xx>`
# notation but escapes valid non-ASCII UTF-8 too, which suits a message that
# is only matched against ASCII keywords and never kept (PSLR-mlnfdltl).
psl_escape_invalid_utf8 <- function(x) {
  bad <- !is.na(x) & !validUTF8(x)
  x[bad] <- iconv(x[bad], from = "latin1", to = "ASCII", sub = "byte")
  x
}
