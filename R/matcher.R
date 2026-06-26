# R engine layer over the cpp11 matcher (PRD s6, s8.2).
#
# Owns normalization, terminal-dot handling, canonical-host deduplication, and
# turning the C++ result (public-suffix depth + kind + section per host) into
# ASCII public-suffix / registrable-domain / rule strings. The exported query
# API, the unknown/output/invalid policies, extraction, rule inspection, and
# the bounded result cache are layered on top of this in P4.

# Session state: the active list (immutable after construction). Holds the
# whole state -- compiled matcher pointer, cache identity, rule table, and
# metadata -- in a single `$state` slot so activation swaps it with one atomic
# assignment and an interrupt can never expose a partially constructed matcher
# (PRD s9). Built lazily from the bundled index on first use; never touches the
# network or user cache.
the_matcher <- new.env(parent = emptyenv())

# Numeric codes shared with the C++ layer.
psl_section_code <- function(section) {
  switch(section, all = 2L, icann = 0L, private = 1L)
}
# kind codes from psl_match(): 0 normal, 1 wildcard, 2 exception, 3 default.
psl_kind_labels <- c("normal", "wildcard", "exception", "default")

build_matcher <- function(rules) {
  section_int <- as.integer(rules$section == "private")
  psl_build_matcher(rules$canonical_key, rules$kind, section_int)
}

# Runtime normalization identifiers, read from the installed `punycoder` at
# activation time. These describe the normalizer actually used to index the
# active matcher, and `psl_version()` reports them regardless of list source
# (PRD s7.4, s8.3). `normalization_profile_info()` returns a one-row data.frame.
runtime_normalizer_meta <- function() {
  prof <- punycoder::normalization_profile_info()
  list(
    normalizer = "punycoder",
    normalizer_version = as.character(utils::packageVersion("punycoder")),
    normalization_profile = as.character(prof$profile),
    unicode_version = as.character(prof$unicode_version)
  )
}

# Build a complete `psl_version()`-shaped metadata list. Source-identity fields
# default to typed `NA`; normalization identifiers default to the runtime
# normalizer (PRD s7.4). Callers override the known fields by name.
psl_meta <- function(...) {
  base <- c(
    list(
      source = NA_character_, path = NA_character_,
      retrieved_at = NA_character_, list_date = NA_character_,
      commit = NA_character_, size = NA_integer_, checksum = NA_character_
    ),
    runtime_normalizer_meta()
  )
  utils::modifyList(base, list(...))
}

# Activate a validated rule table under `meta`. Everything that can fail (the
# matcher build) happens before the single atomic state swap, so a failed or
# interrupted activation leaves the previous active list usable (PRD s9).
# Switching the active list clears the result cache (PRD s7.4, s8.2).
psl_set_active <- function(rules, meta, rebuilt = FALSE) {
  ptr <- build_matcher(rules)
  the_matcher$state <- list(
    ptr = ptr, identity = meta$checksum, rules = rules,
    meta = meta, rebuilt = rebuilt
  )
  psl_cache_clear()
  invisible(meta)
}

# Re-parse the bundled `.dat` source under the runtime normalizer. Used when the
# shipped generated index was canonicalized under a different normalization
# profile or Unicode version than the runtime normalizer (PRD s8.3).
rebuild_bundled_rules <- function() {
  path <- system.file("extdata", "public_suffix_list.dat", package = "pslr")
  if (!nzchar(path)) {
    return(pslr_bundled$rules)
  }
  apply_duplicate_policy(read_psl_file(path), mode = "lenient")
}

# Activate the bundled snapshot. Compares the shipped index's normalization
# profile and Unicode version against the runtime normalizer; on any mismatch it
# rebuilds the index in memory from the bundled source before activation so an
# index canonicalized under one profile is never combined with hosts
# canonicalized under another (PRD s8.3). The shipped source identity (checksum,
# commit, size) is preserved; only the normalizer identifiers reflect runtime.
activate_bundled <- function() {
  rt <- runtime_normalizer_meta()
  bm <- pslr_bundled$meta
  profile_match <- identical(
    bm$normalization_profile, rt$normalization_profile
  )
  unicode_match <- identical(bm$unicode_version, rt$unicode_version)
  mismatch <- !profile_match || !unicode_match
  rules <- if (mismatch) rebuild_bundled_rules() else pslr_bundled$rules
  meta <- psl_meta(
    source = "bundled", retrieved_at = bm$retrieved_at,
    list_date = bm$list_date, commit = bm$commit,
    size = bm$size, checksum = bm$checksum
  )
  psl_set_active(rules, meta, rebuilt = mismatch)
}

# The full active-list state, lazily initialised from the bundled index.
active_state <- function() {
  if (is.null(the_matcher$state)) {
    activate_bundled()
  }
  the_matcher$state
}

# The active matcher pointer (PRD s8.2).
active_matcher <- function() active_state()$ptr

# Stable identity of the active list, used in the result-cache key. For the
# bundled and cache lists it is the source-snapshot checksum.
active_list_identity <- function() active_state()$identity

# Metadata and rule table of the active list, for psl_version() / psl_rules().
active_meta <- function() active_state()$meta
active_rules <- function() active_state()$rules

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

psl_empty_match_result <- function() {
  data.frame(
    public_suffix = character(0), registrable_domain = character(0),
    rule = character(0), kind = character(0), rule_section = character(0),
    ps_depth = integer(0), stringsAsFactors = FALSE
  )
}

psl_match_records <- function(cores, section_code) {
  res <- psl_match(active_matcher(), cores, section_code)
  labels <- strsplit(cores, ".", fixed = TRUE)
  kind <- psl_kind_labels[res$kind + 1L]
  sec <- c("icann", "private")[res$section + 1L] # NA section -> NA
  lapply(seq_along(labels), function(j) {
    d <- derive_one(labels[[j]], res$ps_depth[j], res$kind[j])
    list(
      public_suffix = d$public_suffix,
      registrable_domain = d$registrable_domain,
      rule = d$rule, kind = kind[j], rule_section = sec[j],
      ps_depth = res$ps_depth[j]
    )
  })
}

psl_result_field <- function(cached, name, na) {
  vapply(cached, function(r) if (is.null(r[[name]])) na else r[[name]], na)
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
  if (length(cores) == 0L) {
    return(psl_empty_match_result())
  }

  psl_cache_ensure()
  section_code <- psl_section_code(section)
  prefix <- paste0(active_list_identity(), "|", section_code, "|")

  uniq <- unique(cores)
  keys <- paste0(prefix, uniq)
  cached <- mget(keys, envir = psl_cache_env$tbl, ifnotfound = list(NULL))
  miss <- vapply(cached, is.null, logical(1))

  if (any(miss)) {
    records <- psl_match_records(uniq[miss], section_code)
    psl_cache_store(keys[miss], records)
    cached[miss] <- records
  }

  idx <- match(cores, uniq)
  data.frame(
    public_suffix = psl_result_field(
      cached, "public_suffix", NA_character_
    )[idx],
    registrable_domain = psl_result_field(
      cached, "registrable_domain", NA_character_
    )[idx],
    rule = psl_result_field(cached, "rule", NA_character_)[idx],
    kind = psl_result_field(cached, "kind", NA_character_)[idx],
    rule_section = psl_result_field(
      cached, "rule_section", NA_character_
    )[idx],
    ps_depth = psl_result_field(cached, "ps_depth", NA_integer_)[idx],
    stringsAsFactors = FALSE
  )
}
