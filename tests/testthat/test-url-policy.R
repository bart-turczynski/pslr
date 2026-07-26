# Every test here is fully offline: URL policy is pure string work, and the
# redirect tests drive a scripted transport injected through the
# `pslr.transport` option. Nothing in this file opens a socket.

# One scripted hop. `status` defaults to 200 and `location` adds the header a
# redirect needs; anything past the end of the script answers 200.
scripted_step <- function(step) {
  status <- if (is.null(step$status)) 200L else as.integer(step$status)
  headers <- psl_empty_headers()
  if (!is.null(step$location)) {
    headers <- c(headers, location = step$location)
  }
  list(status = status, headers = headers)
}

# Install an offline transport that answers each request from `script` in turn
# and records every request it saw.
local_scripted_transport <- function(script, .env = parent.frame()) {
  state <- new.env(parent = emptyenv())
  state$requests <- list()
  transport <- function(request) {
    n <- length(state$requests) + 1L
    state$requests[[n]] <- request
    step <- scripted_step(if (n <= length(script)) script[[n]] else list())
    has_body <- !identical(step$status, 304L)
    if (has_body) {
      writeBin(charToRaw("body"), request$destfile)
    }
    new_psl_transport_response(
      status = step$status,
      headers = step$headers,
      effective_url = request$url,
      body_path = if (has_body) request$destfile else NA_character_,
      bytes_downloaded = if (has_body) 4L else 0L
    )
  }
  withr::local_options(pslr.transport = transport, .local_envir = .env)
  state
}

local_destfile <- function(.env = parent.frame()) {
  file.path(withr::local_tempdir(.local_envir = .env), "body.part")
}

# Field names of every request the scripted transport saw.
request_urls <- function(state) {
  vapply(state$requests, \(request) request$url, character(1))
}

request_header <- function(state, n, field) {
  psl_response_header(state$requests[[n]], field)
}

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

test_that("normalization lowercases the scheme and the host", {
  expect_equal(
    psl_normalize_source_url("HTTPS://PubliCSuffix.ORG/list/psl.dat"),
    "https://publicsuffix.org/list/psl.dat"
  )
})

test_that("normalization removes the default https port only", {
  expect_equal(
    psl_normalize_source_url("https://example.org:443/list.dat"),
    "https://example.org/list.dat"
  )
  expect_equal(
    psl_normalize_source_url("https://example.org:8443/list.dat"),
    "https://example.org:8443/list.dat"
  )
})

test_that("normalization turns an empty path into a root path", {
  expect_equal(
    psl_normalize_source_url("https://example.org"),
    "https://example.org/"
  )
  expect_equal(
    psl_normalize_source_url("https://example.org:443"),
    "https://example.org/"
  )
})

test_that("normalization preserves every other path byte verbatim", {
  expect_equal(
    psl_normalize_source_url("https://Example.ORG/List/%7Euser/PSL.dat"),
    "https://example.org/List/%7Euser/PSL.dat"
  )
  expect_equal(
    psl_normalize_source_url("https://example.org//a//b/"),
    "https://example.org//a//b/"
  )
  expect_equal(
    psl_normalize_source_url("https://example.org/%2e%2E/x"),
    "https://example.org/%2e%2E/x"
  )
})

test_that("normalized identity is what the source stream name hashes", {
  spellings <- c(
    "https://example.org:443/list.dat",
    "HTTPS://Example.ORG/list.dat"
  )
  names <- vapply(
    spellings,
    \(url) psl_source_stream_name(psl_normalize_source_url(url)),
    character(1)
  )

  expect_equal(unname(names[[2L]]), unname(names[[1L]]))
  expect_false(
    identical(
      names[[1L]],
      psl_source_stream_name(
        psl_normalize_source_url("https://example.org/List.dat")
      )
    )
  )
})

# ---------------------------------------------------------------------------
# Acceptance
# ---------------------------------------------------------------------------

test_that("a query string is rejected so a token cannot be persisted", {
  err <- expect_error(
    psl_normalize_source_url("https://example.org/list.dat?token=secret"),
    class = "pslr_refresh_url_policy_error"
  )

  expect_match(conditionMessage(err), "query string")
  expect_error(
    psl_normalize_source_url("https://example.org/list.dat?"),
    "query string"
  )
})

test_that("a fragment is rejected", {
  err <- expect_error(
    psl_normalize_source_url("https://example.org/list.dat#part"),
    class = "pslr_refresh_url_policy_error"
  )

  expect_match(conditionMessage(err), "fragment")
})

