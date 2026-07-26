# URL, redirect, and validator-scope policy (freshness v2).
#
# Two things live here, and they are the same thing seen from two sides.
#
#   * SOURCE IDENTITY. A refresh source is one absolute HTTPS URL with no
#     userinfo, no fragment, and no query string. A query is rejected
#     deliberately rather than stripped: request URLs are persisted, and a
#     query is exactly where a token would hide. The accepted URL is then
#     normalized -- lowercase scheme and host, no default port, an empty path
#     becomes `/`, every other path byte preserved verbatim -- and that
#     normalized string, and nothing else, is what `psl_source_stream_name()`
#     hashes into a per-source directory name. Two spellings of the same
#     endpoint therefore share one source stream, and two genuinely different
#     endpoints can never collide.
#
#   * REDIRECT AND VALIDATOR SCOPE. Redirects are followed one hop at a time
#     (the transport never turns on libcurl's own following), at most five of
#     them, and every hop must itself pass the URL policy and stay on the
#     origin the caller asked for. A caller who wants a cross-origin target
#     supplies that target explicitly.
#
# The security-relevant rule is the validator scope: a stored `ETag` or
# `Last-Modified` is an opaque token issued by one specific URL, so it is sent
# ONLY when the request target is byte-for-byte the stored issuer URL, and it
# is dropped before any changed redirect target. A policy violation is refused
# before a validator is forwarded and before any response body is accepted.
#
# Every rejection is signalled as `pslr_refresh_url_policy_error` and every
# message interpolates a URL only after `psl_redact_url()` has removed any
# userinfo the caller supplied.

# ---------------------------------------------------------------------------
# Limits
# ---------------------------------------------------------------------------

psl_max_redirects <- 5L

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

