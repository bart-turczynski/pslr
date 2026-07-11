# Bounded per-engine cache for canonical match results (PRD s8.2).
#
# The cache is a plain columnar env minted by `new_psl_cache()` and owned by the
# `psl_engine` that holds the matcher it caches for; every function here takes
# that env as its explicit first argument. Because a cache belongs to exactly
# one engine (one rule set), it can never mix snapshots, so the key is just the
# canonical host + section -- no list identity. The cache stores only canonical
# ASCII match results and rule metadata. The `unknown` policy, `output =
# "unicode"` decoding, and terminal-dot restoration are all applied *after*
# retrieval, so they are intentionally not part of the key and the cache can
# never change a result. Switching the active list mints a fresh engine with a
# fresh (empty) cache, so activation needs no explicit clear.
#
# Storage is columnar (PSLR-ffdsymhk) and compact (PSLR-muyzxbpl). Instead of
# one R list per host, the cache keeps a key -> integer-index env (`$idx`)
# alongside parallel column vectors of the STRUCTURAL match result: the
# public-suffix depth `$ps_depth`, the byte offsets `$ps_start` / `$rd_start` /
# `$ps1_start`, and the enum codes `$kind_code` / `$section_code`. Every column
# is a plain integer vector, so a cached entry is a handful of ints; the
# user-facing string columns are reconstructed from these offsets on read
# (`psl_derive_strings()`), never stored. A hit resolves to a vector of indices
# via a single `mget()`, then reads each field by vector subsetting -- no
# per-host R closures on the warm path. The offsets are carried so
# `suffix_extract` can be plumbed straight from the cache. The column vectors
# grow by doubling (`$cap_vec` is the allocated length; `$n` the number of live
# entries), giving amortized O(1) appends.
#
# Eviction is a documented full flush: the cache holds at most
# `psl_cache_capacity()` entries; when a store would exceed that bound the whole
# table is dropped and rebuilt. A flat bound with whole-table eviction keeps the
# implementation simple and its memory footprint predictable, at the cost of
# discarding warm entries on overflow. A batch larger than the whole capacity is
# matched but not cached -- and, because it could never fit, does *not* evict at
# all: the warm set survives an oversized one-shot query (PSLR-wyvauroc).

# Default maximum number of (host, section) records retained at once. The
# effective bound lives in the cache env's `$capacity` so it stays mutable
# (package bindings are locked); this constant only seeds it.
#
# Raised 50000 -> 200000 (PSLR-ynbfnhkp) now that P2-P4 made each entry cheap:
# the columnar store measures ~80 bytes/entry (15.9 MB for a full 200000-entry
# table), and memory scales with live entries so a small session pays nothing.
# The higher bound lets a large working set (up to 200000 canonical hosts)
# re-queried across calls stay warm instead of tripping the full-flush cliff --
# on the 200000-unique benchmark this turns the second pass from a flush-and-
# rederive (~1.63 s) into a true cache hit (~0.83 s, ~2x). Above the bound the
# full-flush semantics are unchanged.
psl_cache_default_capacity <- 200000L

# The names of the parallel column vectors held in a cache env, in a single
# place so clear/grow/store/read stay in lockstep. The cache stores only compact
# integer STRUCTURAL columns -- the public-suffix depth, the three byte offsets,
# and the two enum codes returned by `psl_match()`. The user-facing string
# columns are derived on read (`psl_derive_strings()` in matcher.R), after cache
# assembly, so they never need storing. Every cache column is integer.
psl_cache_cols <- c(
  "ps_depth",
  "ps_start",
  "rd_start",
  "ps1_start",
  "kind_code",
  "section_code"
)

# Mint a fresh per-engine cache: an env holding the key -> index env, the
# parallel column vectors, the current entry count, the allocated column length,
# and the effective capacity bound. The store is initialised lazily (via
# `psl_cache_ensure()` / `psl_cache_clear()`), so a freshly minted cache carries
# only its capacity seed until first use. Each `psl_engine` owns one of these.
new_psl_cache <- function() {
  cache <- new.env(parent = emptyenv())
  cache$capacity <- psl_cache_default_capacity
  # A freshly minted cache is empty: `$n == 0` is observable immediately (a
  # just-activated list reads as cold), while the columnar store (`$idx` and the
  # column vectors) stays lazily initialised on first use via
  # `psl_cache_ensure`.
  cache$n <- 0L
  cache
}

