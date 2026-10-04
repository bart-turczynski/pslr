# Locale-independent ASCII lowercase. Base R's tolower() follows the session's
# LC_CTYPE, and under a Turkish or Azeri locale on glibc it maps "I" to the
# dotless "ı": the section marker "ICANN" became "ıcann" and the bundled list
# failed to load. Every string pslr lowercases (section names, hex digests,
# header field names, URL schemes and hosts) is ASCII by definition, so only
# A-Z are mapped and anything else passes through unchanged (PSLR-yomylzid).
#
# The mapping works on bytes, not characters: a header field name holds
# whatever bytes the server sent, and chartr() fails with "invalid input
# multibyte string" on bytes that are not valid in the session's encoding.
# Every byte of a non-ASCII UTF-8 or Latin-1 character is 0x80 or above, so
# rewriting the bytes of A-Z alone leaves every other character intact, and
# each result keeps its input's declared encoding (PSLR-mlnfdltl).
psl_ascii_lower <- function(x) {
  keep <- !is.na(x)
  x[keep] <- vapply(x[keep], psl_ascii_lower_one, character(1))
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

# `x` with each element that is not valid UTF-8 reduced to ASCII, every other
# byte written as `<xx>`, the form psl_curl_reason() gives libcurl messages.
# Header bytes come from the server, and trimws(), the regex functions and
# curl::parse_headers_list() all fail on such input under a UTF-8 ctype. Valid
# UTF-8 and NA pass through unchanged (PSLR-mlnfdltl).
psl_escape_invalid_utf8 <- function(x) {
  bad <- !is.na(x) & !validUTF8(x)
  x[bad] <- iconv(x[bad], from = "latin1", to = "ASCII", sub = "byte")
  x
}
