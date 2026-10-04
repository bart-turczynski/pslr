# Every test here is fully offline: the transport seam is either replaced with
# an injected function or exercised through the pure helpers of the curl
# adapter. Nothing in this file opens a socket.

# A request pointed at a staging file inside a temporary directory.
local_request <- function(
  url = "https://example.org/list.dat",
  ...,
  .env = parent.frame()
) {
  dir <- withr::local_tempdir(.local_envir = .env)
  new_psl_transport_request(url, file.path(dir, "body.part"), ...)
}

test_that("a request normalizes header names and keeps its staging path", {
  request <- local_request(headers = c("If-None-Match" = "\"abc\""))

  expect_s3_class(request, "psl_transport_request")
  expect_named(request$headers, "if-none-match")
  expect_equal(unname(request$headers), "\"abc\"")
  expect_match(request$destfile, "body\\.part$")
  expect_false(request$follow_redirects)
})

test_that("a request defaults to one redirect hop at a time", {
  expect_false(local_request()$follow_redirects)
  expect_true(local_request(follow_redirects = TRUE)$follow_redirects)
})

test_that("a request carries separate connect and total timeouts", {
  withr::local_options(pslr.connect_timeout = 3, pslr.timeout = 7)
  request <- local_request()

  expect_equal(request$connect_timeout, 3)
  expect_equal(request$timeout, 7)
})

test_that("a request caps bodies at the documented 16 MiB ceiling", {
  expect_equal(local_request()$max_bytes, 16777216L)
})

test_that("a request rejects header values that could split the request", {
  expect_error(
    local_request(headers = c("If-None-Match" = "a\r\nX-Evil: 1")),
    "control characters"
  )
  expect_error(
    local_request(headers = c("Bad Name" = "1")),
    "HTTP tokens"
  )
  expect_error(
    local_request(headers = c("If-None-Match" = strrep("a", 8193L))),
    "8192 bytes"
  )
})

test_that("a request rejects malformed scalars", {
  expect_error(local_request(timeout = 0), "positive number")
  expect_error(local_request(connect_timeout = NA_real_), "positive number")
  expect_error(local_request(follow_redirects = NA), "TRUE or FALSE")
  expect_error(local_request(nonsense = 1), "Unexpected argument")
})

test_that("headers collapse repeated fields and accept curl's list shape", {
  headers <- psl_normalize_headers(list("ETag" = "\"a\"", "etag" = "\"b\""))

  expect_named(headers, "etag")
  expect_equal(unname(headers), "\"a\", \"b\"")
  expect_length(psl_normalize_headers(NULL), 0L)
})

test_that("a header holding bytes that are not valid UTF-8 still normalizes", {
  # A transport may hand over raw server bytes. trimws() and chartr() both fail
  # on them under a UTF-8 ctype, so each such name or value is reduced to
  # ASCII with every other byte written as `<xx>` (PSLR-mlnfdltl).
  local_utf8_ctype()
  headers <- c(" X-B\xffD " = " v\xfe ", ETag = " \"a\" ")

  expect_no_condition(normalized <- psl_normalize_headers(headers))
  expect_named(normalized, c("x-b<ff>d", "etag"))
  expect_equal(unname(normalized), c("v<fe>", "\"a\""))
})

test_that("a valid UTF-8 header keeps its characters", {
  local_utf8_ctype()
  value <- intToUtf8(c(0x7A, 0xF3, 0x142, 0x77))

  expect_equal(
    unname(psl_normalize_headers(c("X-Name" = paste0(" ", value, " ")))),
    value
  )
})

test_that("a response header holding a 0xff byte leaves the others readable", {
  local_utf8_ctype()
  response <- new_psl_transport_response(
    503L,
    headers = c(ETag = "\"v\xff\"", "Retry-After" = "30")
  )

  expect_equal(psl_response_header(response, "etag"), NA_character_)
  expect_equal(psl_response_retry_after(response), 30L)
})

