# pslr (development version)

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
