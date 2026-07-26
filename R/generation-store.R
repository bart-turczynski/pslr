# Append-only generation store (freshness v2).
#
# Three record streams -- source state, cache selection, and reminder
# preferences -- are persisted the same way: as a directory of immutable,
# zero-padded generation files (`00000001.rds`, `00000002.rds`, ...). A write
# creates a temporary file in the destination directory, writes and closes it,
# then renames it to a generation name that does not yet exist. Published
# generation files are never overwritten, because replacing an existing file is
# not uniformly atomic across platforms. A reader ignores temporary files,
# validates every candidate, and takes the greatest structurally valid
# generation; an interrupted write therefore leaves either the prior generation
# or a complete new one visible, never a half-written record.
#
# This file is persistence only. It knows nothing about HTTP and takes no
# locks: locking layers on top of these helpers, which is why every entry point
# is a plain function over an explicit directory.

# ---------------------------------------------------------------------------
# Directory seams
# ---------------------------------------------------------------------------

# User config directory, the counterpart of `psl_cache_dir()`. Reminder
# preferences are configuration rather than a reproducible cache, so they live
# outside the cache tree and survive a cache wipe. `tools::R_user_dir()` is an
# R-approved location, and tests point `pslr.config_dir` at a temporary
# directory to stay hermetic.
psl_config_dir <- function() {
  getOption("pslr.config_dir", tools::R_user_dir("pslr", "config"))
}

# Stream directory for one source's append-only state. The directory name is a
# digest of the normalized request URL, so a directory listing never leaks a
# private source URL.
psl_source_stream_dir <- function(normalized_url) {
  file.path(
    psl_cache_dir(),
    "sources",
    psl_source_stream_name(normalized_url)
  )
}

# Stream directory naming which snapshot `psl_use("cache")` resolves to.
psl_selection_stream_dir <- function() {
  file.path(psl_cache_dir(), "selections")
}

# Stream directory for the attach-reminder preference.
psl_reminder_stream_dir <- function() {
  file.path(psl_config_dir(), "reminder")
}

# ---------------------------------------------------------------------------
# Generation names
# ---------------------------------------------------------------------------

# Published generation files are exactly eight digits plus `.rds`. Fixed width
# keeps lexical and numeric order identical, and anything else in the directory
# -- temporary files, locks, editor debris -- is ignored by readers.
psl_generation_regex <- "^[0-9]{8}\\.rds$"
psl_generation_max <- 99999999L

# File name for one generation number.
psl_generation_name <- function(generation) {
  if (
    !is.numeric(generation) ||
      length(generation) != 1L ||
      is.na(generation) ||
      generation != trunc(generation) ||
      generation < 1L
  ) {
    stop("`generation` must be a single positive whole number.", call. = FALSE)
  }
  if (generation > psl_generation_max) {
    stop(
      sprintf(
        "Generation %.0f exceeds the %d-generation stream limit.",
        generation,
        psl_generation_max
      ),
      call. = FALSE
    )
  }
  sprintf("%08d.rds", as.integer(generation))
}