test_that("a validator that needed escaping reads as absent", {
  # pslr sends a validator back byte for byte, so an escaped one would never
  # match on the server; it is dropped and the stored one kept (PSLR-mlnfdltl).
  local_utf8_ctype()
  headers <- c(
    ETag = "\"v\xff\"",
    "Last-Modified" = "Mon, 05 Oct 2026 10:00:00 GMT\xff",
    "Retry-After" = "3\xff",
    "Cache-Control" = "max-age=60"
  )

  normalized <- psl_normalize_headers(headers)

  expect_named(normalized, c("retry-after", "cache-control"))
  expect_equal(unname(normalized), c("3<ff>", "max-age=60"))
})

test_that("a curl validator holding a 0xff byte reads as absent", {
  skip_if_not_installed("curl")
  local_utf8_ctype()
  request <- local_request()
  writeLines("", request$destfile)
  block <- c(
    charToRaw("HTTP/1.1 304 Not Modified\r\nETag: \"v"),
    as.raw(0xff),
    charToRaw("\"\r\nRetry-After: 30\r\n\r\n")
  )
  fetched <- list(status_code = 304L, url = request$url, headers = block)

  response <- psl_curl_response(fetched, NULL, request)

  expect_equal(psl_response_header(response, "etag"), NA_character_)
  expect_equal(psl_response_header(response, "retry-after"), "30")
})

test_that("a response exposes status, headers, effective URL, and body", {
  response <- new_psl_transport_response(
    200L,
    headers = c("ETag" = "\"v1\"", "Content-Type" = "text/plain"),
    effective_url = "https://cdn.example.org/list.dat",
    body_path = "/tmp/body",
    bytes_downloaded = 42L,
    redirects = 1L
  )

  expect_s3_class(response, "psl_transport_response")
  expect_equal(response$status, 200L)
  expect_equal(psl_response_header(response, "etag"), "\"v1\"")
  expect_equal(psl_response_header(response, "ETag"), "\"v1\"")
  expect_equal(response$effective_url, "https://cdn.example.org/list.dat")
  expect_equal(response$bytes_downloaded, 42L)
  expect_equal(response$redirects, 1L)
})

test_that("an absent response header reads as NA", {
  response <- new_psl_transport_response(304L)

  expect_equal(psl_response_header(response, "etag"), NA_character_)
  expect_equal(response$body_path, NA_character_)
  expect_equal(response$bytes_downloaded, 0L)
})

test_that("a response rejects an impossible status", {
  expect_error(new_psl_transport_response(99L), "HTTP status code")
  expect_error(new_psl_transport_response(600L), "HTTP status code")
  expect_error(new_psl_transport_response(NA_integer_), "HTTP status code")
})

test_that("only 200 and 304 classify as successful refresh responses", {
  classify <- \(status) psl_response_class(new_psl_transport_response(status))

  expect_equal(classify(200L), "ok")
  expect_equal(classify(304L), "not_modified")
  expect_equal(classify(301L), "redirect")
  expect_equal(classify(404L), "failure")
  expect_equal(classify(503L), "failure")
})

test_that("a successful status passes the status gate through", {
  expect_equal(
    psl_require_response_status(new_psl_transport_response(200L)),
    "ok"
  )
  expect_equal(
    psl_require_response_status(new_psl_transport_response(304L)),
    "not_modified"
  )
})

test_that("a failure status raises the classed HTTP error", {
  response <- new_psl_transport_response(
    500L,
    effective_url = "https://example.org/list.dat"
  )
  cnd <- tryCatch(
    psl_require_response_status(response, "https://example.org/list.dat"),
    condition = identity
  )

  expect_s3_class(cnd, "pslr_refresh_http_status_error")
  expect_s3_class(cnd, "pslr_refresh_error")
  expect_equal(cnd$status, 500L)
  expect_equal(cnd$retry_after, NA_integer_)
})

test_that("a redirect the caller did not follow is an HTTP failure", {
  response <- new_psl_transport_response(
    302L,
    headers = c(Location = "https://cdn.example.org/list.dat")
  )

  expect_error(
    psl_require_response_status(response),
    class = "pslr_refresh_http_status_error"
  )
  expect_equal(
    psl_response_header(response, "location"),
    "https://cdn.example.org/list.dat"
  )
})

