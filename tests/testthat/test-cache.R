# Bounded session cache (PRD s8.2). The cache must never change results, must
# key on host + list-identity + section (and NOT on unknown/output), must be
# bounded with a documented eviction, and must clear on demand.

test_that("cache hits never change results", {
  psl_cache_clear()
  hosts <- c("www.example.com", "a.b.co.uk", "x.ck", "www.ck", "madeuptld")
  cold_ps <- public_suffix(hosts)
  cold_rd <- registrable_domain(hosts)
  warm_ps <- public_suffix(hosts) # served from cache
  warm_rd <- registrable_domain(hosts)
  expect_identical(cold_ps, warm_ps)
  expect_identical(cold_rd, warm_rd)
})

test_that("the cache key includes the section", {
  psl_cache_clear()
  res <- psl_resolve_cores("example.com", "all")
  expect_identical(psl_cache_env$n, 1L)
  # A different section is a distinct key, not a stale hit.
  psl_resolve_cores("example.com", "icann")
  expect_identical(psl_cache_env$n, 2L)
  # Re-querying an existing (host, section) is a hit: no new entry.
  psl_resolve_cores("example.com", "all")
  expect_identical(psl_cache_env$n, 2L)
})

test_that("unknown and output are applied post-retrieval, not in the key", {
  psl_cache_clear()
  public_suffix("madeuptld") # caches the default-rule result
  n_after_first <- psl_cache_env$n
  # Flipping unknown/output must not add cache entries...
  public_suffix("madeuptld", unknown = "na")
  public_suffix("madeuptld", output = "unicode")
  expect_identical(psl_cache_env$n, n_after_first)
  # ...yet the post-retrieval policy still applies correctly.
  expect_identical(public_suffix("madeuptld", unknown = "na"), NA_character_)
})

test_that("the cache is bounded and evicts by full flush on overflow", {
  on.exit({
    psl_cache_env$capacity <- NULL
    psl_cache_clear()
  })
  psl_cache_clear()
  # Shrink the bound so a small batch trips eviction deterministically.
  psl_cache_env$capacity <- 3L
  hosts <- c("a.com", "b.com", "c.com")
  psl_resolve_cores(hosts, "all")
  expect_lte(psl_cache_env$n, 3L)
  # A fourth distinct host overflows the bound and triggers the flush.
  psl_resolve_cores("d.com", "all")
  expect_lte(psl_cache_env$n, 3L)
  # A batch larger than the whole capacity is matched but not cached.
  res <- psl_resolve_cores(c("e.com", "f.com", "g.com", "h.com"), "all")
  expect_identical(res$public_suffix, rep("com", 4L))
  expect_identical(psl_cache_env$n, 0L)
})

test_that("options(pslr.cache = FALSE) skips storage, keeps results", {
  on.exit({
    options(pslr.cache = NULL)
    psl_cache_clear()
  })
  hosts <- c("www.example.com", "a.b.co.uk", "x.ck", "www.ck", "madeuptld")

  # With caching disabled nothing is stored, on cold or repeated calls.
  options(pslr.cache = FALSE)
  psl_cache_clear()
  off_ps <- public_suffix(hosts)
  off_rd <- registrable_domain(hosts)
  public_suffix(hosts) # a second pass must still not populate the cache
  expect_identical(psl_cache_env$n, 0L)

  # With caching enabled the results are byte-identical and the cache fills.
  options(pslr.cache = TRUE)
  psl_cache_clear()
  on_ps <- public_suffix(hosts)
  on_rd <- registrable_domain(hosts)
  expect_gt(psl_cache_env$n, 0L)
  expect_identical(off_ps, on_ps)
  expect_identical(off_rd, on_rd)

  # A pre-seeded cache is ignored for reads while disabled (still same result).
  options(pslr.cache = FALSE)
  expect_identical(public_suffix(hosts), on_ps)
})

test_that("psl_cache_clear empties the table", {
  public_suffix("example.com")
  expect_gt(psl_cache_env$n, 0L)
  psl_cache_clear()
  expect_identical(psl_cache_env$n, 0L)
})

test_that("psl_cache_ensure lazily initialises an uninitialised store", {
  on.exit(psl_cache_clear())
  # Simulate a never-initialised store (fresh session, before first use).
  psl_cache_env$idx <- NULL
  psl_cache_ensure()
  expect_false(is.null(psl_cache_env$idx))
  expect_identical(psl_cache_env$n, 0L)
})

test_that("storing an empty batch is a no-op", {
  psl_cache_clear()
  expect_null(psl_cache_store(character(0), list()))
  expect_identical(psl_cache_env$n, 0L)
})
