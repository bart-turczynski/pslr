# Referentially safe pruning (freshness v2).
#
# `psl_cache_prune()` is the package's one explicit destructive storage
# operation: it reclaims snapshot bytes that nothing points at any more. It is
# offline, takes only the publish lock, and is built around a single rule --
# NOTHING IS DELETED THAT CANNOT BE PROVEN UNREFERENCED.
#
# Four things are protected, and every one of them is a reference someone can
# still follow after the call returns:
#
#   1. the selected cache snapshot, which is what `psl_use("cache")` resolves;
#   2. every snapshot named by any source stream, across ALL sources rather
#      than only the canonical one, because a custom source's knowledge is a
#      persistent reference exactly like the official source's is;
#   3. the snapshot active in the calling R process, so pruning never breaks
#      the matcher of the session that asked for it; and
#   4. the `keep` most recently first-retrieved otherwise-unreferenced
#      snapshots, which is the deliberate slice of history a user keeps for
#      later comparison.
#
# Retention is ordered by the descriptor's `first_retrieved_at`, NOT by
# filesystem mtime. This is a deliberate correction of v1 behavior: mtime is
# mutable, and a backup restore, a file copy, or a `touch` rewrites it, so
# ordering by it can silently delete the newest history and keep the oldest.
# The descriptor records when these bytes were first received and is published
# once and never rewritten, so it is the only immutable fact about retrieval
# order.
#
# Provability is stronger than "read the current record". A stream whose newest
# generation is unreadable (`recovered` or `corrupt`) may reference any
# snapshot at all, and pruning cannot see which. Such a stream therefore makes
# EVERY published snapshot protected for this call, rather than being treated
# as though its readable older generation were the whole truth. That is also
# why pruning never tries to repair a stream: `psl_store_compact()` refuses to
# delete a corrupt newer generation on purpose, and working around it here
# would turn a reported fault into a silent one.
#
# What pruning deliberately does NOT do: it never touches reminder preferences
# (they live in the config directory, not the cache), never removes legacy v1
# files outside the v2 store, and never changes which list is active.

# ---------------------------------------------------------------------------
# Arguments and result shape
# ---------------------------------------------------------------------------

# Validate the retention count: a single non-negative whole number.
psl_validate_keep <- function(keep) {
  # Gate on scalar-numeric-non-missing first (short-circuit), then check the
  # value constraints vectorized so the guard is not one long `||` chain.
  ok <- is.numeric(keep) &&
    length(keep) == 1L &&
    !is.na(keep) &&
    isTRUE(keep >= 0 & keep == trunc(keep))
  if (!ok) {
    stop("`keep` must be a single non-negative whole number.", call. = FALSE)
  }
  invisible(NULL)
}

# The stable column contract of the result: one row per removed snapshot, with
# both halves of the pair named and the space it freed. A path is `NA` when
# that half was already absent, which is how an orphaned half reads.
psl_prune_row <- function(
  checksum,
  bytes_path = NA_character_,
  descriptor_path = NA_character_,
  bytes_reclaimed = 0
) {
  list(
    checksum = checksum,
    bytes_path = bytes_path,
    descriptor_path = descriptor_path,
    bytes_reclaimed = as.numeric(bytes_reclaimed)
  )
}

# Assemble the result frame from per-row field lists. Built column by column so
# an empty prune still returns the documented columns with the right types.
psl_prune_result <- function(rows) {
  field <- function(name, template) {
    vapply(rows, \(row) row[[name]], template)
  }
  data.frame(
    checksum = field("checksum", NA_character_),
    bytes_path = field("bytes_path", NA_character_),
    descriptor_path = field("descriptor_path", NA_character_),
    bytes_reclaimed = field("bytes_reclaimed", NA_real_),
    stringsAsFactors = FALSE,
    row.names = NULL
  )
}

# A prune that removed some but not all of what it selected. Rooted in the
# existing refresh-error family -- publication is the family that owns writes
# to the shared store -- and carries the result frame of what DID go away, so a
# caller can see exactly how far the operation got.
psl_prune_partial_error <- function(removed, failed) {
  condition <- psl_refresh_error(
    sprintf(
      paste0(
        "Pruned %d snapshot(s), but %d could not be removed: %s. ",
        "The cache is still consistent; every remaining file is either ",
        "referenced or a leftover you can remove by hand."
      ),
      nrow(removed),
      length(failed),
      toString(failed)
    ),
    c("pslr_prune_partial_error", "pslr_refresh_publication_error")
  )
  condition$result <- removed
  condition$failed <- failed
  condition
}

# ---------------------------------------------------------------------------
# The protected set
# ---------------------------------------------------------------------------

