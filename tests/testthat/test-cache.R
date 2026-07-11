# Bounded session cache (PRD s8.2). The cache must never change results, must
# key on host + section (list identity is implied by the engine that owns the
# cache), must NOT key on unknown/output, must be bounded with a documented
# eviction, and must clear on demand.

test_that("cache hits never change results", {
  psl_cache_clear(active_cache())
  hosts <- c("www.example.com", "a.b.co.uk", "x.ck", "www.ck", "madeuptld")
  cold_ps <- public_suffix(hosts)
  cold_rd <- registrable_domain(hosts)
  warm_ps <- public_suffix(hosts) # served from cache
  warm_rd <- registrable_domain(hosts)
  expect_identical(cold_ps, warm_ps)
  expect_identical(cold_rd, warm_rd)
})

test_that("the cache key includes the section", {
  psl_cache_clear(active_cache())
  res <- psl_resolve_cores(psl_default_engine(), "example.com", "all")
  expect_identical(active_cache()$n, 1L)
  # A different section is a distinct key, not a stale hit.
  psl_resolve_cores(psl_default_engine(), "example.com", "icann")
  expect_identical(active_cache()$n, 2L)
  # Re-querying an existing (host, section) is a hit: no new entry.
  psl_resolve_cores(psl_default_engine(), "example.com", "all")
  expect_identical(active_cache()$n, 2L)
})

test_that("unknown and output are applied post-retrieval, not in the key", {
  psl_cache_clear(active_cache())
  public_suffix("madeuptld") # caches the default-rule result
  n_after_first <- active_cache()$n
  # Flipping unknown/output must not add cache entries...
  public_suffix("madeuptld", unknown = "na")
  public_suffix("madeuptld", output = "unicode")
  expect_identical(active_cache()$n, n_after_first)
  # ...yet the post-retrieval policy still applies correctly.
  expect_identical(public_suffix("madeuptld", unknown = "na"), NA_character_)
})

test_that("the cache is bounded and evicts by full flush on overflow", {
  cache <- active_cache()
  on.exit({
    cache$capacity <- NULL
    psl_cache_clear(cache)
  })
  psl_cache_clear(cache)
  # Shrink the bound so a small batch trips eviction deterministically.
  cache$capacity <- 3L
  hosts <- c("a.com", "b.com", "c.com")
  psl_resolve_cores(psl_default_engine(), hosts, "all")
  expect_lte(cache$n, 3L)
  # A fourth distinct host overflows the bound and triggers the flush.
  psl_resolve_cores(psl_default_engine(), "d.com", "all")
  expect_lte(cache$n, 3L)
  # Re-seed a known warm entry, then send an oversized batch (more unique misses
  # than the whole capacity). It is matched but not cached -- and, crucially, it
  # does not evict: the warm entry survives, because flushing to make room a
  # batch this large will never use is pure loss (PSLR-wyvauroc).
  psl_cache_clear(cache)
  psl_resolve_cores(psl_default_engine(), "d.com", "all")
  warm_n <- cache$n
  res <- psl_resolve_cores(
    psl_default_engine(),
    c("e.com", "f.com", "g.com", "h.com"),
    "all"
  )
  expect_identical(res$public_suffix, rep("com", 4L))
  expect_identical(cache$n, warm_n)
})

test_that("options(pslr.cache = FALSE) skips storage, keeps results", {
  on.exit({
    options(pslr.cache = NULL)
    psl_cache_clear(active_cache())
  })
  hosts <- c("www.example.com", "a.b.co.uk", "x.ck", "www.ck", "madeuptld")

  # With caching disabled nothing is stored, on cold or repeated calls.
  options(pslr.cache = FALSE)
  psl_cache_clear(active_cache())
  off_ps <- public_suffix(hosts)
  off_rd <- registrable_domain(hosts)
  public_suffix(hosts) # a second pass must still not populate the cache
  expect_identical(active_cache()$n, 0L)

  # With caching enabled the results are byte-identical and the cache fills.
  options(pslr.cache = TRUE)
  psl_cache_clear(active_cache())
  on_ps <- public_suffix(hosts)
  on_rd <- registrable_domain(hosts)
  expect_gt(active_cache()$n, 0L)
  expect_identical(off_ps, on_ps)
  expect_identical(off_rd, on_rd)

  # A pre-seeded cache is ignored for reads while disabled (still same result).
  options(pslr.cache = FALSE)
  expect_identical(public_suffix(hosts), on_ps)
})

test_that("psl_cache_clear empties the table", {
  public_suffix("example.com")
  expect_gt(active_cache()$n, 0L)
  psl_cache_clear(active_cache())
  expect_identical(active_cache()$n, 0L)
})

test_that("psl_cache_ensure lazily initialises an uninitialised store", {
  cache <- active_cache()
  on.exit(psl_cache_clear(cache))
  # Simulate a never-initialised store (fresh session, before first use).
  cache$idx <- NULL
  psl_cache_ensure(cache)
  expect_false(is.null(cache$idx))
  expect_identical(cache$n, 0L)
})

test_that("storing an empty batch is a no-op", {
  psl_cache_clear(active_cache())
  expect_null(psl_cache_store(active_cache(), character(0), list()))
  expect_identical(active_cache()$n, 0L)
})

test_that("a large cold batch pre-sizes the index and stays retrievable", {
  psl_cache_clear(active_cache())
  # A batch well past a default-sized (29-bucket) hash table, but under the
  # capacity bound, so it is cached rather than flushed.
  hosts <- paste0("host", seq_len(5000L), ".example.com")
  cold <- public_suffix(hosts)
  # Every distinct key is stored: the entry count equals the distinct count.
  expect_identical(active_cache()$n, length(hosts))
  # A warm re-query is served from the pre-sized index, byte-identical.
  warm <- public_suffix(hosts)
  expect_identical(warm, cold)
  expect_identical(warm, rep("com", length(hosts)))
})
