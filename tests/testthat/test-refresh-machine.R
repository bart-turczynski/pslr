# Every test here is fully offline and clock-injected: the transport is a
# scripted double installed through `pslr.transport`, `now` is always an
# explicit instant, and snapshot verification is an injected predicate rather
# than a real cache. Nothing in this file opens a socket or reads the clock.

machine_url <- "https://example.test/list.dat"

# A minimal but complete PSL: both official sections, one rule each.
machine_list <- function(extra = character()) {
  c(
    "// ===BEGIN ICANN DOMAINS===",
    "com",
    extra,
    "// ===END ICANN DOMAINS===",
    "// ===BEGIN PRIVATE DOMAINS===",
    "example.test",
    "// ===END PRIVATE DOMAINS==="
  )
}

# The checksum identity the scripted transport's bytes will hash to.
machine_checksum <- function(lines) {
  path <- tempfile("machine-", fileext = ".dat")
  on.exit(unlink(path), add = TRUE)
  writeLines(lines, path)
  psl_source_checksum(path)
}

machine_now <- function(stamp = "2026-07-01T00:00:00Z") psl_parse_time(stamp)

# A snapshot verifier that recognizes exactly the listed checksums.
verify_known <- function(known = character()) {
  force(known)
  function(checksum) {
    is.character(checksum) && !is.na(checksum) && any(checksum == known)
  }
}

# Install an offline transport answering each request from `steps` in turn and
# recording every request it saw. A step is a list with any of `status`,
# `headers`, `body` (character lines), and `effective_url`; anything past the
# end of the script answers 200 with a valid list.
local_machine_transport <- function(steps = list(), .env = parent.frame()) {
  state <- new.env(parent = emptyenv())
  state$requests <- list()
  transport <- function(request) {
    n <- length(state$requests) + 1L
    state$requests[[n]] <- request
    step <- if (n <= length(steps)) steps[[n]] else list(body = machine_list())
    status <- if (is.null(step$status)) 200L else as.integer(step$status)
    has_body <- !identical(status, 304L) && !is.null(step$body)
    if (has_body) {
      writeLines(step$body, request$destfile)
    }
    new_psl_transport_response(
      status = status,
      headers = if (is.null(step$headers)) {
        psl_empty_headers()
      } else {
        step$headers
      },
      effective_url = request$url,
      body_path = if (has_body) request$destfile else NA_character_,
      bytes_downloaded = if (has_body) {
        as.integer(file.size(request$destfile))
      } else {
        0L
      }
    )
  }
  withr::local_options(pslr.transport = transport, .local_envir = .env)
  state
}

machine_destfile <- function(.env = parent.frame()) {
  file.path(withr::local_tempdir(.local_envir = .env), "body.part")
}

request_count <- function(state) length(state$requests)

machine_request_header <- function(state, n, field) {
  psl_response_header(state$requests[[n]], field)
}

# A stored source state for `machine_url`. Defaults describe a source last
# confirmed a day before `machine_now()` and still inside its courtesy window.
machine_state <- function(...) {
  fields <- list(...)
  defaults <- list(
    request_url = machine_url,
    effective_url = machine_url,
    validator_url = machine_url,
    checksum = machine_checksum(machine_list()),
    etag = "\"v1\"",
    retrieved_at = "2026-06-30T00:00:00Z",
    checked_at = "2026-06-30T00:00:00Z",
    next_check_at = "2026-07-02T00:00:00Z",
    last_attempt_at = "2026-06-30T00:00:00Z",
    last_result = "updated"
  )
  do.call(new_psl_source_state, utils::modifyList(defaults, fields))
}

# ---------------------------------------------------------------------------
# Courtesy window
# ---------------------------------------------------------------------------

test_that("a verified snapshot inside the courtesy window makes no request", {
  transport <- local_machine_transport()
  state <- machine_state()
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(request_count(transport), 0L)
  expect_equal(plan$outcome, "skipped_recently")
  expect_equal(plan$requests, 0L)
  expect_equal(plan$checked_at, "2026-06-30T00:00:00Z")
  expect_equal(plan$checksum, state$checksum)
  expect_false(plan$publish_state)
  expect_false(plan$publish_snapshot)
  expect_null(plan$state)
})

test_that("a skip reports no HTTP status, no body, and no validator", {
  local_machine_transport()
  state <- machine_state()
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_true(is.na(plan$http_status))
  expect_true(is.na(plan$bytes_downloaded))
  expect_equal(plan$validator, "none")
})

