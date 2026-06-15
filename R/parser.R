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

# Empty, correctly typed result used for zero-rule input.
psl_empty_rules <- function() {
  data.frame(
    line = integer(0),
    raw = character(0),
    section = character(0),
    kind = character(0),
    canonical_rule = character(0),
    canonical_key = character(0),
    labels = integer(0),
    stringsAsFactors = FALSE
  )
}

# Parse one rule's content (already trimmed to the token before first
# whitespace) into its kind and the literal label string to canonicalize.
# Returns list(kind, literal). Aborts with `line` context on any grammar error.
psl_parse_rule_content <- function(content, line) {
  kind <- "normal"
  literal <- content

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

  # `strsplit` drops a trailing empty field, so check the dot structure
  # directly to catch leading, trailing, and consecutive dots.
  empty_label <- startsWith(literal, ".") ||
    endsWith(literal, ".") ||
    grepl("..", literal, fixed = TRUE)
  if (empty_label) {
    psl_parse_abort("rule contains an empty label", line)
  }
  labels <- strsplit(literal, ".", fixed = TRUE)[[1]]

  has_star <- grepl("*", labels, fixed = TRUE)
  if (any(has_star)) {
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
    kind <- "wildcard"
    parent <- labels[-1L]
    if (length(parent) == 0L) {
      psl_parse_abort("wildcard rule must have a literal label after '*'", line)
    }
    literal <- paste(parent, collapse = ".")
  }

  list(kind = kind, literal = literal)
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
  if (!is.character(lines) || anyNA(lines)) {
    psl_parse_abort("PSL source lines must be a character vector without NA")
  }
  if (!all(validUTF8(lines))) {
    bad <- which(!validUTF8(lines))[1]
    psl_parse_abort("source is not valid UTF-8", bad)
  }

  n <- length(lines)
  out_line <- integer(0)
  out_raw <- character(0)
  out_section <- character(0)
  out_kind <- character(0)
  out_rule <- character(0)
  out_key <- character(0)
  out_labels <- integer(0)

  section <- NA_character_

  for (i in seq_len(n)) {
    line <- lines[i]

    if (grepl(psl_marker_like_re, line)) {
      m <- regmatches(line, regexec(psl_marker_re, line))[[1]]
      if (length(m) == 0L) {
        psl_parse_abort("malformed section marker", i)
      }
      verb <- m[2]
      name <- tolower(m[3])
      if (verb == "BEGIN") {
        if (!is.na(section)) {
          psl_parse_abort(
            sprintf("nested section: '%s' begins inside '%s'", name, section), i
          )
        }
        section <- name
      } else {
        if (is.na(section)) {
          psl_parse_abort(
            sprintf("'%s' section ends without a matching BEGIN", name), i
          )
        }
        if (section != name) {
          psl_parse_abort(
            sprintf(
              "section end '%s' does not match open section '%s'", name, section
            ),
            i
          )
        }
        section <- NA_character_
      }
      next
    }

    if (startsWith(line, "//")) {
      next # full-line comment
    }

    # Read rule content only up to the first whitespace (PRD s8.1). A line that
    # is blank or starts with whitespace yields no rule content.
    token <- regmatches(line, regexpr("^[^[:space:]]+", line))
    if (length(token) == 0L) {
      next
    }

    if (is.na(section)) {
      psl_parse_abort("rule appears outside any ICANN or PRIVATE section", i)
    }

    parsed <- psl_parse_rule_content(token, i)
    normalized <- punycoder::host_normalize(parsed$literal, strict = TRUE)
    if (is.na(normalized)) {
      psl_parse_abort(
        sprintf("rule '%s' could not be canonicalized", token), i
      )
    }

    canonical_rule <- switch(parsed$kind,
      wildcard = paste0("*.", normalized),
      exception = paste0("!", normalized),
      normalized
    )
    depth <- length(strsplit(normalized, ".", fixed = TRUE)[[1]]) +
      (parsed$kind == "wildcard")

    out_line <- c(out_line, i)
    out_raw <- c(out_raw, token)
    out_section <- c(out_section, section)
    out_kind <- c(out_kind, parsed$kind)
    out_rule <- c(out_rule, canonical_rule)
    out_key <- c(out_key, normalized)
    out_labels <- c(out_labels, depth)
  }

  if (!is.na(section)) {
    psl_parse_abort(sprintf("section '%s' is never closed", section), n)
  }

  data.frame(
    line = out_line,
    raw = out_raw,
    section = out_section,
    kind = out_kind,
    canonical_rule = out_rule,
    canonical_key = out_key,
    labels = out_labels,
    stringsAsFactors = FALSE
  )
}

#' Read and parse a Public Suffix List `.dat` file
#'
#' Internal. Thin reader that loads a UTF-8 PSL source file and delegates to
#' [parse_psl_lines()]. Performs no byte-size limiting and no network access;
#' those belong to the data-raw pipeline and the refresh path.
#'
#' @param path A single readable file path.
#' @return The rule table from [parse_psl_lines()].
#' @noRd
read_psl_file <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    psl_parse_abort("`path` must be a single file path")
  }
  if (!file.exists(path)) {
    psl_parse_abort(sprintf("PSL source file not found: %s", path))
  }
  con <- file(path, open = "r", encoding = "UTF-8")
  on.exit(close(con))
  lines <- readLines(con, warn = FALSE)
  parse_psl_lines(lines)
}
