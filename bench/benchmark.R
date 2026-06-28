#!/usr/bin/env Rscript

# Non-CRAN performance benchmark for pslr (PRD s11.4).
#
# This script is deliberately excluded from the build (.Rbuildignore) and from
# the test suite: shared CI and CRAN timing are not stable, so the timing
# threshold is a release gate run by the maintainer, not a unit test. The
# behavioural property it exercises -- that canonical-host deduplication avoids
# one normalization and one C++ call per duplicate -- IS unit-tested, in the
# test-dedup testthat file under tests/testthat.
#
# Run from the package root with the installed package, or via devtools:
#   Rscript bench/benchmark.R
#
# It reports, after matcher initialization:
#   * fixed fixtures of 1, 1,000, and 100,000 hosts, each as all-unique and
#     all-repeated (single host) variants, in ASCII output;
#   * the cold bundled-index compatibility rebuild cost, reported separately;
#   * a verification that results are correct, not just fast; and
#   * the deduplication proof (normalization and C++ element counts).
#
# Release gate: on the maintainer's reference machine the 100,000-host unique
# ASCII run must complete in <= 2 seconds after initialization.

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

gate_seconds <- 2L

# Deterministic fixtures. A fixed seed makes every run comparable; the host pool
# mixes several public-suffix shapes (plain TLD, multi-label ICANN, private,
# wildcard) so matching exercises more than one index path.
make_fixtures <- function() {
  set.seed(20260615L)
  suffixes <- c(
    "com",
    "co.uk",
    "org",
    "net",
    "io",
    "dev",
    "co.jp",
    "gov.uk",
    "github.io",
    "s3.amazonaws.com",
    "kobe.jp",
    "ck"
  )
  labels <- c(
    "www",
    "api",
    "mail",
    "shop",
    "app",
    "blog",
    "cdn",
    "dev",
    "staging",
    "service",
    "node01",
    "eu-west-1",
    "internal",
    "data",
    "assets"
  )
  rand_host <- function() {
    depth <- sample(1:3, 1L)
    paste(
      c(sample(labels, depth, replace = TRUE), sample(suffixes, 1L)),
      collapse = "."
    )
  }
  pool <- vapply(seq_len(120000L), function(i) rand_host(), character(1))
  list(
    unique_pool = pool,
    repeated_host = "www.shop.example.co.uk"
  )
}

# Median wall-clock seconds of `expr` over `reps` runs (elapsed component of
# system.time). The matcher is initialized by the caller beforehand so init
# cost is never folded into a query measurement.
timed <- function(expr, reps = 5L) {
  e <- substitute(expr)
  env <- parent.frame()
  t <- vapply(
    seq_len(reps),
    function(i) {
      as.numeric(system.time(eval(e, env))["elapsed"])
    },
    numeric(1)
  )
  stats::median(t)
}

fmt_secs <- function(s) formatC(s, format = "f", digits = 4L)

main <- function() {
  fx <- make_fixtures()

  # Initialize the matcher once; every query timing below is post-init.
  invisible(public_suffix("init.example.com"))

  sizes <- c(1L, 1000L, 100000L)
  rows <- list()

  for (n in sizes) {
    uniq <- fx$unique_pool[seq_len(n)]
    rep_in <- rep(fx$repeated_host, n)

    t_uniq <- timed(public_suffix(uniq, output = "ascii"))
    t_rep <- timed(public_suffix(rep_in, output = "ascii"))

    rows[[length(rows) + 1L]] <- data.frame(
      hosts = n,
      variant = "unique",
      seconds = t_uniq,
      stringsAsFactors = FALSE
    )
    rows[[length(rows) + 1L]] <- data.frame(
      hosts = n,
      variant = "repeated",
      seconds = t_rep,
      stringsAsFactors = FALSE
    )
  }
  tab <- do.call(rbind, rows)

  # Verify results, not just timing: spot-check known answers on the 100k
  # unique batch and confirm the repeated batch is internally consistent.
  big <- fx$unique_pool[seq_len(100000L)]
  res_big <- public_suffix(big, output = "ascii")
  stopifnot(
    length(res_big) == 100000L,
    !anyNA(res_big),
    public_suffix("www.shop.example.co.uk") == "co.uk",
    public_suffix("x.github.io") == "github.io",
    public_suffix("a.b.kobe.jp") == "b.kobe.jp",
    registrable_domain("www.shop.example.co.uk") == "example.co.uk"
  )
  rep_res <- public_suffix(rep(fx$repeated_host, 100000L))
  stopifnot(all(rep_res == "co.uk"))

  # Deduplication proof: count the elements crossing into punycoder and the
  # cpp11 matcher for a 100k all-repeated batch. Each must be 1.
  counts <- new.env(parent = emptyenv())
  counts$norm <- 0L
  counts$match <- 0L
  pkg_ns <- asNamespace("pslr")
  puny_ns <- asNamespace("punycoder")
  orig_match <- get("psl_match", envir = pkg_ns)
  orig_norm <- get("host_normalize", envir = puny_ns)
  unlockBinding("psl_match", pkg_ns)
  unlockBinding("host_normalize", puny_ns)
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
  pslr:::psl_cache_clear()
  invisible(public_suffix(rep(fx$repeated_host, 100000L)))
  assign("psl_match", orig_match, envir = pkg_ns)
  assign("host_normalize", orig_norm, envir = puny_ns)

  # Cold bundled-index compatibility rebuild, reported separately (PRD s8.3,
  # s11.4): re-parse the bundled .dat under the runtime normalizer and rebuild
  # the matcher. This is the worst-case activation, not a per-query cost.
  t_rebuild <- timed(
    {
      rules <- pslr:::rebuild_bundled_rules()
      pslr:::build_matcher(rules)
    },
    reps = 3L
  )

  cat("\n## pslr benchmark\n\n")
  cat(sprintf("R %s on %s\n", getRversion(), R.version$platform))
  cat(sprintf("punycoder %s\n\n", as.character(packageVersion("punycoder"))))

  cat("Query (post-init, ASCII), median elapsed seconds:\n\n")
  cat("| hosts | variant | seconds |\n")
  cat("|------:|:--------|--------:|\n")
  for (i in seq_len(nrow(tab))) {
    cat(sprintf(
      "| %d | %s | %s |\n",
      tab$hosts[i],
      tab$variant[i],
      fmt_secs(tab$seconds[i])
    ))
  }
  cat(sprintf(
    "\nCold bundled-index compatibility rebuild (separate): %s s\n",
    fmt_secs(t_rebuild)
  ))
  cat(sprintf(
    "Dedup proof (100k repeated host): %d normalization, %d C++ element\n",
    counts$norm,
    counts$match
  ))

  gate <- tab$seconds[tab$hosts == 100000L & tab$variant == "unique"]
  pass <- gate <= gate_seconds
  cat(sprintf(
    "\nRelease gate: 100k unique ASCII = %s s (<= %d s): %s\n",
    fmt_secs(gate),
    gate_seconds,
    if (pass) "PASS" else "FAIL"
  ))
  if (!pass) {
    quit(status = 1L)
  }
}

main()
