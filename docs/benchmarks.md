# Performance benchmarks

This file records reference results for the non-CRAN benchmark
([`bench/benchmark.R`](../bench/benchmark.R)), per PRD §11.4. The benchmark is
excluded from the package build and the test suite because shared CI and CRAN
timing are not stable; the timing threshold is a **release gate** the maintainer
runs locally before tagging a release, not a unit test.

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

- Date: 2026-06-15
- Machine: Apple Silicon (aarch64-apple-darwin23)
- R: 4.6.0
- punycoder: 1.1.0

Query, post-initialization, ASCII output, median elapsed seconds over 5 runs:

| hosts   | variant  | seconds |
|--------:|:---------|--------:|
| 1       | unique   | 0.0020  |
| 1       | repeated | 0.0020  |
| 1,000   | unique   | 0.0260  |
| 1,000   | repeated | 0.0020  |
| 100,000 | unique   | 0.9330  |
| 100,000 | repeated | 0.0500  |

- **Release gate:** 100,000 unique ASCII = 0.93 s (≤ 2 s) — **PASS**.
- **Deduplication:** the 100,000-host *repeated* run is ~19× faster than the
  unique run, and the dedup proof confirms the 100,000-host repeated batch
  crosses into `punycoder` with **1** element and into the cpp11 matcher with
  **1** element — one normalization and one C++ call total, not one per
  duplicate.

## Cold bundled-index compatibility rebuild

Reported separately because it is a worst-case *activation* cost (re-parsing the
bundled `.dat` under the runtime normalizer and rebuilding the matcher when the
shipped index's normalization profile or Unicode version differs from the
runtime normalizer, PRD §8.3), not a per-query cost. It happens at most once per
session and only on a profile/Unicode mismatch.

- Cold rebuild: ~2.35 s on the reference machine.