# What one stream contributes: the checksum it currently names, and whether the
# stream is readable enough for its answer to be the whole truth.
psl_prune_stream_reference <- function(read) {
  checksum <- read$record$checksum
  list(
    checksum = if (psl_valid_sha256_ref(checksum)) checksum else character(),
    provable = read$status %in% c("empty", "ok")
  )
}

# Every source stream in the cache, readable or not. Custom sources each get
# their own directory, so this is how pruning sees references it has no URL for.
psl_prune_source_reads <- function() {
  root <- file.path(psl_cache_dir(), "sources")
  if (!dir.exists(root)) {
    return(list())
  }
  lapply(
    list.dirs(root, recursive = FALSE),
    psl_store_read,
    validate = validate_psl_source_state
  )
}

# Persistent references across the whole store: the selection plus every
# source. `provable` is FALSE as soon as one stream cannot be read at its
# newest generation.
psl_prune_references <- function() {
  reads <- c(list(psl_read_selection()), psl_prune_source_reads())
  refs <- lapply(reads, psl_prune_stream_reference)
  list(
    checksums = unique(unlist(lapply(refs, \(r) r$checksum))),
    provable = all(vapply(refs, \(r) r$provable, logical(1L)))
  )
}

# The snapshot this process is matching against, or nothing when the active
# list is not a cached snapshot. Reading it lazily initialises the bundled
# engine, which is memory only.
psl_prune_active_checksum <- function() {
  checksum <- psl_snapshots_active_checksum()
  if (is.na(checksum)) character() else checksum
}

# ---------------------------------------------------------------------------
# Selecting what to collect
# ---------------------------------------------------------------------------

# When these bytes were first received, in seconds, or `NA` when no readable
# descriptor records it.
psl_prune_first_retrieved <- function(checksum) {
  descriptor <- psl_read_snapshot_descriptor(checksum)
  as.numeric(psl_as_time(descriptor$first_retrieved_at))
}

# Unreferenced snapshots that are not covered by `keep`, newest retrieval kept
# first. A snapshot with no readable descriptor has no retrieval time to defend
# it and sorts last, so an orphaned half is collected before real history;
# checksum breaks ties, which makes the order deterministic.
psl_prune_collectable <- function(candidates, keep) {
  if (!length(candidates)) {
    return(character())
  }
  retrieved <- vapply(candidates, psl_prune_first_retrieved, numeric(1L))
  ordered <- candidates[order(-retrieved, candidates, na.last = TRUE)]
  if (length(ordered) <= keep) {
    return(character())
  }
  ordered[seq.int(keep + 1L, length(ordered))]
}

# ---------------------------------------------------------------------------
# Deletion
# ---------------------------------------------------------------------------

# Deterministic deletion seam. Tests install a hook that refuses to remove a
# named file, so the partial-deletion error can be asserted without depending
# on file-system permissions.
psl_prune_unlink <- function(path) {
  hook <- getOption("pslr.prune_unlink", NULL)
  if (is.function(hook)) {
    hook(path)
  } else {
    unlink(path)
  }
  invisible(!file.exists(path))
}

# Remove one snapshot as a pair. The descriptor goes first, so the half-deleted
# state a failure can leave is bytes without an identity rather than an
# identity promising bytes. Returns the row describing what went away, plus
# whether the whole pair is now gone.
psl_prune_remove_one <- function(checksum) {
  paths <- c(
    descriptor_path = psl_snapshot_descriptor_path(checksum),
    bytes_path = psl_snapshot_bytes_path(checksum)
  )
  present <- paths[file.exists(paths)]
  sizes <- vapply(present, \(p) as.numeric(file.size(p)), numeric(1L))
  gone <- vapply(present, psl_prune_unlink, logical(1L))
  removed <- names(present)[gone]
  row <- psl_prune_row(
    checksum,
    bytes_path = if ("bytes_path" %in% removed) {
      paths[["bytes_path"]]
    } else {
      NA_character_
    },
    descriptor_path = if ("descriptor_path" %in% removed) {
      paths[["descriptor_path"]]
    } else {
      NA_character_
    },
    bytes_reclaimed = sum(sizes[gone])
  )
  list(row = row, complete = all(gone), removed = any(gone))
}

