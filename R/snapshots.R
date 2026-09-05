# Offline snapshot inventory (freshness v2).
#
# `psl_snapshots()` is the read-only census of every set of PSL bytes this
# installation can resolve: the snapshot shipped with the package plus every
# snapshot published into the user cache. Like `psl_status()` it makes no
# request, writes nothing, and migrates nothing.
#
# Three rules shape it.
#
#   1. IDENTITY IS THE ROW. Bytes are identified by their SHA-256 checksum, so
#      the same bytes stored twice -- shipped with the package AND published in
#      the cache -- are ONE row with one preferred path, never two.
#   2. NO URL LEAVES THIS TABLE THAT THE USER DID NOT SUPPLY. Request URLs of
#      custom sources may be private, so association with sources is reported
#      as `source_count`, a count, and never as a list-column of URLs. The only
#      URL column is `origin_url`, which is immutable build provenance recorded
#      in the snapshot descriptor itself.
#   3. INTEGRITY IS CHEAP BY DEFAULT. A row is classified from file presence,
#      descriptor structure, and the byte size the descriptor recorded -- all
#      metadata reads. Rehashing every snapshot is real I/O per row and is
#      therefore opt-in through `verify = TRUE`.

# ---------------------------------------------------------------------------
# Return schema
# ---------------------------------------------------------------------------

# The stable column contract: name, order, and storage type. `"time"` columns
# are POSIXct in UTC. Owned in one place so row construction and the column
# types can never drift apart.
psl_snapshots_columns <- c(
  checksum = "character",
  path = "character",
  size = "integer",
  content_date = "time",
  first_retrieved_at = "time",
  origin_url = "character",
  first_normalization_profile = "character",
  bundled = "logical",
  selected_cache = "logical",
  active = "logical",
  current_for_any_source = "logical",
  source_count = "integer",
  integrity = "character"
)

# One field of one row, coerced to its declared storage type.
psl_snapshots_scalar <- function(value, type) {
  if (is.null(value) || length(value) != 1L) {
    value <- NA
  }
  switch(
    type,
    character = as.character(value),
    integer = as.integer(value),
    logical = as.logical(value)
  )
}

# One whole column, built from the per-row values. Times are rebuilt from
# seconds rather than concatenated, so the UTC time zone survives regardless of
# how many rows there are -- including none.
psl_snapshots_column <- function(values, type) {
  if (identical(type, "time")) {
    seconds <- vapply(values, \(v) as.numeric(psl_as_time(v)), numeric(1L))
    return(as.POSIXct(seconds, origin = "1970-01-01", tz = "UTC"))
  }
  template <- switch(
    type,
    character = NA_character_,
    integer = NA_integer_,
    logical = NA
  )
  vapply(values, psl_snapshots_scalar, template, type = type)
}

# Assemble the inventory from a list of flat per-row field lists.
new_psl_snapshots <- function(rows) {
  cols <- Map(
    function(name, type) {
      psl_snapshots_column(lapply(rows, \(row) row[[name]]), type)
    },
    names(psl_snapshots_columns),
    psl_snapshots_columns
  )
  structure(
    data.frame(cols, stringsAsFactors = FALSE, row.names = NULL),
    class = c("psl_snapshots", "data.frame")
  )
}

# ---------------------------------------------------------------------------
# Which checksums exist
# ---------------------------------------------------------------------------

# The installed snapshot's identity, or `NA` when the shipped metadata does not
# carry a usable one.
psl_snapshots_bundled_checksum <- function() {
  checksum <- pslr_bundled$meta$checksum
  if (is.character(checksum) && length(checksum) == 1L && !is.na(checksum)) {
    checksum
  } else {
    NA_character_
  }
}

# Path of the PSL source file installed with the package.
psl_snapshots_bundled_path <- function() {
  system.file("extdata", "public_suffix_list.dat", package = "pslr")
}

