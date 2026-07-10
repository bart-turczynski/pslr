#!/usr/bin/env Rscript

# Authoritative developer benchmark for pslr (PRD s11.4).
#
# This is the single benchmark harness. It is deliberately excluded from the
# build (.Rbuildignore: ^bench$) and from the test suite: shared CI and CRAN
# timing are not stable, so the timing threshold is a RELEASE GATE run by the
# maintainer, not a unit test. The behavioural properties it leans on -- an
# exactly-n unique corpus and a genuine cold-cache reset -- ARE unit-tested, via
# the internal helpers in R/benchmark-fixtures.R (test-benchmark-fixtures.R).
#
# Run from the package root against the source tree (so you bench what you are
# editing, not the installed copy):
#
#   Rscript bench/benchmark.R
#
# Two integrity properties that earlier bench code got wrong and this harness
# fixes:
#   * the "unique" corpus is DETERMINISTIC and exactly n distinct (a random
#     sample from a small space silently collapses to far fewer); and
#   * every scenario RESETS its intended cache state inside each timed rep, so a
#     cold measurement is never contaminated by the previous rep's warm cache.
#
# Reported, after matcher initialization:
#   * the release gate -- 100,000 exactly-unique ASCII hosts through
#     public_suffix(), cold, which on the maintainer's reference machine must
#     complete in <= 2 seconds;
#   * cold / warm / cache-off / duplicate-heavy / scalar / unicode-output query
#     scenarios over registrable_domain() (the representative full pipeline);
#   * the cold bundled-index compatibility rebuild (parser/matcher activation);
#   * the columnar cache footprint at 1k / 100k / 200k live entries -- the
#     effective bound is psl_cache_default_capacity (200,000, R/cache.R); and
#   * a deduplication proof (normalization and C++ element counts).

suppressMessages({
  if (
    requireNamespace("pkgload", quietly = TRUE) &&
      file.exists("DESCRIPTION")
  ) {
    pkgload::load_all(".", quiet = TRUE)
  } else {
    library(pslr)
  }
})

source("bench/helpers.R")

gate_seconds <- 2L

# Query scenarios over registrable_domain(), each with a per-rep setup that
# restores its intended cache state before every timed run. `uniq` is the
# exactly-unique corpus; `dup` is the duplicate-heavy corpus.
query_scenarios <- function(uniq, dup, scalar_hosts, reps) {
  n <- length(uniq)
  reset <- pslr:::psl_bench_reset_cache

  cold <- bench_timed(
    run = function() registrable_domain(uniq),
    setup = reset,
    reps = reps
  )
  warm <- bench_timed(
    run = function() registrable_domain(uniq),
    setup = function() {
      reset()
      invisible(registrable_domain(uniq)) # prime, then time the warm hit
    },
    reps = reps
  )
  cache_off <- bench_timed(
    run = function() {
      with_option("pslr.cache", FALSE, registrable_domain(uniq))
    },
    setup = reset,
    reps = reps
  )
  dupheavy <- bench_timed(
    run = function() registrable_domain(dup),
    setup = reset,
    reps = reps
  )
  scalar <- bench_timed(
    run = function() {
      for (h in scalar_hosts) {
        registrable_domain(h)
      }
    },
    setup = reset,
    reps = reps
  )
  unicode <- bench_timed(
    run = function() suffix_extract(uniq, output = "unicode"),
    setup = reset,
    reps = reps
  )

  data.frame(
    scenario = c(
      "cold (cache-on)",
      "warm (cache-on)",
      "cache-off",
      "dupheavy",
      "scalar",
      "unicode-output"
    ),
    hosts = c(n, n, n, length(dup), length(scalar_hosts), n),
    seconds = c(cold, warm, cache_off, dupheavy, scalar, unicode),
    stringsAsFactors = FALSE
  )
}

# Columnar-cache footprint (MB) after filling the cache with `k` distinct hosts.
cache_footprint_mb <- function(k) {
  pslr:::psl_bench_reset_cache()
  invisible(registrable_domain(pslr:::psl_bench_unique_hosts(k)))
  env <- pslr:::active_cache()
  cols <- pslr:::psl_cache_cols
  bytes <- sum(vapply(
    cols,
    function(col) as.numeric(utils::object.size(env[[col]])),
    numeric(1)
  ))
  bytes <- bytes + as.numeric(utils::object.size(env$idx))
  list(entries = env$n, mb = bytes / 1024^2)
}

