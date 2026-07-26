# Referentially safe publication (freshness v2).
#
# Publication is ordered so that a reader can never observe a reference to
# bytes that are not there. Within one commit the order is always:
#
#   1. snapshot bytes    (`snapshots/sha256-<hex>.dat`, immutable);
#   2. snapshot descriptor (`snapshots/sha256-<hex>.rds`, immutable);
#   3. source-state generation, which may reference that checksum;
#   4. cache-selection generation, which names the snapshot `psl_use("cache")`
#      resolves to.
#
# Steps 1 and 2 create content only; steps 3 and 4 create references. An
# interrupt therefore leaves at worst unreferenced snapshot bytes -- reclaimed
# later by pruning -- and never a dangling reference. Source state and
# selection are deliberately not one transaction: an interrupt between them can
# expose newer source knowledge alongside the older safe selection, which a
# later refresh repairs.
#
# Every function here runs under the publish lock, and the composite refresh
# publication also requires the caller's source lock, so the normative lock
# order is checked rather than assumed. Nothing here makes a network request;
# the bytes arrive already downloaded and validated.

# ---------------------------------------------------------------------------
# Snapshot paths
# ---------------------------------------------------------------------------

# Directory holding immutable snapshot bytes and their descriptors.
psl_snapshot_dir <- function() file.path(psl_cache_dir(), "snapshots")

# File-name stem for one snapshot: the checksum identity with its `:` replaced
# by `-`, which keeps the name portable across file systems.
psl_snapshot_slug <- function(checksum) {
  sub(":", "-", psl_checksum_id(checksum), fixed = TRUE)
}

psl_snapshot_bytes_path <- function(checksum) {
  file.path(psl_snapshot_dir(), paste0(psl_snapshot_slug(checksum), ".dat"))
}

psl_snapshot_descriptor_path <- function(checksum) {
  file.path(psl_snapshot_dir(), paste0(psl_snapshot_slug(checksum), ".rds"))
}

# Read one snapshot descriptor, or NULL when it is absent or not a descriptor
# this release understands. A caller that needs to tell those apart reads
# `psl_snapshot_integrity()` instead.
psl_read_snapshot_descriptor <- function(checksum) {
  path <- psl_snapshot_descriptor_path(checksum)
  if (!file.exists(path)) {
    return(NULL)
  }
  record <- tryCatch(readRDS(path), error = \(e) NULL)
  if (is.null(record)) {
    return(NULL)
  }
  ok <- tryCatch(
    {
      validate_psl_snapshot_descriptor(record)
      TRUE
    },
    error = \(e) FALSE
  )
  if (ok) record else NULL
}

# Classify a published snapshot without reparsing the list: `ok`, `missing`
# (bytes or descriptor absent), `checksum_mismatch` (bytes present but not the
# bytes the name claims), or `unknown_schema` (a descriptor this release cannot
# validate). `verify = FALSE` skips the rehash, which is the cheap check a
# publication guard needs.
psl_snapshot_integrity <- function(checksum, verify = FALSE) {
  identity <- psl_checksum_id(checksum)
  bytes <- psl_snapshot_bytes_path(identity)
  descriptor <- psl_snapshot_descriptor_path(identity)
  if (!file.exists(bytes) || !file.exists(descriptor)) {
    return("missing")
  }
  if (is.null(psl_read_snapshot_descriptor(identity))) {
    return("unknown_schema")
  }
  if (verify && !psl_verify_checksum(bytes, identity)) {
    return("checksum_mismatch")
  }
  "ok"
}

# Is this checksum safe to reference from a published record?
psl_snapshot_publishable <- function(checksum) {
  identical(psl_snapshot_integrity(checksum), "ok")
}

# ---------------------------------------------------------------------------
# Guards and seams
# ---------------------------------------------------------------------------

# Deterministic interruption seam. Tests install a hook that aborts at a named
# stage -- "bytes", "descriptor", "source_state", "selection" -- so the
# post-interrupt state can be asserted without racing a real process.
psl_publish_checkpoint <- function(stage) {
  hook <- getOption("pslr.publish_interrupt", NULL)
  if (is.function(hook)) {
    hook(stage)
  }
  invisible(stage)
}

# Refuse to publish a reference to bytes that are not resolvable. This is the
# single enforcement point for the "no dangling reference" invariant, so every
# reference-writing helper below routes through it.
psl_require_publishable <- function(checksum, what) {
  integrity <- psl_snapshot_integrity(checksum)
  if (identical(integrity, "ok")) {
    return(invisible(psl_checksum_id(checksum)))
  }
  stop(errorCondition(
    sprintf(
      "Refusing to publish %s referencing snapshot %s: %s.",
      what,
      psl_checksum_id(checksum),
      switch(
        integrity,
        missing = "its bytes or descriptor are not published",
        unknown_schema = "its descriptor is unreadable or unsupported",
        integrity
      )
    ),
    checksum = psl_checksum_id(checksum),
    integrity = integrity,
    class = "pslr_publication_error"
  ))
}

