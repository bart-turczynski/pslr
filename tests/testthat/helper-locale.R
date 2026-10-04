# Locale helpers for tests whose behavior depends on LC_CTYPE.

# Run the rest of the calling test under a UTF-8 LC_CTYPE, or skip it where no
# UTF-8 locale is installed. Invalid-UTF-8 handling only bites under a UTF-8
# ctype: under the C locale every byte is a valid single-byte character, so a
# test of it would pass with or without the fix it guards (PSLR-ejksqarh).
local_utf8_ctype <- function(env = parent.frame()) {
  for (locale in c("C.UTF-8", "en_US.UTF-8", "C.utf8", "en_US.utf8")) {
    active <- suppressWarnings(
      withr::with_locale(c(LC_CTYPE = locale), Sys.getlocale("LC_CTYPE"))
    )
    if (identical(active, locale)) {
      withr::local_locale(c(LC_CTYPE = locale), .local_envir = env)
      return(invisible(locale))
    }
  }
  testthat::skip("no UTF-8 LC_CTYPE locale is available")
}