# Remove every selected snapshot, then report. A failure does not abort the
# sweep: the remaining candidates are just as unreferenced, and stopping early
# would leave more debris behind than finishing does.
psl_prune_remove <- function(collectable) {
  outcomes <- lapply(collectable, psl_prune_remove_one)
  kept <- outcomes[vapply(outcomes, \(o) o$removed, logical(1L))]
  removed <- psl_prune_result(lapply(kept, \(o) o$row))
  failed <- collectable[!vapply(outcomes, \(o) o$complete, logical(1L))]
  if (length(failed)) {
    stop(psl_prune_partial_error(removed, failed))
  }
  removed
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# The whole decision, under the publish lock: read every reference, protect
# what they name, and collect the rest.
psl_prune_locked <- function(keep) {
  published <- psl_snapshots_published()
  if (!length(published)) {
    return(psl_prune_result(list()))
  }
  references <- psl_prune_references()
  protected <- if (references$provable) {
    unique(c(references$checksums, psl_prune_active_checksum()))
  } else {
    published
  }
  psl_prune_remove(psl_prune_collectable(setdiff(published, protected), keep))
}

#' Prune unreferenced local Public Suffix List snapshots
#'
#' Reclaims cached snapshots that nothing points at any more. The call is
#' explicit, strictly offline, and destructive by design: it deletes snapshot
#' files. It never changes which list is active, and every reference that could
#' still be followed survives it.
#'
#' @details
#' A snapshot is protected, and therefore never removed, when it is any of:
#'
#' * the selected cache snapshot, the one [psl_use()] resolves with
#'   `source = "cache"`;
#' * named by any source's stored state, across every source this cache knows,
#'   not only the official endpoint;
#' * active in the calling R session; or
#' * among the `keep` most recently first-retrieved snapshots that none of the
#'   above already protects.
#'
#' Retention is ordered by when a snapshot's bytes were *first retrieved*, as
#' recorded in its descriptor when it was published, rather than by file
#' modification time. A copy, a restore from backup, or any tool that rewrites
#' timestamps changes mtime but not the fact of when the bytes were received,
#' so first retrieval is the only stable order for history.
#'
#' Pruning runs under the cache's publication lock and removes only complete
#' `.dat`/`.rds` snapshot pairs, so it can never leave a reference pointing at
#' bytes that are gone. Snapshot state pslr cannot fully read is treated as a
#' reference it cannot see: if any source or selection stream is damaged,
#' nothing is collected at all, and the damage is left visible rather than
#' quietly erased. `psl_cache_prune()` is an explicit mutator, so it also
#' performs the one-time migration of a pre-v2 cache before pruning; it never
#' deletes legacy files, and it never reads or writes the reminder preference,
#' which is configuration and lives outside the cache.
#'
#' One honest limitation: pruning cannot discover engines held by *other* R
#' processes, which already hold their parsed rules in memory. It therefore
#' guarantees persistent referential integrity -- no stored reference is ever
#' left dangling -- and not continued on-disk availability for another
#' process's detached engine descriptor.
#'
#' This is distinct from `psl_cache_clear()`, which only flushes this session's
#' in-memory match-result cache and deletes nothing from disk.
#'
#' @param keep Number of unreferenced snapshots to retain *in addition to*
#'   every referenced one, as a single non-negative whole number. The default
#'   `1` keeps one snapshot of history beyond what is still referenced; `0`
#'   keeps only referenced snapshots.
#'
#' @return Invisibly, a [data.frame] with one row per removed snapshot and the
#'   columns `checksum` (character, the `"sha256:<hex>"` identity),
#'   `bytes_path` and `descriptor_path` (character paths removed, `NA` when
#'   that half was already absent), and `bytes_reclaimed` (numeric). The frame
#'   has zero rows when nothing was pruned, including when there is no cache at
#'   all. A prune that removes only part of what it selected signals an error
#'   of class `pslr_prune_partial_error` whose `result` field is this same
#'   frame, describing what was removed before the failure.
#' @seealso [psl_snapshots()], which lists what a prune would consider;
#'   [psl_refresh()], which publishes the snapshots this reclaims; [psl_use()].
#' @examples
#' # Deleting cached snapshots is never a side effect of running an example:
#' if (interactive()) {
#'   psl_cache_prune() # keep referenced snapshots plus one more
#'   psl_cache_prune(keep = 0) # keep only referenced snapshots
#' }
#' @export
psl_cache_prune <- function(keep = 1L) {
  psl_validate_keep(keep)
  keep <- as.integer(keep)
  if (!dir.exists(psl_cache_dir())) {
    return(invisible(psl_prune_result(list())))
  }
  # An explicit mutator migrates a legacy cache first, so its snapshot is a v2
  # reference before pruning decides what is unreferenced. Migration takes the
  # publish lock itself and must therefore finish before this one does.
  psl_migrate_legacy_cache()
  removed <- psl_refresh_with_busy(
    psl_with_publish_lock(psl_prune_locked(keep))
  )
  invisible(removed)
}
