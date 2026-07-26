# Attach-time freshness reminders (freshness v2).
#
# `psl_reminder()` is the opt-in half of the freshness subsystem: a persisted
# preference plus the one startup message it may produce. Nothing here is
# scheduled, backgrounded, or networked -- the only moment pslr ever looks at
# freshness on its own is a direct `library(pslr)` attachment, and even then it
# reads local evidence only.
#
# Four rules shape everything below.
#
#   1. THE PREFERENCE IS CONFIG, NOT CACHE. It lives in an append-only
#      generation stream under `psl_config_dir()`, so wiping or pruning the
#      cache never changes whether a user asked to be reminded. Disabling
#      RETAINS the interval, so re-enabling restores the choice.
#   2. QUERYING NEVER WRITES. `enable = NULL` reports the stored preference --
#      or the documented default when none exists -- and publishes nothing.
#   3. ATTACHMENT, NOT LOADING. The message comes from `.onAttach()`, so a
#      package that merely imports the namespace (`pslr::public_suffix()`) is
#      silent. `packageStartupMessage()` carries it, so
#      `suppressPackageStartupMessages()` works normally, and once-per-session
#      state stops detach/reattach from repeating it.
#   4. A REMINDER MUST NEVER BREAK `library(pslr)`. The whole evaluation is
#      wrapped: any failure -- a corrupt cache, an unreadable config stream, a
#      damaged snapshot -- degrades to silence rather than to an error at
#      attach time.

# ---------------------------------------------------------------------------
# The preference value
# ---------------------------------------------------------------------------

# The stable column contract of the returned one-row preference.
psl_reminder_columns <- c(
  enabled = "logical",
  interval = "integer",
  stored = "logical"
)

new_psl_reminder <- function(enabled, interval, stored) {
  structure(
    data.frame(
      enabled = as.logical(enabled),
      interval = as.integer(interval),
      stored = as.logical(stored),
      stringsAsFactors = FALSE,
      row.names = NULL
    ),
    class = c("psl_reminder", "data.frame")
  )
}

# The current preference. A stream that is empty, corrupt, or recovered proves
# nothing about what the user asked for, so it reports the documented default:
# reminders off, with the default interval retained for a later enable. That is
# also why an unreadable config directory can only ever make pslr quieter.
psl_reminder_read <- function() {
  read <- psl_store_read(psl_reminder_stream_dir(), validate_psl_reminder_pref)
  if (identical(read$status, "ok")) {
    new_psl_reminder(read$record$enabled, read$record$interval, TRUE)
  } else {
    new_psl_reminder(FALSE, psl_reminder_default_interval, FALSE)
  }
}

