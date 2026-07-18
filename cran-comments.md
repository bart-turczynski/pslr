## R CMD check results

0 errors | 0 warnings | 1 note

The NOTE is an incoming-feasibility maintainer-email change, from
`bartek+pslr@turczynski.pl` to `bartek@turczynski.pl`. This is the same
maintainer (Bart Turczynski, ORCID 0000-0002-8788-7980); the address was
normalized to drop the per-package plus-tag alias. No change of person or
organization.

## Changes in this version

This is a feature-and-compatibility release (1.0.1 -> 1.1.1). The intervening
1.0.2 and 1.1.0 versions were tagged during development but never submitted to
CRAN, so their changes ship here. Highlights:

* The core matcher is now a reverse-label trie (one right-to-left label descent
  per host), roughly halving direct-match time; results are byte-identical.
* New `psl_engine()` builds a self-contained, process-local PSL engine, and the
  five query functions gain an optional `engine=` argument to query a specific
  snapshot without touching session-global state.
* New offline helpers `psl_outdated()`, `psl_cache_prune()`, and an
  `options(pslr.cache = FALSE)` escape hatch.
* **Dependency floor lowered to `punycoder (>= 1.1.0)`** — the current CRAN
  `punycoder` release — and the development `Remotes:` field is removed, so
  `pslr` now resolves entirely from CRAN. `pslr` calls only `punycoder` API
  present since 1.1.0 and is forward-compatible with the upcoming `punycoder`
  1.2.x, whose default `host_normalize()` output is byte-identical.

## Dependencies

* `pslr` imports `punycoder` for its canonical-host normalization (IDNA/Unicode)
  layer. The floor is `punycoder (>= 1.1.0)`, the current CRAN release, so the
  import resolves against CRAN with no development remotes.

**Coordinated submission order.** `pslr`, `punycoder`, and `rurl` are
co-maintained. This `pslr` release deliberately requires only the current CRAN
`punycoder`, so it is submitted **first** and installs cleanly today. The sibling
releases (`punycoder` 1.2.1, then `rurl` 2.7.0) follow, each after the preceding
package is live on CRAN.

## Test environments

* local: macOS (aarch64), R 4.6.0 — `R CMD check --as-cran`
* GitHub Actions (`.github/workflows/full-check.yml`): macOS-latest (release),
  Windows-latest (release), Ubuntu-latest (R devel, release, oldrel-1), all with
  `--as-cran`.
* R-hub is configured through `.github/workflows/rhub.yaml`. Local release
  checks can be launched with:
  `rhub::rhub_check("https://github.com/bart-turczynski/pslr")`.

## Portability

* The matcher is compiled with `cpp11` and links no external system library.
* Host normalization is delegated to `punycoder`. `punycoder` works with or
  without the optional `libidn2` system library; when `libidn2` is absent it
  uses a bundled fallback backend. The Windows CI configuration builds
  `punycoder` from source without `libidn2`, so the continuously tested Windows
  job exercises the fallback backend, and `pslr`'s full normalization and query
  suite passes against it.

## Network use

* No network access occurs during package load, examples, tests, or any query.
* The only function that accesses the network is `psl_refresh()`, and only when
  called explicitly. It is HTTPS-only, rejects embedded credentials and
  downgrade redirects, and enforces a source-size ceiling. Its examples are
  wrapped in `\dontrun{}` and its tests use an injected downloader, so the check
  is fully offline.

## Downstream dependencies

None on CRAN.
