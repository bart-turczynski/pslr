## R CMD check results

0 errors | 0 warnings | 1 note

The NOTE is the incoming-feasibility timing flag:

* Days since last update: 3

This is an intentionally small maintenance resubmission to keep `pslr`
installable with the current and upcoming `punycoder` API.

## Changes in this version

This is a small maintenance update (1.0.1 -> 1.0.2).

* `pslr` no longer passes the `strict` argument to `punycoder::host_normalize()`.
  `punycoder` removed that (inert) argument in favour of explicit UTS #46 flags
  that default to the same strict profile, so the bare call is behavior-
  preserving.
* The `punycoder` floor is raised to `>= 1.2.0` (the current release), matching
  the coordinated chain (see Dependencies). No user-visible behavior change in
  `pslr` itself.

## Dependencies

* `pslr` imports `punycoder` for its canonical-host normalization
  (IDNA/Unicode) layer. The floor tracks the current `punycoder` release,
  `punycoder (>= 1.2.0)`: the three packages are co-maintained and released
  together, so each requires the current release of its sibling rather than the
  oldest version at which a given call first worked.

**Coordinated submission order.** `punycoder`, `pslr`, and `rurl` form a
dependency chain and are submitted to CRAN **in this order** so each resolves
cleanly against versions already on CRAN:

1. **`punycoder` 1.2.0** — the base of the chain (no CRAN sibling dependency).
2. **`pslr` 1.0.2** — this package; imports `punycoder (>= 1.2.0)`. Submitted
   after `punycoder` 1.2.0 reaches CRAN so the floor resolves.
3. **`rurl` 2.2.0** — imports both `punycoder (>= 1.2.0)` and `pslr (>= 1.0.2)`;
   submitted last, once both are on CRAN.

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
