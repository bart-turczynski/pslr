# Deterministic fixtures for the developer benchmark harness (bench/).
#
# These helpers live in R/ (not bench/, which is Rbuildignored and unavailable
# under R CMD check) purely so the correctness properties the benchmark relies
# on -- an exactly-n unique host corpus and a real cold-cache reset -- can be
# unit-tested. They are internal, unexported, and undocumented; the harness in
# bench/ calls them via `pslr:::psl_bench_*()`.

# Public-suffix shapes spanning several index paths (plain TLD, multi-label
# ICANN, private/wildcard), so a benchmark corpus exercises more than one branch
# of the matcher rather than a single suffix.
psl_bench_suffix_pool <- c(
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

# Exactly `n` distinct hosts. Every host embeds its own index `i` twice in the
# labels, so the values are guaranteed unique regardless of how the suffix pool
# repeats -- `length(unique(psl_bench_unique_hosts(n))) == n` always holds. This
# is the honest cold/unique fixture the release gate depends on: a random sample
# from a small space silently collapses to far fewer than `n` distinct hosts.
psl_bench_unique_hosts <- function(n) {
  i <- seq_len(n)
  suffix <- psl_bench_suffix_pool[(i %% length(psl_bench_suffix_pool)) + 1L]
  sprintf("host%d.sub%d.%s", i, i, suffix)
}

# `n` hosts drawn (cycling) from a small pool of `pool_size` distinct hosts, for
# the cache-friendly duplicate-heavy scenario.
psl_bench_dupheavy_hosts <- function(n, pool_size = 1000L) {
  pool <- psl_bench_unique_hosts(pool_size)
  pool[((seq_len(n) - 1L) %% pool_size) + 1L]
}

# Cold-cache reset used by the harness before each timed cold rep, wrapped as a
# named helper so a test can assert it actually empties the in-memory cache
# (`psl_cache_env$n == 0`) rather than trusting the bench to reset state.
psl_bench_reset_cache <- function() {
  psl_cache_clear()
  invisible(NULL)
}