# Generation numbers of the published files in `dir`, ascending. Temporary and
# unrelated files are dropped here, so no other helper has to know about them.
psl_generation_numbers <- function(dir) {
  if (!dir.exists(dir)) {
    return(integer())
  }
  files <- list.files(dir, pattern = psl_generation_regex)
  sort(as.integer(sub("\\.rds$", "", files)))
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# Classify one published generation file. `validate` is a strict validator from
# the schema layer (or NULL to accept any list). The failure reason is coarse
# and deliberate: `unreadable` means the bytes are not a readable RDS object,
# `unsupported_schema` means a record this pslr does not understand -- likely
# written by a newer release -- and `invalid` means a structurally broken
# record of a known schema.
psl_store_classify <- function(path, generation, validate) {
  entry <- list(
    generation = generation,
    path = path,
    valid = FALSE,
    reason = NA_character_,
    message = NA_character_,
    record = NULL
  )
  record <- tryCatch(readRDS(path), error = \(e) e, warning = \(w) w)
  if (inherits(record, "condition")) {
    entry$reason <- "unreadable"
    entry$message <- conditionMessage(record)
    return(entry)
  }
  problem <- if (is.null(validate)) {
    if (is.list(record)) NULL else "A record must be a named list."
  } else {
    tryCatch(
      {
        validate(record)
        NULL
      },
      error = conditionMessage
    )
  }
  if (!is.null(problem)) {
    entry$reason <- if (grepl("schema version", problem, fixed = TRUE)) {
      "unsupported_schema"
    } else {
      "invalid"
    }
    entry$message <- problem
    return(entry)
  }
  entry$valid <- TRUE
  entry$record <- record
  entry
}

# Classify every published generation in `dir`, ascending.
psl_store_entries <- function(dir, validate = NULL) {
  numbers <- psl_generation_numbers(dir)
  lapply(numbers, function(generation) {
    psl_store_classify(
      file.path(dir, psl_generation_name(generation)),
      generation,
      validate
    )
  })
}

# Read the current record of a stream.
#
# Returns a result list rather than the bare record, because "no record yet",
# "a clean record", and "a clean record hiding behind a corrupt newer one" mean
# different things to a freshness claim and must stay distinguishable:
#
#   * `status = "empty"`     -- no published generation.
#   * `status = "ok"`        -- the greatest published generation is valid.
#   * `status = "recovered"` -- the greatest published generation is not valid;
#                               `record` is the greatest valid older one, and
#                               callers must not present it as confirmed
#                               current.
#   * `status = "corrupt"`   -- generations exist but none of them is valid.
#
# `faults` describes every rejected generation, and `gaps` lists generation
# numbers missing from the retained range (compaction trims a stream from the
# bottom, so a gap is only a fault between the lowest and highest file present).
psl_store_read <- function(dir, validate = NULL) {
  entries <- psl_store_entries(dir, validate)
  numbers <- vapply(entries, \(e) e$generation, integer(1L))
  ok <- vapply(entries, \(e) e$valid, logical(1L))
  gaps <- if (length(numbers)) {
    setdiff(seq(min(numbers), max(numbers)), numbers)
  } else {
    integer()
  }
  faults <- lapply(entries[!ok], \(e) e[c("generation", "reason", "message")])
  status <- if (!length(entries)) {
    "empty"
  } else if (!any(ok)) {
    "corrupt"
  } else if (isTRUE(ok[[length(ok)]])) {
    "ok"
  } else {
    "recovered"
  }
  current <- if (any(ok)) entries[[max(which(ok))]] else NULL
  list(
    status = status,
    record = current$record,
    generation = if (is.null(current)) NA_integer_ else current$generation,
    faults = faults,
    gaps = as.integer(gaps)
  )
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

# Append one generation to a stream.
#
# `build` receives the generation number the record will be published under, so
# a record's `generation` field can never disagree with its file name. The
# record is written to a temporary file in the destination directory, closed,
# and only then renamed onto a generation name that does not yet exist -- an
# existing published generation is never a rename target. Returns the published
# path invisibly.
psl_store_append <- function(dir, build, validate = NULL) {
  if (!is.function(build)) {
    stop("`build` must be a function of the generation number.", call. = FALSE)
  }
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(dir)) {
    stop(sprintf("Could not create stream directory: %s", dir), call. = FALSE)
  }
  numbers <- psl_generation_numbers(dir)
  generation <- if (length(numbers)) max(numbers) + 1L else 1L
  record <- build(generation)
  if (!is.null(validate)) {
    validate(record)
  }
  stamped <- record$generation
  if (!is.null(stamped) && !identical(stamped, generation)) {
    stop(
      sprintf(
        "Record generation %s does not match published generation %d.",
        format(stamped),
        generation
      ),
      call. = FALSE
    )
  }
  target <- file.path(dir, psl_generation_name(generation))
  if (file.exists(target)) {
    stop(
      sprintf("Generation %d is already published in %s.", generation, dir),
      call. = FALSE
    )
  }
  tmp <- tempfile(pattern = "tmp-", tmpdir = dir, fileext = ".part")
  on.exit(unlink(tmp), add = TRUE)
  con <- file(tmp, open = "wb")
  saveRDS(record, con)
  close(con)
  if (!file.rename(tmp, target)) {
    stop(
      sprintf("Could not publish generation %d in %s.", generation, dir),
      call. = FALSE
    )
  }
  invisible(target)
}

# ---------------------------------------------------------------------------
# Compaction
# ---------------------------------------------------------------------------

# Trim a stream's history from the bottom.
#
# `keep` is the number of valid generations retained and is at least two: the
# latest valid generation plus at least one older valid generation, so a crash
# during a later append still leaves a readable predecessor. Only files strictly
# below the lowest retained generation are removed, which means compaction can
# never delete the only valid generation and can never delete a corrupt newer
# generation either -- erasing that would silently turn a `recovered` read into
# an `ok` one and hide the fault. Temporary files are left alone; they belong to
# a possibly live writer. Returns the removed paths invisibly.
psl_store_compact <- function(dir, keep = 2L, validate = NULL) {
  if (
    !is.numeric(keep) ||
      length(keep) != 1L ||
      is.na(keep) ||
      keep != trunc(keep) ||
      keep < 2L
  ) {
    stop("`keep` must be a single whole number of at least two.", call. = FALSE)
  }
  entries <- psl_store_entries(dir, validate)
  valid <- vapply(entries, \(e) e$valid, logical(1L))
  if (sum(valid) <= keep) {
    return(invisible(character()))
  }
  valid_numbers <- vapply(entries[valid], \(e) e$generation, integer(1L))
  floor_generation <- utils::tail(valid_numbers, as.integer(keep))[[1L]]
  numbers <- vapply(entries, \(e) e$generation, integer(1L))
  paths <- vapply(entries[numbers < floor_generation], \(e) e$path, "")
  # `unlink()` collapses a whole vector into one status, so delete one file at
  # a time and report only what actually went away.
  failures <- vapply(paths, unlink, integer(1L))
  invisible(unname(paths[failures == 0L]))
}