# Raise a URL-policy error whose message names the offending URL. `template`
# takes exactly one `%s`, and the URL reaches it only through the redactor, so
# no diagnostic can print a credential a caller embedded.
psl_url_policy_stop <- function(template, url) {
  stop(psl_refresh_url_policy_error(
    sprintf(template, psl_redact_url(url)),
    request_url = url
  ))
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# Absolute URL with an authority, split into the five pieces the policy cares
# about. `query` and `fragment` keep their leading delimiter so that an empty
# but present query (`https://host/p?`) is still visible as present.
psl_absolute_url_pattern <- paste0(
  "^([A-Za-z][A-Za-z0-9+.-]*)://",
  "([^/?#]*)",
  "([^?#]*)",
  "(\\?[^#]*)?",
  "(#.*)?$"
)

psl_parse_absolute_url <- function(url) {
  parts <- regmatches(url, regexec(psl_absolute_url_pattern, url))[[1L]]
  if (!length(parts)) {
    return(NULL)
  }
  list(
    scheme = parts[[2L]],
    authority = parts[[3L]],
    path = parts[[4L]],
    query = parts[[5L]],
    fragment = parts[[6L]]
  )
}

# Split an authority into host and port. Returns `NULL` when the authority is
# not a bare `host` / `host:port` / `[v6]:port`, so a malformed authority is a
# rejection rather than a guess.
psl_split_authority <- function(authority) {
  if (startsWith(authority, "[")) {
    close <- regexpr("]", authority, fixed = TRUE)
    if (close < 0L) {
      return(NULL)
    }
    host <- substr(authority, 1L, close)
    rest <- substring(authority, close + 1L)
  } else {
    colon <- regexpr(":", authority, fixed = TRUE)
    if (colon < 0L) {
      host <- authority
      rest <- ""
    } else {
      host <- substr(authority, 1L, colon - 1L)
      rest <- substring(authority, colon)
    }
  }
  if (nzchar(rest) && !grepl("^:[0-9]*$", rest)) {
    return(NULL)
  }
  list(host = host, port = substring(rest, 2L))
}

# ASCII host names only: an internationalized domain must already be punycode
# by the time it reaches the network layer.
psl_valid_url_host <- function(host) {
  if (startsWith(host, "[")) {
    return(grepl("^\\[[0-9A-Fa-f:.]+\\]$", host))
  }
  grepl("^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$", host)
}

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

# Accept one refresh source URL and return its normalized form: the source
# identity. Anything the policy rejects raises here, before a request is built.
psl_normalize_source_url <- function(url) {
  if (!is.character(url) || length(url) != 1L || is.na(url) || !nzchar(url)) {
    stop(psl_refresh_url_policy_error(
      "A refresh URL must be a single non-empty string."
    ))
  }
  if (grepl("[[:cntrl:][:space:]]", url)) {
    psl_url_policy_stop(
      "Refresh refused: the URL %s contains whitespace or control characters.",
      url
    )
  }
  parts <- psl_parse_absolute_url(url)
  if (is.null(parts)) {
    psl_url_policy_stop("Refresh refused: %s is not an absolute URL.", url)
  }
  if (!identical(tolower(parts$scheme), "https")) {
    psl_url_policy_stop("Refresh refused: %s is not an https URL.", url)
  }
  if (grepl("@", parts$authority, fixed = TRUE)) {
    psl_url_policy_stop("Refresh refused: %s must not embed credentials.", url)
  }
  if (nzchar(parts$fragment)) {
    psl_url_policy_stop("Refresh refused: %s must not carry a fragment.", url)
  }
  if (nzchar(parts$query)) {
    psl_url_policy_stop(
      "Refresh refused: %s must not carry a query string.",
      url
    )
  }
  paste0(
    "https://",
    psl_normalize_authority(parts$authority, url),
    psl_url_path(parts$path)
  )
}

# Lowercase the host and drop the default port; keep any other port as given.
psl_normalize_authority <- function(authority, url) {
  split <- psl_split_authority(authority)
  if (is.null(split) || !psl_valid_url_host(split$host)) {
    psl_url_policy_stop("Refresh refused: %s has no usable host.", url)
  }
  host <- tolower(split$host)
  port <- if (identical(split$port, "443")) "" else split$port
  if (nzchar(port)) paste0(host, ":", port) else host
}

# An empty path is `/`; every other path byte -- percent-encoding, case,
# trailing slash -- is preserved exactly as the caller wrote it.
psl_url_path <- function(path) {
  if (nzchar(path)) path else "/"
}

# Scheme, host, and port of an already-normalized URL.
psl_url_origin <- function(normalized_url) {
  sub("^(https://[^/]*)/.*$", "\\1", normalized_url)
}

psl_same_origin <- function(a, b) {
  identical(psl_url_origin(a), psl_url_origin(b))
}

# ---------------------------------------------------------------------------
# Redirects
# ---------------------------------------------------------------------------

# Resolve and vet one `Location` against the URL it came from. Absolute,
# protocol-relative, and root-relative targets are resolved; any other relative
# reference is refused rather than resolved, because a partial resolver is a
# worse failure mode than an explicit "supply the target yourself". The
# resolved target must pass the full URL policy and stay same-origin.
psl_redirect_target <- function(current_url, location) {
  usable <- is.character(location) &&
    length(location) == 1L &&
    !is.na(location) &&
    nzchar(trimws(location))
  if (!usable) {
    stop(psl_refresh_url_policy_error(
      "Refresh refused: the server sent a redirect without a Location.",
      request_url = current_url
    ))
  }
  location <- trimws(location)
  target <- if (grepl("^[A-Za-z][A-Za-z0-9+.-]*://", location)) {
    location
  } else if (startsWith(location, "//")) {
    paste0("https:", location)
  } else if (startsWith(location, "/")) {
    paste0(psl_url_origin(current_url), location)
  } else {
    psl_url_policy_stop(
      "Refresh refused: the redirect target %s is not an absolute URL.",
      location
    )
  }
  target <- psl_normalize_source_url(target)
  if (!psl_same_origin(target, current_url)) {
    psl_url_policy_stop(
      "Refresh refused: the redirect target %s is not same-origin.",
      target
    )
  }
  target
}

# ---------------------------------------------------------------------------
# Validator scope
# ---------------------------------------------------------------------------

# The validator headers to send to `url`: the stored ones when `url` is
# byte-for-byte the URL that issued them, and none otherwise. Which validator
# is stored, and how it is sanitized, is decided elsewhere; this decides only
# where it may go.
psl_scoped_validator_headers <- function(url, headers, issuer_url) {
  scoped <- is.character(issuer_url) &&
    length(issuer_url) == 1L &&
    !is.na(issuer_url) &&
    identical(url, issuer_url)
  if (!scoped || !length(headers)) {
    return(psl_empty_headers())
  }
  psl_normalize_headers(headers)
}

# ---------------------------------------------------------------------------
# Policy-driven fetch
# ---------------------------------------------------------------------------

# Fetch `url` under the full policy, one redirect hop at a time, and return the
# first non-redirect response together with the normalized request URL, the
# final effective URL, the hop count, and whether a validator was actually
# sent. A redirect body is discarded before the next hop is considered, so no
# bytes from an intermediate response can reach a caller.
psl_fetch_with_policy <- function(
  url,
  destfile,
  ...,
  headers = psl_empty_headers(),
  validator_headers = psl_empty_headers(),
  validator_issuer = NA_character_,
  max_redirects = psl_max_redirects
) {
  request_url <- psl_normalize_source_url(url)
  headers <- psl_normalize_headers(headers)
  current <- request_url
  followed <- 0L
  repeat {
    validator <- psl_scoped_validator_headers(
      current,
      validator_headers,
      validator_issuer
    )
    response <- psl_transport_fetch(new_psl_transport_request(
      current,
      destfile,
      ...,
      headers = c(headers, validator),
      follow_redirects = FALSE
    ))
    if (!identical(psl_response_class(response), "redirect")) {
      return(list(
        response = response,
        request_url = request_url,
        effective_url = current,
        redirects = followed,
        validator_sent = length(validator) > 0L
      ))
    }
    unlink(destfile)
    if (followed >= max_redirects) {
      stop(psl_refresh_url_policy_error(
        sprintf("Refresh refused: more than %d redirects.", max_redirects),
        request_url = request_url
      ))
    }
    current <- psl_redirect_target(
      current,
      psl_response_header(response, "location")
    )
    followed <- followed + 1L
  }
}
