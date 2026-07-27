# Offline snapshot comparison (freshness v2, PSLR-aeuaykkf).
#
# `psl_diff()` answers "what changed between these two Public Suffix Lists?"
# from snapshots that are already on this machine. Three rules shape it.
#
#   1. NOTHING IS FETCHED. Every accepted input form resolves from local bytes,
#      the installed snapshot, or an in-memory rule table. There is no
#      date-to-snapshot resolver and no historical downloader: the upstream
#      endpoint publishes only the current list, and the list itself asks
#      callers not to rely on VCS URLs. Local collection starts at the first
#      explicit `psl_refresh()` and every distinct validated download is
#      retained until `psl_cache_prune()`.
#   2. NOTHING IS ACTIVATED. Both sides resolve independently and neither
#      touches the session-global engine `psl_use()` controls, so diffing the
#      cache cannot change what the next query answers.
#   3. THE COMPARISON IS CANONICAL, NOT TEXTUAL. Rules are compared after
#      parsing and canonicalization, so comments, blank lines, whitespace,
#      case, source ordering, and raw Unicode spelling never show up as a
#      change.

# ---------------------------------------------------------------------------
# Logical identity
# ---------------------------------------------------------------------------

# The marker that a rule kind prefixes onto its canonical labels. Shared by the
# strip and rebuild directions so they can never disagree.
psl_diff_markers <- c(normal = "", wildcard = "*.", exception = "!")

# Canonical labels with the leading wildcard or exception marker removed -- the
# logical identity a diff row is keyed on. This is exactly the `canonical_key`
# the parser records, recovered from a rule table that carries only the marked
# `canonical_rule`.
psl_diff_strip_marker <- function(canonical_rule, kind) {
  out <- canonical_rule
  wildcard <- kind == "wildcard"
  exception <- kind == "exception"
  out[wildcard] <- substr(out[wildcard], 3L, nchar(out[wildcard]))
  out[exception] <- substr(out[exception], 2L, nchar(out[exception]))
  out
}

# The inverse: canonical rule text for canonical labels under a rule kind.
psl_diff_add_marker <- function(canonical_key, kind) {
  paste0(unname(psl_diff_markers[kind]), canonical_key)
}

# ---------------------------------------------------------------------------
# Resolving one side
# ---------------------------------------------------------------------------

# The `psl_rules()` column contract a rule-table input must carry. `rule` and
# `labels` are required for schema fidelity -- a table without them is not a
# `psl_rules()` table -- while the diff itself reads only `canonical_rule`,
# `kind`, and `section`.
psl_diff_table_columns <- c(
  "rule",
  "canonical_rule",
  "kind",
  "section",
  "labels"
)

psl_diff_abort <- function(arg, detail) {
  stop(sprintf("`%s` %s", arg, detail), call. = FALSE)
}

# Reject anything that is not a supported input form, naming every form that is.
psl_diff_abort_type <- function(arg) {
  psl_diff_abort(
    arg,
    paste0(
      'must be "bundled", "cache", a path to a PSL source file, a ',
      "`psl_engine`, or a rule table with the `psl_rules()` schema."
    )
  )
}

# Validate one character column of a rule table and return it unchanged.
psl_diff_table_column <- function(x, column, arg, values = NULL) {
  value <- x[[column]]
  if (!is.character(value) || anyNA(value)) {
    psl_diff_abort(
      arg,
      sprintf("column `%s` must be a character vector with no `NA`.", column)
    )
  }
  if (!is.null(values) && !all(value %in% values)) {
    bad <- unique(value[!value %in% values])[[1L]]
    psl_diff_abort(
      arg,
      sprintf(
        "column `%s` has the unsupported value \"%s\"; expected one of: %s.",
        column,
        bad,
        toString(paste0("\"", values, "\""))
      )
    )
  }
  value
}

