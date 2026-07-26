# Cross-cutting acceptance scenarios for freshness v2.
#
# The per-unit suites (refresh, status, snapshots, reminder, prune, migration,
# locking, publication) each prove their own layer. This file proves the rows of
# the specification's acceptance table that NO single one of them can see: what
# happens when refresh, publication, selection, activation, status, reminders,
# inventory, and pruning are exercised together, and what must NOT happen to
# ordinary queries while all of that goes on.
#
# Everything here is offline and deterministic. The transport is a scripted
# double installed through `pslr.transport`, every timestamp derives from the
# injected `pslr.clock`, and process contention is simulated through the lock
# seam -- no test spawns a second R process, opens a socket, or writes outside
# its own temporary directory.

acceptance_a <- "https://a.example/list.dat"
acceptance_b <- "https://b.example/list.dat"

# Freeze the clock every persisted timestamp derives from.
acceptance_clock <- function(
  stamp = "2026-07-01T00:00:00Z",
  .env = parent.frame()
) {
  instant <- psl_parse_time(stamp)
  withr::local_options(pslr.clock = function() instant, .local_envir = .env)
  instant
}

# Reset the once-per-session reminder flag for one test, so file ordering can
# never decide whether a reminder is emitted.
acceptance_reminder_session <- function(.env = parent.frame()) {
  previous <- psl_reminder_session$emitted
  psl_reminder_session$emitted <- FALSE
  withr::defer(psl_reminder_session$emitted <- previous, envir = .env)
  invisible(NULL)
}

# A transport that answers each source URL with its own fixture, and runs
# `during` inside the first request it serves. That callback is how a second
# refresh is made to happen while this one is still "on the network", which is
# the only honest way to observe overlap without a second R process.
local_source_transport <- function(
  fixtures,
  during = NULL,
  .env = parent.frame()
) {
  state <- new.env(parent = emptyenv())
  state$requests <- list()
  state$reentered <- FALSE
  transport <- function(request) {
    state$requests <- c(state$requests, list(request))
    if (!is.null(during) && !state$reentered) {
      state$reentered <- TRUE
      during(request)
    }
    fixture <- fixtures[[request$url]]
    if (!file.copy(fixture, request$destfile, overwrite = TRUE)) {
      stop("acceptance transport could not stage its fixture", call. = FALSE)
    }
    new_psl_transport_response(
      status = 200L,
      headers = psl_empty_headers(),
      effective_url = request$url,
      body_path = request$destfile,
      bytes_downloaded = as.integer(file.size(request$destfile))
    )
  }
  withr::local_options(pslr.transport = transport, .local_envir = .env)
  state
}

# ---------------------------------------------------------------------------
# Refresh handed over to status
# ---------------------------------------------------------------------------

test_that("an unactivated download leaves the engine on an older snapshot", {
  local_pslr_clean()
  now <- acceptance_clock()
  local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("nowhere.example"))
  ))
  first <- psl_refresh(acceptance_a, activate = TRUE)

  updated <- psl_refresh(acceptance_a, force = TRUE)

  # The engine still answers from the snapshot it was given...
  expect_identical(psl_version()$checksum, first$checksum)
  expect_identical(public_suffix("a.nowhere.example"), "example")
  # ...and status says exactly why that is worth knowing.
  active <- psl_status("active", now = now)
  expect_identical(active$state, "update_available")
  expect_identical(active$checksum, first$checksum)
  expect_identical(active$source_checksum, updated$checksum)
  # The newer bytes are the cache choice and are confirmed current.
  cached <- psl_status("cache", now = now)
  expect_identical(cached$state, "confirmed_current")
  expect_identical(cached$checksum, updated$checksum)
})