test_that("Retry-After survives on 429 and 503 only", {
  with_retry <- \(status) {
    psl_response_retry_after(new_psl_transport_response(
      status,
      headers = c("Retry-After" = "120")
    ))
  }

  expect_equal(with_retry(429L), 120L)
  expect_equal(with_retry(503L), 120L)
  expect_equal(with_retry(500L), NA_integer_)
})

test_that("a 503 error object carries the Retry-After delay", {
  response <- new_psl_transport_response(
    503L,
    headers = c("Retry-After" = "30")
  )
  cnd <- tryCatch(
    psl_require_response_status(response),
    condition = identity
  )

  expect_equal(cnd$retry_after, 30L)
  expect_match(conditionMessage(cnd), "Retry after 30 seconds")
})

test_that("an injected transport replaces the network entirely", {
  tally <- new.env(parent = emptyenv())
  tally$calls <- 0L
  withr::local_options(pslr.transport = function(request) {
    tally$calls <- tally$calls + 1L
    new_psl_transport_response(304L, effective_url = request$url)
  })

  response <- psl_transport_fetch(local_request())

  expect_equal(response$status, 304L)
  expect_equal(tally$calls, 1L)
})

test_that("a transport failure is not retried", {
  tally <- new.env(parent = emptyenv())
  tally$calls <- 0L
  withr::local_options(pslr.transport = function(request) {
    tally$calls <- tally$calls + 1L
    stop(psl_refresh_transport_error("boom", reason = "timeout"))
  })

  expect_error(
    psl_transport_fetch(local_request()),
    class = "pslr_refresh_transport_error"
  )
  expect_equal(tally$calls, 1L)
})

test_that("a transport that returns the wrong shape is rejected", {
  withr::local_options(pslr.transport = \(request) list(status = 200L))

  expect_error(psl_transport_fetch(local_request()), "psl_transport_response")
})

test_that("a non-function transport option is refused", {
  withr::local_options(pslr.transport = "not a function")

  expect_error(psl_transport(), "must be a function")
})

test_that("the default transport is the curl adapter", {
  expect_identical(psl_transport(), psl_curl_transport)
})

test_that("the user agent names the package and its version", {
  expect_match(psl_user_agent(), "^pslr/[0-9]")
})

test_that("libcurl failures map to coarse reason tokens", {
  expect_equal(psl_curl_reason("Timeout was reached"), "timeout")
  expect_equal(psl_curl_reason("Operation too slow"), "timeout")
  expect_equal(psl_curl_reason("Could not resolve host: example.org"), "dns")
  expect_equal(psl_curl_reason("SSL certificate problem"), "tls")
  expect_equal(psl_curl_reason("Failed to connect to example.org"), "connect")
  expect_equal(psl_curl_reason("Maximum file size exceeded"), "limit")
  expect_equal(psl_curl_reason("something else entirely"), "transport")
})

test_that("a libcurl message holding invalid UTF-8 still gets a token", {
  # Server bytes quoted into the message need not be valid UTF-8; lowercasing
  # or matching them must not error or warn (PSLR-ejksqarh).
  local_utf8_ctype()
  invalid <- "Could not resolve host: \xff\xfe.example"
  expect_false(validUTF8(invalid))
  expect_no_condition(reason <- psl_curl_reason(invalid))
  expect_equal(reason, "dns")

  marked <- "\xc3\x28 SSL certificate problem"
  Encoding(marked) <- "UTF-8"
  expect_no_condition(reason <- psl_curl_reason(marked))
  expect_equal(reason, "tls")

  expect_equal(psl_curl_reason("\xff\xfe\xfd"), "transport")
})

