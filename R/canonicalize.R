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
  # `nchar()` and `substr()` abort on an undecodable string, so a byte sequence
  # that is not valid UTF-8 gets a fixed stand-in. This keeps the message
  # identical whatever the session locale, which the raw bytes would not be.
  if (!validUTF8(s)) {
    return("<undecodable bytes>")
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
    res[shaped] <- vapply(
      parts,
      function(p) {
        all(grepl("^(0|[1-9][0-9]{0,2})$", p)) && all(as.integer(p) <= 255L)
      },
      logical(1)
    )
  }
  out[present] <- res
  out
}

# Resolve the encoding of caller-supplied hosts to UTF-8 before any matching.
#
# R marks a string "unknown" when it is in the session's native encoding. Under
# a UTF-8 locale that is indistinguishable from UTF-8, so unmarked non-ASCII
# hosts work by accident; under a non-UTF-8 locale (LC_ALL=C, and CRAN's Windows
# checks) the same bytes are reinterpreted and canonicalization fails, returning
# NA for a host that resolves fine one locale over. Callers should not have to
# declare `Encoding(host) <- "UTF-8"` to get a stable answer.
#
# Unmarked non-ASCII input is resolved two ways: if the bytes are valid UTF-8,
# declare that (the overwhelmingly common case, and what a caller reading from a
# UTF-8 source actually holds); otherwise honour R's contract that "unknown"
# means native and transcode. ASCII and already-marked strings are untouched.
psl_declare_utf8 <- function(x) {
  candidate <- !is.na(x) &
    Encoding(x) == "unknown" &
    grepl("[^\001-\177]", x, useBytes = TRUE)
  if (!any(candidate)) {
    return(x)
  }

  as_utf8 <- candidate & validUTF8(x)
  if (any(as_utf8)) {
    marked <- x[as_utf8]
    Encoding(marked) <- "UTF-8"
    x[as_utf8] <- marked
  }

  from_native <- candidate & !as_utf8
  if (any(from_native)) {
    x[from_native] <- enc2utf8(x[from_native])
  }
  x
}

psl_canonical_result <- function(domain) {
  n <- length(domain)
  list(
    input = domain,
    status = rep("ok", n),
    host = rep(NA_character_, n),
    core = rep(NA_character_, n),
    had_dot = rep(FALSE, n)
  )
}

psl_normalize_unique_hosts <- function(domain) {
  uniq <- unique(domain)
  idx <- match(domain, uniq)
  list(
    normalized = punycoder::host_normalize(uniq)[idx],
    ipv4 = is_ipv4_literal(uniq)[idx]
  )
}

psl_abort_invalid_host <- function(domain, bad) {
  if (!any(bad)) {
    return(invisible(NULL))
  }
  i <- which(bad)[1L]
  stop(
    sprintf("Invalid host at position %d: %s", i, trunc_for_msg(domain[i])),
    call. = FALSE
  )
}

psl_fill_valid_hosts <- function(out, normalized) {
  valid <- out$status == "ok"
  out$host[valid] <- normalized[valid]
  out$had_dot[valid] <- endsWith(normalized[valid], ".")
  out$core[valid] <- ifelse(
    out$had_dot[valid],
    substr(out$host[valid], 1L, nchar(out$host[valid]) - 1L),
    out$host[valid]
  )
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
  domain <- psl_declare_utf8(domain)
  out <- psl_canonical_result(domain)
  if (length(domain) == 0L) {
    return(out)
  }

  # Bytes that survive `psl_declare_utf8()` still undecodable are genuinely
  # invalid input, not a programming error: per the input contract they are
  # reported like any other invalid host. They must be withheld from the
  # regex-based checks below, which abort on an undecodable string rather than
  # returning FALSE. `out$input` keeps the caller's original bytes.
  undecodable <- !is.na(domain) & !validUTF8(domain)
  reportable <- domain
  domain[undecodable] <- NA_character_

  # Undecodable elements are deliberately excluded here so they fall through to
  # the `bad` test below and land on status "invalid" rather than "na" -- they
  # are malformed input, not absent input, and `invalid = "error"` must abort on
  # them.
  is_missing <- is.na(domain) & !undecodable
  out$status[is_missing] <- "na"

  # Deduplicate before normalization so a repeated host costs a single
  # `punycoder` canonicalization (and IPv4-literal check) regardless of its
  # multiplicity (PRD s8.2, s11.4). The matcher layer separately deduplicates
  # the C++ matching call, so the per-duplicate cost of both crossings is
  # avoided. `match()` maps each input back to its unique representative, with
  # `NA` matching the single retained `NA`.
  norm <- psl_normalize_unique_hosts(domain)
  bad <- !is_missing & (is.na(norm$normalized) | norm$ipv4)
  out$status[bad] <- "invalid"

  if (identical(invalid, "error") && any(bad)) {
    psl_abort_invalid_host(reportable, bad)
  }

  psl_fill_valid_hosts(out, norm$normalized)
}
