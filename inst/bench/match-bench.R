#!/usr/bin/env Rscript
# Match-throughput benchmark for pslr (PSLR-dmhuazyj, P1 baseline).
#
# Standalone: NOT a test, NOT run on CRAN, NOT sourced by the package. Run it by
# hand to measure the query hot path before/after the columnar rewrite (P2-P5):
#
#   Rscript inst/bench/match-bench.R
#
# It reports throughput (hosts/s) for three scenarios over registrable_domain(),
# the representative full-pipeline query (canonicalize -> cache -> C++ match ->
# derive):
#
#   * cold    -- 200k UNIQUE synthetic hosts, result cache flushed first.
#   * warm    -- the same 200k hosts a second time (cache already primed). NB:
#                200k unique > the 50k cache capacity, so the whole-table
#                eviction fires and warm gains little over cold on the unique
#                set; the duplicates-heavy run is where the cache pays off.
#   * dupheavy-- 200k hosts drawn from a 1k-host pool (cache-friendly), cold.
#   * scalar  -- 1k separate scalar calls (per-call fixed-cost sensitivity).
#
# ---------------------------------------------------------------------------
# BASELINE. Machine: Apple Silicon (darwin 25.4.0), R via devtools::load_all.
#
# P1 baseline, pslr 1.0.2 (pre-rewrite, feature/pslr-p1-bench-oracle):
#
#   cold      200000 hosts in  4.262 s  ->    46,926 hosts/s
#   warm      200000 hosts in  3.294 s  ->    60,716 hosts/s
#   dupheavy  200000 hosts in  0.084 s  -> 2,380,952 hosts/s (1k unique, cached)
#   scalar      1000 calls  in  0.517 s  ->  0.517 ms/call (1,934 hosts/s)
#
# Post-P4, pslr 1.0.2.9000 (feature/pslr-p5-cache-policy; measured 2026-07-02
# via devtools::load_all -- NB `Rscript inst/bench/match-bench.R` alone loads
# the INSTALLED pslr, so run it under load_all to bench the source tree):
#
#   cold      200000 hosts in  2.03 s  ->    98,800 hosts/s   (~2.1x vs P1)
#   warm      200000 hosts in  1.50 s  ->   133,000 hosts/s   (~2.2x vs P1)
#   dupheavy  200000 hosts in  0.09 s  -> 2,270,000 hosts/s
#   scalar      1000 calls  in  0.11 s  ->     8,900 hosts/s   (~4.6x vs P1)
#
# P5 cache-policy experiment (cache DISABLED via options(pslr.cache = FALSE);
# same machine/run). Within a single vectorized call `unique()` already dedups,
# so the cache only pays off ACROSS calls -- on one-shot UNIQUE-host batches the
# cache READ (mget of every key, all misses) is pure overhead:
#
#   cold      200000 hosts in  1.38 s  ->   145,000 hosts/s   (cache-off ~1.5x)
#   warm      200000 hosts in  1.36 s  ->   147,000 hosts/s
#   scalar      1000 calls  in  0.07 s  ->    14,900 hosts/s   (cache-off ~1.7x)
#
# ...but on the cache's home turf -- the SAME hosts re-queried across separate
# calls -- caching is the clear winner:
#
#   repeat-batch1k (200 calls x 1k hosts)  cache-on 0.70 s vs off 1.33 s (~1.9x)
#   repeat-scalar  ( 20 calls x 100 hosts) cache-on 0.11 s vs off 0.13 s (~1.2x)
#
# Policy (PSLR-ynbfnhkp): keep the cache always-on by default; add the
# `options(pslr.cache = FALSE)` escape hatch (results identical, only storage/
# reads toggled) for one-shot unique-host batches; raise the bound 50000->200000
# (columnar entries are ~80 bytes; a 200000-unique warm pass drops 1.63->0.83s).
#
# Treat the numbers this run prints, not these comments, as the live baseline.
# ---------------------------------------------------------------------------

suppressMessages({
  if (!requireNamespace("pslr", quietly = TRUE)) {
    stop("install pslr first (or run under devtools::load_all())")
  }
  library(pslr)
})

# Flush the bounded result cache so a "cold" run really is cold. Internal, but
# a bench legitimately reaches for it.
clear_cache <- function() {
  f <- tryCatch(
    get("psl_cache_clear", envir = asNamespace("pslr")),
    error = function(e) NULL
  )
  if (!is.null(f)) {
    f()
  }
  invisible(NULL)
}

# Deterministic corpus generators (no RNG dependence on seed availability).
suffix_pool <- c(
  "com",
  "co.uk",
  "org",
  "net",
  "io",
  "com.cn",
  "kobe.jp",
  "github.io",
  "blogspot.com",
  "com.au"
)

make_unique_hosts <- function(n) {
  i <- seq_len(n)
  sprintf(
    "host%d.sub%d.%s",
    i,
    i %% 997L,
    suffix_pool[(i %% length(suffix_pool)) + 1L]
  )
}

make_dupheavy_hosts <- function(n, pool_size = 1000L) {
  pool <- make_unique_hosts(pool_size)
  pool[((seq_len(n) - 1L) %% pool_size) + 1L]
}

timed <- function(label, n, expr) {
  elapsed <- system.time(force(expr))[["elapsed"]]
  rate <- n / elapsed
  cat(sprintf(
    "%-9s %8d hosts in %7.3f s  -> %10.0f hosts/s\n",
    label,
    n,
    elapsed,
    rate
  ))
  invisible(elapsed)
}

main <- function() {
  n <- 200000L
  cat("pslr match-bench | registrable_domain() | ", format(Sys.time()), "\n")
  ver <- as.character(utils::packageVersion("pslr"))
  cat(sprintf("pslr version: %s\n\n", ver))

  uniq <- make_unique_hosts(n)
  dup <- make_dupheavy_hosts(n)

  # Force lazy activation + a first canonicalization pass out of the timing.
  invisible(registrable_domain("warmup.example.com"))

  clear_cache()
  timed("cold", n, registrable_domain(uniq)) # cache flushed above
  timed("warm", n, registrable_domain(uniq)) # cache primed by the cold run

  clear_cache()
  timed("dupheavy", n, registrable_domain(dup)) # cache-friendly (1k unique)

  scalar_hosts <- make_unique_hosts(1000L)
  clear_cache()
  timed("scalar", 1000L, {
    for (h in scalar_hosts) {
      registrable_domain(h)
    }
  })

  cat("\ndone.\n")
}

main()