# Number of generations each stream retains after a publication. Compaction
# runs under the publish lock, where it is safe, and always keeps at least one
# valid predecessor.
psl_stream_keep <- function() getOption("pslr.stream_keep", 8L)

# Append one generation and compact the stream behind it.
psl_publish_append <- function(dir, build, validate) {
  path <- psl_store_append(dir, build, validate)
  psl_store_compact(dir, keep = psl_stream_keep(), validate = validate)
  path
}

# ---------------------------------------------------------------------------
# Snapshot bytes and descriptor
# ---------------------------------------------------------------------------

# Move a staged file into the snapshot directory under a temporary name. A
# same-file-system rename is the fast path; a staged file on another file
# system (a plain `tempdir()` download) is copied instead.
psl_stage_into_snapshots <- function(from) {
  dir.create(psl_snapshot_dir(), recursive = TRUE, showWarnings = FALSE)
  staged <- tempfile("tmp-", tmpdir = psl_snapshot_dir(), fileext = ".part")
  if (file.rename(from, staged)) {
    return(staged)
  }
  if (!file.copy(from, staged, overwrite = FALSE)) {
    stop(
      sprintf("Could not stage snapshot bytes from %s", from),
      call. = FALSE
    )
  }
  unlink(from)
  staged
}

# Publish snapshot bytes, content-addressed and immutable.
#
# Bytes already published under the same checksum are authoritative: the staged
# copy is discarded rather than replacing them, so a published `.dat` is never
# rewritten and no reader ever sees it half-replaced. Returns the checksum
# identity of the published bytes.
psl_publish_snapshot_bytes <- function(path, checksum = NULL) {
  psl_lock_assert_held(psl_publish_lock_name, "Publishing snapshot bytes")
  if (!file.exists(path)) {
    stop(sprintf("Snapshot bytes not found: %s", path), call. = FALSE)
  }
  identity <- if (is.null(checksum)) {
    psl_source_checksum(path)
  } else {
    psl_checksum_id(checksum)
  }
  if (!psl_verify_checksum(path, identity)) {
    stop(errorCondition(
      sprintf("Staged bytes do not match %s.", identity),
      checksum = identity,
      class = "pslr_publication_error"
    ))
  }
  target <- psl_snapshot_bytes_path(identity)
  # Bytes already published under this identity are authoritative -- but only
  # while they still ARE those bytes. A file that fails its own checksum is
  # local corruption, not a published snapshot, and is exactly what a repair
  # download exists to replace; keeping it would leave the cache permanently
  # unusable after one bad sector.
  if (file.exists(target)) {
    if (psl_verify_checksum(target, identity)) {
      unlink(path)
      return(identity)
    }
    unlink(target)
  }
  staged <- psl_stage_into_snapshots(path)
  on.exit(unlink(staged), add = TRUE)
  # Re-check under the lock: another holder may have published these exact
  # bytes while we staged them, and published bytes are never overwritten.
  if (!file.exists(target) && !file.rename(staged, target)) {
    stop(
      sprintf("Could not publish snapshot bytes to %s", target),
      call. = FALSE
    )
  }
  identity
}

# Publish the immutable descriptor for already-published bytes.
#
# A descriptor that is already present and valid is kept: identity and
# provenance of one set of bytes do not change, so re-publication is a no-op
# rather than a rewrite. Returns the descriptor record.
psl_publish_snapshot_descriptor <- function(
  checksum,
  ...,
  content_date = NA,
  commit = NA_character_,
  origin_url = NA_character_,
  first_retrieved_at = psl_now()
) {
  psl_check_empty_dots(...)
  psl_lock_assert_held(
    psl_publish_lock_name,
    "Publishing a snapshot descriptor"
  )
  identity <- psl_checksum_id(checksum)
  bytes <- psl_snapshot_bytes_path(identity)
  if (!file.exists(bytes)) {
    stop(errorCondition(
      sprintf(
        "Refusing to describe snapshot %s: its bytes are not published.",
        identity
      ),
      checksum = identity,
      integrity = "missing",
      class = "pslr_publication_error"
    ))
  }
  existing <- psl_read_snapshot_descriptor(identity)
  if (!is.null(existing)) {
    return(existing)
  }
  record <- new_psl_snapshot_descriptor(
    checksum = identity,
    size = as.integer(file.size(bytes)),
    storage = "cache",
    path = basename(bytes),
    content_date = content_date,
    commit = commit,
    origin_url = origin_url,
    first_retrieved_at = psl_as_rfc3339(first_retrieved_at)
  )
  target <- psl_snapshot_descriptor_path(identity)
  tmp <- tempfile("tmp-", tmpdir = psl_snapshot_dir(), fileext = ".part")
  on.exit(unlink(tmp), add = TRUE)
  con <- file(tmp, open = "wb")
  saveRDS(record, con)
  close(con)
  if (!file.exists(target) && !file.rename(tmp, target)) {
    stop(
      sprintf("Could not publish snapshot descriptor to %s", target),
      call. = FALSE
    )
  }
  record
}