# Every checksum with bytes or a descriptor in the cache's snapshot directory.
# Reading the file names is enough: the layout is content-addressed, so the
# name IS the identity and no file has to be opened to enumerate the store.
psl_snapshots_published <- function() {
  dir <- psl_snapshot_dir()
  if (!dir.exists(dir)) {
    return(character())
  }
  files <- list.files(dir, pattern = "^sha256-[0-9a-f]{64}[.](dat|rds)$")
  if (!length(files)) {
    return(character())
  }
  unique(paste0("sha256:", substr(files, 8L, 71L)))
}

# The checksum `psl_use("cache")` would resolve to, or `NA` when there is no
# trustworthy selection. A `recovered` or `corrupt` selection stream proves
# nothing about the current selection and is reported as no selection at all,
# exactly as `psl_status()` treats it.
psl_snapshots_selected <- function() {
  read <- psl_read_selection()
  usable <- identical(read$status, "ok") &&
    psl_valid_sha256_ref(read$record$checksum)
  if (usable) read$record$checksum else NA_character_
}

# What each readable source stream currently says, reduced to a checksum and
# whether that knowledge is the stream's own current generation. The request
# URL is deliberately dropped here rather than filtered out later, so no code
# path downstream can leak it into the inventory.
psl_snapshots_source_index <- function() {
  root <- file.path(psl_cache_dir(), "sources")
  if (!dir.exists(root)) {
    return(list(checksum = character(), current = logical()))
  }
  entries <- lapply(list.dirs(root, recursive = FALSE), function(dir) {
    read <- psl_store_read(dir, validate_psl_source_state)
    usable <- read$status %in%
      c("ok", "recovered") &&
      psl_valid_sha256_ref(read$record$checksum)
    if (!usable) {
      return(NULL)
    }
    list(
      checksum = read$record$checksum,
      current = identical(read$status, "ok")
    )
  })
  entries <- entries[!vapply(entries, is.null, logical(1L))]
  list(
    checksum = vapply(entries, \(e) e$checksum, character(1L)),
    current = vapply(entries, \(e) e$current, logical(1L))
  )
}

# The active engine's snapshot identity. Reading it lazily initialises the
# bundled engine in this process, which is memory only -- no file is written.
psl_snapshots_active_checksum <- function() {
  checksum <- active_meta()$checksum
  if (is.character(checksum) && length(checksum) == 1L && !is.na(checksum)) {
    checksum
  } else {
    NA_character_
  }
}

# Everything one call needs to classify every row, read exactly once.
psl_snapshots_context <- function(verify) {
  sources <- psl_snapshots_source_index()
  list(
    verify = verify,
    bundled = psl_snapshots_bundled_checksum(),
    selected = psl_snapshots_selected(),
    active = psl_snapshots_active_checksum(),
    sources = sources
  )
}

# The distinct identities the inventory covers, in a deterministic order.
# Radix ordering keeps that order independent of the collation locale.
#
# A checksum referenced by the selection or by a source but no longer stored is
# included on purpose: a dangling reference is part of the local state, and
# reporting it as `missing` is more useful than silently omitting it.
psl_snapshots_checksums <- function(ctx) {
  known <- c(
    psl_snapshots_published(),
    ctx$bundled,
    ctx$selected,
    ctx$sources$checksum
  )
  known <- unique(known[!is.na(known)])
  # Every identity must resolve to at least one storage location: a checksum
  # this release cannot even parse is only ever the installed one.
  resolvable <- vapply(known, psl_valid_sha256_ref, logical(1L))
  if (!is.na(ctx$bundled)) {
    resolvable <- resolvable | known == ctx$bundled
  }
  sort(known[resolvable], method = "radix")
}

# ---------------------------------------------------------------------------
# Storage locations
# ---------------------------------------------------------------------------

# Bytes that are not the size their descriptor recorded cannot be the bytes the
# checksum names. Comparing sizes is a metadata read, so this catches the
# common truncation and overwrite cases without hashing anything.
psl_snapshots_size_integrity <- function(path, recorded) {
  known <- is.numeric(recorded) && length(recorded) == 1L
  if (!known || is.na(recorded) || is.na(file.size(path))) {
    return("ok")
  }
  if (identical(as.numeric(file.size(path)), as.numeric(recorded))) {
    "ok"
  } else {
    "checksum_mismatch"
  }
}

