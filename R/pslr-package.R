#' @keywords internal
#' @seealso
#' Core queries: [public_suffix()], [registrable_domain()],
#' [is_public_suffix()], [suffix_extract()], [public_suffix_rule()].
#' List management and provenance: [psl_use()], [psl_refresh()],
#' [psl_version()], [psl_rules()].
#'
#' The `introduction` vignette is a full tour:
#' `vignette("introduction", package = "pslr")`.
#' @examples
#' # The two core queries: public suffix (eTLD) and registrable domain (eTLD+1).
#' public_suffix("www.example.co.uk")
#' registrable_domain("www.example.co.uk")
#'
#' # Every query is vectorized over a character vector of hostnames.
#' suffix_extract(c("shop.example.com", "www.example.co.uk"))
#'
#' # Rule sections are selected explicitly, so a private registry only widens
#' # the answer when you ask it to.
#' public_suffix("mysite.blogspot.com", section = "icann")
#' public_suffix("mysite.blogspot.com", section = "private")
#'
#' # Hosts are canonicalized before matching; A-labels in, Unicode back out.
#' registrable_domain("www.xn--bcher-kva.de", output = "unicode")
#'
#' # Which rule decided the answer, and which list produced it.
#' public_suffix_rule("www.example.co.uk")
#' psl_version()[, c("source", "list_date", "unicode_version")]
"_PACKAGE"

#' @useDynLib pslr, .registration = TRUE
## usethis namespace: start
## usethis namespace: end
NULL

# Direct `library(pslr)` attachment is the only moment pslr evaluates freshness
# on its own, and it does so offline, at most once per session, and only when
# the user opted in with `psl_reminder(enable = TRUE)`. Loading the namespace
# alone -- `pslr::public_suffix()` -- deliberately has no hook at all, so an
# importing package never inherits another package's startup message.
.onAttach <- function(libname, pkgname) {
  psl_reminder_attach()
}
