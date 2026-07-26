# Injectable HTTP transport (freshness v2).
#
# Conditional refresh needs more than "a file appeared on disk": it has to read
# the status code to tell a `304` from a `200`, read `ETag` / `Last-Modified` /
# `Cache-Control` off the response, and know the effective URL a redirect chain
# landed on. The v1 downloader seam returned only a path, so none of that could
# be threaded through it. This file replaces it with a request/response
# contract:
#
#     transport(request) -> psl_transport_response
#
# `psl_curl_transport()` is the production adapter; `curl` stays in `Suggests`
# and is reached through `requireNamespace()`. Tests inject their own function
# through the `pslr.transport` option and never touch the network.
#
# Redirects are followed ONE HOP AT A TIME by default (`follow_redirects =
# FALSE`): a `3xx` comes back as an ordinary response carrying its `location`
# header, and the caller decides whether that hop is allowed. The redirect
# policy itself -- HTTPS only, same-origin, at most five hops, validator
# scoping -- belongs to the URL layer, not here. The response also carries
# `effective_url` and a `redirects` count so a caller that opts into
# `follow_redirects = TRUE` can still see where it ended up.

# ---------------------------------------------------------------------------
# Seams
# ---------------------------------------------------------------------------

# Stable user agent identifying the client to the upstream endpoint, as the
# official download guidance asks.
psl_user_agent <- function() {
  sprintf("pslr/%s", as.character(utils::packageVersion("pslr")))
}

# Seconds allowed for the connect phase and for the whole transfer. Separate
# because a reachable-but-slow server and an unreachable one deserve different
# ceilings; both are options so a test can drive them without waiting.
psl_connect_timeout <- function() getOption("pslr.connect_timeout", 10)

psl_total_timeout <- function() getOption("pslr.timeout", 60)

# The transport in force. Tests replace it wholesale; production gets `curl`.
psl_transport <- function() {
  transport <- getOption("pslr.transport", psl_curl_transport)
  if (!is.function(transport)) {
    stop("`pslr.transport` must be a function of one request.", call. = FALSE)
  }
  transport
}

# ---------------------------------------------------------------------------
# Headers
# ---------------------------------------------------------------------------

psl_empty_headers <- function() {
  out <- character()
  names(out) <- character()
  out
}

# Normalize headers to a named character vector with lowercase field names.
# Accepts the named list `curl::parse_headers_list()` returns as well as a
# plain named character vector, so a test double can hand over either. Repeated
# fields collapse into one comma-separated value, which is how HTTP defines a
# repeated field anyway.
psl_normalize_headers <- function(headers) {
  if (is.null(headers) || !length(headers)) {
    return(psl_empty_headers())
  }
  if (is.list(headers)) {
    headers <- vapply(headers, \(v) toString(as.character(v)), character(1))
  }
  if (!is.character(headers) || is.null(names(headers))) {
    stop("Headers must be a named character vector.", call. = FALSE)
  }
  fields <- tolower(trimws(names(headers)))
  values <- trimws(unname(headers))
  unique_fields <- unique(fields)
  out <- vapply(
    unique_fields,
    \(field) toString(values[fields == field]),
    character(1)
  )
  names(out) <- unique_fields
  out
}

# One header value, or `NA` when the field is absent.
psl_response_header <- function(response, name) {
  headers <- response$headers
  name <- tolower(name)
  if (!length(headers) || !name %in% names(headers)) {
    return(NA_character_)
  }
  unname(headers[[name]])
}

