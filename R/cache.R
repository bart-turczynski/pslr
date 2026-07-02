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
psl_cache_default_capacity <- 50000L

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
  for (col in c(psl_cache_char_cols, psl_cache_int_cols)) {
    length(psl_cache_env[[col]]) <- new_cap
  }
  psl_cache_env$cap_vec <- new_cap
  invisible(NULL)
}

# Store records (a list of parallel column vectors) under already-composed keys,
# honouring the capacity bound. Appends into the column vectors and records each
# key -> slot mapping in the index env.
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
  psl_cache_grow(psl_cache_env$n + m)
  slots <- psl_cache_env$n + seq_len(m)
  for (col in c(psl_cache_char_cols, psl_cache_int_cols)) {
    psl_cache_env[[col]][slots] <- records[[col]]
  }
  mapping <- as.list(slots)
  names(mapping) <- keys
  list2env(mapping, envir = psl_cache_env$idx)
  psl_cache_env$n <- psl_cache_env$n + m
  invisible(NULL)
}
