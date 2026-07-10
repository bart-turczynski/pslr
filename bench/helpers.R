# Shared timing / cache-state helpers for the pslr benchmark harness.
#
# Sourced by bench/benchmark.R. Both files are Rbuildignored (^bench$) and never
# shipped or run under R CMD check; the deterministic host generators and the
# cold-cache reset live in R/benchmark-fixtures.R so they stay unit-testable.

# Median wall-clock seconds of `setup()`-then-`run()` over `reps` runs, timing
# only `run()`. `setup` restores the scenario's intended state *inside every
# repetition* (e.g. clear or prime the cache) so a cold measurement is never
# quietly contaminated by the previous rep's warm cache; its cost is excluded
# from the timing. Returns the median elapsed component of `system.time()`.
bench_timed <- function(run, setup = function() invisible(NULL), reps = 5L) {
  t <- vapply(
    seq_len(reps),
    function(i) {
      setup()
      as.numeric(system.time(run())["elapsed"])
    },
    numeric(1)
  )
  stats::median(t)
}

fmt_secs <- function(s) formatC(s, format = "f", digits = 4L)

# Run `expr` with an option temporarily set, restoring the prior value after
# (used for the cache-off scenario via `options(pslr.cache = FALSE)`).
with_option <- function(name, value, expr) {
  old <- do.call(options, stats::setNames(list(value), name))
  on.exit(options(old), add = TRUE)
  force(expr)
}
