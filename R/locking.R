# Advisory cross-process locks (freshness v2).
#
# Two lock kinds coordinate the freshness subsystem:
#
#   * one lock per normalized source (`<stream name>.lock`), held across the
#     whole refresh of that source -- state read, network work, publication --
#     so two processes never race the same endpoint; and
#   * one publish lock (`publish.lock`), held only for the short publication,
#     compaction, and pruning phases that touch shared cache state.
#
# The normative order is source lock, then publish lock, never the reverse.
# Different sources may therefore do network work concurrently while their
# publication phases serialize, and pruning -- which takes only the publish
# lock -- can never wait on a source lock while holding it. The order is
# enforced in-process by `psl_lock_guard_order()`, so an ordering mistake is a
# deterministic error instead of an occasional cross-process deadlock.
#
# The primitive is `dir.create()`: creating a directory is an atomic
# exclusive-create on both POSIX and Windows, needs no extra dependency, and
# fails cleanly when the name already exists. Locks are advisory -- nothing
# stops a foreign process from writing the cache -- have a bounded wait, and a
# lock artifact left behind by a crashed process does not by itself imply
# ownership: an artifact whose recorded mtime is older than the staleness
# horizon may be reclaimed once, after which the ordinary exclusive create
# decides the winner.

# ---------------------------------------------------------------------------
# Seams
# ---------------------------------------------------------------------------

# Directory holding every lock artifact.
psl_lock_dir <- function() file.path(psl_cache_dir(), "locks")

# Path of one named lock. Names are stream names or "publish", never raw URLs.
psl_lock_path <- function(name) {
  file.path(psl_lock_dir(), paste0(name, ".lock"))
}

# Lock name for one normalized source URL: the same digest the source-state
# stream directory uses, so a lock listing leaks no source URL either.
psl_source_lock_name <- function(normalized_url) {
  psl_source_stream_name(normalized_url)
}

# Name of the single cross-source publication lock.
psl_publish_lock_name <- "publish"

# Bounded wait, in seconds, before an acquisition gives up and reports busy.
psl_lock_timeout <- function() getOption("pslr.lock_timeout", 10)

# Delay between acquisition attempts, in seconds.
psl_lock_retry_interval <- function() {
  getOption("pslr.lock_retry_interval", 0.05)
}

# Age, in seconds, past which a lock artifact is treated as debris from a
# crashed process rather than as evidence of a live holder.
psl_lock_stale_after <- function() getOption("pslr.lock_stale_seconds", 900)

# Injectable clock and sleep. Tests drive the bounded wait with a fake clock so
# a contention test costs no wall time; production uses the real ones.
psl_now <- function() {
  clock <- getOption("pslr.clock", Sys.time)
  now <- clock()
  if (!inherits(now, "POSIXt")) {
    stop("`pslr.clock` must return a POSIXct time.", call. = FALSE)
  }
  now
}

psl_lock_sleep <- function(seconds) {
  sleeper <- getOption("pslr.lock_sleep", Sys.sleep)
  sleeper(seconds)
  invisible(NULL)
}

# The single "can I take this artifact right now?" decision, isolated so tests
# can simulate a foreign holder without a second R process. Returns TRUE when
# this process now owns `path`.
psl_lock_try_create <- function(path) {
  override <- getOption("pslr.lock_try_create", NULL)
  if (is.function(override)) {
    return(isTRUE(override(path)))
  }
  # `dir.create()` warns when the directory exists; a busy lock is ordinary
  # control flow here, not a condition worth surfacing.
  isTRUE(suppressWarnings(dir.create(path, recursive = FALSE)))
}

# ---------------------------------------------------------------------------
# In-process registry and ordering guard
# ---------------------------------------------------------------------------

# Locks this process currently holds, most recently acquired last.
psl_lock_state <- new.env(parent = emptyenv())
psl_lock_state$held <- character()

psl_locks_held <- function() psl_lock_state$held

psl_lock_is_held <- function(name) name %in% psl_lock_state$held

# Refuse an acquisition that would violate the normative order or re-enter a
# lock this process already holds. Both are internal bugs: re-entering an
# advisory lock would release it early on the inner exit, and taking a source
# lock under the publish lock is the deadlock-forming order.
psl_lock_guard_order <- function(name) {
  if (psl_lock_is_held(name)) {
    stop(
      sprintf("Lock \"%s\" is already held by this process.", name),
      call. = FALSE
    )
  }
  publish_held <- psl_lock_is_held(psl_publish_lock_name)
  if (publish_held && !identical(name, psl_publish_lock_name)) {
    stop(
      sprintf(
        paste0(
          "Lock order violation: cannot acquire source lock \"%s\" while ",
          "holding the publish lock. The order is source lock, then publish ",
          "lock."
        ),
        name
      ),
      call. = FALSE
    )
  }
  invisible(NULL)
}

