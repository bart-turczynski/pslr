# Performance benchmarks

This file records reference results for the non-CRAN benchmark
([`bench/benchmark.R`](../bench/benchmark.R)), per PRD §11.4. The benchmark is
excluded from the package build and the test suite because shared CI and CRAN
timing are not stable; the timing threshold is a **release gate** the maintainer
runs locally before tagging a release, not a unit test.

The harness is now **deterministic-unique with per-rep state reset**: the
"unique" corpus is exactly *n* distinct hosts (`pslr:::psl_bench_unique_hosts()`
in `R/benchmark-fixtures.R`, embedding each index into the labels so it can never
silently collapse to fewer), and every scenario restores its intended cache
state — cold clears, warm primes, cache-off sets `options(pslr.cache = FALSE)` —
*inside each timed rep* via `pslr:::psl_bench_reset_cache()`. Cold measurements
are therefore genuinely cold, replacing the previously warm-contaminated,
non-unique measurement these numbers superseded.

The behavioural property the benchmark exercises — that canonical-host
deduplication avoids one normalization and one C++ call per duplicate — is
covered by a deterministic, timing-independent unit test in
[`tests/testthat/test-dedup.R`](../tests/testthat/test-dedup.R).

## Release gate

> On the maintainer's reference machine, the 100,000-host unique ASCII query
> must complete in **no more than 2 seconds** after matcher initialization.

`bench/benchmark.R` exits non-zero if this gate fails.

## How to run

```sh
Rscript bench/benchmark.R
```

## Reference results

Recorded on the maintainer's reference machine. Re-record when the matcher,
canonicalization layer, or `punycoder` dependency changes materially.

- Date: 2026-07-10
- Machine: Apple Silicon (aarch64-apple-darwin23)
- R: version 4.6.0 (2026-04-24)
- punycoder: 1.2.0

Query, post-initialization, median elapsed seconds over 5 reps. The throughput
scenarios run the exactly-unique 200,000-host corpus through
`registrable_domain()` (`unicode-output` through `suffix_extract()`); `scalar`
loops over 1,000 single-host calls; the release gate runs 100,000 unique hosts
through `public_suffix()`.

| scenario        | hosts   | seconds |
|:----------------|--------:|--------:|
| cold (cache-on) | 200,000 | 2.6620  |
| warm (cache-on) | 200,000 | 1.1760  |
| cache-off       | 200,000 | 1.8050  |
| dupheavy        | 200,000 | 0.0760  |
| scalar          | 1,000   | 0.1590  |
| unicode-output  | 200,000 | 3.1680  |

- **Release gate:** 100,000 unique ASCII (cold) = 1.1860 s (≤ 2 s) — **PASS**.
- **Deduplication:** the duplicate-heavy 200,000-host run (drawn from a
  1,000-host pool) is ~35× faster than the cold unique run, and the dedup proof
  confirms a 100,000-host all-repeated batch crosses into `punycoder` with **1**
  element and into the cpp11 matcher with **1** element — one normalization and
  one C++ call total, not one per duplicate.

## Cache memory footprint

The result cache is a key→integer-index environment (`psl_cache_env$idx`, a
hash table with one binding per distinct host) alongside parallel column vectors
(`R/cache.R`). Two figures matter, measured at 1k / 100k / 200k live entries (the
effective bound is `psl_cache_default_capacity` = 200,000):

| live entries | columnar `object.size()` (MB) | gc-delta retained heap (MB) |
|-------------:|------------------------------:|----------------------------:|
| 1,000        | 0.12                          | 0.9                         |
| 100,000      | 13.81                         | 58.6                        |
| 200,000      | 27.94                         | 113.6                       |

**Method and caveat.** The columnar figure sums `utils::object.size()` over the
column vectors and the index — but `object.size()` does **not** account for the
live `$idx` environment (the per-key hash-table bindings and their character
keys), so it materially undercounts real memory. The right-hand figure is a
**gc-delta retained-heap** measurement: in a fresh session, `gc(reset = TRUE)`,
read baseline used-Mb with the cache empty, populate to *N* entries via real
`registrable_domain()` queries, drop the input vector, then read used-Mb again
after a full `gc()` and report the delta. This captures the actual retained heap
including the environment index — roughly **~600 bytes/entry** at scale (vs the
~140 bytes/entry the columnar count implies). The gc-delta is a retained-heap
*proxy*, not a per-object profiler (it can over-attribute allocator/heap
overhead and is noisy at the 1k scale, near gc granularity); `lobstr::obj_size()`
would give a tighter per-object number but was unavailable on this machine.
It supersedes the earlier "~80 bytes/entry" claim, which came from the
environment-blind `object.size()` path.

## Cold bundled-index compatibility rebuild

Reported separately because it is a worst-case *activation* cost (re-parsing the
bundled `.dat` under the runtime normalizer and rebuilding the matcher when the
shipped index's normalization profile or Unicode version differs from the
runtime normalizer, PRD §8.3), not a per-query cost. It happens at most once per
session and only on a profile/Unicode mismatch.

- Cold rebuild: ~2.16 s on the reference machine.
