## R CMD check results

0 errors | 0 warnings | 2 notes

Both notes were measured on 2026-09-10 with `R CMD check --as-cran` against the
submitted tarball, built with `R CMD build` from a clean `git archive` export of
the release commit `ac68982` -- not from a working tree.

* `checking CRAN incoming feasibility` reports one possibly invalid URL,
  `https://gitlab.com/bart-turczynski/pslr/-/issues`, the `BugReports:` field,
  status 404. The tracker is public and open. GitLab has migrated issues to work
  items and returns 404 on the legacy `/-/issues` path for signed-out clients on
  every project on the site; the sibling path `/-/work_items` returns 200 to the
  same anonymous scripted client, as does the repository root. Re-measured
  2026-09-10 against `gitlab.com/gitlab-org/gitlab` as a control, which answers
  identically. A browser follows the redirect, which is why the page loads by
  hand. The address is the one users need and it is not dropped; repointing
  `BugReports:` at `/-/work_items` is deferred to the next release cycle rather
  than made at submission time, because GitLab's migration is still in progress.

* `checking examples` reports `psl_diff` at 8.3s elapsed, over the 5s threshold.
  `psl_diff()` is new in this version, and two of its three example calls diff
  against the bundled Public Suffix List, whose snapshot this release grows from
  10212 rules to 10323; parsing that list is the whole of the cost. Measured
  per call on the submission machine: the two small on-disk lists diff in 0.05s,
  `psl_diff("bundled", "bundled")` takes 6.3s and the provenance call
  `psl_diff("bundled", old)` 3.1s. The examples are correct and deliberately
  left runnable -- this package wraps no example in `\donttest{}` -- so the cost
  is real work a user's first call also pays, not setup overhead.

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

  Note for the URL check: this is the 404 explained under "R CMD check
  results" above. It is site-wide legacy-path behavior at GitLab, not a broken
  address.

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