# A rule kind and its canonical rule text must agree about the marker, or the
# logical identity recovered from the text would silently be wrong.
psl_diff_check_markers <- function(canonical_rule, kind, arg) {
  expected <- unname(psl_diff_markers[kind])
  actual <- substr(canonical_rule, 1L, nchar(expected))
  starred <- expected == "" & grepl("^([*]|!)", canonical_rule)
  bad <- which(actual != expected | starred)
  if (length(bad)) {
    i <- bad[[1L]]
    psl_diff_abort(
      arg,
      sprintf(
        paste0(
          "row %d has `canonical_rule` \"%s\", which does not match its ",
          "`kind` \"%s\"."
        ),
        i,
        canonical_rule[[i]],
        kind[[i]]
      )
    )
  }
  invisible(NULL)
}

# Turn a `psl_rules()`-shaped table into the internal rule table the diff
# consumes. The recovered labels are re-canonicalized under the runtime
# normalizer, so a hand-built table holding mixed-case or Unicode rule text is
# compared on exactly the same footing as a parsed source file, and the
# canonical rule text is rebuilt from the normalized labels rather than trusted.
psl_diff_table_rules <- function(x, arg) {
  missing <- setdiff(psl_diff_table_columns, names(x))
  if (length(missing)) {
    psl_diff_abort(
      arg,
      sprintf("is missing the `psl_rules()` column(s): %s.", toString(missing))
    )
  }
  raw <- psl_diff_table_column(x, "rule", arg)
  canonical_rule <- psl_diff_table_column(x, "canonical_rule", arg)
  kind <- psl_diff_table_column(
    x,
    "kind",
    arg,
    c("normal", "wildcard", "exception")
  )
  section <- psl_diff_table_column(x, "section", arg, c("icann", "private"))
  psl_diff_check_markers(canonical_rule, kind, arg)

  key <- punycoder::host_normalize(psl_diff_strip_marker(canonical_rule, kind))
  if (anyNA(key)) {
    i <- which(is.na(key))[[1L]]
    psl_diff_abort(
      arg,
      sprintf(
        "row %d has rule \"%s\", which could not be canonicalized.",
        i,
        canonical_rule[[i]]
      )
    )
  }

  rules <- data.frame(
    line = seq_along(key),
    raw = raw,
    section = section,
    kind = kind,
    canonical_rule = psl_diff_add_marker(key, kind),
    canonical_key = key,
    labels = lengths(strsplit(key, ".", fixed = TRUE)) +
      (kind == "wildcard"),
    stringsAsFactors = FALSE
  )
  apply_duplicate_policy(rules, mode = "lenient")
}

# Resolve a character scalar: the two reserved source names, else a local PSL
# source file. Reserved names always win, so a file literally named `cache` has
# to be given as a path with a directory component.
psl_diff_source_snapshot <- function(x, arg) {
  if (identical(x, "bundled")) {
    return(bundled_snapshot())
  }
  if (identical(x, "cache")) {
    return(cache_snapshot())
  }
  if (!file.exists(x)) {
    psl_diff_abort(
      arg,
      sprintf(
        paste0(
          "is \"%s\", which is neither \"bundled\", \"cache\", nor an ",
          "existing PSL source file."
        ),
        x
      )
    )
  }
  path_snapshot(x)
}

# Resolve one side of the comparison to its rule table plus, when the input form
# carries it, the `psl_version()` row describing where those rules came from.
# Never activates anything and never makes a request.
psl_diff_resolve <- function(x, arg) {
  if (inherits(x, "psl_engine")) {
    return(psl_diff_resolved(x$snapshot))
  }
  if (is.data.frame(x)) {
    return(list(rules = psl_diff_table_rules(x, arg), version = NULL))
  }
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    psl_diff_abort_type(arg)
  }
  psl_diff_resolved(psl_diff_source_snapshot(x, arg))
}

psl_diff_resolved <- function(snapshot) {
  list(rules = snapshot$rules, version = as_psl_version_df(snapshot$meta))
}

