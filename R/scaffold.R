#' Report that the scaffold is ready
#'
#' A placeholder shipped with the package scaffold so there is an exported,
#' documented, and tested function from the very first commit. It returns `TRUE`
#' only when both the compiled `cpp11` engine and the `punycoder` dependency
#' respond, which proves the full toolchain (LinkingTo, registration,
#' dynamic-library load, and the imported normalizer) is wired. The real public
#' API (see `docs/PRD.md` s7) replaces it in later phases.
#'
#' @return A single logical value, `TRUE` when the engine and `punycoder` are
#'   both reachable.
#'
#' @examples
#' scaffold_ready()
#'
#' @importFrom punycoder puny_encode
#' @export
scaffold_ready <- function() {
  # "muenchen" with U+00FC; built from code points to keep this file ASCII.
  muenchen <- intToUtf8(c(109L, 252L, 110L, 99L, 104L, 101L, 110L))
  identical(pslr_engine_id(), "pslr-cpp11-scaffold") &&
    identical(puny_encode(muenchen), "xn--mnchen-3ya")
}
