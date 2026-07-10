# Correctness properties the developer benchmark harness (bench/) relies on.
# The harness itself is Rbuildignored and cannot be sourced under R CMD check,
# so the exactly-n unique corpus and the cold-cache reset are pinned here via
# their internal helpers in R/benchmark-fixtures.R.

test_that("psl_bench_unique_hosts produces exactly n distinct hosts", {
  for (n in c(1L, 1000L, 5000L)) {
    hosts <- psl_bench_unique_hosts(n)
    expect_length(hosts, n)
    expect_length(unique(hosts), n)
  }
})

test_that("psl_bench_unique_hosts values are plausible host strings", {
  hosts <- psl_bench_unique_hosts(1000L)
  expect_type(hosts, "character")
  expect_false(anyNA(hosts))
  # host<i>.sub<i>.<suffix> -- at least three dot-separated labels, no spaces.
  expect_true(all(grepl("^host[0-9]+\\.sub[0-9]+\\.[a-z.]+$", hosts)))
})

test_that("psl_bench_dupheavy_hosts draws n hosts from a bounded pool", {
  dup <- psl_bench_dupheavy_hosts(2000L, pool_size = 100L)
  expect_length(dup, 2000L)
  expect_length(unique(dup), 100L)
})

test_that("psl_bench_reset_cache empties the in-memory cache", {
  # Prime the cache with a real query, then assert the reset clears it.
  registrable_domain(psl_bench_unique_hosts(50L))
  expect_gt(psl_cache_env$n, 0L)

  psl_bench_reset_cache()
  expect_identical(psl_cache_env$n, 0L)
})
