# Changelog

## pslr 1.0.2

### Internal

- Dropped the redundant `strict = TRUE` argument from
  [`punycoder::host_normalize()`](https://rdrr.io/pkg/punycoder/man/host_normalize.html)
  calls. `punycoder` removed the inert `strict` flag in favour of
  explicit UTS [\#46](https://github.com/bart-turczynski/pslr/issues/46)
  flags (all defaulting to the strict profile), so the bare call is
  behavior-preserving and forward-compatible with that release. No
  user-visible change; this keeps `pslr` installable against the
  upcoming `punycoder` release.

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