# ---------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------

# Reduce one snapshot's rules to parallel vectors keyed by logical identity, in
# a locale-independent order.
#
# Within one section the duplicate policy guarantees at most one rule per
# identity, so the common case is one row per identity and the vectors are just
# a reordering. Section membership is deliberately NOT part of the identity --
# an ICANN/PRIVATE move has to surface as `changed`, not as an unrelated
# add/remove pair -- so a list that legally carries the same labels in BOTH
# sections contributes two rules under one identity. Those collapse into one
# entry whose values are joined in ICANN-then-PRIVATE order, which keeps the
# result exactly one row per identity.
psl_diff_side <- function(rules) {
  ord <- order(
    rules$canonical_key,
    match(rules$section, c("icann", "private")),
    method = "radix"
  )
  side <- list(
    key = rules$canonical_key[ord],
    rule = rules$canonical_rule[ord],
    kind = rules$kind[ord],
    section = rules$section[ord]
  )
  if (anyDuplicated(side$key) == 0L) {
    return(side)
  }
  group <- factor(side$key, levels = unique(side$key))
  joined <- lapply(side[c("rule", "kind", "section")], function(value) {
    vapply(split(value, group), toString, character(1L), USE.NAMES = FALSE)
  })
  c(list(key = levels(group)), joined)
}

# Classify every identity either side knows and drop the ones that did not move.
# Because a canonical rule is its marker plus its identity, two rules sharing an
# identity have identical text exactly when they share a kind -- so a surviving
# identity differs precisely when its kind or its section differs.
#
# The whole body is shape-preserving, so two snapshots that agree -- and two
# empty rule tables -- fall out as the same typed zero-row frame with no special
# case.
psl_diff_frame <- function(old, new) {
  o <- psl_diff_side(old)
  n <- psl_diff_side(new)
  keys <- sort(unique(c(o$key, n$key)), method = "radix")
  oi <- match(keys, o$key)
  ni <- match(keys, n$key)
  in_old <- !is.na(oi)
  in_new <- !is.na(ni)

  change <- rep(NA_character_, length(keys))
  change[!in_old] <- "added"
  change[!in_new] <- "removed"
  both <- in_old & in_new
  change[both & (o$kind[oi] != n$kind[ni] | o$section[oi] != n$section[ni])] <-
    "changed"

  keep <- !is.na(change)
  data.frame(
    change = change[keep],
    rule = keys[keep],
    old_rule = o$rule[oi][keep],
    new_rule = n$rule[ni][keep],
    old_kind = o$kind[oi][keep],
    new_kind = n$kind[ni][keep],
    old_section = o$section[oi][keep],
    new_section = n$section[ni][keep],
    stringsAsFactors = FALSE,
    row.names = NULL
  )
}