# One cached snapshot as a storage location: where its bytes are, what its
# descriptor says about them, and how far the two agree.
psl_snapshots_cache_location <- function(checksum, verify) {
  bytes <- psl_snapshot_bytes_path(checksum)
  descriptor <- psl_read_snapshot_descriptor(checksum)
  integrity <- psl_snapshot_integrity(checksum, verify = verify)
  if (identical(integrity, "ok")) {
    integrity <- psl_snapshots_size_integrity(bytes, descriptor$size)
  }
  present <- file.exists(bytes)
  list(
    path = if (present) bytes else NA_character_,
    size = if (present) as.integer(file.size(bytes)) else descriptor$size,
    content_date = descriptor$content_date,
    first_retrieved_at = descriptor$first_retrieved_at,
    origin_url = descriptor$origin_url,
    normalization_profile = descriptor$normalization_profile,
    integrity = integrity
  )
}

# The installed snapshot as a storage location. Its descriptor is the metadata
# built into the package, so an identity this release cannot read at all is
# `unknown_schema` for the same reason an unreadable cache descriptor is.
psl_snapshots_bundled_location <- function(verify) {
  meta <- pslr_bundled$meta
  path <- psl_snapshots_bundled_path()
  present <- nzchar(path) && file.exists(path)
  list(
    path = if (present) path else NA_character_,
    size = if (present) as.integer(file.size(path)) else meta$size,
    content_date = psl_parse_list_date(meta$list_date),
    first_retrieved_at = psl_parse_list_date(meta$retrieved_at),
    origin_url = meta$url,
    normalization_profile = meta$normalization_profile,
    integrity = psl_snapshots_bundled_integrity(meta, path, present, verify)
  )
}

psl_snapshots_bundled_integrity <- function(meta, path, present, verify) {
  if (!psl_valid_sha256_ref(meta$checksum)) {
    return("unknown_schema")
  }
  if (!present) {
    return("missing")
  }
  size <- psl_snapshots_size_integrity(path, meta$size)
  if (!identical(size, "ok")) {
    return(size)
  }
  if (verify && !psl_verify_checksum(path, meta$checksum)) {
    return("checksum_mismatch")
  }
  "ok"
}

# Every location holding these bytes, best first. Duplicate storage collapses
# here: a location whose bytes actually resolve outranks one that does not, and
# the cache copy outranks the installed copy, because the cache copy is the one
# pruning and refreshing act on.
psl_snapshots_locations <- function(checksum, ctx) {
  locations <- list()
  if (psl_valid_sha256_ref(checksum)) {
    locations$cache <- psl_snapshots_cache_location(checksum, ctx$verify)
  }
  if (identical(checksum, ctx$bundled)) {
    locations$bundled <- psl_snapshots_bundled_location(ctx$verify)
  }
  broken <- vapply(
    locations,
    \(loc) !identical(loc$integrity, "ok"),
    logical(1L)
  )
  locations[order(broken)]
}

# The first value a location knows for one provenance field. This is sound
# only for provenance that genuinely belongs to the bytes -- upstream date,
# first receipt, origin URL -- where a value recorded in either location
# describes the same bytes. It is NOT sound for the normalization fields: those
# record the normalizer installed when each location's descriptor was first
# written, so two locations holding the same bytes can honestly disagree. They
# are read from the preferred location instead, never merged across locations.
psl_snapshots_coalesce <- function(locations, field) {
  for (location in locations) {
    value <- location[[field]]
    if (!is.null(value) && length(value) == 1L && !is.na(value)) {
      return(value)
    }
  }
  NA
}

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

# The four logical flags plus the source count. `source_count` counts sources
# whose retained knowledge names these bytes; `current_for_any_source` is
# stricter and requires at least one of those streams to be readable at its
# current generation, because a `recovered` stream must never be presented as
# confirmation.
psl_snapshots_flags <- function(checksum, ctx) {
  matched <- ctx$sources$checksum == checksum
  list(
    bundled = identical(checksum, ctx$bundled),
    selected_cache = identical(checksum, ctx$selected),
    active = identical(checksum, ctx$active),
    current_for_any_source = any(matched & ctx$sources$current),
    source_count = sum(matched)
  )
}

