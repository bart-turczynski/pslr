# pslr (development version)

* New `options(pslr.cache = FALSE)` escape hatch disables the session result
  cache for the current session, skipping every cache read and write. It never
  changes a result -- misses are derived by the same code path -- so output is
  byte-identical to the cached path; it only controls whether entries are stored
  and read. Useful for one-shot batches of mostly-unique hosts, where within a
  single vectorized call `unique()` already deduplicates and the per-key cache
  read is pure overhead (roughly 1.5x faster with the cache off on a
  200,000-unique batch). Caching stays on by default.

## Internal

* Raised the default session-cache bound from 50,000 to 200,000 entries. The
  columnar store (from the P2-P4 rewrite) costs about 80 bytes per entry
  (~16 MB for a full 200,000-entry table) and memory scales with live entries,
  so small sessions pay nothing. The higher bound lets a large working set
  re-queried across calls stay warm instead of tripping the full-flush eviction
  cliff -- on a 200,000-unique benchmark the second pass drops from ~1.63 s
  (flush and re-derive) to ~0.83 s (a true cache hit). The full-flush eviction
  semantics above the bound are unchanged.

* The core C++ matcher (`psl_match()`) now also returns 1-based byte offsets
  into the canonical ASCII host (`ps_start` / `rd_start` / `ps1_start`). The R
  engine derives the public-suffix, registrable-domain, and rule strings for the
  whole miss vector at once with a single vectorized `substr()` per column,
  replacing the per-host `derive_one()`/`suffix_labels()` `paste()` loop (now
  removed). Pure internal restructuring; query results are byte-identical (the
  differential oracle is unchanged), but the miss-path string derivation is
  roughly 40x faster and drops out of the query profile.
* The session result cache is now columnar. Instead of one R list per host, it
  keeps a key -> integer-index environment alongside parallel column vectors
  (including the `ps_start` / `rd_start` byte offsets), grown by doubling. Cache
  hits resolve via a single `mget()` of indices plus vectorized column
  subsetting, and `psl_resolve_cores()` returns its columns directly, removing
  the six per-call `vapply()` reassembly passes over the whole unique-host list.
  Pure internal restructuring; the cache key semantics and the differential
  oracle are unchanged, but the warm-cache query path is dramatically faster.
* The shared per-element query builder (`psl_query_frame()`, now
  `psl_query_cols()`) returns a plain list of parallel column vectors instead of
  constructing a 12-column `data.frame` on every call. The length-preserving
  accessors (`public_suffix()` / `registrable_domain()` / `is_public_suffix()`)
  read the one or two columns they need directly; only `suffix_extract()` and
  `public_suffix_rule()` build a `data.frame`, once, at the end. `suffix_extract()`
  additionally drops its per-row `strsplit` loop, slicing the registrant label
  and subdomain out of the canonical host with vectorized `substr()` over the
  matcher's `ps_start` / `rd_start` byte offsets. Pure internal restructuring;
  query results and the differential oracle are unchanged, but the fixed
  per-call overhead falls sharply (warm scalar `registrable_domain()` roughly
  halves).

# pslr 1.0.2

## Internal

* Dropped the redundant `strict = TRUE` argument from `punycoder::host_normalize()`
  calls. `punycoder` removed the inert `strict` flag in favour of explicit
  UTS #46 flags (all defaulting to the strict profile), so the bare call is
  behavior-preserving and forward-compatible with that release. No user-visible
  change; this keeps `pslr` installable against the upcoming `punycoder` release.
* Refactored `psl_canonicalize()`, `parse_psl_lines()`, the core matcher
  resolution, and `psl_refresh()`/`psl_use()` into smaller helpers to clear
  `goodpractice` cyclomatic-complexity and function-length findings. Pure
  internal restructuring; no behavior or API change.

# pslr 1.0.1

Launch-readiness audit follow-ups (no API changes).

* `suffix_extract(output = "unicode")` no longer turns an empty subdomain into
  `NA`. An absent subdomain is reported as `""` for both `"ascii"` and
  `"unicode"` output, matching the documented schema.
* Choice-style option arguments (`section`, `output`, `unknown`, `invalid`, and
  `psl_use()`'s `source`) now abort when a caller supplies a non-scalar value,
  even one that happens to equal the formal's default vector (e.g.
  `invalid = c("na", "error")`). Previously such a call was mistaken for the
  untouched default and silently used the first choice. Omitted options still
  default to their first choice.
* A corrupt cache marker (`current.rds`) is now handled gracefully instead of
  leaking a raw `readRDS()` "unknown input format" error. `psl_refresh(force =
  TRUE)` ignores an unreadable marker and republishes a valid cache, and
  `psl_use("cache")` reports a pslr cache-corruption error with remediation.
* PSL sources with a repeated ICANN or PRIVATE section are now rejected. The
  official format carries exactly one complete section of each; a second
  `BEGIN` for either aborts the parse instead of loading both copies.
* A zero-length non-character `domain` (e.g. `numeric(0)`, `NULL`) now aborts
  with the documented type error instead of being silently coerced to an empty
  result. This is consistent with the input contract: a wrong argument type is
  a programming error regardless of length. The valid empty character vector
  `character(0)` still returns a zero-length result.

# pslr 1.0.0

First public release: a spec-complete Public Suffix List engine for R.

* Bundled the Public Suffix List snapshot pinned to upstream commit
  `9186eee` (list date 2026-06-13), with a deterministic `data-raw/`
  regeneration script, an internal validated rule index, generation metadata
  (commit, source URL, checksum, normalization profile, Unicode version), and
  MPL-2.0 data licensing separate from the package's MIT code license.
* Added the public query API: `public_suffix()`, `registrable_domain()`,
  `is_public_suffix()`, `suffix_extract()`, and `public_suffix_rule()`. All are
  vectorised, length- and name-preserving, NA-safe, and share the
  `section` / `output` / `unknown` / `invalid` policies. Input is canonicalized
  through `punycoder` with terminal-dot preservation and dotted-decimal IPv4
  literal rejection, and repeated queries are served from a bounded session
  cache keyed by host, active-list identity, and section.
* Added refresh and activation: `psl_refresh()`, `psl_use()`, `psl_version()`,
  and `psl_rules()`. `psl_refresh()` is the only network path -- an explicit,
  https-only, credential- and downgrade-redirect-rejecting download with a size
  ceiling, full validation, a 24-hour reuse throttle, and an atomic cache
  publish that never exposes a partial snapshot or replaces a valid cache after
  a failed refresh. `psl_use()` switches the session's active list between the
  bundled snapshot, the user cache, and a custom path, validating before any
  state changes and clearing the result cache on a successful switch. The
  bundled index is rebuilt in memory from source when its normalization profile
  or Unicode version differs from the runtime normalizer, never mixing profiles.
  `psl_version()` reports the active-list identity and runtime normalization
  identifiers needed to reproduce a result; `psl_rules()` exposes the active
  rule table.
* Canonical-host deduplication: a repeated host costs a single `punycoder`
  normalization and a single C++ matcher call regardless of multiplicity. A
  non-CRAN benchmark and its release gate live in `bench/benchmark.R`.