test_that("a host name quoted in a libcurl message does not pick the reason", {
  # The host can come from a redirect target, so a name holding "filesize",
  # "timeout" or "ssl" must not turn a DNS or connect failure into a limit,
  # timeout or TLS one (PSLR-mlnfdltl).
  for (host in c("filesize.example", "timeout.example", "ssl.example.org")) {
    expect_equal(
      psl_curl_reason(paste("Could not resolve host:", host)),
      "dns",
      label = host
    )
    expect_equal(
      psl_curl_reason(sprintf(
        "Failed to connect to %s port 443 after 3 ms: Connection refused",
        host
      )),
      "connect",
      label = host
    )
    expect_equal(
      psl_curl_reason(sprintf(
        "Could not resolve hostname [%s]:\nCould not resolve host: %s",
        host,
        host
      )),
      "dns",
      label = host
    )
    # Older libcurl quotes the host after an apostrophe of its own.
    expect_equal(
      psl_curl_reason(sprintf("Couldn't resolve host '%s'", host)),
      "dns",
      label = host
    )
  }
  expect_equal(
    psl_curl_reason(paste(
      "OpenSSL SSL_connect: SSL_ERROR_SYSCALL",
      "in connection to timeout.example:443"
    )),
    "tls"
  )
  expect_equal(
    psl_curl_reason(paste(
      "SSL: certificate subject name (filesize.example)",
      "does not match target host name 'timeout.example'"
    )),
    "tls"
  )
  expect_equal(
    psl_curl_reason(paste(
      "Failed to connect to ssl.example.org port 443 after 10001 ms:",
      "Timeout was reached"
    )),
    "timeout"
  )
})

test_that("parenthesized text that names no host still picks the reason", {
  expect_equal(
    psl_curl_reason("Recv failure (Connection timed out)"),
    "timeout"
  )
  expect_equal(psl_curl_reason("Recv failure (SSL_ERROR_SYSCALL)"), "tls")
})

test_that("curl's bracketed host suffix does not pick the reason", {
  # curl >= 6.0.0 appends ` [host]` to libcurl's text before its detail line;
  # a code with no token of its own still reads the message (PSLR-mlnfdltl).
  expect_equal(
    psl_curl_reason(
      paste(
        "Failure when receiving data from the peer [filesize.example]:",
        "Recv failure: Connection reset by peer",
        sep = "\n"
      ),
      "curl_error_recv_error"
    ),
    "connect"
  )
})

test_that("a host curl 5.x brackets mid-message does not pick the reason", {
  # curl < 6.0.0 raises a plain simpleError, so the message alone decides.
  expect_equal(
    psl_curl_reason(paste(
      "Timeout was reached: [filesize.example]",
      "Resolving timed out after 10000 milliseconds"
    )),
    "timeout"
  )
  expect_equal(
    psl_curl_reason(paste(
      "SSL peer certificate or SSH remote key was not OK: [timeout.example]",
      "SSL: no alternative certificate subject name matches"
    )),
    "tls"
  )
})

test_that("a quoted URL with no host marker does not pick the reason", {
  expect_equal(
    psl_curl_reason("Unsupported proxy syntax in 'http://filesize.example'"),
    "transport"
  )
})

# A condition shaped like the ones curl >= 6.0.0 raises: its class names the
# libcurl error code, and its message quotes the host in brackets.
curl_condition <- function(code, message) {
  structure(
    class = c(paste0("curl_error_", code), "curl_error", "error", "condition"),
    list(message = message, call = NULL)
  )
}

test_that("curl's error class picks the reason over the message", {
  expect_equal(
    psl_curl_reason("Timeout was reached", "curl_error_couldnt_resolve_host"),
    "dns"
  )
  expect_equal(
    psl_curl_reason("anything", "curl_error_couldnt_resolve_proxy"),
    "dns"
  )
  expect_equal(
    psl_curl_reason("anything", "curl_error_operation_timedout"),
    "timeout"
  )
  expect_equal(
    psl_curl_reason("anything", "curl_error_peer_failed_verification"),
    "tls"
  )
  expect_equal(
    psl_curl_reason("anything", "curl_error_ssl_connect_error"),
    "tls"
  )
  expect_equal(
    psl_curl_reason("Could not resolve host", "curl_error_couldnt_connect"),
    "connect"
  )
  expect_equal(
    psl_curl_reason("anything", "curl_error_filesize_exceeded"),
    "limit"
  )
  # A code with no mapping of its own falls back to the message.
  expect_equal(
    psl_curl_reason("Recv failure: Connection reset", "curl_error_recv_error"),
    "connect"
  )
})

