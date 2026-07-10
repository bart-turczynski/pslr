# R engine layer over the cpp11 matcher (PRD s6, s8.2).
#
# Owns normalization, terminal-dot handling, canonical-host deduplication, and
# turning the C++ result (public-suffix depth + kind + section per host) into
# ASCII public-suffix / registrable-domain / rule strings. The exported query
# API, the unknown/output/invalid policies, extraction, rule inspection, and
# the bounded result cache are layered on top of this in P4.

# Session state: the process-wide default `psl_engine` (immutable after
# construction) that the global query API delegates to. It pairs a
# `psl_snapshot` (rules + metadata + source identity) with the compiled matcher,
# held in a single `$state` slot so activation swaps it with one atomic
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

# The `psl_version()`-shaped snapshot-metadata schema, owned in one place:
# field order and per-field storage type. This is the single source of truth
# consumed by `new_psl_meta()` (construction + defaults), `validate_psl_meta()`
# (checked boundary), and `as_psl_version_df()` (the one-row data.frame). The
# source-identity fields carry a typed `NA` default; the normalization
# identifiers default to the runtime normalizer (PRD s7.4).
psl_meta_fields <- c(
  source = "character",
  path = "character",
  retrieved_at = "character",
  list_date = "character",
  commit = "character",
  size = "integer",
  checksum = "character",
  normalizer = "character",
  normalizer_version = "character",
  normalization_profile = "character",
  unicode_version = "character"
)

# Typed `NA` for a schema storage type.
psl_meta_na <- function(type) {
  switch(type, character = NA_character_, integer = NA_integer_)
}

# Construct a complete snapshot-metadata list. Source-identity fields default to
# typed `NA`; normalization identifiers default to the runtime normalizer.
# Callers override the known fields by name. Owns field order, types, and
# defaults for the whole package.
new_psl_meta <- function(...) {
  base <- utils::modifyList(
    lapply(psl_meta_fields, psl_meta_na),
    runtime_normalizer_meta()
  )
  utils::modifyList(base, list(...))
}

# Validate a snapshot-metadata list against the schema: every field present,
# each a length-1 vector of its declared storage type. Returns `x` invisibly on
# success; errors otherwise. A checked boundary for callers that must trust a
# meta object's shape.
validate_psl_meta <- function(x) {
  if (!is.list(x)) {
    stop("`x` must be a metadata list.", call. = FALSE)
  }
  missing <- setdiff(names(psl_meta_fields), names(x))
  if (length(missing)) {
    stop(
      "Metadata is missing required field(s): ",
      paste(missing, collapse = ", "),
      ".",
      call. = FALSE
    )
  }
  for (field in names(psl_meta_fields)) {
    type <- psl_meta_fields[[field]]
    value <- x[[field]]
    ok <- length(value) == 1L &&
      switch(
        type,
        character = is.character(value),
        integer = is.integer(value)
      )
    if (!ok) {
      stop(
        sprintf("Metadata field `%s` must be a length-1 %s.", field, type),
        call. = FALSE
      )
    }
  }
  invisible(x)
}

# Backwards-compatible alias for the constructor (PRD s7.4). Existing callers
# (R/refresh.R) build metadata through this name.
psl_meta <- function(...) {
  new_psl_meta(...)
}

# A `psl_snapshot` is the immutable descriptor of a rule set plus its
# provenance: the rule table, the `psl_version()`-shaped metadata, and the
# source identity (checksum) reported by `psl_version()`. `rebuilt` records
# whether the rules were re-parsed from source under the runtime normalizer
# because the shipped index's normalization profile mismatched (PRD s8.3); it
# lives with the rules it describes. Internal, unexported.
# @noRd
new_psl_snapshot <- function(rules, meta, rebuilt = FALSE) {
  structure(
    list(
      rules = rules,
      meta = meta,
      identity = meta$checksum,
      rebuilt = rebuilt
    ),
    class = "psl_snapshot"
  )
}

# A `psl_engine` bundles a `psl_snapshot`, the compiled C++ matcher built from
# its rules, and the bounded result cache for that matcher. The engine is
# PROCESS-LOCAL: the matcher is an external pointer that does not serialize
# across sessions or parallel workers. Only the snapshot descriptor is
# serializable; a restore would rebuild the pointer and mint a fresh cache from
# the snapshot's rules. (No serialization code lives here yet.) The cache is
# engine-local: it belongs to exactly one rule set, so it can never mix
# snapshots and its keys need no list identity. Internal, unexported.
# @noRd
new_psl_engine <- function(snapshot) {
  structure(
    list(
      snapshot = snapshot,
      matcher = build_matcher(snapshot$rules),
      cache = new_psl_cache()
    ),
    class = "psl_engine"
  )
}

