## R CMD check results

0 errors | 0 warnings | 1 note

The NOTE is the incoming-feasibility spell-check flagging domain-vocabulary
terms in the Description (ICANN, PSL, eTLD, canonicalization, hostnames,
matcher, registrable). These are correct and intentional; they are also listed
in inst/WORDLIST.

## Changes in this version

This is a small maintenance update (1.0.1 -> 1.0.2) with no user-visible change.

* `pslr` no longer passes the `strict` argument to `punycoder::host_normalize()`.
  `punycoder` removed that (inert) argument in favour of explicit UTS #46 flags
  that default to the same strict profile, so the bare call is behavior-
  preserving. This keeps `pslr` installable against both the current `punycoder`
  (1.1.0) and its next release.

## Dependencies

* `pslr` imports `punycoder` (>= 1.1.0) for its canonical-host normalization
  (IDNA/Unicode) layer. The bare `host_normalize()` call works against
  `punycoder` 1.1.0 (on CRAN) and later, so the dependency floor is unchanged.

## Test environments

* local: macOS (aarch64), R 4.6.0 — `R CMD check --as-cran`
* GitHub Actions (`.github/workflows/full-check.yml`): macOS-latest (release),
  Windows-latest (release), Ubuntu-latest (R devel, release, oldrel-1), all with
  `--as-cran`.

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