test_that("the courtesy window never covers a snapshot that does not verify", {
  transport <- local_machine_transport(list(list(status = 304L)))
  state <- machine_state()
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known()
  )
  expect_equal(request_count(transport), 2L)
  expect_equal(plan$outcome, "downloaded_unchanged")
})

test_that("force bypasses the courtesy window but still sends a validator", {
  transport <- local_machine_transport(list(list(status = 304L)))
  state <- machine_state()
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    force = TRUE,
    verify = verify_known(state$checksum)
  )
  expect_equal(request_count(transport), 1L)
  expect_equal(machine_request_header(transport, 1L, "if-none-match"), "\"v1\"")
  expect_equal(plan$outcome, "not_modified")
  expect_equal(plan$validator, "etag")
})

test_that("a source that was never seen goes straight to a request", {
  transport <- local_machine_transport()
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    now = machine_now(),
    verify = verify_known()
  )
  expect_equal(request_count(transport), 1L)
  expect_equal(plan$outcome, "updated")
  expect_true(is.na(plan$previous_checksum))
})

# ---------------------------------------------------------------------------
# Validator selection
# ---------------------------------------------------------------------------

test_that("an unconditional GET goes out when no validator is stored", {
  transport <- local_machine_transport()
  state <- machine_state(etag = NA_character_, next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_true(is.na(machine_request_header(transport, 1L, "if-none-match")))
  expect_true(
    is.na(machine_request_header(transport, 1L, "if-modified-since"))
  )
  expect_equal(plan$validator, "none")
})

test_that("Last-Modified is used when no usable ETag is stored", {
  transport <- local_machine_transport(list(list(status = 304L)))
  state <- machine_state(
    etag = NA_character_,
    last_modified = "Mon, 29 Jun 2026 00:00:00 GMT",
    next_check_at = NA
  )
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(
    machine_request_header(transport, 1L, "if-modified-since"),
    "Mon, 29 Jun 2026 00:00:00 GMT"
  )
  expect_equal(plan$validator, "last_modified")
})

test_that("a redirect that invalidates the validator scope drops it", {
  transport <- local_machine_transport(list(
    list(status = 301L, headers = c(location = "/moved/list.dat"))
  ))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(request_count(transport), 2L)
  expect_true(is.na(machine_request_header(transport, 2L, "if-none-match")))
  expect_equal(plan$validator, "none")
  expect_equal(plan$effective_url, "https://example.test/moved/list.dat")
  expect_equal(plan$state$validator_url, "https://example.test/moved/list.dat")
  expect_true(is.na(plan$state$etag))
})

# ---------------------------------------------------------------------------
# 304 with usable local bytes
# ---------------------------------------------------------------------------

test_that("a 304 over verified bytes advances only checked_at", {
  local_machine_transport(list(list(status = 304L)))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(plan$outcome, "not_modified")
  expect_equal(plan$http_status, 304L)
  expect_equal(plan$checksum, state$checksum)
  expect_equal(plan$state$checksum, state$checksum)
  expect_equal(plan$state$retrieved_at, state$retrieved_at)
  expect_equal(plan$state$checked_at, "2026-07-01T00:00:00Z")
  expect_true(plan$publish_state)
  expect_false(plan$publish_snapshot)
  expect_true(is.na(plan$path))
})

test_that("a 304 accepts a rotated validator", {
  local_machine_transport(list(
    list(status = 304L, headers = c(etag = "\"v2\""))
  ))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(plan$state$etag, "\"v2\"")
})

test_that("a 304 sets next_check_at from server freshness", {
  local_machine_transport(list(
    list(
      status = 304L,
      headers = c("cache-control" = "max-age=200000", age = "100")
    )
  ))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(plan$state$next_check_at, "2026-07-03T07:31:40Z")
})

test_that("a 304 to a request that carried no validator is refused", {
  local_machine_transport(list(list(status = 304L)))
  state <- machine_state(etag = NA_character_, next_check_at = NA)
  expect_error(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      state = state,
      now = machine_now(),
      verify = verify_known(state$checksum)
    ),
    class = "pslr_refresh_transport_error"
  )
})

# ---------------------------------------------------------------------------
# 304 repair
# ---------------------------------------------------------------------------

