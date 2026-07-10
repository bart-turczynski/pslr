# PSL-format parser (PRD s8.1).
#
# Turns Public Suffix List source text into a validated, structured rule table.
# This layer does structural parsing, grammar validation, and per-rule
# canonicalization only. It deliberately stops short of:
#   * duplicate / conflict policy  -> handled by the caller (PSLR-waspwyud);
#   * byte-size limits, network, metadata, indexing -> data-raw / refresh.
#
# Structural markers `*` and `!` are never passed to hostname normalization;
# only the literal label portion of a rule is canonicalized, with the same
# `punycoder` contract used for host labels at query time.

# Official section-boundary markers, e.g.
#   // ===BEGIN ICANN DOMAINS===
#   // ===END PRIVATE DOMAINS===
# Internal whitespace is tolerated; the name and BEGIN/END verb are not.
psl_marker_re <- paste0(
  "^//[[:space:]]*===(BEGIN|END)[[:space:]]+",
  "(ICANN|PRIVATE)[[:space:]]+DOMAINS===[[:space:]]*$"
)
# A line that looks like a marker (so typos are rejected) but may be malformed.
psl_marker_like_re <- "^//[[:space:]]*==="

# Abort with a structured, testable condition that carries the offending source
# line. Messages never echo a whole input file (PRD s9).
psl_parse_abort <- function(reason, line = NULL) {
  message <- if (is.null(line)) {
    reason
  } else {
    sprintf("PSL parse error at line %d: %s", line, reason)
  }
  stop(errorCondition(message, line = line, class = "pslr_parse_error"))
}

# Single source of truth for the rule-table schema: an ordered, named list of
# zero-length prototype vectors. The names fix the column order; each
# prototype's type fixes the column type. Everything that materializes a rule
# table -- preallocated parser storage, the zero-row result, and the finalized
# data.frame -- derives its shape from here, so the schema is spelled out once.
psl_rule_prototypes <- function() {
  list(
    line = integer(0),
    raw = character(0),
    section = character(0),
    kind = character(0),
    canonical_rule = character(0),
    canonical_key = character(0),
    labels = integer(0)
  )
}

# Allocate typed, `n`-row storage as a named list of columns. Indexing each
# zero-length prototype by `seq_len(n)` yields an `n`-long vector of the right
# type (NA-filled for n > 0, empty for n == 0), so no per-column type spelling
# is repeated here.
new_psl_rules <- function(n = 0L) {
  lapply(psl_rule_prototypes(), \(proto) proto[seq_len(n)])
}

# Trim preallocated storage `x` to its first `n` filled rows and assemble the
# final base data.frame. Splicing the named columns as named arguments
# reproduces the historical `data.frame(line = ..., raw = ..., ...)` call
# exactly (column names, order, types, and default row names).
finalize_psl_rules <- function(x, n) {
  cols <- lapply(x, \(col) col[seq_len(n)])
  do.call(data.frame, c(cols, list(stringsAsFactors = FALSE)))
}

# Empty, correctly typed result used for zero-rule input.
psl_empty_rules <- function() {
  finalize_psl_rules(new_psl_rules(0L), 0L)
}

# Strip a leading `!` exception marker. Returns list(kind, literal); aborts if
# the rule has no labels after `!` or uses `!` anywhere but the first character.
psl_strip_exception <- function(literal, line) {
  kind <- "normal"
  if (startsWith(literal, "!")) {
    kind <- "exception"
    literal <- substring(literal, 2L)
    if (!nzchar(literal)) {
      psl_parse_abort("exception rule has no labels after '!'", line)
    }
  }
  if (grepl("!", literal, fixed = TRUE)) {
    psl_parse_abort("'!' is only allowed as the first character", line)
  }
  list(kind = kind, literal = literal)
}

# Validate and apply a leftmost `*` wildcard. Given the split labels and the
# current rule kind, returns the updated list(kind, literal); aborts with `line`
# context on any wildcard grammar error. A rule with no `*` is returned as-is.
psl_apply_wildcard <- function(labels, kind, line) {
  has_star <- grepl("*", labels, fixed = TRUE)
  if (!any(has_star)) {
    return(list(kind = kind, literal = paste(labels, collapse = ".")))
  }
  star_positions <- which(has_star)
  if (any(labels[star_positions] != "*")) {
    psl_parse_abort("'*' must be a complete label, not part of one", line)
  }
  if (length(star_positions) != 1L || star_positions[1] != 1L) {
    psl_parse_abort("'*' is only allowed as the leftmost label", line)
  }
  if (kind == "exception") {
    psl_parse_abort("a rule cannot be both an exception and a wildcard", line)
  }
  parent <- labels[-1L]
  if (length(parent) == 0L) {
    psl_parse_abort("wildcard rule must have a literal label after '*'", line)
  }
  list(kind = "wildcard", literal = paste(parent, collapse = "."))
}

# Parse one rule's content (already trimmed to the token before first
# whitespace) into its kind and the literal label string to canonicalize.
# Returns list(kind, literal). Aborts with `line` context on any grammar error.
psl_parse_rule_content <- function(content, line) {
  ex <- psl_strip_exception(content, line)
  literal <- ex$literal

  # `strsplit` drops a trailing empty field, so check the dot structure
  # directly to catch leading, trailing, and consecutive dots.
  empty_label <- startsWith(literal, ".") ||
    endsWith(literal, ".") ||
    grepl("..", literal, fixed = TRUE)
  if (empty_label) {
    psl_parse_abort("rule contains an empty label", line)
  }
  labels <- strsplit(literal, ".", fixed = TRUE)[[1]]

  psl_apply_wildcard(labels, ex$kind, line)
}