#' Compare two Public Suffix List snapshots
#'
#' Reports which rules were added, removed, or changed between two Public Suffix
#' List snapshots that are already available locally. The comparison is
#' canonical rather than textual: both sides are parsed and canonicalized first,
#' so comments, blank lines, whitespace, letter case, source ordering, and raw
#' Unicode spelling are never reported as changes.
#'
#' The call is strictly offline. No input form triggers a request, and neither
#' side changes the session-global list that [psl_use()] controls, so diffing
#' the cache leaves the next query answering from exactly the list it did
#' before.
#'
#' @param old,new The two snapshots to compare. Each accepts, independently, one
#'   of: `"bundled"` (the snapshot installed with the package), `"cache"` (the
#'   snapshot [psl_use()] would resolve, i.e. the current cache selection), a
#'   path to a local PSL source file, a `psl_engine` from [psl_engine()], or a
#'   rule table with the [psl_rules()] schema. `"bundled"` and `"cache"` are
#'   reserved names, so a file with either of those names must be given as a
#'   path carrying a directory component.
#' @param ... These dots are for future extension and must be empty.
#'
#' @section Which snapshots are available:
#' The upstream endpoint publishes only the current list, and the list itself
#' asks callers not to depend on version-control URLs, so `psl_diff()` resolves
#' no dates and downloads no history. Installing the package performs no
#' request and provides only the bundled snapshot; local collection begins at
#' the first explicit [psl_refresh()], after which each distinct validated
#' download is retained as an immutable file until [psl_cache_prune()] collects
#' it. [psl_snapshots()] lists what is resolvable, with a `path` for each set of
#' stored bytes; any of those paths, or any historical revision the caller
#' materializes as a file by other means, can be passed here directly.
#'
#' @section Change semantics:
#' A rule's *logical identity* is its canonical labels with the leading `*.` or
#' `!` marker removed, so `*.example.com` and `example.com` are the same
#' identity in two different states. `change` is:
#'
#' \describe{
#'   \item{`added`}{The identity exists only in `new`.}
#'   \item{`removed`}{The identity exists only in `old`.}
#'   \item{`changed`}{The identity exists in both, but its canonical rule kind
#'     or its ICANN/PRIVATE section differs.}
#' }
#'
#' Identities that exist in both snapshots in the same state are not reported.
#' Section membership is a compared attribute rather than part of the identity,
#' so a rule moving between the ICANN and PRIVATE sections is one `changed` row
#' rather than an unrelated `removed`/`added` pair. A list may legally carry the
#' same labels once in each section; such rules collapse into the single row for
#' their identity, with the values of that side joined in ICANN-then-PRIVATE
#' order.
#'
#' @return A base [data.frame] with one row per changed logical identity,
#'   ordered by that identity, and columns, in order: `change` (`"added"`,
#'   `"removed"`, or `"changed"`), `rule` (the logical identity), `old_rule` and
#'   `new_rule` (canonical rule text including any `*.` or `!` marker),
#'   `old_kind` and `new_kind` (`"normal"`, `"wildcard"`, or `"exception"`), and
#'   `old_section` and `new_section` (`"icann"` or `"private"`). Every field
#'   belonging to a side the identity is absent from is `NA`. Two snapshots that
#'   agree return the same columns and types with zero rows.
#'
#'   Provenance is attached as the attributes `old_version` and `new_version`,
#'   each a one-row [psl_version()] frame describing that side's snapshot, or
#'   `NULL` when the input was a rule table and therefore carries no provenance.
#' @seealso [psl_snapshots()], [psl_refresh()], [psl_rules()], [psl_version()]
#' @examples
#' # Two small lists on disk, written offline.
#' write_list <- function(private) {
#'   path <- tempfile(fileext = ".dat")
#'   writeLines(
#'     c(
#'       "// ===BEGIN ICANN DOMAINS===",
#'       "com",
#'       "// ===END ICANN DOMAINS===",
#'       "// ===BEGIN PRIVATE DOMAINS===",
#'       private,
#'       "// ===END PRIVATE DOMAINS==="
#'     ),
#'     path
#'   )
#'   path
#' }
#' old <- write_list(c("a.example.com", "*.b.example.com"))
#' new <- write_list(c("b.example.com", "c.example.com"))
#'
#' # One row each: a.example.com removed, b.example.com changed kind,
#' # c.example.com added.
#' psl_diff(old, new)
#'
#' # Agreeing snapshots return the same columns with zero rows.
#' psl_diff("bundled", "bundled")
#'
#' # Provenance travels with the result when the input form carries it.
#' attr(psl_diff("bundled", old), "old_version")$checksum
#' @export
psl_diff <- function(old, new, ...) {
  psl_check_empty_dots(...)
  old <- psl_diff_resolve(old, "old")
  new <- psl_diff_resolve(new, "new")
  structure(
    psl_diff_frame(old$rules, new$rules),
    old_version = old$version,
    new_version = new$version
  )
}