test_that("a 304 over unusable bytes makes exactly one repair request", {
  transport <- local_machine_transport(list(list(status = 304L)))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known()
  )
  expect_equal(request_count(transport), 2L)
  expect_equal(plan$requests, 2L)
  expect_true(is.na(machine_request_header(transport, 2L, "if-none-match")))
  expect_equal(plan$validator, "none")
})

test_that("repaired bytes are republished even when the checksum matches", {
  lines <- machine_list()
  transport <- local_machine_transport(list(
    list(status = 304L),
    list(body = lines)
  ))
  state <- machine_state(checksum = machine_checksum(lines), next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known()
  )
  expect_equal(request_count(transport), 2L)
  expect_equal(plan$outcome, "downloaded_unchanged")
  expect_true(plan$publish_snapshot)
  expect_equal(plan$checksum, state$checksum)
})

test_that("a repair download of different bytes is an update", {
  transport <- local_machine_transport(list(
    list(status = 304L),
    list(body = machine_list("net"))
  ))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known()
  )
  expect_equal(plan$outcome, "updated")
  expect_equal(plan$previous_checksum, state$checksum)
  expect_equal(plan$checksum, machine_checksum(machine_list("net")))
  expect_true(plan$publish_snapshot)
})

test_that("a failed repair GET preserves every prior freshness field", {
  transport <- local_machine_transport(list(
    list(status = 304L),
    list(status = 503L, headers = c("retry-after" = "120"))
  ))
  state <- machine_state(next_check_at = NA)
  now <- machine_now()
  failure <- tryCatch(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      state = state,
      now = now,
      verify = verify_known()
    ),
    pslr_refresh_error = \(cnd) cnd
  )
  expect_s3_class(failure, "pslr_refresh_http_status_error")
  expect_equal(failure$status, 503L)
  expect_equal(request_count(transport), 2L)
  recorded <- psl_refresh_failure_state(state, failure, now)
  expect_equal(recorded$checksum, state$checksum)
  expect_equal(recorded$checked_at, state$checked_at)
  expect_equal(recorded$retrieved_at, state$retrieved_at)
  expect_equal(recorded$etag, state$etag)
  expect_equal(recorded$last_result, "http_status_error")
  expect_equal(recorded$last_attempt_at, "2026-07-01T00:00:00Z")
})

test_that("a 304 answering the unconditional repair GET is refused", {
  transport <- local_machine_transport(list(
    list(status = 304L),
    list(status = 304L)
  ))
  state <- machine_state(next_check_at = NA)
  expect_error(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      state = state,
      now = machine_now(),
      verify = verify_known()
    ),
    class = "pslr_refresh_transport_error"
  )
  expect_equal(request_count(transport), 2L)
})

# ---------------------------------------------------------------------------
# 200
# ---------------------------------------------------------------------------

test_that("a 200 with the same checksum creates no snapshot", {
  lines <- machine_list()
  transport <- local_machine_transport(list(
    list(body = lines, headers = c(etag = "\"v2\""))
  ))
  state <- machine_state(checksum = machine_checksum(lines), next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(request_count(transport), 1L)
  expect_equal(plan$outcome, "downloaded_unchanged")
  expect_false(plan$publish_snapshot)
  expect_true(plan$publish_state)
  expect_equal(plan$checksum, state$checksum)
  expect_equal(plan$state$etag, "\"v2\"")
  expect_equal(plan$state$checked_at, "2026-07-01T00:00:00Z")
  expect_equal(plan$state$retrieved_at, "2026-07-01T00:00:00Z")
})

test_that("a 200 with a different checksum requires a new snapshot", {
  lines <- machine_list("net")
  local_machine_transport(list(list(body = lines)))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(plan$outcome, "updated")
  expect_equal(plan$checksum, machine_checksum(lines))
  expect_equal(plan$previous_checksum, state$checksum)
  expect_true(plan$publish_snapshot)
  expect_true(file.exists(plan$path))
  expect_equal(plan$descriptor$first_retrieved_at, "2026-07-01T00:00:00Z")
  expect_equal(plan$state$last_result, "updated")
})

test_that("a 200 reports the status, byte count, and validator sent", {
  local_machine_transport(list(list(body = machine_list("net"))))
  state <- machine_state(next_check_at = NA)
  plan <- psl_refresh_transition(
    machine_url,
    machine_destfile(),
    state = state,
    now = machine_now(),
    verify = verify_known(state$checksum)
  )
  expect_equal(plan$http_status, 200L)
  expect_equal(plan$validator, "etag")
  expect_gt(plan$bytes_downloaded, 0L)
})

# ---------------------------------------------------------------------------
# Rejected bytes
# ---------------------------------------------------------------------------

test_that("a 200 carrying an invalid list is refused with state intact", {
  local_machine_transport(list(list(body = c("// nonsense", "com"))))
  state <- machine_state(next_check_at = NA)
  destfile <- machine_destfile()
  now <- machine_now()
  failure <- tryCatch(
    psl_refresh_transition(
      machine_url,
      destfile,
      state = state,
      now = now,
      verify = verify_known(state$checksum)
    ),
    pslr_refresh_error = \(cnd) cnd
  )
  expect_s3_class(failure, "pslr_refresh_validation_error")
  expect_false(file.exists(destfile))
  recorded <- psl_refresh_failure_state(state, failure, now)
  expect_equal(recorded$checksum, state$checksum)
  expect_equal(recorded$checked_at, state$checked_at)
  expect_equal(recorded$retrieved_at, state$retrieved_at)
  expect_equal(recorded$next_check_at, state$next_check_at)
  expect_equal(recorded$last_result, "validation_error")
})

test_that("a validation failure never quotes the response body", {
  local_machine_transport(list(list(body = c("// nonsense", "com"))))
  state <- machine_state(next_check_at = NA)
  failure <- tryCatch(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      state = state,
      now = machine_now(),
      verify = verify_known(state$checksum)
    ),
    pslr_refresh_error = \(cnd) cnd
  )
  expect_equal(
    conditionMessage(failure),
    "Refresh refused: the downloaded list is not a valid Public Suffix List."
  )
})