# Publish bytes and descriptor together: the whole content half of a commit,
# before any reference to it exists. Returns the descriptor record.
psl_publish_snapshot <- function(
  path,
  ...,
  checksum = NULL,
  content_date = NA,
  commit = NA_character_,
  origin_url = NA_character_,
  first_retrieved_at = psl_now()
) {
  psl_check_empty_dots(...)
  psl_publish_checkpoint("bytes")
  identity <- psl_publish_snapshot_bytes(path, checksum)
  psl_publish_checkpoint("descriptor")
  psl_publish_snapshot_descriptor(
    identity,
    content_date = content_date,
    commit = commit,
    origin_url = origin_url,
    first_retrieved_at = first_retrieved_at
  )
}

# ---------------------------------------------------------------------------
# References
# ---------------------------------------------------------------------------

# Append one source-state generation. `...` is forwarded to the constructor, so
# a misspelled field is rejected there rather than silently dropped. A non-`NA`
# `checksum` must already resolve to a published snapshot.
psl_publish_source_state <- function(request_url, ...) {
  psl_lock_assert_held(psl_publish_lock_name, "Publishing source state")
  fields <- list(...)
  checksum <- fields$checksum
  if (is.character(checksum) && length(checksum) == 1L && !is.na(checksum)) {
    psl_require_publishable(checksum, "source state")
  }
  psl_publish_checkpoint("source_state")
  psl_publish_append(
    psl_source_stream_dir(request_url),
    \(g) {
      do.call(
        new_psl_source_state,
        c(list(request_url = request_url, generation = g), fields)
      )
    },
    validate_psl_source_state
  )
}

# Append one cache-selection generation naming the snapshot `psl_use("cache")`
# resolves to. The referenced snapshot must already be published.
psl_publish_selection <- function(
  checksum,
  ...,
  request_url = NA_character_,
  selected_at = psl_now()
) {
  psl_check_empty_dots(...)
  psl_lock_assert_held(psl_publish_lock_name, "Publishing a cache selection")
  identity <- psl_require_publishable(checksum, "a cache selection")
  psl_publish_checkpoint("selection")
  psl_publish_append(
    psl_selection_stream_dir(),
    \(g) {
      new_psl_selection(
        identity,
        generation = g,
        request_url = request_url,
        selected_at = selected_at
      )
    },
    validate_psl_selection
  )
}

# The current cache selection, as a store read result. `record$checksum` is
# only trustworthy alongside `psl_snapshot_integrity()`, because pruning and
# manual cache tampering both happen outside pslr's control.
psl_read_selection <- function() {
  psl_store_read(psl_selection_stream_dir(), validate_psl_selection)
}

psl_read_source_state <- function(request_url) {
  psl_store_read(psl_source_stream_dir(request_url), validate_psl_source_state)
}

# ---------------------------------------------------------------------------
# Composite commit
# ---------------------------------------------------------------------------

# Publish one refreshed source in the referentially safe order.
#
# The caller holds the source lock across its network work and calls this for
# the short publication phase, which takes the publish lock -- source lock,
# then publish lock, the normative order. `path` names freshly downloaded and
# already validated bytes; pass `path = NULL` with a `checksum` to commit a
# `304` against a snapshot that is already published.
#
# `state` and `descriptor` are lists of constructor fields. `select = FALSE`
# commits source knowledge without repointing `psl_use("cache")`, which is what
# a refresh of a non-selected source does.
psl_publish_refresh <- function(
  request_url,
  ...,
  path = NULL,
  checksum = NULL,
  descriptor = list(),
  state = list(),
  select = TRUE
) {
  psl_check_empty_dots(...)
  psl_lock_assert_held(
    psl_source_lock_name(request_url),
    "Publishing a refresh"
  )
  psl_with_publish_lock({
    identity <- if (is.null(path)) {
      psl_require_publishable(checksum, "a refresh")
    } else {
      do.call(
        psl_publish_snapshot,
        c(list(path = path, checksum = checksum), descriptor)
      )$checksum
    }
    source_path <- do.call(
      psl_publish_source_state,
      c(
        list(request_url = request_url),
        utils::modifyList(state, list(checksum = identity))
      )
    )
    selection_path <- if (select) {
      psl_publish_selection(identity, request_url = request_url)
    } else {
      NA_character_
    }
    list(
      checksum = identity,
      source_state = source_path,
      selection = selection_path
    )
  })
}