psl_validate_source_lines <- function(lines) {
  if (length(lines) == 0L) {
    return(invisible(NULL))
  }
  if (!is.character(lines) || anyNA(lines)) {
    psl_parse_abort("PSL source lines must be a character vector without NA")
  }
  if (!all(validUTF8(lines))) {
    bad <- which(!validUTF8(lines))[1]
    psl_parse_abort("source is not valid UTF-8", bad)
  }
  invisible(NULL)
}

psl_read_marker <- function(line, number) {
  if (!grepl(psl_marker_like_re, line)) {
    return(NULL)
  }
  m <- regmatches(line, regexec(psl_marker_re, line))[[1]]
  if (length(m) == 0L) {
    psl_parse_abort("malformed section marker", number)
  }
  list(verb = m[2], name = tolower(m[3]))
}

psl_update_section <- function(marker, section, section_opens, number) {
  name <- marker$name
  if (identical(marker$verb, "BEGIN")) {
    if (!is.na(section)) {
      psl_parse_abort(
        sprintf("nested section: '%s' begins inside '%s'", name, section),
        number
      )
    }
    section_opens[[name]] <- section_opens[[name]] + 1L
    if (section_opens[[name]] > 1L) {
      psl_parse_abort(
        sprintf("section '%s' appears more than once", name),
        number
      )
    }
    return(list(section = name, section_opens = section_opens))
  }

  if (is.na(section)) {
    psl_parse_abort(
      sprintf("'%s' section ends without a matching BEGIN", name),
      number
    )
  }
  if (section != name) {
    psl_parse_abort(
      sprintf(
        "section end '%s' does not match open section '%s'",
        name,
        section
      ),
      number
    )
  }
  list(section = NA_character_, section_opens = section_opens)
}

psl_rule_token <- function(line) {
  regmatches(line, regexpr("^[^[:space:]]+", line))
}

psl_build_rule_record <- function(token, section, number) {
  parsed <- psl_parse_rule_content(token, number)
  normalized <- punycoder::host_normalize(parsed$literal)
  if (is.na(normalized)) {
    psl_parse_abort(
      sprintf("rule '%s' could not be canonicalized", token),
      number
    )
  }

  canonical_rule <- switch(
    parsed$kind,
    wildcard = paste0("*.", normalized),
    exception = paste0("!", normalized),
    normalized
  )
  depth <- length(strsplit(normalized, ".", fixed = TRUE)[[1]]) +
    (parsed$kind == "wildcard")

  list(
    line = number,
    raw = token,
    section = section,
    kind = parsed$kind,
    canonical_rule = canonical_rule,
    canonical_key = normalized,
    labels = depth
  )
}

#' Parse Public Suffix List source lines into a validated rule table
#'
#' Internal. Consumes a character vector of source lines (one PSL `.dat` line
#' per element) and returns a structured, canonicalized rule table. Performs
#' structural parsing, grammar validation, and per-rule canonicalization via the
#' `punycoder` contract. Duplicate and conflict policy is the caller's
#' responsibility.
#'
#' @param lines Character vector of source lines, already split on newlines.
#' @return A base data.frame with columns `line`, `raw`, `section`, `kind`,
#'   `canonical_rule`, `canonical_key`, and `labels`, one row per accepted rule,
#'   in source order.
#' @noRd
parse_psl_lines <- function(lines) {
  if (length(lines) == 0L) {
    return(psl_empty_rules())
  }
  psl_validate_source_lines(lines)

  n <- length(lines)
  # Preallocate one slot per source line -- an upper bound on accepted rules --
  # and fill by a running index, so the columns never grow with `c()`. Trimmed
  # to the real count by `finalize_psl_rules()` after the scan.
  out <- new_psl_rules(n)
  columns <- names(out)
  count <- 0L

  section <- NA_character_
  # The official format carries exactly one complete ICANN section and one
  # complete PRIVATE section; a repeated section is a structural error (PRD
  # s8.1). Count how often each is opened so a second BEGIN aborts.
  section_opens <- c(icann = 0L, private = 0L)

  for (i in seq_len(n)) {
    line <- lines[i]

    marker <- psl_read_marker(line, i)
    if (!is.null(marker)) {
      state <- psl_update_section(marker, section, section_opens, i)
      section <- state$section
      section_opens <- state$section_opens
      next
    }

    if (startsWith(line, "//")) {
      next # full-line comment
    }

    # Read rule content only up to the first whitespace (PRD s8.1). A line that
    # is blank or starts with whitespace yields no rule content.
    token <- psl_rule_token(line)
    if (length(token) == 0L) {
      next
    }

    if (is.na(section)) {
      psl_parse_abort("rule appears outside any ICANN or PRIVATE section", i)
    }

    record <- psl_build_rule_record(token, section, i)
    count <- count + 1L
    for (col in columns) {
      out[[col]][count] <- record[[col]]
    }
  }

  if (!is.na(section)) {
    psl_parse_abort(sprintf("section '%s' is never closed", section), n)
  }

  finalize_psl_rules(out, count)
}

#' Read and parse a Public Suffix List `.dat` file
#'
#' Internal. Thin reader that loads a UTF-8 PSL source file and delegates to
#' `parse_psl_lines()`. Performs no byte-size limiting and no network access;
#' those belong to the data-raw pipeline and the refresh path.
#'
#' @param path A single readable file path.
#' @return The rule table from `parse_psl_lines()`.
#' @noRd
read_psl_file <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    psl_parse_abort("`path` must be a single file path")
  }
  if (!file.exists(path)) {
    psl_parse_abort(sprintf("PSL source file not found: %s", path))
  }
  con <- file(path, open = "r", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)
  lines <- readLines(con, warn = FALSE)
  parse_psl_lines(lines)
}