test_that("a 200 with no body at all is refused", {
  local_machine_transport(list(list(body = NULL)))
  state <- machine_state(next_check_at = NA)
  expect_error(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      state = state,
      now = machine_now(),
      verify = verify_known(state$checksum)
    ),
    class = "pslr_refresh_validation_error"
  )
})

test_that("a body over the ceiling is refused before it is parsed", {
  withr::local_options(pslr.max_bytes = 16L)
  local_machine_transport(list(list(body = machine_list())))
  state <- machine_state(next_check_at = NA)
  destfile <- machine_destfile()
  expect_error(
    psl_refresh_transition(
      machine_url,
      destfile,
      state = state,
      now = machine_now(),
      verify = verify_known(state$checksum)
    ),
    class = "pslr_refresh_response_limit_error"
  )
  expect_false(file.exists(destfile))
})

test_that("an HTTP failure preserves state and records a coarse attempt", {
  transport <- local_machine_transport(list(list(status = 500L)))
  state <- machine_state(next_check_at = NA)
  now <- machine_now()
  failure <- tryCatch(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      state = state,
      now = now,
      verify = verify_known(state$checksum)
    ),
    pslr_refresh_error = \(cnd) cnd
  )
  expect_equal(request_count(transport), 1L)
  expect_s3_class(failure, "pslr_refresh_http_status_error")
  recorded <- psl_refresh_failure_state(state, failure, now)
  expect_named(
    recorded,
    c(
      "effective_url",
      "validator_url",
      "checksum",
      "etag",
      "last_modified",
      "retrieved_at",
      "checked_at",
      "next_check_at",
      "last_attempt_at",
      "last_result"
    )
  )
  expect_equal(recorded$last_result, "http_status_error")
})

test_that("a foreign condition records no attempt category", {
  state <- machine_state()
  recorded <- psl_refresh_failure_state(
    state,
    simpleError("something else"),
    machine_now()
  )
  expect_true(is.na(recorded$last_result))
  expect_equal(recorded$checked_at, state$checked_at)
})

test_that("a rejected URL never reaches the transport", {
  transport <- local_machine_transport()
  expect_error(
    psl_refresh_transition(
      "http://example.test/list.dat",
      machine_destfile(),
      now = machine_now(),
      verify = verify_known()
    ),
    class = "pslr_refresh_url_policy_error"
  )
  expect_equal(request_count(transport), 0L)
})

test_that("`force` must be a single flag", {
  local_machine_transport()
  expect_error(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      now = machine_now(),
      force = NA,
      verify = verify_known()
    ),
    "single TRUE or FALSE"
  )
})

test_that("a misspelled optional argument is rejected", {
  local_machine_transport()
  expect_error(
    psl_refresh_transition(
      machine_url,
      machine_destfile(),
      forse = TRUE,
      now = machine_now()
    ),
    "Unexpected argument"
  )
})
