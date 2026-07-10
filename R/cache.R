# Bounded session cache for canonical match results (PRD s8.2).
#
# Keyed by canonical host + active-list identity + section, the cache stores
# only canonical ASCII match results and rule metadata. The `unknown` policy,
# `output = "unicode"` decoding, and terminal-dot restoration are all applied
# *after* retrieval, so they are intentionally not part of the key and the cache
# can never change a result. Switching the active list clears the cache.
#
# Storage is columnar (PSLR-ffdsymhk). Instead of one R list per host, the cache
# keeps a key -> integer-index env (`$idx`) alongside parallel column vectors
# (`$public_suffix`, `$registrable_domain`, `$rule`, `$kind`, `$rule_section`,
# `$ps_depth`, and the byte offsets `$ps_start` / `$rd_start`). A hit resolves
# to a vector of indices via a single `mget()`, then reads each field by vector
# subsetting -- no per-host R closures on the warm path. The offsets are carried
# so P4's `suffix_extract` can be plumbed straight from the cache. The column
# vectors grow by doubling (`$cap_vec` is the allocated length; `$n` the number
# of live entries), giving amortized O(1) appends.
#
# Eviction is a documented full flush: the cache holds at most
# `psl_cache_capacity()` entries; when a store would exceed that bound the whole
# table is dropped and rebuilt. A flat bound with whole-table eviction keeps the
# implementation simple and its memory footprint predictable, at the cost of
# discarding warm entries on overflow. A batch larger than the capacity is
# matched but not cached.

# Default maximum number of (host, list, section) records retained at once. The
# effective bound lives in `psl_cache_env$capacity` so it stays mutable (package
# bindings are locked); this constant only seeds it.
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

# The names of the parallel column vectors held in `psl_cache_env`, in a single
# place so clear/grow/store/read stay in lockstep. Character columns plus the
# two integer columns (`ps_depth` and the byte offsets).
psl_cache_char_cols <- c(
  "public_suffix",
  "registrable_domain",
  "rule",
  "kind",
  "rule_section"
)
psl_cache_int_cols <- c("ps_depth", "ps_start", "rd_start")

# All eight parallel match columns in one place, so every loop that walks the
# columnar store (clear/grow/store here, plus the resolver in matcher.R) stays
# in lockstep with the schema. Character columns first, then the integer ones.
psl_cache_cols <- c(psl_cache_char_cols, psl_cache_int_cols)

# Session state: the key -> index env, the parallel column vectors, the current
# entry count, the allocated column length, and the effective capacity bound.
psl_cache_env <- new.env(parent = emptyenv())

# Current capacity bound, seeded from the default on first use.
psl_cache_capacity <- function() {
  if (is.null(psl_cache_env$capacity)) {
    psl_cache_env$capacity <- psl_cache_default_capacity
  }
  psl_cache_env$capacity
}

#' Drop every cached match result
#'
#' Called on list activation (PRD s7.4, s8.2) and lazily before first use.
#' Resets the key env and every column vector atomically (PRD s7.4).
#' @noRd
psl_cache_clear <- function() {
  psl_cache_env$idx <- new.env(parent = emptyenv())
  psl_cache_env$n <- 0L
  psl_cache_env$cap_vec <- 0L
  for (col in psl_cache_char_cols) {
    psl_cache_env[[col]] <- character(0)
  }
  for (col in psl_cache_int_cols) {
    psl_cache_env[[col]] <- integer(0)
  }
  invisible(NULL)
}

# Ensure the columnar store exists before a get/put without forcing a load-time
# init.
psl_cache_ensure <- function() {
  if (is.null(psl_cache_env$idx)) {
    psl_cache_clear()
  }
}

# Ensure the column vectors can hold at least `need` entries, doubling the
# allocated length (`length<-` preserves existing values and NA-pads the tail).
psl_cache_grow <- function(need) {
  cur <- psl_cache_env$cap_vec
  if (need <= cur) {
    return(invisible(NULL))
  }
  new_cap <- max(cur, 1L)
  while (new_cap < need) {
    new_cap <- new_cap * 2L
  }
  for (col in psl_cache_cols) {
    length(psl_cache_env[[col]]) <- new_cap
  }
  psl_cache_env$cap_vec <- new_cap
  invisible(NULL)
}

# Store records (a list of parallel column vectors) under already-composed keys,
# honouring the capacity bound. Appends into the column vectors and records each
# key -> slot mapping in the index env.
# Look up the cache slot index for each key, or all-NA when the escape hatch
# (`options(pslr.cache = FALSE)`) is set. A miss (key absent) is NA_integer_.
psl_cache_lookup <- function(keys, cache_on) {
  if (!cache_on) {
    return(rep(NA_integer_, length(keys)))
  }
  unlist(
    mget(keys, envir = psl_cache_env$idx, ifnotfound = list(NA_integer_)),
    use.names = FALSE
  )
}

psl_cache_store <- function(keys, records) {
  m <- length(keys)
  if (m == 0L) {
    return(invisible(NULL))
  }
  capacity <- psl_cache_capacity()
  if (psl_cache_env$n + m > capacity) {
    psl_cache_clear()
    if (m > capacity) {
      return(invisible(NULL))
    }
  }
  # Pre-size the key index to the incoming batch so a large cold batch fills a
  # right-sized hash table in one shot instead of rehashing on every insert. A
  # hash env's bucket count is fixed at creation, so only (re)size a fresh
  # (empty) index -- never a populated one. The hint is bounded below by R's
  # default size (tiny scalar calls stay cheap) and above by capacity.
  if (psl_cache_env$n == 0L) {
    psl_cache_env$idx <- new.env(
      parent = emptyenv(),
      size = min(max(m, 29L), capacity)
    )
  }
  psl_cache_grow(psl_cache_env$n + m)
  slots <- psl_cache_env$n + seq_len(m)
  for (col in psl_cache_cols) {
    psl_cache_env[[col]][slots] <- records[[col]]
  }
  mapping <- as.list(slots)
  names(mapping) <- keys
  list2env(mapping, envir = psl_cache_env$idx)
  psl_cache_env$n <- psl_cache_env$n + m
  invisible(NULL)
}