test_that("a DNS failure for a misleading host name stays a DNS failure", {
  request <- local_request()
  for (host in c("filesize.example", "timeout.example", "ssl.example.org")) {
    message <- sprintf(
      "Could not resolve hostname [%s]:\nCould not resolve host: %s",
      host,
      host
    )
    for (cnd in list(
      simpleError(message),
      curl_condition("couldnt_resolve_host", message)
    )) {
      out <- tryCatch(psl_curl_failed(cnd, request), condition = identity)
      expect_s3_class(out, "pslr_refresh_transport_error")
      expect_equal(out$reason, "dns", label = host)
    }
  }
})

test_that("curl's size-ceiling class is a limit error whatever the message", {
  request <- local_request()
  cnd <- tryCatch(
    psl_curl_failed(
      curl_condition("filesize_exceeded", "Exceeded the maximum allowed size"),
      request
    ),
    condition = identity
  )

  expect_s3_class(cnd, "pslr_refresh_response_limit_error")
})

test_that("a timeout becomes a transport error carrying no raw trace", {
  request <- local_request()
  writeLines("partial", request$destfile)
  cnd <- tryCatch(
    psl_curl_failed(
      simpleError("Timeout was reached: server.example.org secret-token"),
      request
    ),
    condition = identity
  )

  expect_s3_class(cnd, "pslr_refresh_transport_error")
  expect_s3_class(cnd, "pslr_refresh_error")
  expect_equal(cnd$reason, "timeout")
  expect_no_match(conditionMessage(cnd), "secret-token")
  expect_false(file.exists(request$destfile))
})

test_that("a TLS failure and a DNS failure keep their reasons apart", {
  request <- local_request()
  tls <- tryCatch(
    psl_curl_failed(simpleError("SSL peer handshake failed"), request),
    condition = identity
  )
  dns <- tryCatch(
    psl_curl_failed(simpleError("Could not resolve host"), request),
    condition = identity
  )

  expect_equal(tls$reason, "tls")
  expect_equal(dns$reason, "dns")
})

test_that("a libcurl message holding invalid UTF-8 is a transport error", {
  # The classed error, not base R's "invalid input multibyte string", reaches
  # the caller of psl_refresh() (PSLR-ejksqarh).
  local_utf8_ctype()
  request <- local_request()
  cnd <- tryCatch(
    psl_curl_failed(simpleError("Could not resolve host: \xff\xfe"), request),
    condition = identity
  )

  expect_s3_class(cnd, "pslr_refresh_transport_error")
  expect_s3_class(cnd, "pslr_refresh_error")
  expect_equal(cnd$reason, "dns")
})

test_that("a transfer aborted by the size ceiling is a limit error", {
  request <- local_request()
  cnd <- tryCatch(
    psl_curl_failed(simpleError("Maximum file size exceeded"), request),
    condition = identity
  )

  expect_s3_class(cnd, "pslr_refresh_response_limit_error")
  expect_equal(cnd$limit_bytes, 16777216)
})

test_that("a decoded body over the ceiling is rejected and discarded", {
  request <- local_request(max_bytes = 64)
  writeLines(strrep("x", 200L), request$destfile)
  fetched <- list(status_code = 200L, url = request$url, headers = raw())

  cnd <- tryCatch(
    psl_curl_response(fetched, NULL, request),
    condition = identity
  )

  expect_s3_class(cnd, "pslr_refresh_response_limit_error")
  expect_equal(cnd$limit_bytes, 64)
  expect_false(file.exists(request$destfile))
})

test_that("a 304 response reports no body and discards the staging file", {
  skip_if_not_installed("curl")
  request <- local_request()
  writeLines("", request$destfile)
  fetched <- list(
    status_code = 304L,
    url = request$url,
    headers = charToRaw("HTTP/1.1 304 Not Modified\r\nETag: \"v2\"\r\n\r\n")
  )

  response <- psl_curl_response(fetched, NULL, request)

  expect_equal(response$status, 304L)
  expect_equal(response$body_path, NA_character_)
  expect_equal(response$bytes_downloaded, 0L)
  expect_equal(psl_response_header(response, "etag"), "\"v2\"")
  expect_false(file.exists(request$destfile))
})