# A field name must be an HTTP token and a value must contain no CR, LF, NUL,
# or other ASCII control character: a header pslr *sends* is assembled from
# stored state, and an unchecked control character there is request splitting.
# Values are also capped, matching the validator size rule.
psl_check_request_headers <- function(headers) {
  if (!length(headers)) {
    return(invisible(NULL))
  }
  if (!is.character(headers) || is.null(names(headers))) {
    stop("`headers` must be a named character vector.", call. = FALSE)
  }
  if (anyNA(headers) || anyNA(names(headers))) {
    stop("`headers` must not contain missing values.", call. = FALSE)
  }
  if (!all(grepl("^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", names(headers)))) {
    stop("`headers` names must be HTTP tokens.", call. = FALSE)
  }
  if (any(grepl("[[:cntrl:]]", headers))) {
    stop("`headers` values must not contain control characters.", call. = FALSE)
  }
  if (any(nchar(headers, type = "bytes") > 8192L)) {
    stop("`headers` values must be at most 8192 bytes.", call. = FALSE)
  }
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# Request
# ---------------------------------------------------------------------------

psl_check_positive_number <- function(value, what) {
  ok <- is.numeric(value) &&
    length(value) == 1L &&
    !is.na(value) &&
    is.finite(value) &&
    value > 0
  if (!ok) {
    stop(sprintf("`%s` must be a single positive number.", what), call. = FALSE)
  }
  invisible(NULL)
}

psl_check_flag <- function(value, what) {
  if (!is.logical(value) || length(value) != 1L || is.na(value)) {
    stop(sprintf("`%s` must be a single TRUE or FALSE.", what), call. = FALSE)
  }
  invisible(NULL)
}

psl_check_string <- function(value, what) {
  ok <- is.character(value) &&
    length(value) == 1L &&
    !is.na(value) &&
    nzchar(value)
  if (!ok) {
    stop(
      sprintf("`%s` must be a single non-empty string.", what),
      call. = FALSE
    )
  }
  invisible(NULL)
}

# Construct one validated transport request. `destfile` is where a response
# body is staged; the caller owns that path and its cleanup, because a body
# only becomes a snapshot after full validation.
new_psl_transport_request <- function(
  url,
  destfile,
  ...,
  headers = psl_empty_headers(),
  connect_timeout = psl_connect_timeout(),
  timeout = psl_total_timeout(),
  max_bytes = psl_max_source_bytes(),
  follow_redirects = FALSE
) {
  psl_check_empty_dots(...)
  request <- list(
    url = url,
    destfile = destfile,
    headers = psl_normalize_headers(headers),
    connect_timeout = connect_timeout,
    timeout = timeout,
    max_bytes = max_bytes,
    follow_redirects = follow_redirects
  )
  validate_psl_transport_request(structure(
    request,
    class = "psl_transport_request"
  ))
}

validate_psl_transport_request <- function(x) {
  if (!inherits(x, "psl_transport_request")) {
    stop("`request` must be a psl_transport_request.", call. = FALSE)
  }
  psl_check_string(x$url, "url")
  psl_check_string(x$destfile, "destfile")
  psl_check_request_headers(x$headers)
  psl_check_positive_number(x$connect_timeout, "connect_timeout")
  psl_check_positive_number(x$timeout, "timeout")
  psl_check_positive_number(x$max_bytes, "max_bytes")
  psl_check_flag(x$follow_redirects, "follow_redirects")
  x
}

# ---------------------------------------------------------------------------
# Response
# ---------------------------------------------------------------------------

# Construct one validated transport response. `body_path` is `NA` whenever
# there is no body to read -- a `304` carries none by definition -- so a caller
# never has to distinguish "empty file" from "no body".
new_psl_transport_response <- function(
  status,
  ...,
  headers = psl_empty_headers(),
  effective_url = NA_character_,
  body_path = NA_character_,
  bytes_downloaded = 0L,
  redirects = 0L
) {
  psl_check_empty_dots(...)
  response <- list(
    status = psl_as_count(status),
    headers = psl_normalize_headers(headers),
    effective_url = effective_url,
    body_path = body_path,
    bytes_downloaded = psl_as_count(bytes_downloaded),
    redirects = psl_as_count(redirects)
  )
  validate_psl_transport_response(structure(
    response,
    class = "psl_transport_response"
  ))
}

psl_check_optional_string <- function(value, what) {
  ok <- is.character(value) && length(value) == 1L
  if (!ok) {
    stop(
      sprintf("`%s` must be a single string or NA.", what),
      call. = FALSE
    )
  }
  invisible(NULL)
}

validate_psl_transport_response <- function(x) {
  if (!inherits(x, "psl_transport_response")) {
    stop("A transport must return a psl_transport_response.", call. = FALSE)
  }
  status_ok <- is.integer(x$status) &&
    length(x$status) == 1L &&
    !is.na(x$status) &&
    x$status >= 100L &&
    x$status <= 599L
  if (!status_ok) {
    stop("`status` must be a single HTTP status code.", call. = FALSE)
  }
  psl_check_optional_string(x$effective_url, "effective_url")
  psl_check_optional_string(x$body_path, "body_path")
  count_ok <- is.integer(x$bytes_downloaded) &&
    !is.na(x$bytes_downloaded) &&
    x$bytes_downloaded >= 0L
  if (!count_ok) {
    stop("`bytes_downloaded` must be a non-negative count.", call. = FALSE)
  }
  redirects_ok <- is.integer(x$redirects) &&
    length(x$redirects) == 1L &&
    (is.na(x$redirects) || x$redirects >= 0L)
  if (!redirects_ok) {
    stop("`redirects` must be a non-negative count or NA.", call. = FALSE)
  }
  x
}

# ---------------------------------------------------------------------------
# Status classification
# ---------------------------------------------------------------------------

# Only `200` and `304` are successful refresh responses. Everything else --
# including a redirect the caller chose not to follow -- is classified here and
# acted on by the refresh state machine.
psl_response_class <- function(response) {
  status <- response$status
  if (identical(status, 200L)) {
    return("ok")
  }
  if (identical(status, 304L)) {
    return("not_modified")
  }
  if (status >= 300L && status < 400L) {
    return("redirect")
  }
  "failure"
}

# `Retry-After`, honoured only where it is meaningful: a server asking a client
# to back off answers `429` or `503`.
psl_response_retry_after <- function(response) {
  if (!response$status %in% c(429L, 503L)) {
    return(NA_integer_)
  }
  psl_retry_after_seconds(psl_response_header(response, "retry-after"))
}

# Turn a non-successful response into the classed HTTP error, preserving a
# valid `Retry-After`. Returns the classification for `200` and `304`.
psl_require_response_status <- function(response, request_url = NA_character_) {
  classification <- psl_response_class(response)
  if (classification %in% c("ok", "not_modified")) {
    return(classification)
  }
  stop(psl_refresh_http_status_error(
    response$status,
    retry_after = psl_response_retry_after(response),
    request_url = request_url,
    effective_url = response$effective_url
  ))
}

# ---------------------------------------------------------------------------
# curl adapter
# ---------------------------------------------------------------------------

# Coarse reason token for a libcurl failure. The raw libcurl message is
# deliberately dropped rather than attached to the condition: it is the one
# string in this layer that can quote server-supplied text, and refresh errors
# must never carry transport traces. The token still tells timeout, DNS, TLS,
# and connection failures apart.
psl_curl_reason <- function(message) {
  message <- tolower(message)
  patterns <- c(
    limit = "file ?size|maximum file size",
    timeout = "timed out|timeout|operation too slow",
    dns = "resolve host|resolve proxy|name or service not known",
    tls = "ssl|tls|certificate|handshake",
    connect = "connect|connection refused|network is unreachable"
  )
  hit <- names(patterns)[vapply(patterns, grepl, logical(1), x = message)]
  if (length(hit)) hit[[1L]] else "transport"
}

# Build the libcurl handle for one request. No automatic retries are configured
# anywhere: a failed refresh is reported, never silently repeated.
psl_curl_handle <- function(request) {
  handle <- curl::new_handle(
    followlocation = request$follow_redirects,
    connecttimeout = as.numeric(request$connect_timeout),
    timeout = as.numeric(request$timeout),
    maxfilesize_large = as.numeric(request$max_bytes),
    useragent = psl_user_agent(),
    accept_encoding = "gzip"
  )
  if (length(request$headers)) {
    curl::handle_setheaders(handle, .list = as.list(request$headers))
  }
  handle
}

# Redirect hops libcurl actually followed, or `NA` when it cannot be read.
psl_curl_redirects <- function(handle) {
  hops <- tryCatch(curl::handle_data(handle)$redirects, error = \(e) NULL)
  if (is.null(hops) || length(hops) != 1L || is.na(hops)) {
    return(NA_integer_)
  }
  as.integer(hops)
}

# The production transport. Every failure leaves the response contract intact:
# either a validated `psl_transport_response`, or a classed refresh error.
psl_curl_transport <- function(request) {
  validate_psl_transport_request(request)
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop(psl_refresh_transport_error(
      paste0(
        "psl_refresh() needs the 'curl' package to download lists over https; ",
        "install it or set the `pslr.transport` option to a custom transport."
      ),
      reason = "no_transport",
      request_url = request$url
    ))
  }
  handle <- psl_curl_handle(request)
  fetched <- tryCatch(
    curl::curl_fetch_disk(request$url, request$destfile, handle = handle),
    error = function(cnd) psl_curl_failed(cnd, request)
  )
  psl_curl_response(fetched, handle, request)
}

