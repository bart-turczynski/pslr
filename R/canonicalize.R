# Input contract and canonicalization layer (PRD s5).
#
# Turns a user `domain` vector into per-element canonical lowercase ASCII hosts
# plus a status (`ok` / `na` / `invalid`), recording the single terminal root
# dot so it can be restored on hostname-shaped outputs. Normalization and label
# validation are delegated to the required `punycoder` contract; this layer adds
# the IPv4-literal rejection and the missing-vs-invalid distinction the query
# API needs, and enforces the `invalid = c("na", "error")` policy.

# Truncate a single input for an error message so a pathological value cannot
# dump an unbounded string into the condition (PRD s9).
trunc_for_msg <- function(s) {
  if (is.na(s)) {
    return("NA")
  }
  if (nchar(s) > 60L) paste0(substr(s, 1L, 60L), "...") else s
}

# Canonical dotted-decimal IPv4 literal predicate (PRD s5.2). Applies to the
# whole element after removing at most one terminal root dot: exactly four
# dot-separated decimal components, each written without leading zeros (except
# "0") and valued 0-255. Non-canonical forms such as "01.2.3.4" or "999.1.1.1"
# are not literals and continue through ordinary hostname validation.
is_ipv4_literal <- function(x) {
  out <- rep(FALSE, length(x))
  present <- !is.na(x)
  if (!any(present)) {
    return(out)
  }
  s <- sub("\\.$", "", x[present])
  shaped <- grepl("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", s)
  res <- rep(FALSE, length(s))
  if (any(shaped)) {
    parts <- strsplit(s[shaped], ".", fixed = TRUE)
    res[shaped] <- vapply(parts, function(p) {
      all(grepl("^(0|[1-9][0-9]{0,2})$", p)) && all(as.integer(p) <= 255L)
    }, logical(1))
  }
  out[present] <- res
  out
}

#' Canonicalize a host vector against the input contract
#'
#' @param domain Character vector of hostnames (Unicode or ASCII).
#' @param invalid `"na"` marks invalid elements with status `"invalid"`;
#'   `"error"` aborts on the first invalid element, reporting its 1-based index.
#' @return A list of equal-length vectors: `input` (unchanged), `status`
#'   (`"ok"`, `"na"`, `"invalid"`), `host` (canonical ASCII with the terminal
#'   dot, `NA` unless `ok`), `core` (canonical ASCII without the terminal dot),
#'   and `had_dot` (logical). `NA_character_` input is `"na"` (missing), not
#'   invalid.
#' @noRd
psl_canonicalize <- function(domain, invalid = "na") {
  # A non-character `domain` is a programming error regardless of length: an
  # empty wrong-typed vector (e.g. numeric(0), NULL) is not the same as the
  # valid empty character vector character(0) (PRD s5.2, s7.1).
  if (!is.character(domain)) {
    stop("`domain` must be a character vector.", call. = FALSE)
  }
  n <- length(domain)
  status <- rep("ok", n)
  host <- rep(NA_character_, n)
  core <- rep(NA_character_, n)
  had_dot <- rep(FALSE, n)
  if (n == 0L) {
    return(list(
      input = domain, status = status, host = host, core = core,
      had_dot = had_dot
    ))
  }

  is_missing <- is.na(domain)
  status[is_missing] <- "na"

  # Deduplicate before normalization so a repeated host costs a single
  # `punycoder` canonicalization (and IPv4-literal check) regardless of its
  # multiplicity (PRD s8.2, s11.4). The matcher layer separately deduplicates
  # the C++ matching call, so the per-duplicate cost of both crossings is
  # avoided. `match()` maps each input back to its unique representative, with
  # `NA` matching the single retained `NA`.
  uniq <- unique(domain)
  idx <- match(domain, uniq)
  norm_uniq <- punycoder::host_normalize(uniq, strict = TRUE)
  ipv4_uniq <- is_ipv4_literal(uniq)
  normalized <- norm_uniq[idx]
  bad <- !is_missing & (is.na(normalized) | ipv4_uniq[idx])
  status[bad] <- "invalid"

  if (identical(invalid, "error") && any(bad)) {
    i <- which(bad)[1L]
    stop(
      sprintf(
        "Invalid host at position %d: %s", i, trunc_for_msg(domain[i])
      ),
      call. = FALSE
    )
  }

  valid <- status == "ok"
  host[valid] <- normalized[valid]
  had_dot[valid] <- endsWith(normalized[valid], ".")
  core[valid] <- ifelse(
    had_dot[valid],
    substr(host[valid], 1L, nchar(host[valid]) - 1L),
    host[valid]
  )

  list(
    input = domain, status = status, host = host, core = core,
    had_dot = had_dot
  )
}
