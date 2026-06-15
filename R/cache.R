# Bounded session cache for canonical match results (PRD s8.2).
#
# Keyed by canonical host + active-list identity + section, the cache stores
# only canonical ASCII match results and rule metadata. The `unknown` policy,
# `output = "unicode"` decoding, and terminal-dot restoration are all applied
# *after* retrieval, so they are intentionally not part of the key and the cache
# can never change a result. Switching the active list clears the cache.
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
psl_cache_default_capacity <- 50000L

# Session state: the hash table of records, its current entry count, and the
# effective capacity bound.
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
#' @noRd
psl_cache_clear <- function() {
  psl_cache_env$tbl <- new.env(parent = emptyenv())
  psl_cache_env$n <- 0L
  invisible(NULL)
}

# Ensure the table exists before a get/put without forcing a load-time init.
psl_cache_ensure <- function() {
  if (is.null(psl_cache_env$tbl)) {
    psl_cache_clear()
  }
}

# Store records under already-composed keys, honouring the capacity bound.
psl_cache_store <- function(keys, records) {
  if (length(keys) == 0L) {
    return(invisible(NULL))
  }
  capacity <- psl_cache_capacity()
  if (psl_cache_env$n + length(keys) > capacity) {
    psl_cache_clear()
    if (length(keys) > capacity) {
      return(invisible(NULL))
    }
  }
  tbl <- psl_cache_env$tbl
  for (i in seq_along(keys)) {
    assign(keys[i], records[[i]], envir = tbl)
  }
  psl_cache_env$n <- psl_cache_env$n + length(keys)
  invisible(NULL)
}