# Translate a libcurl failure into the classed error it belongs to. A transfer
# aborted by the size ceiling is a response-limit failure, not a generic
# transport one.
psl_curl_failed <- function(cnd, request) {
  unlink(request$destfile)
  reason <- psl_curl_reason(conditionMessage(cnd))
  if (identical(reason, "limit")) {
    stop(psl_refresh_response_limit_error(
      NA_real_,
      request$max_bytes,
      request_url = request$url
    ))
  }
  stop(psl_refresh_transport_error(
    sprintf("Refresh transport failed (%s).", reason),
    reason = reason,
    request_url = request$url
  ))
}

# Assemble the response, enforcing the decoded-body ceiling on what actually
# landed on disk. `maxfilesize_large` only guards what libcurl transfers, so a
# compressed body that expands past the ceiling is caught here instead.
psl_curl_response <- function(fetched, handle, request) {
  status <- as.integer(fetched$status_code)
  size <- file.size(request$destfile)
  size <- if (length(size) != 1L || is.na(size)) 0 else as.numeric(size)
  if (size > request$max_bytes) {
    unlink(request$destfile)
    stop(psl_refresh_response_limit_error(
      size,
      request$max_bytes,
      request_url = request$url
    ))
  }
  # A `304` has no body by definition; libcurl still opened the staging file.
  has_body <- !identical(status, 304L)
  if (!has_body) {
    unlink(request$destfile)
  }
  new_psl_transport_response(
    status = status,
    headers = psl_normalize_headers(curl::parse_headers_list(fetched$headers)),
    effective_url = fetched$url,
    body_path = if (has_body) request$destfile else NA_character_,
    bytes_downloaded = if (has_body) as.integer(size) else 0L,
    redirects = psl_curl_redirects(handle)
  )
}

# Perform one request through the transport in force and validate what came
# back, so an injected transport cannot hand a malformed response to the
# refresh state machine.
psl_transport_fetch <- function(request) {
  validate_psl_transport_request(request)
  validate_psl_transport_response(psl_transport()(request))
}
