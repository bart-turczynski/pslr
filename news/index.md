# Changelog

## pslr (development version)

- `output = "unicode"` now decodes each distinct A-label only once per
  call –
  [`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md)
  pools its five columns into a single
  [`punycoder::puny_decode()`](https://bart-turczynski.github.io/punycoder/reference/puny_decode.html)
  crossing and every query deduplicates repeats – so unicode output on
  batches with repeated or overlapping hosts is markedly faster; decoded
  output is byte-identical (PSLR-cpzrjksw).

- Every query no longer pays for a per-call
  [`strsplit()`](https://rdrr.io/r/base/strsplit.html) to count host
  labels;
  [`is_public_suffix()`](https://bart-turczynski.github.io/pslr/reference/is_public_suffix.md)
  now reads the matcher’s `ps_start` offset, which is equivalent, so
  results are unchanged (PSLR-rriiajin).

- The session result cache now pre-sizes its key index to the incoming
  unique-batch size, so a large cold batch fills a right-sized hash
  table in one shot instead of rehashing repeatedly during insertion;
  results are unchanged (PSLR-gtvggjmd).

- The PSL-format parser now preallocates its rule columns and fills them
  by index instead of growing them one accepted rule at a time, making a
  full list rebuild roughly 3x faster; output is byte-identical
  (PSLR-wanopbqy).

- New
  [`psl_cache_prune()`](https://bart-turczynski.github.io/pslr/reference/psl_cache_prune.md)
  removes superseded on-disk `psl-<hex>.dat` cache snapshots, always
  keeping the active snapshot plus the `keep` most-recent others
  (default one previous); a no-op when there is no cache or marker
  (PSLR-nwdejhkf).

- Cache checksum verification now recomputes the algorithm named by the
  recorded `sha256:`/`md5:` prefix instead of whichever hash `digest`
  availability picks at call time, so a cache is no longer spuriously
  reported as corrupt across machines that differ in the optional
  `digest` package; a missing `digest` for an `sha256`-recorded cache
  now raises an actionable install error rather than a corruption error
  (PSLR-mxohlxiq).

- The cache commit marker is now structurally validated when read, so a
  readable-but-malformed `current.rds` (missing `dat_file`, a short
  `meta`, or wrong field types) raises the actionable cache-corruption
  error advising `psl_refresh(force = TRUE)` instead of degrading into
  silent `NULL` reads; newly written markers carry a schema version and
  markers from earlier releases stay valid (PSLR-nwdejhkf).

- The `punycoder` dependency floor is raised to `>= 1.2.0`, the current
  release; `pslr`, `punycoder`, and `rurl` are co-maintained and each
  requires the current release of its sibling
  ([\#70](https://github.com/bart-turczynski/pslr/issues/70)).

- New
  [`psl_outdated()`](https://bart-turczynski.github.io/pslr/reference/psl_outdated.md)
  reports whether the active list snapshot is older than a threshold
  (default 180 days), purely offline from
  [`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)’s
  `list_date`, as a nudge toward
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md);
  the snapshot age in days is returned in the `"age_days"` attribute
  ([\#62](https://github.com/bart-turczynski/pslr/issues/62)).

- New `options(pslr.cache = FALSE)` escape hatch disables the session
  result cache for the current session, skipping every cache read and
  write. It never changes a result – misses are derived by the same code
  path – so output is byte-identical to the cached path; it only
  controls whether entries are stored and read. Useful for one-shot
  batches of mostly-unique hosts, where within a single vectorized call
  [`unique()`](https://rdrr.io/r/base/unique.html) already deduplicates
  and the per-key cache read is pure overhead (roughly 1.5x faster with
  the cache off on a 200,000-unique batch). Caching stays on by default.

### Internal

- The global query functions now resolve a single process-wide default
  engine via `psl_default_engine()` and thread it explicitly through the
  internal match/cache path (`psl_query_cols` -\> `psl_resolve_cores`
  -\> `psl_match_records`), replacing the implicit global-state fetch;
  [`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
  and the refresh activation paths replace that default engine. Public
  signatures and behaviour are byte-identical (PSLR-cchcomkk).

- Moved result-cache ownership into the `psl_engine`: each engine mints
  its own `new_psl_cache()`, so activating a list swaps the whole engine
  (starting cold) instead of clearing a shared global, and the cache key
  drops the now-redundant list-identity prefix (keyed on section +
  canonical host); public behaviour is byte-identical, with new
  engine-cache isolation tests (PSLR-bcgedhmy).

- Modelled the active-list state as internal `psl_snapshot` (rules +
  metadata + source identity) and process-local `psl_engine` (snapshot +
  compiled matcher) objects, and unified the two cache-activation paths
  onto a shared `psl_load_cached_snapshot()` loader behind a single
  `psl_activate_snapshot()` choke-point; internal only, public behaviour
  byte-identical (PSLR-fvotbdti).

- The five public query functions and
  [`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md)
  now carry scalar formal defaults validated by an internal
  `check_choice()`, dropping the
  [`missing()`](https://rdrr.io/r/base/missing.html)-based supplied-flag
  bookkeeping; argument handling and every result and error are
  unchanged (PSLR-adsnjbjg).

- Consolidated the snapshot-metadata field schema behind a single owner:
  `new_psl_meta()` (construction/defaults), `validate_psl_meta()`
  (checked boundary), and `as_psl_version_df()` (the one-row
  [`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
  frame) all read one `psl_meta_fields` schema, replacing the field
  lists that were re-spelled in `R/matcher.R`, `R/metadata.R`, and
  `data-raw/update_psl.R`; output is byte-identical (PSLR-bnrbjhur).

- Consolidated the two overlapping benchmark scripts into a single
  authoritative harness under `bench/` (shared fixtures/timing in
  `bench/helpers.R`), removed the unreferenced
  `inst/bench/match-bench.R`, and fixed two integrity defects: the
  “unique” corpus is now deterministic and exactly-n distinct (via the
  internal, unit-tested `psl_bench_unique_hosts()`), and every scenario
  resets its intended cache state inside each timed rep so a cold
  measurement is no longer contaminated by the previous rep’s warm cache
  (PSLR-cefytpjr).

- Raised test coverage from 96% to 100% by exercising the
  previously-uncovered error and fallback branches across `refresh.R`,
  `matcher.R`, `cache.R`, `canonicalize.R`, `duplicates.R`, and
  `parser.R` (mocked downloader/`digest`/`curl`/`system.file` seams,
  crafted inputs); the one unreachable C++ epilogue brace in
  `matcher.cpp` is excluded with a `# nocov` marker. No behaviour
  change; the differential oracle is unchanged
  ([\#66](https://github.com/bart-turczynski/pslr/issues/66)).

- Collapsed the repeated `section`/`unknown`/`invalid` option-validation
  preamble across the five exported query functions into a shared
  `resolve_common_opts()` helper, factored
  [`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md)’s
  byte-offset slicing into `psl_slice_registrant()`, and drove
  `psl_query_cols()`’s eight match columns off the shared schema
  (reusing `psl_match_alloc()`, now `NA`-filled). Clears the remaining
  `goodpractice` function-length findings for `R/query.R`; results are
  byte-identical (oracle unchanged)
  ([\#65](https://github.com/bart-turczynski/pslr/issues/65)).

- Drove `psl_resolve_cores()`’s eight parallel match columns off the
  shared cache schema (`psl_cache_cols`) instead of spelling each column
  out four times, and factored the cache-index lookup into
  `psl_cache_lookup()`. Clears the `goodpractice` function-length
  finding; results are byte-identical (oracle and cache tests unchanged)
  ([\#64](https://github.com/bart-turczynski/pslr/issues/64)).

- Raised the default session-cache bound from 50,000 to 200,000 entries.
  The columnar store (from the P2-P4 rewrite) costs about 80 bytes per
  entry (~16 MB for a full 200,000-entry table) and memory scales with
  live entries, so small sessions pay nothing. The higher bound lets a
  large working set re-queried across calls stay warm instead of
  tripping the full-flush eviction cliff – on a 200,000-unique benchmark
  the second pass drops from ~1.63 s (flush and re-derive) to ~0.83 s (a
  true cache hit). The full-flush eviction semantics above the bound are
  unchanged.

- The core C++ matcher (`psl_match()`) now also returns 1-based byte
  offsets into the canonical ASCII host (`ps_start` / `rd_start` /
  `ps1_start`). The R engine derives the public-suffix,
  registrable-domain, and rule strings for the whole miss vector at once
  with a single vectorized
  [`substr()`](https://rdrr.io/r/base/substr.html) per column, replacing
  the per-host `derive_one()`/`suffix_labels()`
  [`paste()`](https://rdrr.io/r/base/paste.html) loop (now removed).
  Pure internal restructuring; query results are byte-identical (the
  differential oracle is unchanged), but the miss-path string derivation
  is roughly 40x faster and drops out of the query profile.

- The session result cache is now columnar. Instead of one R list per
  host, it keeps a key -\> integer-index environment alongside parallel
  column vectors (including the `ps_start` / `rd_start` byte offsets),
  grown by doubling. Cache hits resolve via a single
  [`mget()`](https://rdrr.io/r/base/get.html) of indices plus vectorized
  column subsetting, and `psl_resolve_cores()` returns its columns
  directly, removing the six per-call
  [`vapply()`](https://rdrr.io/r/base/lapply.html) reassembly passes
  over the whole unique-host list. Pure internal restructuring; the
  cache key semantics and the differential oracle are unchanged, but the
  warm-cache query path is dramatically faster.

- The shared per-element query builder (`psl_query_frame()`, now
  `psl_query_cols()`) returns a plain list of parallel column vectors
  instead of constructing a 12-column `data.frame` on every call. The
  length-preserving accessors
  ([`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md)
  /
  [`registrable_domain()`](https://bart-turczynski.github.io/pslr/reference/registrable_domain.md)
  /
  [`is_public_suffix()`](https://bart-turczynski.github.io/pslr/reference/is_public_suffix.md))
  read the one or two columns they need directly; only
  [`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md)
  and
  [`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md)
  build a `data.frame`, once, at the end.
  [`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md)
  additionally drops its per-row `strsplit` loop, slicing the registrant
  label and subdomain out of the canonical host with vectorized
  [`substr()`](https://rdrr.io/r/base/substr.html) over the matcher’s
  `ps_start` / `rd_start` byte offsets. Pure internal restructuring;
  query results and the differential oracle are unchanged, but the fixed
  per-call overhead falls sharply (warm scalar
  [`registrable_domain()`](https://bart-turczynski.github.io/pslr/reference/registrable_domain.md)
  roughly halves).

## pslr 1.0.2

### Internal

- Dropped the redundant `strict = TRUE` argument from
  [`punycoder::host_normalize()`](https://bart-turczynski.github.io/punycoder/reference/host_normalize.html)
  calls. `punycoder` removed the inert `strict` flag in favour of
  explicit UTS [\#46](https://github.com/bart-turczynski/pslr/issues/46)
  flags (all defaulting to the strict profile), so the bare call is
  behavior-preserving and forward-compatible with that release. No
  user-visible change; this keeps `pslr` installable against the
  upcoming `punycoder` release.
- Refactored `psl_canonicalize()`, `parse_psl_lines()`, the core matcher
  resolution, and
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)/[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
  into smaller helpers to clear `goodpractice` cyclomatic-complexity and
  function-length findings. Pure internal restructuring; no behavior or
  API change.

## pslr 1.0.1

CRAN release: 2026-06-22

Launch-readiness audit follow-ups (no API changes).

- `suffix_extract(output = "unicode")` no longer turns an empty
  subdomain into `NA`. An absent subdomain is reported as `""` for both
  `"ascii"` and `"unicode"` output, matching the documented schema.
- Choice-style option arguments (`section`, `output`, `unknown`,
  `invalid`, and
  [`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)’s
  `source`) now abort when a caller supplies a non-scalar value, even
  one that happens to equal the formal’s default vector (e.g.
  `invalid = c("na", "error")`). Previously such a call was mistaken for
  the untouched default and silently used the first choice. Omitted
  options still default to their first choice.
- A corrupt cache marker (`current.rds`) is now handled gracefully
  instead of leaking a raw
  [`readRDS()`](https://rdrr.io/r/base/readRDS.html) “unknown input
  format” error. `psl_refresh(force = TRUE)` ignores an unreadable
  marker and republishes a valid cache, and `psl_use("cache")` reports a
  pslr cache-corruption error with remediation.
- PSL sources with a repeated ICANN or PRIVATE section are now rejected.
  The official format carries exactly one complete section of each; a
  second `BEGIN` for either aborts the parse instead of loading both
  copies.
- A zero-length non-character `domain` (e.g. `numeric(0)`, `NULL`) now
  aborts with the documented type error instead of being silently
  coerced to an empty result. This is consistent with the input
  contract: a wrong argument type is a programming error regardless of
  length. The valid empty character vector `character(0)` still returns
  a zero-length result.

## pslr 1.0.0

First public release: a spec-complete Public Suffix List engine for R.

- Bundled the Public Suffix List snapshot pinned to upstream commit
  `9186eee` (list date 2026-06-13), with a deterministic `data-raw/`
  regeneration script, an internal validated rule index, generation
  metadata (commit, source URL, checksum, normalization profile, Unicode
  version), and MPL-2.0 data licensing separate from the package’s MIT
  code license.
- Added the public query API:
  [`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md),
  [`registrable_domain()`](https://bart-turczynski.github.io/pslr/reference/registrable_domain.md),
  [`is_public_suffix()`](https://bart-turczynski.github.io/pslr/reference/is_public_suffix.md),
  [`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md),
  and
  [`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md).
  All are vectorised, length- and name-preserving, NA-safe, and share
  the `section` / `output` / `unknown` / `invalid` policies. Input is
  canonicalized through `punycoder` with terminal-dot preservation and
  dotted-decimal IPv4 literal rejection, and repeated queries are served
  from a bounded session cache keyed by host, active-list identity, and
  section.
- Added refresh and activation:
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md),
  [`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md),
  [`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md),
  and
  [`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md).
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)
  is the only network path – an explicit, https-only, credential- and
  downgrade-redirect-rejecting download with a size ceiling, full
  validation, a 24-hour reuse throttle, and an atomic cache publish that
  never exposes a partial snapshot or replaces a valid cache after a
  failed refresh.
  [`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
  switches the session’s active list between the bundled snapshot, the
  user cache, and a custom path, validating before any state changes and
  clearing the result cache on a successful switch. The bundled index is
  rebuilt in memory from source when its normalization profile or
  Unicode version differs from the runtime normalizer, never mixing
  profiles.
  [`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
  reports the active-list identity and runtime normalization identifiers
  needed to reproduce a result;
  [`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md)
  exposes the active rule table.
- Canonical-host deduplication: a repeated host costs a single
  `punycoder` normalization and a single C++ matcher call regardless of
  multiplicity. A non-CRAN benchmark and its release gate live in
  `bench/benchmark.R`.
