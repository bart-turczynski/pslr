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
