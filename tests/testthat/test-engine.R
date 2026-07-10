# The result cache is owned by the `psl_engine` that holds the matcher it caches
# for (PSLR-bcgedhmy). Two engines built from two snapshots must therefore have
# independent caches: a store into one cannot be observed through the other.

test_that("each engine owns an isolated result cache", {
  rules <- active_rules()
  meta <- active_meta()
  engine_a <- new_psl_engine(new_psl_snapshot(rules, meta))
  engine_b <- new_psl_engine(new_psl_snapshot(rules, meta))

  # Distinct cache objects, both starting empty once initialised.
  expect_false(identical(engine_a$cache, engine_b$cache))
  psl_cache_ensure(engine_a$cache)
  psl_cache_ensure(engine_b$cache)
  expect_identical(engine_a$cache$n, 0L)
  expect_identical(engine_b$cache$n, 0L)

  # Storing into engine A's cache leaves engine B's cache untouched. The store
  # payload is the compact structural record the cache actually holds, built by
  # the same producer the resolver uses.
  records <- psl_match_structural(engine_a$matcher, "example.com", 2L)
  psl_cache_store(engine_a$cache, "2|example.com", records)
  expect_identical(engine_a$cache$n, 1L)
  expect_identical(engine_b$cache$n, 0L)
})
