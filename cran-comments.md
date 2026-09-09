## R CMD check results

0 errors | 0 warnings | 0 notes

## Changes in this version

This is a feature release (1.1.1 -> 1.2.0). It contains one breaking change and
one bundled-data update that changes query results; both are detailed below and
in NEWS.md.

* Breaking: `psl_snapshots()`'s `normalization_profile` column is renamed
  `first_normalization_profile` and documented as first-publication provenance.
  A snapshot descriptor records the normalizer installed when those bytes were
  first published, but pslr re-parses source bytes under the *runtime*
  normalizer at every load, so the inventory could report a profile that was no
  longer in use anywhere, contradicting `psl_version()` about the same active
  snapshot in the same session. Query results are unaffected.

* Data: the bundled Public Suffix List snapshot moves from upstream commit
  `9186eeed` (2026-06-13) to `46ae48ce` (2026-09-05), a net +140 / -29 rules,
  10212 to 10323. This changes query results for real domains. The official
  upstream test vectors are unchanged between the two commits and still pass.

* New: `psl_diff(old, new)` reports rules added, removed or changed between two
  locally available snapshots. It resolves no dates, downloads nothing, and
  activates neither side.

* The built pkgdown site is no longer packaged. `_pkgdown.yml` writes to
  `site/`, which `.Rbuildignore` had not learned about, so generated
  documentation was being carried into the tarball.

* `URL` and `BugReports` moved from GitHub to GitLab. The GitHub account that
  hosted this package is suspended, so the previously declared homepage and bug
  tracker no longer resolve. `URL` is now the pkgdown site
  <https://bart-turczynski.gitlab.io/pslr/> and the GitLab repository, followed
  by the canonical CRAN and r-universe pages; `BugReports` is the GitLab issue
  tracker. All are public and were verified to resolve before submission.

  Note for the URL check: GitLab returns HTTP 404 on `/-/issues` for
  unauthenticated clients across the whole site, not only for this project --
  <https://gitlab.com/gitlab-org/gitlab/-/issues> behaves identically. The
  tracker is public and reachable in a browser.

## Platform

Tested locally on macOS aarch64 (R release) and on GitLab CI: Ubuntu, R devel /
release / oldrel-1. Windows and macOS coverage for this submission comes from
win-builder and the macOS builder rather than from CI, which is Linux-only
since the project moved off GitHub Actions.

## Reverse dependencies

The only CRAN reverse dependency is 'rurl', currently 3.0.1 (published
2026-09-09). It was checked against this submission -- `R CMD check` on
`rurl_3.0.1.tar.gz` resolved against pslr 1.2.0 and punycoder 1.2.1 returns
`Status: OK`, no errors, warnings or notes.

'rurl' declares `pslr (>= 1.1.1)`, and neither the renamed `psl_snapshots()`
column nor `psl_diff()` is on any path it uses.

## Note on the 'punycoder' dependency

pslr's bundled index records the normalization profile it was generated under
and rebuilds in memory if the installed 'punycoder' reports a different one.
This release ships an index built under the 'punycoder' CRAN currently serves
(1.2.1), so no rebuild occurs for any user. A future 'punycoder' will move its
pinned Unicode version, at which point pslr will rebuild on load -- correctly,
and with a byte-identical rule set -- until a subsequent pslr reships the index.
The `Imports` floor deliberately stays at `punycoder (>= 1.1.0)`: no behavior
here requires a newer one.
