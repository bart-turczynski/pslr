## R CMD check results

0 errors | 0 warnings | 1 note

Measured on 2026-09-12 with `R CMD check --as-cran` on macOS aarch64 (R 4.6.0),
with 'punycoder' 1.2.1 -- the version CRAN serves -- resolved from an isolated
library, so the measurement is not taken against a development build installed
locally. `cran-comments.md` is in `.Rbuildignore`, so revisions to this file do
not change the tarball the measurement describes.

* `checking CRAN incoming feasibility` is expected to report the `BugReports:`
  address as a 404:

      Found the following (possibly) invalid URLs:
        URL: https://gitlab.com/bart-turczynski/pslr/-/issues
          From: DESCRIPTION
          Status: 404

  This is the address the incoming check itself asks for. GitLab has migrated
  issues to work items and answers `/-/issues` with 404 to any signed-out,
  non-browser client, on every project on the site: GitLab's own tracker,
  `https://gitlab.com/gitlab-org/gitlab/-/issues`, answers 404 identically. A
  browser is redirected (302) to `/-/work_items`, so the link works for a
  reader.

  No gitlab.com address clears both checks. The first 1.2.1 upload declared
  `/-/work_items`, which returns 200, and was archived at the pretest because
  `tools:::.check_package_CRAN_incoming()` accepts a gitlab.com `BugReports:`
  only when its path ends in `/-/issues`, and suggested that form. Every such
  path, with or without a query string, is the 404 above. The field now follows
  the check's suggestion, as the reverse dependency 'rurl' 3.0.1 does on CRAN.

## This is a resubmission

A first upload of 1.2.1 on 2026-09-12 was archived at the incoming pretest for a
single NOTE asking that `BugReports:` use `/-/issues` rather than `/-/work_items`;
that is done, as discussed above. No other file changed.

1.2.0 was archived at the incoming pretest on 2026-09-11 for two findings. Both
are addressed.

* **Overall checktime 11 min > 10 min**, mainly `checking tests ... [495s]`.

  The cause was a quadratic write pattern in the PSL parser, not test volume:
  `parse_psl_lines()` preallocated its rule columns and then wrote each row
  through a helper, which made the columns referenced twice and copied all of
  them on every rule. The writes are now in place, with byte-identical output
  and no behavior change.

  Measured on one machine, same isolated library, archived tarball versus this
  one: `checking tests` falls from `[105s/114s]` to `[21s/34s]`, and the whole
  check from 2m 19.7s to 1m 16.8s. That is a 5x reduction in the tests step
  rather than a hardware difference, so the 495s step should fall to roughly
  100-150s on CRAN's machines and the overall checktime well under the limit.
  No test was deleted, shortened or made conditional: the suite still runs
  2034 passing expectations.

* **`https://gitlab.com/bart-turczynski/pslr/-/issues`, status 404**, in
  `DESCRIPTION`. Unavoidable for a gitlab.com tracker, discussed above.

1.2.0 was never published, so this release reaches users as 1.1.1 -> 1.2.1 and
carries the whole 1.2.0 changelog. Both sections are kept in `NEWS.md`.

## Changes in this version

This is a feature release. It contains one breaking change and one bundled-data
update that changes query results; both are detailed below and in NEWS.md.

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

* Performance: parsing the Public Suffix List is roughly 7x faster;
  `read_psl_file()` drops from 11.97s to 1.69s on the bundled list.

* The built pkgdown site is no longer packaged. `_pkgdown.yml` writes to
  `site/`, which `.Rbuildignore` had not learned about, so generated
  documentation was being carried into the tarball.

* `URL` and `BugReports` moved from GitHub to GitLab. The GitHub account that
  hosted this package is suspended, so the previously declared homepage and bug
  tracker no longer resolve. `URL` is now the pkgdown site
  <https://bart-turczynski.gitlab.io/pslr/> and the GitLab repository, followed
  by the canonical CRAN and r-universe pages. All are public and were verified
  to resolve before submission.

## Platform

Tested locally on macOS aarch64 (R release) and on GitLab CI: Ubuntu, R devel /
release / oldrel-1. Windows and macOS coverage for this submission comes from
win-builder and the macOS builder rather than from CI, which is Linux-only
since the project moved off GitHub Actions.

## Reverse dependencies

The only CRAN reverse dependency is 'rurl', currently 3.0.1 (published
2026-09-09). It was checked against this submission -- `R CMD check --as-cran`
on `rurl_3.0.1.tar.gz` resolved against this pslr and 'punycoder' 1.2.1 returns
0 errors and no test failures.

'rurl' declares `pslr (>= 1.1.1)`, and neither the renamed `psl_snapshots()`
column nor `psl_diff()` is on any path it uses.

## Note on the 'punycoder' dependency

pslr's bundled index records the normalization profile it was generated under
and rebuilds in memory if the installed 'punycoder' reports a different one.
This release ships an index built under the 'punycoder' CRAN currently serves
(1.2.1), so no rebuild occurs for any user, and the examples run in well under a
second in total.

A future 'punycoder' will move its pinned Unicode version, at which point pslr
will rebuild on load -- correctly, and with a byte-identical rule set -- until a
subsequent pslr reships the index. Disclosed so it is not a surprise: measured
against that unreleased 'punycoder', the rebuild puts the `psl_diff` example at
roughly 8.5s, over the 5s threshold, so this package may begin drawing an
examples-timing NOTE on CRAN's machines once that 'punycoder' is published,
without pslr itself changing. A pslr release reshipping the index under the new
pin is already prepared for that point.

The `Imports` floor deliberately stays at `punycoder (>= 1.1.0)`: no behavior
here requires a newer one.
