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

# The active matcher pointer, built on first use from the bundled index. The
# identity string is part of the result-cache key, so it must change whenever
# the active list does; for the bundled list it is the snapshot checksum.
active_matcher <- function() {
  if (is.null(the_matcher$ptr)) {
    the_matcher$ptr <- build_matcher(pslr_bundled$rules)
    the_matcher$identity <- pslr_bundled$meta$checksum
  }
  the_matcher$ptr
}

# Stable identity of the active list, used in the result-cache key.
active_list_identity <- function() {
  active_matcher()
  the_matcher$identity
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

#' Resolve canonical hosts to ASCII match results, with session caching
#'
#' Takes canonical lowercase ASCII hosts (no terminal dot, no `NA`), serves any
#' previously seen (host, active-list, section) triples from the bounded session
#' cache, deduplicates the remaining misses before crossing into C++ once each,
#' runs the prevailing-rule algorithm, caches the derived metadata, and returns
#' one row per input core. Results are canonical ASCII without the terminal dot:
#' the `unknown`/`output` policies and dot restoration are applied by callers,
#' so they are deliberately absent from the cache key (PRD s8.2).
#'
#' @param cores Character vector of canonical hosts (no terminal dot, no `NA`).
#' @param section One of `"all"`, `"icann"`, `"private"`.
#' @return A data frame with `length(cores)` rows and columns `public_suffix`,
#'   `registrable_domain`, `rule`, `kind`, `rule_section`, `ps_depth`.
#' @noRd
psl_resolve_cores <- function(cores, section) {
  empty <- data.frame(
    public_suffix = character(0), registrable_domain = character(0),
    rule = character(0), kind = character(0), rule_section = character(0),
    ps_depth = integer(0), stringsAsFactors = FALSE
  )
  if (length(cores) == 0L) {
    return(empty)
  }

  psl_cache_ensure()
  section_code <- psl_section_code(section)
  prefix <- paste0(active_list_identity(), "|", section_code, "|")

  uniq <- unique(cores)
  keys <- paste0(prefix, uniq)
  cached <- mget(keys, envir = psl_cache_env$tbl, ifnotfound = list(NULL))
  miss <- vapply(cached, is.null, logical(1))

  if (any(miss)) {
    res <- psl_match(active_matcher(), uniq[miss], section_code)
    miss_labels <- strsplit(uniq[miss], ".", fixed = TRUE)
    kind <- psl_kind_labels[res$kind + 1L]
    sec <- c("icann", "private")[res$section + 1L] # NA section -> NA
    records <- lapply(seq_along(miss_labels), function(j) {
      d <- derive_one(miss_labels[[j]], res$ps_depth[j], res$kind[j])
      list(
        public_suffix = d$public_suffix,
        registrable_domain = d$registrable_domain,
        rule = d$rule, kind = kind[j], rule_section = sec[j],
        ps_depth = res$ps_depth[j]
      )
    })
    psl_cache_store(keys[miss], records)
    cached[miss] <- records
  }

  field <- function(name, na) {
    vapply(cached, function(r) if (is.null(r[[name]])) na else r[[name]], na)
  }
  idx <- match(cores, uniq)
  data.frame(
    public_suffix = field("public_suffix", NA_character_)[idx],
    registrable_domain = field("registrable_domain", NA_character_)[idx],
    rule = field("rule", NA_character_)[idx],
    kind = field("kind", NA_character_)[idx],
    rule_section = field("rule_section", NA_character_)[idx],
    ps_depth = field("ps_depth", NA_integer_)[idx],
    stringsAsFactors = FALSE
  )
}

#' Match a vector of hosts against the active PSL matcher
#'
#' Internal engine entry point preserved for the matcher tests. Canonicalizes
#' each host (treating invalid input as `NA`), resolves the valid cores through
#' the cached core layer, and restores the terminal root dot on hostname-shaped
#' outputs.
#'
#' @param domain Character vector of hostnames (Unicode or ASCII).
#' @param section One of `"all"`, `"icann"`, `"private"`.
#' @return A list of equal-length vectors: `host`, `public_suffix`,
#'   `registrable_domain`, `rule`, `kind`, `rule_section`. Hostname-shaped
#'   columns are ASCII with the terminal dot restored.
#' @noRd
psl_match_hosts <- function(domain, section = "all") {
  canon <- psl_canonicalize(domain, invalid = "na")
  n <- length(canon$input)
  public_suffix <- rep(NA_character_, n)
  registrable_domain <- rep(NA_character_, n)
  rule <- rep(NA_character_, n)
  kind <- rep(NA_character_, n)
  rule_section <- rep(NA_character_, n)

  valid <- canon$status == "ok"
  if (any(valid)) {
    res <- psl_resolve_cores(canon$core[valid], section)
    public_suffix[valid] <- res$public_suffix
    registrable_domain[valid] <- res$registrable_domain
    rule[valid] <- res$rule
    kind[valid] <- res$kind
    rule_section[valid] <- res$rule_section
    public_suffix <- restore_root_dot(public_suffix, canon$had_dot)
    registrable_domain <- restore_root_dot(registrable_domain, canon$had_dot)
  }

  list(
    host = canon$host, public_suffix = public_suffix,
    registrable_domain = registrable_domain, rule = rule,
    kind = kind, rule_section = rule_section
  )
}
