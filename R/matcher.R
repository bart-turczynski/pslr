# R engine layer over the cpp11 matcher (PRD s6, s8.2).
#
# Owns normalization, terminal-dot handling, canonical-host deduplication, and
# turning the C++ result (public-suffix depth + kind + section per host) into
# ASCII public-suffix / registrable-domain / rule strings. The exported query
# API, the unknown/output/invalid policies, extraction, rule inspection, and
# the bounded result cache are layered on top of this in P4.

# Session state: the active matcher (immutable after construction). Built lazily
# from the bundled index on first use; never touches the network or user cache.
the_matcher <- new.env(parent = emptyenv())

# Numeric codes shared with the C++ layer.
psl_section_code <- function(section) {
  switch(section, all = 2L, icann = 0L, private = 1L)
}
# kind codes from psl_match(): 0 normal, 1 wildcard, 2 exception, 3 default.
psl_kind_labels <- c("normal", "wildcard", "exception", "default")

build_matcher <- function(rules) {
  section_int <- ifelse(rules$section == "icann", 0L, 1L)
  psl_build_matcher(rules$canonical_key, rules$kind, section_int)
}

# The active matcher pointer, built on first use from the bundled index.
active_matcher <- function() {
  if (is.null(the_matcher$ptr)) {
    the_matcher$ptr <- build_matcher(pslr_bundled$rules)
  }
  the_matcher$ptr
}

# Derive the ASCII rule, public suffix, and registrable domain for one host.
# `labels` are the canonical host labels (leftmost first); `depth` is the
# prevailing public-suffix label count and `kind` its 0-3 code.
derive_one <- function(labels, depth, kind) {
  n <- length(labels)
  suffix_labels <- function(d) paste(labels[(n - d + 1L):n], collapse = ".")

  if (is.na(depth) || depth < 1L) {
    return(list(
      public_suffix = NA_character_, registrable_domain = NA_character_,
      rule = NA_character_
    ))
  }
  public_suffix <- suffix_labels(depth)
  registrable_domain <- if (n > depth) {
    suffix_labels(depth + 1L)
  } else {
    NA_character_
  }

  rule <- switch(psl_kind_labels[kind + 1L],
    normal = public_suffix,
    wildcard = paste0("*.", suffix_labels(depth - 1L)),
    exception = paste0("!", suffix_labels(depth + 1L)),
    default = "*"
  )
  list(
    public_suffix = public_suffix,
    registrable_domain = registrable_domain,
    rule = rule
  )
}

#' Match a vector of hosts against the active PSL matcher
#'
#' Internal engine entry point. Normalizes and canonicalizes each host through
#' the `punycoder` contract, deduplicates canonical hosts before crossing into
#' C++, runs the prevailing-rule algorithm, and returns ASCII results plus the
#' prevailing rule. Invalid (un-normalizable) and `NA` inputs yield `NA` rows;
#' the terminal root dot is preserved on hostname-shaped outputs.
#'
#' @param domain Character vector of hostnames (Unicode or ASCII).
#' @param section One of `"all"`, `"icann"`, `"private"`.
#' @return A list of equal-length vectors: `host`, `public_suffix`,
#'   `registrable_domain`, `rule`, `kind`, `rule_section`. Hostname-shaped
#'   columns are ASCII with the terminal dot restored.
#' @noRd
psl_match_hosts <- function(domain, section = "all") {
  n <- length(domain)
  host <- rep(NA_character_, n)
  public_suffix <- rep(NA_character_, n)
  registrable_domain <- rep(NA_character_, n)
  rule <- rep(NA_character_, n)
  kind <- rep(NA_character_, n)
  rule_section <- rep(NA_character_, n)

  if (n == 0L) {
    return(list(
      host = host, public_suffix = public_suffix,
      registrable_domain = registrable_domain, rule = rule,
      kind = kind, rule_section = rule_section
    ))
  }

  normalized <- punycoder::host_normalize(as.character(domain), strict = TRUE)
  had_dot <- !is.na(normalized) & endsWith(normalized, ".")
  core <- normalized
  core[had_dot] <- substr(core[had_dot], 1L, nchar(core[had_dot]) - 1L)
  valid <- !is.na(core) & nzchar(core)
  host[valid] <- normalized[valid]
  if (!any(valid)) {
    return(list(
      host = host, public_suffix = public_suffix,
      registrable_domain = registrable_domain, rule = rule,
      kind = kind, rule_section = rule_section
    ))
  }

  # Deduplicate canonical hosts so each distinct host crosses into C++ once.
  uniq <- unique(core[valid])
  res <- psl_match(active_matcher(), uniq, psl_section_code(section))

  uniq_labels <- strsplit(uniq, ".", fixed = TRUE)
  derived <- lapply(seq_along(uniq), function(j) {
    derive_one(uniq_labels[[j]], res$ps_depth[j], res$kind[j])
  })
  u_ps <- vapply(derived, `[[`, character(1), "public_suffix")
  u_rd <- vapply(derived, `[[`, character(1), "registrable_domain")
  u_rule <- vapply(derived, `[[`, character(1), "rule")
  u_kind <- psl_kind_labels[res$kind + 1L]
  u_sec <- c("icann", "private")[res$section + 1L] # NA section -> NA

  idx <- match(core[valid], uniq)
  public_suffix[valid] <- u_ps[idx]
  registrable_domain[valid] <- u_rd[idx]
  rule[valid] <- u_rule[idx]
  kind[valid] <- u_kind[idx]
  rule_section[valid] <- u_sec[idx]

  # Restore the terminal root dot on hostname-shaped outputs only.
  restore <- had_dot & valid
  add_dot <- function(x) ifelse(is.na(x), x, paste0(x, "."))
  public_suffix[restore] <- add_dot(public_suffix[restore])
  registrable_domain[restore] <- add_dot(registrable_domain[restore])

  list(
    host = host, public_suffix = public_suffix,
    registrable_domain = registrable_domain, rule = rule,
    kind = kind, rule_section = rule_section
  )
}
