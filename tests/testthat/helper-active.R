# Test helpers for refresh / activation (PRD s7.4, s11.3; freshness v2).

# Path to the bundled PSL source snapshot used as an offline download fixture.
bundled_dat_path <- function() {
  system.file("extdata", "public_suffix_list.dat", package = "pslr")
}

# A complete but minimal PSL, written to a temporary file. `extra` adds ICANN
# rules, which is how a test produces upstream bytes that differ from the
# bundled fixture without touching the network.
write_test_list <- function(extra = character(), path = NULL) {
  if (is.null(path)) {
    path <- tempfile("pslr-list-", fileext = ".dat")
  }
  writeLines(
    c(
      "// ===BEGIN ICANN DOMAINS===",
      "com",
      "co.uk",
      extra,
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      "example.com",
      "// ===END PRIVATE DOMAINS==="
    ),
    path
  )
  path
}

# One field of a transport step, with its default.
step_field <- function(step, name, default) {
  value <- step[[name]]
  if (is.null(value)) default else value
}

# Install a scripted offline transport for the calling test.
#
# Each element of `steps` answers one request in order; anything past the end
# repeats the last step, and an empty script answers every request with HTTP 200
# carrying the bundled list. A step is a list with any of `status`, `headers`,
# and `path` (a local file whose bytes become the response body). Only a `200`
# carries a body, which is also what the real transport does with a `304`.
#
# Returns the recording environment, so a test can assert the exact number of
# requests -- zero for a courtesy skip, one for a conditional check, two for a
# `304` repair -- and inspect the headers that were actually sent.
local_fake_transport <- function(steps = list(), .env = parent.frame()) {
  state <- new.env(parent = emptyenv())
  state$requests <- list()
  transport <- function(request) {
    n <- length(state$requests) + 1L
    state$requests[[n]] <- request
    step <- if (n <= length(steps)) {
      steps[[n]]
    } else if (length(steps)) {
      steps[[length(steps)]]
    } else {
      list()
    }
    status <- as.integer(step_field(step, "status", 200L))
    has_body <- identical(status, 200L)
    if (has_body) {
      src <- step_field(step, "path", bundled_dat_path())
      if (!file.copy(src, request$destfile, overwrite = TRUE)) {
        stop("fake transport could not stage its fixture", call. = FALSE)
      }
    }
    new_psl_transport_response(
      status = status,
      headers = step_field(step, "headers", psl_empty_headers()),
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

request_count <- function(state) length(state$requests)

# Headers actually sent with request `n`, as a named character vector.
request_headers <- function(state, n = 1L) state$requests[[n]]$headers

# Seed a v1 (pre-freshness) cache: a content-addressed `psl-<hex>.dat` plus the
# `current.rds` commit marker naming it. Returns the marker's `dat_file` name.
seed_legacy_cache <- function(dir, src = bundled_dat_path()) {
  checksum <- psl_source_checksum(src)
  dat_file <- paste0("psl-", sub("^sha256:", "", checksum), ".dat")
  dat <- file.path(dir, dat_file)
  file.copy(src, dat, overwrite = TRUE)
  saveRDS(
    list(
      dat_file = dat_file,
      meta = psl_meta(
        source = "cache",
        path = dat,
        retrieved_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
        size = as.integer(file.size(dat)),
        checksum = checksum
      )
    ),
    file.path(dir, "current.rds")
  )
  dat_file
}

# Isolate session state for one test: private cache and config directories, no
# leaked transport, no lock the previous test forgot to release, and a reset
# active list before and after the test body.
local_pslr_clean <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(
    pslr.cache_dir = dir,
    pslr.config_dir = file.path(dir, "config"),
    pslr.transport = NULL,
    pslr.max_bytes = NULL,
    pslr.clock = NULL,
    .local_envir = env
  )
  psl_lock_state$held <- character()
  reset_active_for_test()
  withr::defer(
    {
      psl_lock_state$held <- character()
      reset_active_for_test()
    },
    envir = env
  )
  dir
}

reset_active_for_test <- function() {
  # Nulling the state discards the engine and its cache; the next query lazily
  # rebuilds a fresh engine carrying a fresh empty cache.
  the_matcher$state <- NULL
  invisible(NULL)
}