test_that("activating the download reports a confirmed current engine", {
  local_pslr_clean()
  now <- acceptance_clock()
  local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("nowhere.example"))
  ))
  psl_refresh(acceptance_a, activate = TRUE)

  updated <- psl_refresh(acceptance_a, force = TRUE, activate = TRUE)

  active <- psl_status("active", now = now)
  expect_identical(active$state, "confirmed_current")
  expect_identical(active$checksum, updated$checksum)
  expect_identical(public_suffix("a.nowhere.example"), "nowhere.example")
})

# ---------------------------------------------------------------------------
# Two processes, one source
# ---------------------------------------------------------------------------

test_that("the source lock is held across the request, not just the commit", {
  local_pslr_clean()
  acceptance_clock()
  local_fake_transport(list(list(path = write_test_list())))
  scripted <- getOption("pslr.transport")
  observed <- new.env(parent = emptyenv())
  withr::local_options(pslr.transport = function(request) {
    observed$held <- psl_locks_held()
    scripted(request)
  })

  psl_refresh(acceptance_a)

  # Network time is inside the source lock, so two processes can never have a
  # request to the same endpoint in flight at once. The publish lock is not
  # taken yet, which is what keeps a slow download off other sources.
  expect_identical(observed$held, psl_source_lock_name(acceptance_a))
  expect_length(psl_locks_held(), 0L)
})

test_that("a refresh contended by another process regresses nothing", {
  local_pslr_clean()
  instant <- acceptance_clock()
  transport <- local_fake_transport(list(list(path = write_test_list())))
  first <- psl_refresh(acceptance_a)
  state <- psl_read_source_state(acceptance_a)
  selection <- psl_read_selection()

  # Another process holds the source lock and never lets go: the bounded wait
  # expires immediately, two days after the successful check.
  busy <- withr::with_options(
    list(
      pslr.clock = function() instant + as.difftime(48, units = "hours"),
      pslr.lock_try_create = function(path) FALSE,
      pslr.lock_timeout = 0
    ),
    tryCatch(psl_refresh(acceptance_a, force = TRUE), error = \(e) e)
  )

  expect_s3_class(busy, "pslr_refresh_busy")
  # No request was made, and not one byte of source state or selection moved.
  expect_identical(request_count(transport), 1L)
  expect_identical(psl_read_source_state(acceptance_a), state)
  expect_identical(psl_read_selection(), selection)
  expect_identical(psl_status("cache", now = instant)$checksum, first$checksum)
})

test_that("a clock that moved backwards cannot regress a source's freshness", {
  local_pslr_clean()
  instant <- acceptance_clock("2026-07-02T00:00:00Z")
  local_fake_transport(list(
    list(headers = c(ETag = "\"v1\""), path = write_test_list()),
    list(status = 304L)
  ))
  first <- psl_refresh(acceptance_a)

  # A second process (or an NTP correction) winds the clock back a day. The
  # confirmation is real, but publishing its time would move a source timestamp
  # backwards, which the invariant forbids.
  again <- withr::with_options(
    list(pslr.clock = function() instant - 86400),
    psl_refresh(acceptance_a, force = TRUE)
  )

  expect_identical(again$outcome, "not_modified")
  expect_identical(again$checked_at, first$checked_at)
  record <- psl_read_source_state(acceptance_a)$record
  expect_identical(record$checked_at, "2026-07-02T00:00:00Z")
  expect_identical(record$retrieved_at, "2026-07-02T00:00:00Z")
  # The attempt itself is still recorded, with the time it actually happened.
  expect_identical(record$last_attempt_at, "2026-07-01T00:00:00Z")
})

# ---------------------------------------------------------------------------
# Two processes, two sources
# ---------------------------------------------------------------------------