test_that("userinfo is rejected and redacted in the message", {
  err <- expect_error(
    psl_normalize_source_url("https://user:hunter2@example.org/list.dat"),
    class = "pslr_refresh_url_policy_error"
  )

  expect_match(conditionMessage(err), "credentials")
  expect_match(conditionMessage(err), "<redacted>@example.org", fixed = TRUE)
  expect_no_match(conditionMessage(err), "hunter2", fixed = TRUE)
  expect_no_match(err$request_url, "hunter2", fixed = TRUE)
})

test_that("a non-https scheme is rejected", {
  expect_error(
    psl_normalize_source_url("http://example.org/list.dat"),
    class = "pslr_refresh_url_policy_error"
  )
  expect_error(
    psl_normalize_source_url("ftp://example.org/list.dat"),
    "not an https URL"
  )
  expect_error(
    psl_normalize_source_url("file:///etc/passwd"),
    "not an https URL"
  )
})

test_that("a relative or malformed URL is rejected", {
  expect_error(
    psl_normalize_source_url("/list/psl.dat"),
    "not an absolute URL"
  )
  expect_error(
    psl_normalize_source_url("example.org/list.dat"),
    "not an absolute URL"
  )
  expect_error(
    psl_normalize_source_url("//example.org/list.dat"),
    class = "pslr_refresh_url_policy_error"
  )
})

test_that("a missing or unusable host is rejected", {
  expect_error(psl_normalize_source_url("https:///list.dat"), "usable host")
  expect_error(
    psl_normalize_source_url("https://example.org:80x/list.dat"),
    "usable host"
  )
  expect_error(
    psl_normalize_source_url("https://ex ample.org/list.dat"),
    class = "pslr_refresh_url_policy_error"
  )
})

test_that("a control character in the URL is rejected", {
  expect_error(
    psl_normalize_source_url("https://example.org/list\r\nX-Evil: 1"),
    "control characters"
  )
})

test_that("a non-string URL is rejected", {
  expect_error(psl_normalize_source_url(NA_character_), "single non-empty")
  expect_error(psl_normalize_source_url(""), "single non-empty")
  expect_error(psl_normalize_source_url(character()), "single non-empty")
  expect_error(psl_normalize_source_url(42), "single non-empty")
})

# ---------------------------------------------------------------------------
# Redirect targets
# ---------------------------------------------------------------------------

test_that("a redirect target may be absolute or root-relative", {
  current <- "https://example.org/list.dat"

  expect_equal(
    psl_redirect_target(current, "https://EXAMPLE.org:443/new.dat"),
    "https://example.org/new.dat"
  )
  expect_equal(
    psl_redirect_target(current, "/new/list.dat"),
    "https://example.org/new/list.dat"
  )
  expect_equal(
    psl_redirect_target(current, "//example.org/new.dat"),
    "https://example.org/new.dat"
  )
})

test_that("a cross-origin redirect target is refused", {
  current <- "https://example.org/list.dat"

  expect_error(
    psl_redirect_target(current, "https://evil.example/list.dat"),
    class = "pslr_refresh_url_policy_error"
  )
  expect_error(
    psl_redirect_target(current, "https://example.org:8443/list.dat"),
    "same-origin"
  )
  expect_error(
    psl_redirect_target(current, "//evil.example/list.dat"),
    "same-origin"
  )
})

test_that("a redirect to plain http is refused", {
  expect_error(
    psl_redirect_target(
      "https://example.org/list.dat",
      "http://example.org/list.dat"
    ),
    "not an https URL"
  )
})

test_that("an unresolvable or absent Location is refused", {
  current <- "https://example.org/a/list.dat"

  expect_error(psl_redirect_target(current, "new.dat"), "absolute URL")
  expect_error(
    psl_redirect_target(current, NA_character_),
    "without a Location"
  )
  expect_error(psl_redirect_target(current, ""), "without a Location")
})

test_that("same-origin compares scheme, host, and port", {
  expect_true(psl_same_origin(
    "https://example.org/a",
    "https://example.org/b/c"
  ))
  expect_false(psl_same_origin(
    "https://example.org/a",
    "https://example.org:8443/a"
  ))
})

# ---------------------------------------------------------------------------
# Validator scope
# ---------------------------------------------------------------------------

test_that("a validator is scoped to the exact issuer URL", {
  validator <- c("If-None-Match" = "\"abc\"")

  expect_named(
    psl_scoped_validator_headers(
      "https://example.org/list.dat",
      validator,
      "https://example.org/list.dat"
    ),
    "if-none-match"
  )
  expect_length(
    psl_scoped_validator_headers(
      "https://example.org/list.dat",
      validator,
      "https://example.org/other.dat"
    ),
    0L
  )
  expect_length(
    psl_scoped_validator_headers(
      "https://example.org/list.dat",
      validator,
      NA_character_
    ),
    0L
  )
})

# ---------------------------------------------------------------------------
# Policy-driven fetch
# ---------------------------------------------------------------------------