# The single activation choke-point: replace the default engine with one built
# from `snapshot`. Everything that can fail (the matcher build inside
# `new_psl_engine()`) happens before the single atomic state swap, so a failed
# or interrupted activation leaves the previous default engine usable (PRD s9).
# The new engine carries its own empty result cache, so swapping it in
# atomically replaces the cache too -- switching the active list starts cold
# (PRD s7.4, s8.2) with no explicit clear.
psl_activate_snapshot <- function(snapshot) {
  the_matcher$state <- new_psl_engine(snapshot)
  invisible(snapshot$meta)
}

# Activate a validated rule table under `meta`. A thin wrapper that builds the
# snapshot descriptor and hands it to the activation choke-point.
psl_set_active <- function(rules, meta, rebuilt = FALSE) {
  psl_activate_snapshot(new_psl_snapshot(rules, meta, rebuilt = rebuilt))
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

# The process-wide default `psl_engine`: the single active engine that the
# global query API delegates to, lazily initialised from the bundled index on
# first use. `psl_use()` and the refresh activation paths replace it.
psl_default_engine <- function() {
  if (is.null(the_matcher$state)) {
    activate_bundled()
  }
  the_matcher$state
}

# The default engine's snapshot descriptor (rules, metadata, source identity).
active_snapshot <- function() psl_default_engine()$snapshot

# The default engine's matcher pointer (PRD s8.2).
active_matcher <- function() psl_default_engine()$matcher

# The default engine's result cache (PRD s8.2). Engine-local, minted empty by
# `new_psl_engine()` and lazily initialised on first store via the bundled init.
active_cache <- function() psl_default_engine()$cache

# Stable identity of the default engine's list, reported by `psl_version()`. For
# the bundled and cache lists it is the source-snapshot checksum. No longer part
# of the result-cache key (the cache is engine-local).
active_list_identity <- function() active_snapshot()$identity

# Metadata and rule table of the default engine's list, for psl_version() /
# psl_rules().
active_meta <- function() active_snapshot()$meta
active_rules <- function() active_snapshot()$rules

# Allocate the eight parallel match columns, typed and named per the shared
# cache schema (`psl_cache_char_cols` character, `psl_cache_int_cols` integer),
# each `NA`-filled and of length `n`. Keeping this schema-driven means the
# resolver and the columnar cache never drift apart. The `NA` fill is what the
# query builder (`psl_query_cols()`) relies on for invalid inputs; the resolver
# overwrites every slot (each core is either a hit or a miss), so the fill is
# inert there.
psl_match_alloc <- function(n) {
  cols <- c(
    lapply(psl_cache_char_cols, \(col) rep(NA_character_, n)),
    lapply(psl_cache_int_cols, \(col) rep(NA_integer_, n))
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
psl_match_records <- function(matcher, cores, section_code) {
  res <- psl_match(matcher, cores, section_code)
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
#' Takes an explicit `engine` plus canonical lowercase ASCII hosts (no terminal
#' dot, no `NA`), serves any previously seen (host, section) pairs from that
#' engine's bounded cache,
#' deduplicates the remaining misses before crossing into C++ once each,
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
#' @param engine The `psl_engine` to resolve against; its `$matcher` runs the
#'   matches and its `$cache` serves and stores them.
#' @param cores Character vector of canonical hosts (no terminal dot, no `NA`).
#' @param section One of `"all"`, `"icann"`, `"private"`.
#' @return A list of parallel column vectors, each `length(cores)`:
#'   `public_suffix`, `registrable_domain`, `rule`, `kind`, `rule_section`,
#'   `ps_depth`, and the byte offsets `ps_start` / `rd_start`.
#' @noRd
psl_resolve_cores <- function(engine, cores, section) {
  if (length(cores) == 0L) {
    return(psl_empty_match_result())
  }

  # Escape hatch (PRD s8.2): `options(pslr.cache = FALSE)` skips every cache
  # read and write for the call. It changes only whether entries are stored or
  # read -- never a result: the misses are derived by the same code path, so the
  # output is byte-identical to the cached path (verified by test-cache.R).
  cache_on <- !isFALSE(getOption("pslr.cache", TRUE))

  cache <- engine$cache
  psl_cache_ensure(cache)
  section_code <- psl_section_code(section)
  # The cache is engine-local, so the key needs only the section (the list
  # identity is implied by which engine owns the cache).
  prefix <- paste0(section_code, "|")

  uniq <- unique(cores)
  nu <- length(uniq)
  keys <- paste0(prefix, uniq)
  cache_idx <- psl_cache_lookup(cache, keys, cache_on)
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
      cols[[col]][hit] <- cache[[col]][hi]
    }
  }
  if (any(miss)) {
    records <- psl_match_records(engine$matcher, uniq[miss], section_code)
    for (col in psl_cache_cols) {
      cols[[col]][miss] <- records[[col]]
    }
    if (cache_on) {
      psl_cache_store(cache, keys[miss], records)
    }
  }

  idx <- match(cores, uniq)
  lapply(cols, `[`, idx)
}