test_that("overlapping refreshes of two sources publish valid references", {
  local_pslr_clean()
  acceptance_clock()
  fixtures <- list()
  fixtures[[acceptance_a]] <- write_test_list("a.example")
  fixtures[[acceptance_b]] <- write_test_list("b.example")
  nested <- new.env(parent = emptyenv())
  transport <- local_source_transport(
    fixtures,
    during = function(request) {
      # Source A's entire refresh -- request, publication, and selection --
      # completes while source B's download is still in flight.
      nested$result <- psl_refresh(acceptance_a)
    }
  )

  outer <- psl_refresh(acceptance_b)

  expect_identical(request_count(transport), 2L)
  expect_identical(nested$result$outcome, "updated")
  expect_false(identical(nested$result$checksum, outer$checksum))
  # Every mutable reference published by either refresh resolves to bytes that
  # exist and still hash to their own name.
  referenced <- c(
    psl_read_source_state(acceptance_a)$record$checksum,
    psl_read_source_state(acceptance_b)$record$checksum,
    psl_read_selection()$record$checksum
  )
  integrity <- vapply(
    referenced,
    psl_snapshot_integrity,
    character(1L),
    verify = TRUE
  )
  expect_identical(unname(integrity), rep("ok", 3L))
  expect_identical(unique(psl_snapshots(verify = TRUE)$integrity), "ok")
  # The refresh that committed last is the cache choice.
  expect_identical(psl_read_selection()$record$checksum, outer$checksum)
})

# ---------------------------------------------------------------------------
# Inventory, pruning, and refreshing again
# ---------------------------------------------------------------------------

test_that("pruning two sources' history keeps every referenced snapshot", {
  local_pslr_clean()
  acceptance_clock()
  local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("second.example")),
    list(path = write_test_list("third.example"))
  ))
  superseded <- psl_refresh(acceptance_a)
  current_a <- psl_refresh(acceptance_a, force = TRUE)
  current_b <- psl_refresh(acceptance_b, activate = TRUE)

  # Bundled plus three distinct downloads, all intact.
  inventory <- psl_snapshots(verify = TRUE)
  expect_identical(nrow(inventory), 4L)
  expect_identical(unique(inventory$integrity), "ok")

  removed <- psl_cache_prune(keep = 0L)

  # Only the snapshot no source and no selection still names is reclaimed.
  expect_identical(removed$checksum, superseded$checksum)
  expect_false(file.exists(psl_snapshot_bytes_path(superseded$checksum)))
  expect_identical(psl_snapshot_integrity(current_a$checksum, TRUE), "ok")
  expect_identical(psl_snapshot_integrity(current_b$checksum, TRUE), "ok")
  expect_identical(unique(psl_snapshots(verify = TRUE)$integrity), "ok")

  # And the cache is still usable and refreshable afterwards. The fourth
  # request repeats the last fixture, so source A converges on bytes source B
  # already published -- one snapshot, two sources.
  again <- psl_refresh(acceptance_a, force = TRUE)
  expect_identical(again$outcome, "updated")
  expect_identical(again$checksum, current_b$checksum)
  expect_identical(psl_use("cache")$checksum, again$checksum)
  expect_identical(
    psl_snapshots()$source_count[
      psl_snapshots()$checksum == again$checksum
    ],
    2L
  )
})

# ---------------------------------------------------------------------------
# Legacy migration through the public path
# ---------------------------------------------------------------------------

test_that("a refresh migrates an md5 legacy cache and preserves its file", {
  cache <- local_pslr_clean()
  acceptance_clock()
  staged <- write_test_list("legacy.example")
  md5 <- psl_checksum(staged, "md5")
  legacy <- file.path(cache, paste0("psl-", sub("^md5:", "", md5), ".dat"))
  file.copy(staged, legacy)
  saveRDS(
    list(
      manifest_version = 1L,
      dat_file = basename(legacy),
      meta = psl_meta(
        source = "cache",
        path = legacy,
        retrieved_at = "2024-03-04 05:06:07 UTC",
        size = as.integer(file.size(legacy)),
        checksum = md5
      )
    ),
    file.path(cache, "current.rds")
  )
  digest <- psl_sha256_file(legacy)
  local_fake_transport(list(list(path = write_test_list())))

  psl_refresh(acceptance_a)

  # The md5-era bytes were validated and re-identified by SHA-256...
  imported <- paste0("sha256:", digest)
  expect_identical(psl_snapshot_integrity(imported, TRUE), "ok")
  expect_true(imported %in% psl_snapshots()$checksum)
  # ...their original file is still there, byte for byte, with its marker...
  expect_identical(psl_sha256_file(legacy), digest)
  expect_true(file.exists(file.path(cache, "current.rds")))
  # ...and the migrated source record protects the import from an explicit
  # prune, because a source still references it.
  psl_cache_prune(keep = 0L)
  expect_identical(psl_snapshot_integrity(imported, TRUE), "ok")
  expect_identical(psl_sha256_file(legacy), digest)
})