test_that("a 200 response reports the staged body and its byte count", {
  skip_if_not_installed("curl")
  request <- local_request()
  writeBin(as.raw(rep(65L, 10L)), request$destfile)
  fetched <- list(
    status_code = 200L,
    url = "https://cdn.example.org/list.dat",
    headers = charToRaw("HTTP/1.1 200 OK\r\nETag: \"v3\"\r\n\r\n")
  )

  response <- psl_curl_response(fetched, NULL, request)

  expect_equal(response$status, 200L)
  expect_equal(response$body_path, request$destfile)
  expect_equal(response$bytes_downloaded, 10L)
  expect_equal(response$effective_url, "https://cdn.example.org/list.dat")
})

test_that("one header byte that is not valid UTF-8 drops no other header", {
  # curl::parse_headers_list() returns an empty list for the whole block when
  # any header holds such a byte under a UTF-8 ctype, which lost the
  # validators and Retry-After (PSLR-mlnfdltl).
  skip_if_not_installed("curl")
  local_utf8_ctype()
  request <- local_request()
  writeLines("", request$destfile)
  block <- c(
    charToRaw("HTTP/1.1 503 Service Unavailable\r\nETag: \"v4\"\r\n"),
    charToRaw("Last-Modified: Mon, 05 Oct 2026 10:00:00 GMT\r\nX-B"),
    as.raw(0xff),
    charToRaw("d: v"),
    as.raw(0xfe),
    charToRaw("\r\nRetry-After: 30\r\n\r\n")
  )
  fetched <- list(status_code = 503L, url = request$url, headers = block)

  expect_no_condition(response <- psl_curl_response(fetched, NULL, request))
  expect_equal(psl_response_header(response, "etag"), "\"v4\"")
  expect_equal(
    psl_response_header(response, "last-modified"),
    "Mon, 05 Oct 2026 10:00:00 GMT"
  )
  expect_equal(psl_response_retry_after(response), 30L)
  expect_equal(psl_response_header(response, "x-b<ff>d"), "v<fe>")
})

test_that("a valid UTF-8 header block parses as before", {
  skip_if_not_installed("curl")
  local_utf8_ctype()
  request <- local_request()
  writeLines("", request$destfile)
  value <- intToUtf8(c(0x7A, 0xF3, 0x142, 0x77))
  block <- charToRaw(enc2utf8(paste0(
    "HTTP/1.1 304 Not Modified\r\nETag: \"v5\"\r\nX-Name: ",
    value,
    "\r\n\r\n"
  )))
  fetched <- list(status_code = 304L, url = request$url, headers = block)

  response <- psl_curl_response(fetched, NULL, request)

  expect_equal(psl_response_header(response, "etag"), "\"v5\"")
  expect_equal(psl_response_header(response, "x-name"), value)
})

test_that("a valid UTF-8 header beside an invalid one is read as sent", {
  # The escape is per header: one bad byte elsewhere in the block must not
  # rewrite the characters of another header (PSLR-mlnfdltl).
  skip_if_not_installed("curl")
  local_utf8_ctype()
  request <- local_request()
  writeLines("", request$destfile)
  etag <- enc2utf8(paste0("\"caf", intToUtf8(0xE9), "\""))
  block <- c(
    charToRaw("HTTP/1.1 200 OK\r\nETag: "),
    charToRaw(etag),
    charToRaw("\r\nX-A: "),
    as.raw(0xff),
    charToRaw("\r\n\r\n")
  )
  fetched <- list(status_code = 200L, url = request$url, headers = block)

  response <- psl_curl_response(fetched, NULL, request)

  expect_identical(
    charToRaw(psl_response_header(response, "etag")),
    charToRaw(etag)
  )
  expect_equal(psl_response_header(response, "x-a"), "<ff>")
})

