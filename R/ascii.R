# Locale-independent ASCII lowercase. Base R's tolower() follows the session's
# LC_CTYPE, and under a Turkish or Azeri locale on glibc it maps "I" to the
# dotless "ı": the section marker "ICANN" became "ıcann" and the bundled list
# failed to load. Every string pslr lowercases (section names, hex digests,
# header field names, URL schemes and hosts) is ASCII by definition, so only
# A-Z are mapped and anything else passes through unchanged (PSLR-yomylzid).
psl_ascii_lower <- function(x) {
  chartr(paste(LETTERS, collapse = ""), paste(letters, collapse = ""), x)
}