# Assert that a publication step runs under the lock it requires.
psl_lock_assert_held <- function(name, what) {
  if (!psl_lock_is_held(name)) {
    stop(
      sprintf("%s requires the \"%s\" lock.", what, name),
      call. = FALSE
    )
  }
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# Busy condition
# ---------------------------------------------------------------------------

# A bounded wait that expired. Classed so a caller can distinguish "another
# process is working on this source" from a real failure and, per the failure
# matrix, make no request at all.
psl_lock_busy_condition <- function(name, timeout) {
  errorCondition(
    sprintf(
      "Timed out after %s seconds waiting for the \"%s\" lock.",
      format(timeout),
      name
    ),
    lock = name,
    timeout = timeout,
    class = c("pslr_lock_busy", "pslr_busy_error")
  )
}

# ---------------------------------------------------------------------------
# Acquire and release
# ---------------------------------------------------------------------------

# Record who took a lock, for diagnostics and staleness. The file is advisory
# information only -- nothing trusts it to prove ownership.
psl_lock_stamp <- function(path) {
  info <- list(
    pid = Sys.getpid(),
    acquired_at = psl_format_time(psl_now()),
    host = Sys.info()[["nodename"]]
  )
  tryCatch(saveRDS(info, file.path(path, "owner.rds")), error = \(e) NULL)
  invisible(info)
}

# Age of an existing lock artifact in seconds, or NA when it cannot be read.
psl_lock_age <- function(path) {
  mtime <- file.mtime(path)
  if (length(mtime) != 1L || is.na(mtime)) {
    return(NA_real_)
  }
  as.numeric(difftime(psl_now(), mtime, units = "secs"))
}

# Drop a lock artifact that is older than the staleness horizon. Returns TRUE
# when something was removed, so the caller retries the ordinary exclusive
# create rather than assuming it now owns the lock.
psl_lock_reclaim_stale <- function(path) {
  age <- psl_lock_age(path)
  if (is.na(age) || age < psl_lock_stale_after()) {
    return(FALSE)
  }
  unlink(path, recursive = TRUE)
  !dir.exists(path)
}

# Acquire one lock with a bounded wait.
#
# Returns a lock handle on success and NULL when the wait expires, so a caller
# can tell "acquired" from "busy" without catching a condition. The wait is
# bounded by `timeout` measured on the injectable clock; a stale artifact is
# reclaimed at most once per call.
psl_lock_acquire <- function(name, timeout = psl_lock_timeout()) {
  psl_lock_guard_order(name)
  dir.create(psl_lock_dir(), recursive = TRUE, showWarnings = FALSE)
  path <- psl_lock_path(name)
  deadline <- as.numeric(psl_now()) + as.numeric(timeout)
  reclaimed <- FALSE
  repeat {
    if (psl_lock_try_create(path)) {
      psl_lock_state$held <- c(psl_lock_state$held, name)
      psl_lock_stamp(path)
      return(structure(
        list(name = name, path = path),
        class = "psl_lock"
      ))
    }
    if (!reclaimed) {
      reclaimed <- TRUE
      if (psl_lock_reclaim_stale(path)) {
        next
      }
    }
    if (as.numeric(psl_now()) >= deadline) {
      return(NULL)
    }
    psl_lock_sleep(psl_lock_retry_interval())
  }
}

# Release a lock this process holds. Releasing is best effort on the artifact
# -- a lock whose directory was already removed by a stale-lock reclaim is
# still dropped from the in-process registry, so the registry never outlives
# the artifact.
psl_lock_release <- function(lock) {
  if (!inherits(lock, "psl_lock")) {
    stop("`lock` must be a lock handle from psl_lock_acquire().", call. = FALSE)
  }
  unlink(lock$path, recursive = TRUE)
  held <- psl_lock_state$held
  last <- utils::tail(which(held == lock$name), 1L)
  if (length(last)) {
    psl_lock_state$held <- held[-last]
  }
  invisible(lock$name)
}

# Evaluate `expr` while holding `name`.
#
# `on_busy = "error"` signals the classed busy condition when the bounded wait
# expires; `on_busy = "null"` returns NULL instead, for callers that treat
# contention as "someone else is already doing this work".
psl_with_lock <- function(
  name,
  expr,
  timeout = psl_lock_timeout(),
  on_busy = c("error", "null")
) {
  on_busy <- match.arg(on_busy)
  lock <- psl_lock_acquire(name, timeout = timeout)
  if (is.null(lock)) {
    if (identical(on_busy, "error")) {
      stop(psl_lock_busy_condition(name, timeout))
    }
    return(NULL)
  }
  on.exit(psl_lock_release(lock), add = TRUE)
  force(expr)
}

# Hold one source's lock across its whole refresh, including network work.
psl_with_source_lock <- function(
  normalized_url,
  expr,
  timeout = psl_lock_timeout(),
  on_busy = c("error", "null")
) {
  psl_with_lock(
    psl_source_lock_name(normalized_url),
    expr,
    timeout = timeout,
    on_busy = match.arg(on_busy)
  )
}

# Hold the publish lock for a short publication, compaction, or pruning phase.
# Never make a network request in here.
psl_with_publish_lock <- function(
  expr,
  timeout = psl_lock_timeout(),
  on_busy = c("error", "null")
) {
  psl_with_lock(
    psl_publish_lock_name,
    expr,
    timeout = timeout,
    on_busy = match.arg(on_busy)
  )
}