psl_snapshots_provenance <- function(locations) {
  fields <- c(
    "content_date",
    "first_retrieved_at",
    "origin_url"
  )
  values <- lapply(fields, \(field) psl_snapshots_coalesce(locations, field))
  names(values) <- fields
  values
}

psl_snapshots_row <- function(checksum, ctx) {
  locations <- psl_snapshots_locations(checksum, ctx)
  preferred <- locations[[1L]]
  c(
    list(
      checksum = checksum,
      path = preferred$path,
      size = preferred$size,
      integrity = preferred$integrity,
      first_normalization_profile = preferred$normalization_profile
    ),
    psl_snapshots_provenance(locations),
    psl_snapshots_flags(checksum, ctx)
  )
}

#' Inventory of the locally available Public Suffix List snapshots
#'
#' Lists every set of Public Suffix List bytes this installation can resolve:
#' the snapshot installed with the package plus every snapshot published into
#' the user cache. There is exactly one row per distinct SHA-256 checksum, so
#' bytes stored in more than one place collapse into a single row with one
#' preferred path.
#'
#' The call is strictly offline and read-only. It makes no request, writes
#' nothing, repairs nothing, and performs no cache migration; a snapshot whose
#' local storage is damaged is reported through `integrity` rather than raised
#' as an error.
#'
#' @details
#' `integrity` is one of:
#'
#' \describe{
#'   \item{`ok`}{Bytes and a readable descriptor are both present and agree.}
#'   \item{`missing`}{The bytes or the descriptor are not stored, which is also
#'     what a reference to an already pruned snapshot reports.}
#'   \item{`checksum_mismatch`}{The stored bytes cannot be the bytes the
#'     checksum names.}
#'   \item{`unknown_schema`}{The descriptor is unreadable, or was written by a
#'     release whose schema this one does not support.}
#' }
#'
#' Descriptors are checked structurally; no list is reparsed, so an ordinary
#' call is cheap enough to make casually. By default `checksum_mismatch` is
#' derived from metadata alone -- a stored file whose size differs from the size
#' its descriptor recorded cannot hold the bytes the checksum names. That misses
#' corruption that preserves the byte count; `verify = TRUE` rehashes every
#' snapshot's bytes and catches it, at the cost of reading every stored file in
#' full.
#'
#' Request URLs of custom sources may be private, so association with sources
#' is reported only as the count `source_count`. The inventory never returns a
#' source URL; `origin_url` is immutable provenance recorded in the snapshot's
#' own descriptor.
#'
#' @param ... These dots are for future extension and must be empty.
#' @param verify Whether to rehash every snapshot's bytes to detect corruption
#'   that preserves the byte count. `FALSE` (the default) classifies rows from
#'   metadata alone; `TRUE` reads every stored snapshot in full.
#'
#' @return A base [data.frame] of class `psl_snapshots`, one row per distinct
#'   checksum, ordered by `checksum`, with the columns, in order: `checksum`
#'   (character, the `"sha256:<hex>"` identity), `path` (character, the
#'   preferred storage location, `NA` when the bytes are not stored), `size`
#'   (integer bytes), `content_date` (POSIXct upstream provenance date),
#'   `first_retrieved_at` (POSIXct, when these bytes were first received),
#'   `origin_url` (character immutable origin recorded at publication),
#'   `first_normalization_profile` (character, the normalization profile in use
#'   when these bytes were first published to the preferred location; it is
#'   first-publication provenance, not the profile this session queries under
#'   -- for that, see [psl_version()]), `bundled` (logical, installed with the
#'   package), `selected_cache` (logical, the snapshot `psl_use("cache")` would
#'   resolve to), `active` (logical, the snapshot active in this session),
#'   `current_for_any_source` (logical, named by at least one source's current
#'   record), `source_count` (integer number of sources associated with these
#'   bytes), and `integrity` (character, see Details). Unavailable values are a
#'   typed `NA`. The bundled snapshot is always inventoried, so the result is
#'   never empty on a working installation.
#' @seealso [psl_status()], [psl_refresh()], [psl_diff()],
#'   [psl_cache_prune()]
#' @examples
#' # Every snapshot this installation can resolve, without any network access:
#' snapshots <- psl_snapshots()
#' snapshots[c("checksum", "bundled", "size", "integrity")]
#'
#' # The snapshot installed with the package is always inventoried:
#' snapshots[snapshots$bundled, ]$integrity
#'
#' # Rehash every stored snapshot instead of trusting recorded sizes:
#' psl_snapshots(verify = TRUE)$integrity
#' @export
psl_snapshots <- function(..., verify = FALSE) {
  psl_check_empty_dots(...)
  psl_check_flag(verify, "verify")
  ctx <- psl_snapshots_context(verify)
  rows <- lapply(psl_snapshots_checksums(ctx), psl_snapshots_row, ctx = ctx)
  new_psl_snapshots(rows)
}

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