# Publish one preference generation and return the value it establishes.
psl_reminder_write <- function(enabled, interval) {
  psl_store_append(
    psl_reminder_stream_dir(),
    \(generation) {
      new_psl_reminder_pref(enabled, interval, generation = generation)
    },
    validate_psl_reminder_pref
  )
  new_psl_reminder(enabled, interval, TRUE)
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

psl_reminder_check_enable <- function(enable) {
  if (!is.logical(enable) || length(enable) != 1L || is.na(enable)) {
    stop("`enable` must be TRUE, FALSE, or NULL.", call. = FALSE)
  }
  enable
}

# The interval is a whole number of days of at least one: a sub-day reminder
# would fire on every attach, and a fractional one has no persisted form.
psl_reminder_check_every <- function(every) {
  ok <- is.numeric(every) &&
    length(every) == 1L &&
    !is.na(every) &&
    is.finite(every) &&
    every == trunc(every) &&
    every >= 1
  if (!ok) {
    stop(
      "`every` must be a single whole number of days of at least one.",
      call. = FALSE
    )
  }
  as.integer(every)
}

#' Persistent opt-in freshness reminder
#'
#' Queries or sets whether attaching pslr with `library(pslr)` may print one
#' offline freshness reminder per R session, and how many days of unconfirmed
#' freshness it takes before that reminder applies.
#'
#' Reminders are off until you turn them on. The preference is configuration
#' rather than cache: it is stored under [tools::R_user_dir()]`("pslr",
#' "config")`, so refreshing, pruning, or deleting the snapshot cache never
#' changes it. Disabling retains the interval, so a later
#' `psl_reminder(enable = TRUE)` restores the schedule you chose.
#'
#' Querying, enabling, and disabling are all strictly offline; no part of the
#' reminder path makes a network request.
#'
#' @details
#' When reminders are enabled, a *direct* `library(pslr)` attachment evaluates
#' [psl_status()] offline and may emit a single [packageStartupMessage()]. A
#' package that merely imports the namespace, as in `pslr::public_suffix()`,
#' never triggers it, `suppressPackageStartupMessages()` suppresses it as
#' usual, and it is emitted at most once per session -- detaching and
#' reattaching does not repeat it.
#'
#' The message appears only for the three states where local evidence supports
#' advice: `"never_checked"`, `"check_due"`, and `"update_available"`. For
#' `"update_available"` the newer snapshot is already stored locally, so the
#' message suggests activating it with `psl_use("cache")` rather than fetching
#' anything again. Any failure while evaluating the reminder -- damaged cache
#' state included -- degrades to silence, so attaching the package cannot break.
#'
#' @param enable Whether attach reminders are on: `TRUE` to enable, `FALSE` to
#'   disable, or `NULL` (the default) to report the current preference without
#'   writing anything.
#' @param every The reminder interval in whole days, at least one. `NULL` (the
#'   default) reuses the stored interval, or 7 days when no preference has been
#'   stored yet. Only meaningful together with `enable`.
#'
#' @return A one-row base [data.frame] of class `psl_reminder` with the columns
#'   `enabled` (logical), `interval` (integer days), and `stored` (logical,
#'   whether the value came from a stored preference rather than the defaults).
#'   Returned visibly when querying and invisibly when writing.
#' @seealso [psl_status()], [psl_refresh()], [psl_use()]
#' @examples
#' # Query the current preference; this writes nothing.
#' psl_reminder()
#'
#' # Enabling writes to your config directory, so this example points that
#' # seam at a temporary directory instead.
#' old <- options(pslr.config_dir = file.path(tempdir(), "pslr-reminder"))
#'
#' psl_reminder(enable = TRUE, every = 14)
#' psl_reminder()
#'
#' # Disabling retains the interval for a later re-enable.
#' psl_reminder(enable = FALSE)$interval
#'
#' options(old)
#' @export
psl_reminder <- function(enable = NULL, every = NULL) {
  current <- psl_reminder_read()
  if (is.null(enable)) {
    if (!is.null(every)) {
      stop("`every` can only be set together with `enable`.", call. = FALSE)
    }
    return(current)
  }
  enable <- psl_reminder_check_enable(enable)
  interval <- if (is.null(every)) {
    current$interval
  } else {
    psl_reminder_check_every(every)
  }
  invisible(psl_reminder_write(enable, interval))
}

# ---------------------------------------------------------------------------
# The attach message
# ---------------------------------------------------------------------------

# Once-per-session emission state. It lives in the namespace, which survives
# `detach()`, so reattaching in the same session stays silent.
psl_reminder_session <- new.env(parent = emptyenv())

# The only three states a reminder speaks about. `confirmed_current` needs no
# advice, and `missing`, `untracked`, and `unknown` are not something a startup
# message should nag about.
psl_reminder_states <- c("never_checked", "check_due", "update_available")

# The advice for one state. `update_available` deliberately names no download:
# those bytes are already on disk, and the outstanding action is activation.
psl_reminder_advice <- function(status) {
  switch(
    status$state,
    never_checked = paste(
      "pslr has never confirmed its active Public Suffix List snapshot",
      "against its source. Run psl_refresh() to check."
    ),
    check_due = sprintf(
      paste(
        "pslr last confirmed its active Public Suffix List snapshot %s ago.",
        "Run psl_refresh() to check again."
      ),
      psl_status_days(status$check_age_days)
    ),
    update_available = paste(
      "A newer Public Suffix List snapshot is already in your pslr cache but",
      "is not the active one. Run psl_use(\"cache\") to activate it."
    )
  )
}

# The message lines, or NULL when nothing should be said.
psl_reminder_lines <- function() {
  preference <- psl_reminder_read()
  if (!isTRUE(preference$enabled)) {
    return(NULL)
  }
  status <- psl_status("active")
  if (!status$state %in% psl_reminder_states) {
    return(NULL)
  }
  c(
    strwrap(psl_reminder_advice(status), width = 76L),
    "Silence this reminder with psl_reminder(enable = FALSE)."
  )
}

# Emit at most one reminder per session. Every failure mode is swallowed here:
# a broken cache must leave the package attachable, so the worst outcome of an
# unreadable local state is a missing reminder.
psl_reminder_attach <- function() {
  lines <- tryCatch(
    if (isTRUE(psl_reminder_session$emitted)) NULL else psl_reminder_lines(),
    error = \(e) NULL,
    warning = \(w) NULL
  )
  if (!is.null(lines)) {
    psl_reminder_session$emitted <- TRUE
    packageStartupMessage(paste(lines, collapse = "\n"))
  }
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

psl_reminder_days <- function(interval) {
  sprintf("%d day%s", interval, if (identical(interval, 1L)) "" else "s")
}

psl_reminder_detail <- function(x) {
  if (isTRUE(x$enabled)) {
    sprintf(
      paste(
        "Attaching pslr may print one offline freshness reminder per session",
        "once its snapshot has gone %s without a confirmed check."
      ),
      psl_reminder_days(x$interval)
    )
  } else {
    paste(
      "Attaching pslr prints no freshness reminder. Turn reminders on with",
      "psl_reminder(enable = TRUE)."
    )
  }
}

psl_reminder_field_lines <- function(x) {
  values <- c(
    interval = psl_reminder_days(x$interval),
    preference = if (isTRUE(x$stored)) "stored" else "not stored (defaults)"
  )
  labels <- paste0(names(values), ":")
  sprintf("  %s %s", formatC(labels, width = -max(nchar(labels))), values)
}

psl_reminder_complete <- function(x) {
  all(names(psl_reminder_columns) %in% names(x))
}

#' @rdname psl_reminder
#' @param x A `psl_reminder` preference, as returned by [psl_reminder()].
#' @param ... Passed on to the data frame methods when `x` no longer carries
#'   the full preference contract.
#' @return `format()` returns a character vector of display lines and `print()`
#'   returns `x` invisibly.
#' @keywords internal
#' @export
format.psl_reminder <- function(x, ...) {
  if (nrow(x) != 1L || !psl_reminder_complete(x)) {
    return(format.data.frame(x, ...))
  }
  c(
    sprintf(
      "<psl_reminder: %s>",
      if (isTRUE(x$enabled)) "enabled" else "disabled"
    ),
    strwrap(psl_reminder_detail(x), width = 76L, prefix = "  "),
    psl_reminder_field_lines(x)
  )
}

#' @rdname psl_reminder
#' @keywords internal
#' @export
print.psl_reminder <- function(x, ...) {
  if (nrow(x) != 1L || !psl_reminder_complete(x)) {
    print.data.frame(x, ...)
    return(invisible(x))
  }
  cat(format(x, ...), sep = "\n")
  invisible(x)
}