# Current capacity bound, seeded from the default on first use.
psl_cache_capacity <- function(cache) {
  if (is.null(cache$capacity)) {
    cache$capacity <- psl_cache_default_capacity
  }
  cache$capacity
}

#' Drop every cached match result in `cache`
#'
#' Resets an existing cache env in place: the key env and every column vector
#' are cleared atomically. A fresh engine already carries an empty cache, so
#' activation does not call this; it is kept to reset a live cache (capacity
#' overflow, benchmark resets, tests).
#' @noRd
psl_cache_clear <- function(cache) {
  cache$idx <- new.env(parent = emptyenv())
  cache$n <- 0L
  cache$cap_vec <- 0L
  for (col in psl_cache_cols) {
    cache[[col]] <- integer(0)
  }
  invisible(NULL)
}

# Ensure the columnar store exists before a get/put without forcing a load-time
# init.
psl_cache_ensure <- function(cache) {
  if (is.null(cache$idx)) {
    psl_cache_clear(cache)
  }
}

# Ensure the column vectors can hold at least `need` entries, doubling the
# allocated length (`length<-` preserves existing values and NA-pads the tail).
psl_cache_grow <- function(cache, need) {
  cur <- cache$cap_vec
  if (need <= cur) {
    return(invisible(NULL))
  }
  new_cap <- max(cur, 1L)
  while (new_cap < need) {
    new_cap <- new_cap * 2L
  }
  for (col in psl_cache_cols) {
    length(cache[[col]]) <- new_cap
  }
  cache$cap_vec <- new_cap
  invisible(NULL)
}

# Look up the cache slot index for each key, or all-NA when the escape hatch
# (`options(pslr.cache = FALSE)`) is set. A miss (key absent) is NA_integer_.
psl_cache_lookup <- function(cache, keys, cache_on) {
  if (!cache_on) {
    return(rep(NA_integer_, length(keys)))
  }
  unlist(
    mget(keys, envir = cache$idx, ifnotfound = list(NA_integer_)),
    use.names = FALSE
  )
}

# Store records (a list of parallel column vectors) under already-composed keys,
# honouring the capacity bound. Appends into the column vectors and records each
# key -> slot mapping in the index env.
psl_cache_store <- function(cache, keys, records) {
  m <- length(keys)
  if (m == 0L) {
    return(invisible(NULL))
  }
  capacity <- psl_cache_capacity(cache)
  # An oversized batch -- its own unique misses exceed the whole capacity -- is
  # matched but never cached. Return *before* evicting: flushing the warm set to
  # make room for a batch this large will never use is pure loss, so the
  # existing entries survive an oversized one-shot query (PSLR-wyvauroc).
  if (m > capacity) {
    return(invisible(NULL))
  }
  # A batch that fits the capacity but would overflow the live set evicts by
  # full flush, then stores -- favouring the most-recent working set (D11).
  if (cache$n + m > capacity) {
    psl_cache_clear(cache)
  }
  # Pre-size the key index to the incoming batch so a large cold batch fills a
  # right-sized hash table in one shot instead of rehashing on every insert. A
  # hash env's bucket count is fixed at creation, so only (re)size a fresh
  # (empty) index -- never a populated one. The hint is bounded below by R's
  # default size (tiny scalar calls stay cheap) and above by capacity.
  if (cache$n == 0L) {
    cache$idx <- new.env(
      parent = emptyenv(),
      size = min(max(m, 29L), capacity)
    )
  }
  psl_cache_grow(cache, cache$n + m)
  slots <- cache$n + seq_len(m)
  for (col in psl_cache_cols) {
    cache[[col]][slots] <- records[[col]]
  }
  mapping <- as.list(slots)
  names(mapping) <- keys
  list2env(mapping, envir = cache$idx)
  cache$n <- cache$n + m
  invisible(NULL)
}