test_that("a fetch normalizes the request URL before asking the transport", {
  state <- local_scripted_transport(list(list(status = 200L)))

  result <- psl_fetch_with_policy(
    "HTTPS://Example.ORG:443/list.dat",
    local_destfile()
  )

  expect_equal(result$request_url, "https://example.org/list.dat")
  expect_equal(result$effective_url, "https://example.org/list.dat")
  expect_equal(result$redirects, 0L)
  expect_equal(request_urls(state), "https://example.org/list.dat")
})

test_that("a fetch follows up to five same-origin hops one at a time", {
  script <- c(
    lapply(1:5, \(n) list(status = 302L, location = sprintf("/hop%d", n))),
    list(list(status = 200L))
  )
  state <- local_scripted_transport(script)

  result <- psl_fetch_with_policy(
    "https://example.org/list.dat",
    local_destfile()
  )

  expect_equal(result$redirects, 5L)
  expect_equal(result$response$status, 200L)
  expect_equal(result$request_url, "https://example.org/list.dat")
  expect_equal(result$effective_url, "https://example.org/hop5")
  expect_length(state$requests, 6L)
})

test_that("a sixth redirect is refused", {
  script <- lapply(1:6, \(n) list(status = 302L, location = sprintf("/h%d", n)))
  state <- local_scripted_transport(script)

  expect_error(
    psl_fetch_with_policy("https://example.org/list.dat", local_destfile()),
    class = "pslr_refresh_url_policy_error"
  )
  expect_length(state$requests, 6L)
})

test_that("a cross-origin redirect ends the fetch before the next request", {
  state <- local_scripted_transport(list(
    list(status = 301L, location = "https://evil.example/list.dat")
  ))
  destfile <- local_destfile()

  err <- expect_error(
    psl_fetch_with_policy("https://example.org/list.dat", destfile),
    class = "pslr_refresh_url_policy_error"
  )

  expect_match(conditionMessage(err), "same-origin")
  expect_length(state$requests, 1L)
  expect_false(file.exists(destfile))
})

test_that("a redirect to plain http ends the fetch", {
  state <- local_scripted_transport(list(
    list(status = 302L, location = "http://example.org/list.dat")
  ))

  expect_error(
    psl_fetch_with_policy("https://example.org/list.dat", local_destfile()),
    "not an https URL"
  )
  expect_length(state$requests, 1L)
})

test_that("a validator is sent when the target equals the issuer", {
  state <- local_scripted_transport(list(list(status = 304L)))

  result <- psl_fetch_with_policy(
    "https://example.org/list.dat",
    local_destfile(),
    validator_headers = c("If-None-Match" = "\"abc\""),
    validator_issuer = "https://example.org/list.dat"
  )

  expect_true(result$validator_sent)
  expect_equal(request_header(state, 1L, "if-none-match"), "\"abc\"")
})

test_that("a validator is never forwarded to a changed redirect target", {
  state <- local_scripted_transport(list(
    list(status = 302L, location = "/moved.dat"),
    list(status = 200L)
  ))

  result <- psl_fetch_with_policy(
    "https://example.org/list.dat",
    local_destfile(),
    validator_headers = c("If-None-Match" = "\"abc\""),
    validator_issuer = "https://example.org/list.dat"
  )

  expect_equal(request_header(state, 1L, "if-none-match"), "\"abc\"")
  expect_equal(request_header(state, 2L, "if-none-match"), NA_character_)
  expect_equal(result$effective_url, "https://example.org/moved.dat")
  expect_false(result$validator_sent)
})

test_that("a validator issued by another source URL is never sent", {
  state <- local_scripted_transport(list(list(status = 200L)))

  result <- psl_fetch_with_policy(
    "https://example.org/list.dat",
    local_destfile(),
    validator_headers = c("If-None-Match" = "\"abc\""),
    validator_issuer = "https://other.example/list.dat"
  )

  expect_false(result$validator_sent)
  expect_equal(request_header(state, 1L, "if-none-match"), NA_character_)
})

test_that("a fetch keeps sending the caller's own headers across hops", {
  state <- local_scripted_transport(list(
    list(status = 307L, location = "/moved.dat"),
    list(status = 200L)
  ))

  psl_fetch_with_policy(
    "https://example.org/list.dat",
    local_destfile(),
    headers = c("Accept" = "text/plain"),
    validator_headers = c("If-None-Match" = "\"abc\""),
    validator_issuer = "https://example.org/list.dat"
  )

  expect_equal(request_header(state, 2L, "accept"), "text/plain")
})

test_that("a fetch rejects an unknown request argument", {
  local_scripted_transport(list(list(status = 200L)))

  expect_error(
    psl_fetch_with_policy(
      "https://example.org/list.dat",
      local_destfile(),
      timeoot = 5
    ),
    class = "error"
  )
})
