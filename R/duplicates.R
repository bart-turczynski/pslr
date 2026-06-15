# Duplicate and conflict policy by trust boundary (PRD s8.1).
#
# Consumes the validated rule table from `parse_psl_lines()` and enforces the
# duplicate / conflict rules, which differ by trust boundary:
#
#   * conflicting rule kinds for the same canonical labels within one section
#     are fatal in every mode;
#   * exact same-section duplicates are fatal in the maintainer build pipeline
#     ("strict") so upstream anomalies are reviewed before release, but warn
#     once and deduplicate (retaining the first source occurrence) at runtime
#     ("lenient") so a benign upstream duplication cannot block a refresh;
#   * the same rule may appear once in each section, because section membership
#     is part of a rule's identity.

#' Apply the duplicate / conflict policy to a parsed rule table
#'
#' Internal. Detects conflicting rule kinds (fatal in all modes) and exact
#' same-section duplicates (fatal under `"strict"`, warn-and-deduplicate under
#' `"lenient"`). Cross-section duplicates are always permitted.
#'
#' @param rules A rule table as returned by [parse_psl_lines()].
#' @param mode `"strict"` for the maintainer build pipeline; `"lenient"` for
#'   runtime refresh and custom-path loads.
#' @return The rule table with exact same-section duplicates removed under
#'   `"lenient"`, unchanged otherwise, with reset row names.
#' @noRd
apply_duplicate_policy <- function(rules, mode = c("strict", "lenient")) {
  mode <- match.arg(mode)
  if (nrow(rules) == 0L) {
    return(rules)
  }

  # "canonical labels" for the conflict check is the marker-stripped literal;
  # an exact duplicate is byte-identical canonical rule text. A space never
  # appears in a canonical key or rule, so it is a safe group-key separator.
  conflict_group <- paste(rules$section, rules$canonical_key, sep = " ")
  exact_group <- paste(rules$section, rules$canonical_rule, sep = " ")

  psl_check_conflicts(rules, conflict_group)

  dup <- duplicated(exact_group)
  if (any(dup)) {
    if (mode == "strict") {
      psl_report_strict_duplicates(rules, exact_group, dup)
    }
    psl_warn_dropped_duplicates(rules, dup)
    rules <- rules[!dup, , drop = FALSE]
    rownames(rules) <- NULL
  }
  rules
}

# Abort if any (section, canonical_key) group carries more than one rule kind.
psl_check_conflicts <- function(rules, conflict_group) {
  kinds_by_group <- split(rules$kind, conflict_group)
  conflicted <- vapply(
    kinds_by_group, function(k) length(unique(k)) > 1L, logical(1)
  )
  if (!any(conflicted)) {
    return(invisible())
  }
  group <- names(conflicted)[conflicted][1]
  idx <- which(conflict_group == group)
  psl_parse_abort(
    sprintf(
      "conflicting rule kinds for '%s' in the %s section (lines %s): %s",
      rules$canonical_key[idx[1]],
      rules$section[idx[1]],
      paste(rules$line[idx], collapse = ", "),
      paste(unique(rules$kind[idx]), collapse = " vs ")
    ),
    rules$line[idx[1]]
  )
}

# Strict mode: any exact same-section duplicate is a hard error.
psl_report_strict_duplicates <- function(rules, exact_group, dup) {
  first_dup <- which(dup)[1]
  first_seen <- which(exact_group == exact_group[first_dup])[1]
  psl_parse_abort(
    sprintf(
      "duplicate rule '%s' in the %s section (first seen at line %d); %d total",
      rules$canonical_rule[first_dup],
      rules$section[first_dup],
      rules$line[first_seen],
      sum(dup)
    ),
    rules$line[first_dup]
  )
}

# Lenient mode: emit a single summarising warning before dropping duplicates.
psl_warn_dropped_duplicates <- function(rules, dup) {
  first_dup <- which(dup)[1]
  warning(
    sprintf(
      paste0(
        "dropped %d duplicate rule(s), retaining the first occurrence of ",
        "each; first duplicate: '%s' in the %s section at line %d"
      ),
      sum(dup),
      rules$canonical_rule[first_dup],
      rules$section[first_dup],
      rules$line[first_dup]
    ),
    call. = FALSE
  )
}
