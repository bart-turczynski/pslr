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
      source = NA_character_,
      path = NA_character_,
      retrieved_at = NA_character_,
      list_date = NA_character_,
      commit = NA_character_,
      size = NA_integer_,
      checksum = NA_character_
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
    ptr = ptr,
    identity = meta$checksum,
    rules = rules,
    meta = meta,
    rebuilt = rebuilt
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
    bm$normalization_profile,
    rt$normalization_profile
  )
  unicode_match <- identical(bm$unicode_version, rt$unicode_version)
  mismatch <- !profile_match || !unicode_match
  rules <- if (mismatch) rebuild_bundled_rules() else pslr_bundled$rules
  meta <- psl_meta(
    source = "bundled",
    retrieved_at = bm$retrieved_at,
    list_date = bm$list_date,
    commit = bm$commit,
    size = bm$size,
    checksum = bm$checksum
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

# Allocate the eight parallel match columns, typed and named per the shared
# cache schema (`psl_cache_char_cols` character, `psl_cache_int_cols` integer),
# each of length `n`. Keeping this schema-driven means the resolver and the
# columnar cache never drift apart.
psl_match_alloc <- function(n) {
  cols <- c(
    lapply(psl_cache_char_cols, \(col) character(n)),
    lapply(psl_cache_int_cols, \(col) integer(n))
  )
  names(cols) <- psl_cache_cols
  cols
}

psl_empty_match_result <- function() psl_match_alloc(0L)

# Derive the ASCII public suffix / registrable domain / rule strings for the
# WHOLE miss vector at once, using the 1-based byte offsets the C++ matcher
# returns (`ps_start` / `rd_start` / `ps1_start`) with a single vectorized
# `substr()` per column. Reproduces the old per-host `derive_one()` exactly: an
# NA offset (public-suffix depth < 1, or no registrant label) yields NA. Returns
# a list of parallel column vectors (one per field, all `length(cores)`),
# including the raw `ps_start` / `rd_start` offsets so the columnar cache can
# carry them for P4's `suffix_extract`.
psl_match_records <- function(cores, section_code) {
  res <- psl_match(active_matcher(), cores, section_code)
  end <- nchar(cores)
  kind <- psl_kind_labels[res$kind + 1L]
  sec <- c("icann", "private")[res$section + 1L] # NA section -> NA

  public_suffix <- ifelse(
    is.na(res$ps_start),
    NA_character_,
    substr(cores, res$ps_start, end)
  )
  registrable_domain <- ifelse(
    is.na(res$rd_start),
    NA_character_,
    substr(cores, res$rd_start, end)
  )

  rule <- rep(NA_character_, length(cores))
  # Only a valid public-suffix depth (ps_start present) carries a rule string;
  # this mirrors derive_one()'s `depth < 1` guard returning NA for every field.
  has_ps <- !is.na(res$ps_start)
  is_normal <- has_ps & kind == "normal"
  is_wild <- has_ps & kind == "wildcard"
  is_exc <- has_ps & kind == "exception"
  is_def <- has_ps & kind == "default"
  rule[is_normal] <- public_suffix[is_normal]
  rule[is_wild] <- paste0(
    "*.",
    substr(cores[is_wild], res$ps1_start[is_wild], end[is_wild])
  )
  rule[is_exc] <- paste0("!", registrable_domain[is_exc])
  rule[is_def] <- "*"

  list(
    public_suffix = public_suffix,
    registrable_domain = registrable_domain,
    rule = rule,
    kind = kind,
    rule_section = sec,
    ps_depth = res$ps_depth,
    ps_start = res$ps_start,
    rd_start = res$rd_start
  )
}

#' Resolve canonical hosts to ASCII match results, with session caching
#'
#' Takes canonical lowercase ASCII hosts (no terminal dot, no `NA`), serves any
#' previously seen (host, active-list, section) triples from the bounded session
#' cache, deduplicates the remaining misses before crossing into C++ once each,
#' runs the prevailing-rule algorithm, caches the derived metadata, and returns
#' one entry per input core. Results are canonical ASCII without the terminal
#' dot: the `unknown`/`output` policies and dot restoration are applied by
#' callers, so they are deliberately absent from the cache key (PRD s8.2).
#'
#' Hits are read from the columnar cache by a single `mget()` of indices
#' followed by vectorized column subsetting (no per-host closures); misses are
#' derived by `psl_match_records()`, written into the unique-level columns, and
#' appended to the cache. The final result is one entry per input via a
#' `match()` back onto the unique cores.
#'
#' @param cores Character vector of canonical hosts (no terminal dot, no `NA`).
#' @param section One of `"all"`, `"icann"`, `"private"`.
#' @return A list of parallel column vectors, each `length(cores)`:
#'   `public_suffix`, `registrable_domain`, `rule`, `kind`, `rule_section`,
#'   `ps_depth`, and the byte offsets `ps_start` / `rd_start`.
#' @noRd
psl_resolve_cores <- function(cores, section) {
  if (length(cores) == 0L) {
    return(psl_empty_match_result())
  }

  # Escape hatch (PRD s8.2): `options(pslr.cache = FALSE)` skips every cache
  # read and write for the call. It changes only whether entries are stored or
  # read -- never a result: the misses are derived by the same code path, so the
  # output is byte-identical to the cached path (verified by test-cache.R).
  cache_on <- !isFALSE(getOption("pslr.cache", TRUE))

  psl_cache_ensure()
  section_code <- psl_section_code(section)
  prefix <- paste0(active_list_identity(), "|", section_code, "|")

  uniq <- unique(cores)
  nu <- length(uniq)
  keys <- paste0(prefix, uniq)
  cache_idx <- psl_cache_lookup(keys, cache_on)
  hit <- !is.na(cache_idx)
  miss <- !hit

  # The eight parallel columns, driven by the shared cache schema so this stays
  # in lockstep with clear/grow/store. Warm hits are copied out of the cache
  # columns by vectorized subsetting; cold misses are derived once by
  # `psl_match_records()`, placed, and appended to the cache (which may flush
  # first per the capacity bound; hits are already copied out).
  cols <- psl_match_alloc(nu)
  if (any(hit)) {
    hi <- cache_idx[hit]
    for (col in psl_cache_cols) {
      cols[[col]][hit] <- psl_cache_env[[col]][hi]
    }
  }
  if (any(miss)) {
    records <- psl_match_records(uniq[miss], section_code)
    for (col in psl_cache_cols) {
      cols[[col]][miss] <- records[[col]]
    }
    if (cache_on) {
      psl_cache_store(keys[miss], records)
    }
  }

  idx <- match(cores, uniq)
  lapply(cols, `[`, idx)
}