# The short labels that describe one row's role, in a fixed order so two rows
# never describe the same role differently.
psl_snapshots_tags <- function(row) {
  tags <- c(
    if (isTRUE(row$bundled)) "bundled",
    if (isTRUE(row$selected_cache)) "selected",
    if (isTRUE(row$active)) "active",
    if (row$source_count > 0L) {
      sprintf(
        "%d source%s",
        row$source_count,
        if (row$source_count == 1L) "" else "s"
      )
    }
  )
  if (length(tags)) toString(tags) else "unreferenced"
}

psl_snapshots_size_label <- function(size) {
  if (is.na(size)) "? B" else sprintf("%s B", format(size, big.mark = ","))
}

psl_snapshots_date_label <- function(x) {
  if (is.na(x)) "-" else format(x, "%Y-%m-%d", tz = "UTC")
}

# One display line per row: identity, size, content date, roles, and the
# integrity state whenever it is anything other than `ok`.
psl_snapshots_lines <- function(x) {
  cells <- lapply(seq_len(nrow(x)), function(i) {
    row <- x[i, ]
    c(
      psl_status_short_checksum(row$checksum),
      psl_snapshots_size_label(row$size),
      psl_snapshots_date_label(row$content_date),
      psl_snapshots_tags(row),
      if (identical(row$integrity, "ok")) {
        ""
      } else {
        paste0("[", row$integrity, "]")
      }
    )
  })
  widths <- vapply(
    seq_len(4L),
    \(j) max(nchar(vapply(cells, \(cell) cell[[j]], character(1L)))),
    integer(1L)
  )
  vapply(
    cells,
    function(cell) {
      padded <- sprintf("%-*s", widths, cell[seq_len(4L)])
      trimws(paste("  ", paste(padded, collapse = "  "), cell[[5L]]), "right")
    },
    character(1L)
  )
}

# Does `x` still carry the whole column contract the display assumes?
psl_snapshots_complete <- function(x) {
  all(names(psl_snapshots_columns) %in% names(x))
}

#' @rdname psl_snapshots
#' @param x A `psl_snapshots` inventory, as returned by [psl_snapshots()].
#' @return `format()` returns a character vector of display lines and `print()`
#'   returns `x` invisibly.
#' @keywords internal
#' @export
format.psl_snapshots <- function(x, ...) {
  # Subsetting columns leaves the class behind but not the contract, so a
  # partial inventory falls back to ordinary data-frame display.
  if (!psl_snapshots_complete(x)) {
    return(format.data.frame(x, ...))
  }
  if (!nrow(x)) {
    return("<psl_snapshots: no snapshots>")
  }
  header <- sprintf(
    "<psl_snapshots: %d snapshot%s>",
    nrow(x),
    if (nrow(x) == 1L) "" else "s"
  )
  c(header, psl_snapshots_lines(x))
}

#' @rdname psl_snapshots
#' @keywords internal
#' @export
print.psl_snapshots <- function(x, ...) {
  if (!psl_snapshots_complete(x)) {
    print.data.frame(x, ...)
    return(invisible(x))
  }
  cat(format(x, ...), sep = "\n")
  invisible(x)
}