# ---------------------------------------------------------------------------
# Reminders over the whole subsystem
# ---------------------------------------------------------------------------

test_that("a newer cache under the shipped bundle suggests activation", {
  local_pslr_clean()
  acceptance_reminder_session()
  now <- acceptance_clock()
  transport <- local_fake_transport(list(list(path = write_test_list())))
  psl_reminder(enable = TRUE)

  downloaded <- psl_refresh()

  # The refresh downloaded newer bytes for the source the bundle came from, but
  # activated nothing, so the session is still on the shipped snapshot.
  expect_identical(psl_version()$source, "bundled")
  status <- psl_status("active", now = now)
  expect_identical(status$state, "update_available")
  expect_identical(status$source_checksum, downloaded$checksum)
  # The attach message therefore asks for activation, not another download.
  message <- paste(
    testthat::capture_messages(psl_reminder_attach()),
    collapse = ""
  )
  expect_match(message, "activate", fixed = TRUE)
  expect_match(message, "psl_use(\"cache\")", fixed = TRUE)
  expect_false(grepl("psl_refresh", message, fixed = TRUE))
  # Nothing about status or reminders made a request of its own.
  expect_identical(request_count(transport), 1L)
})

test_that("importing the namespace alone has no hook that could speak", {
  namespace <- asNamespace("pslr")
  # `.onAttach` is the only startup hook, so `pslr::public_suffix()` from an
  # importing package can neither emit a reminder nor evaluate freshness.
  expect_type(get(".onAttach", envir = namespace, inherits = FALSE), "closure")
  expect_false(exists(".onLoad", envir = namespace, inherits = FALSE))
})

# ---------------------------------------------------------------------------
# The queries the whole package exists for
# ---------------------------------------------------------------------------

test_that("refreshing and pruning never disturb queries or other engines", {
  local_pslr_clean()
  acceptance_clock()
  hosts <- c("www.example.co.uk", "shop.example.com", "a.nowhere.example")
  independent <- psl_engine("bundled")
  before <- list(
    suffix = public_suffix(hosts),
    domain = registrable_domain(hosts),
    extract = suffix_extract(hosts),
    engine_suffix = public_suffix(hosts, engine = independent),
    engine_extract = suffix_extract(hosts, engine = independent),
    version = psl_version()
  )
  local_fake_transport(list(
    list(path = write_test_list()),
    list(path = write_test_list("nowhere.example"))
  ))

  psl_refresh(acceptance_a)
  psl_refresh(acceptance_a, force = TRUE)
  psl_cache_prune(keep = 0L)

  # Nothing that did not activate a snapshot can change an answer.
  expect_identical(public_suffix(hosts), before$suffix)
  expect_identical(registrable_domain(hosts), before$domain)
  expect_identical(suffix_extract(hosts), before$extract)
  expect_identical(psl_version(), before$version)

  # Activating the refreshed list changes the session's answers and leaves an
  # independently built engine exactly where it was.
  psl_use("cache")
  expect_identical(public_suffix("a.nowhere.example"), "nowhere.example")
  expect_identical(
    public_suffix(hosts, engine = independent),
    before$engine_suffix
  )
  expect_identical(
    suffix_extract(hosts, engine = independent),
    before$engine_extract
  )
})
