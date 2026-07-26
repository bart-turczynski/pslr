# Active-list metadata APIs (PRD s7.4).
#
# `psl_version()` exposes the identity of the active list -- the source-snapshot
# provenance plus the runtime normalization identifiers actually used to index
# the active matcher -- so a query result can be reproduced. `psl_rules()`
# exposes the active rule table itself. Both read the immutable active state
# built by R/matcher.R; neither accesses the network or the user cache.

# Derive the one-row `psl_version()` data.frame from a snapshot-metadata list,
# in the documented column order and types. Column order and per-field type come
# from the shared `psl_meta_fields` schema (R/matcher.R), so this never
# re-spells the field list. Shared by psl_version() and the psl_refresh() return
# value (PRD s7.4).
as_psl_version_df <- function(meta) {
  cols <- Map(
    function(field, type) {
      value <- meta[[field]]
      switch(type, character = as.character(value), integer = as.integer(value))
    },
    names(psl_meta_fields),
    psl_meta_fields
  )
  data.frame(cols, stringsAsFactors = FALSE, row.names = NULL)
}

# Backwards-compatible alias used by psl_version() and R/refresh.R.
psl_version_df <- function(meta) {
  as_psl_version_df(meta)
}

#' Identity of the active Public Suffix List
#'
#' Returns a one-row [data.frame] describing the list currently active in this R
#' session: its source-snapshot provenance and the normalization identifiers
#' actually used to index the active matcher. Reproducing a query result
#' requires both the active-list identity and these normalization identifiers
#' (PRD s10), so a reproducibility-sensitive workflow should record this row.
#'
#' @details
#' The columns, in order, are:
#'
#' \describe{
#'   \item{`source`}{`"bundled"`, `"cache"`, or `"path"`.}
#'   \item{`url`}{Source URL of the active snapshot: the upstream download URL
#'     for the bundled list; `NA` for a `"cache"` or `"path"` source.}
#'   \item{`path`}{File path of a `"cache"` or `"path"` source; `NA` otherwise.}
#'   \item{`retrieved_at`}{Network retrieval timestamp, or `NA`.}
#'   \item{`list_date`}{Upstream list date, or `NA` when unknown.}
#'   \item{`commit`}{Upstream commit SHA, or `NA` when unknown.}
#'   \item{`size`}{Source byte size (integer).}
#'   \item{`checksum`}{Source checksum, including its algorithm prefix
#'     (e.g. `"sha256:..."`).}
#'   \item{`normalizer`}{The dependency providing canonicalization,
#'     currently `"punycoder"`.}
#'   \item{`normalizer_version`}{Its installed package version.}
#'   \item{`normalization_profile`}{Its stable case-mapping / IDNA / validation
#'     profile identifier.}
#'   \item{`unicode_version`}{The Unicode data version used by that profile.}
#' }
#'
#' Unavailable metadata is a typed `NA`, never omitted. The normalization
#' identifiers describe the implementation used by the current session, whether
#' the active list came from the bundled snapshot, the user cache, or a custom
#' path; an in-memory compatibility rebuild (PRD s8.3) updates them without
#' altering the shipped source identity or checksum.
#'
#' @return A one-row base [data.frame] with the columns described in Details.
#' @seealso [psl_use()], [psl_refresh()], [psl_rules()]
#' @examples
#' psl_version()
#' @export
psl_version <- function() {
  psl_version_df(active_meta())
}

# Parse a stored `list_date` string to POSIXct in UTC. Accepts the ISO 8601
# "Z" form the bundled snapshot records (e.g. "2026-06-13T21:47:08Z"), a
# space-separated timestamp, or a plain calendar date. NA in -> NA out; an
# unparseable string also yields NA, so a caller such as `psl_status()` reports
# an unknown date rather than inventing one.
psl_parse_list_date <- function(x) {
  na <- as.POSIXct(NA_character_, tz = "UTC")
  if (length(x) != 1L || is.na(x)) {
    return(na)
  }
  for (fmt in c("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d")) {
    parsed <- as.POSIXct(x, format = fmt, tz = "UTC")
    if (!is.na(parsed)) {
      return(parsed)
    }
  }
  na
}

#' Rules of the active Public Suffix List
#'
#' Returns the explicit rules of the active list as a base [data.frame], one row
#' per rule. The implicit default `*` rule is not included.
#'
#' @param section Which rule sections to return: `"all"` (default), `"icann"`,
#'   or `"private"`.
#' @return A base [data.frame] with columns, in order: `rule` (original source
#'   rule text), `canonical_rule` (the canonicalized rule, including the `*.` or
#'   `!` marker), `kind` (`"normal"`, `"wildcard"`, or `"exception"`), `section`
#'   (`"icann"` or `"private"`), and `labels` (integer rule depth, counting a
#'   wildcard label). Rows are ordered first by section (ICANN before PRIVATE)
#'   and then by source-file order.
#' @seealso [psl_version()], [public_suffix_rule()]
#' @examples
#' head(psl_rules("icann"))
#' nrow(psl_rules("private"))
#' @export
psl_rules <- function(section = "all") {
  section <- check_choice(section, c("all", "icann", "private"), "section")
  r <- active_rules()
  if (!identical(section, "all")) {
    r <- r[r$section == section, , drop = FALSE]
  }
  ord <- order(match(r$section, c("icann", "private")), r$line)
  r <- r[ord, , drop = FALSE]
  data.frame(
    rule = r$raw,
    canonical_rule = r$canonical_rule,
    kind = r$kind,
    section = r$section,
    labels = as.integer(r$labels),
    stringsAsFactors = FALSE,
    row.names = NULL
  )
}
