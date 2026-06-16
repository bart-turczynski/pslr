## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new submission.

The remaining NOTE is the expected "New submission" note for a first submission.

## Dependencies

* `pslr` imports `punycoder` (>= 1.1.0) for its canonical-host normalization
  (IDNA/Unicode) layer. `punycoder` 1.1.0 is on CRAN, so the dependency resolves
  from CRAN with no `Remotes` field.

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

None — this is a new package.