# Deduplication proof: count elements crossing into punycoder's normalizer and
# the cpp11 matcher for a 100k all-repeated batch. Canonical-host dedup must
# collapse each to 1.
dedup_proof <- function(host, n) {
  counts <- new.env(parent = emptyenv())
  counts$norm <- 0L
  counts$match <- 0L
  pkg_ns <- asNamespace("pslr")
  puny_ns <- asNamespace("punycoder")
  orig_match <- get("psl_match", envir = pkg_ns)
  orig_norm <- get("host_normalize", envir = puny_ns)
  unlockBinding("psl_match", pkg_ns)
  unlockBinding("host_normalize", puny_ns)
  on.exit({
    assign("psl_match", orig_match, envir = pkg_ns)
    assign("host_normalize", orig_norm, envir = puny_ns)
  })
  assign(
    "psl_match",
    function(ptr, hosts, section) {
      counts$match <- counts$match + length(hosts)
      orig_match(ptr, hosts, section)
    },
    envir = pkg_ns
  )
  assign(
    "host_normalize",
    function(x, ...) {
      counts$norm <- counts$norm + length(x)
      orig_norm(x, ...)
    },
    envir = puny_ns
  )
  pslr:::psl_bench_reset_cache()
  invisible(public_suffix(rep(host, n)))
  list(norm = counts$norm, match = counts$match)
}

# Verify results, not just timing, before trusting any measurement.
verify_correct <- function(uniq) {
  res <- public_suffix(uniq, output = "ascii")
  stopifnot(
    length(res) == length(uniq),
    length(unique(uniq)) == length(uniq), # the corpus really is all-unique
    !anyNA(res),
    public_suffix("www.shop.example.co.uk") == "co.uk",
    public_suffix("x.github.io") == "github.io",
    public_suffix("a.b.kobe.jp") == "b.kobe.jp",
    registrable_domain("www.shop.example.co.uk") == "example.co.uk"
  )
  invisible(NULL)
}

main <- function(
  n_gate = 100000L,
  n_throughput = 200000L,
  mem_sizes = c(1000L, 100000L, 200000L),
  reps = 5L
) {
  gate_hosts <- pslr:::psl_bench_unique_hosts(n_gate)
  uniq <- pslr:::psl_bench_unique_hosts(n_throughput)
  dup <- pslr:::psl_bench_dupheavy_hosts(n_throughput)
  scalar_hosts <- pslr:::psl_bench_unique_hosts(1000L)
  repeated_host <- "www.shop.example.co.uk"

  # Initialize the matcher once; every query timing below is post-init.
  invisible(public_suffix("init.example.com"))
  verify_correct(gate_hosts)

  # Release gate: exactly-unique ASCII through public_suffix(), cold each rep.
  gate <- bench_timed(
    run = function() public_suffix(gate_hosts, output = "ascii"),
    setup = pslr:::psl_bench_reset_cache,
    reps = reps
  )

  tab <- query_scenarios(uniq, dup, scalar_hosts, reps)

  t_rebuild <- bench_timed(
    run = function() {
      rules <- pslr:::rebuild_bundled_rules()
      pslr:::build_matcher(rules)
    },
    reps = min(reps, 3L)
  )

  mem <- lapply(mem_sizes, cache_footprint_mb)
  dedup <- dedup_proof(repeated_host, n_gate)

  cat("\n## pslr benchmark\n\n")
  cat(sprintf("R %s on %s\n", getRversion(), R.version$platform))
  puny_ver <- as.character(utils::packageVersion("punycoder"))
  cat(sprintf("punycoder %s\n\n", puny_ver))

  cat("Query (post-init), median elapsed seconds:\n\n")
  cat("| scenario | hosts | seconds |\n")
  cat("|:---------|------:|--------:|\n")
  for (i in seq_len(nrow(tab))) {
    cat(sprintf(
      "| %s | %d | %s |\n",
      tab$scenario[i],
      tab$hosts[i],
      fmt_secs(tab$seconds[i])
    ))
  }

  cat("\nColumnar cache footprint (bound = ")
  cat(sprintf("%d entries):\n\n", pslr:::psl_cache_default_capacity))
  cat("| live entries | MB |\n")
  cat("|-------------:|---:|\n")
  for (m in mem) {
    mb <- formatC(m$mb, format = "f", digits = 2L)
    cat(sprintf("| %d | %s |\n", m$entries, mb))
  }

  cat(sprintf(
    "\nCold bundled-index compatibility rebuild (separate): %s s\n",
    fmt_secs(t_rebuild)
  ))
  cat(sprintf(
    "Dedup proof (%d repeated host): %d normalization, %d C++ element\n",
    n_gate,
    dedup$norm,
    dedup$match
  ))

  pass <- gate <= gate_seconds
  cat(sprintf(
    "\nRelease gate: %d unique ASCII (cold) = %s s (<= %d s): %s\n",
    n_gate,
    fmt_secs(gate),
    gate_seconds,
    if (pass) "PASS" else "FAIL"
  ))
  if (!pass) {
    quit(status = 1L)
  }
  invisible(tab)
}

# Auto-run only when executed as a script (Rscript), not when sourced for a
# quick smoke test with a small n.
if (sys.nframe() == 0L) {
  main()
}
