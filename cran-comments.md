## Resubmission

This resubmits 1.2.2 with one change, as Uwe Ligges suggested on
2026-10-23: `BugReports:` now names
https://gitlab.com/bart-turczynski/pslr/-/work_items instead of
`/-/issues`, which returned 404 to the URL check. The R code, C++
sources, tests and documentation are unchanged.

## R CMD check results

0 errors | 0 warnings | 1 note

Measured on 2026-10-24 with `R CMD check --as-cran` on the resubmitted
tarball on macOS aarch64 (R 4.6.1), with the remote incoming checks on
against https://cloud.r-project.org, and 'punycoder' 1.3.0 from CRAN. The
test suite ran in 25s. No URL is reported as invalid.

* `checking CRAN incoming feasibility`:

      The BugReports field in DESCRIPTION has
        https://gitlab.com/bart-turczynski/pslr/-/work_items
      which should likely be
        https://gitlab.com/bart-turczynski/pslr/-/work_items/issues
      instead.

  This is the NOTE Uwe Ligges described on 2026-10-23 as a bug in the
  check for GitLab. On gitlab.com, `/-/work_items` answers 200 to any
  client, while `/-/issues` answers 404 to a client that does not ask for
  HTML, `tools::check_url_db()` included, and redirects a browser to
  `/-/work_items`.

## Test environments

These ran on the first 1.2.2 upload. This tarball changes only
`DESCRIPTION` metadata (`BugReports:` and the roxygen2 version field) and
two maintainer scripts under `tools/`.

* win-builder: R-devel (2026-10-21 r90733), R 4.6.1 and R 4.5.3: 1 NOTE each,
  the `BugReports:` `/-/issues` 404 this resubmission removes.
* macOS builder: R 4.6.1, macOS 26.6 arm64: Status OK.
* R-hub: Linux, macOS arm64, clang ASAN, clang UBSAN, valgrind and rchk
  (R-devel): OK.

## Reason for this release

1.2.1 cannot load its bundled Public Suffix List under a Turkish or
Azerbaijani locale on glibc: base R's `tolower("I")` there is the dotless
"ı", so the section marker "ICANN" no longer matched and loading failed with
"subscript out of bounds". Every package that queries pslr, 'rurl' included,
failed in such a session. pslr now lowercases ASCII only. A package being
prepared for CRAN depends on this fix, which is why this release follows 1.2.1
after about six weeks.

## Changes in this version

A bug-fix release with no API change and no change to the bundled list.

* The bundled list loads, and lowercase comparisons hold, under a Turkish or
  Azerbaijani locale.
* The bundled index is rebuilt under 'punycoder' 1.3.0, and `Imports:` now
  requires `punycoder (>= 1.3.0)`. Under 1.3.0's new normalization profile,
  1.2.1 rebuilt its index on every load.
* Fixes to how `psl_refresh()` and the on-disk cache handle checksums, `ETag`
  values, response headers and error messages that are not valid UTF-8, or not
  in lower case.
* A new vignette compares pslr with other Public Suffix List libraries.
* 'cucumber' is no longer in `Suggests`.

## Reverse dependencies

The only direct CRAN reverse dependency is 'rurl' 3.1.0, which imports pslr.
'pagerankr' 0.1.1 depends on pslr through 'rurl'. Both were checked with
`R CMD check --as-cran` (incoming checks off) on their CRAN tarballs, against this pslr and CRAN's
'punycoder' 1.3.0: each returned Status OK, with no test failures.