test_that("an empty or missing header block reads as no headers", {
  skip_if_not_installed("curl")
  local_utf8_ctype()

  expect_length(psl_curl_headers(raw()), 0L)
  expect_length(psl_curl_headers(NULL), 0L)

  request <- local_request()
  writeLines("", request$destfile)
  fetched <- list(status_code = 304L, url = request$url, headers = raw())
  response <- psl_curl_response(fetched, NULL, request)
  expect_length(response$headers, 0L)
})

test_that("an obs-text ETag from curl reaches If-None-Match byte for byte", {
  # A Latin-1 entity tag is allowed by RFC 9110 and is not valid UTF-8. It is
  # stored as the server sent it and sent back the same way: never escaped,
  # and handed to curl unchanged (PSLR-tiugfvxh).
  skip_if_not_installed("curl")
  local_utf8_ctype()
  etag <- c(charToRaw("\"caf"), as.raw(0xe9), charToRaw("\""))
  staging <- local_request()
  writeLines("", staging$destfile)
  block <- c(
    charToRaw("HTTP/1.1 200 OK\r\nETag: "),
    etag,
    charToRaw("\r\n\r\n")
  )
  fetched <- list(status_code = 200L, url = staging$url, headers = block)

  response <- psl_curl_response(fetched, NULL, staging)
  expect_identical(charToRaw(psl_response_header(response, "etag")), etag)

  stored <- psl_validator_update(NA_character_, NA_character_, response$headers)
  conditional <- psl_validator_request(stored$etag, stored$last_modified)
  expect_no_condition(request <- local_request(headers = conditional$headers))
  expect_identical(charToRaw(request$headers[["if-none-match"]]), etag)

  sent <- NULL
  local_mocked_bindings(
    handle_setheaders = function(handle, ..., .list = list()) {
      sent <<- .list
      handle
    },
    .package = "curl"
  )
  psl_curl_handle(request)
  expect_identical(charToRaw(sent[["if-none-match"]]), etag)
})

test_that("curl takes an obs-text request header without a warning", {
  # curl::handle_setheaders() runs a regex over each value, which warns on
  # bytes that are not valid UTF-8 under a UTF-8 ctype; libcurl itself sends
  # them as they are (PSLR-tiugfvxh).
  skip_if_not_installed("curl")
  local_utf8_ctype()
  ctype <- Sys.getlocale("LC_CTYPE")
  request <- local_request()
  request$headers <- c("if-none-match" = "\"caf\xe9\"")

  expect_no_condition(psl_curl_handle(request))
  expect_identical(Sys.getlocale("LC_CTYPE"), ctype)
})

test_that("an obs-text request validator is checked by its bytes", {
  # Bytes 0x80-0x9F are obs-text on the wire, not control characters, so a
  # stored validator holding one is sent rather than refused (PSLR-tiugfvxh).
  local_utf8_ctype()
  value <- "\"a\x85\xe9\""

  expect_no_condition(
    request <- local_request(
      headers = c("If-None-Match" = value)
    )
  )
  expect_identical(
    charToRaw(request$headers[["if-none-match"]]),
    charToRaw(value)
  )
  expect_error(
    local_request(headers = c("If-None-Match" = "\"a\xe9\r\nX: 1\"")),
    "control characters"
  )
})

test_that("repeated validator headers read the same in vector and list form", {
  # The repeated fields are combined first and the result judged as one, so
  # the outcome cannot depend on the shape the transport used (PSLR-tiugfvxh).
  local_utf8_ctype()
  vector <- c(ETag = " \"a\" ", etag = " \"b\xff\" ")
  listed <- list(etag = c(" \"a\" ", " \"b\xff\" "))

  expect_identical(
    psl_normalize_headers(vector),
    psl_normalize_headers(listed)
  )
  expect_identical(
    charToRaw(psl_normalize_headers(listed)[["etag"]]),
    charToRaw("\"a\", \"b\xff\"")
  )
  expect_identical(
    psl_validator_update("\"old\"", NA_character_, vector),
    psl_validator_update("\"old\"", NA_character_, listed)
  )
})
