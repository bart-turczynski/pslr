## R CMD check results

0 errors | 0 warnings | 1 note

Measured on 2026-10-22 with `R CMD check --as-cran` on the 1.2.2 tarball on
macOS aarch64 (R 4.6.1), with the remote incoming checks on, against a
library holding only the versions CRAN serves today, 'punycoder' 1.3.0 among
them. The test suite ran in 25s. A second `R CMD check`, against 'punycoder'
1.3.0 built from source with libidn2 2.3.8 as on CRAN's Debian flavors,
returned Status OK.

## Test environments

* win-builder: R-devel (2026-10-21 r90733), R 4.6.1 and R 4.5.3: 1 NOTE each,
  the `BugReports:` 404 below.
* macOS builder: R 4.6.1, macOS 26.6 arm64: Status OK.
* R-hub: Linux, macOS arm64, clang ASAN, clang UBSAN, valgrind and rchk
  (R-devel): OK.

* `checking CRAN incoming feasibility` reports the `BugReports:` address as a
  404:

      Found the following (possibly) invalid URLs:
        URL: https://gitlab.com/bart-turczynski/pslr/-/issues
          From: DESCRIPTION
          Status: 404

  This is the form the incoming check asks for on gitlab.com, and it is the
  same address 1.2.1 was accepted with. GitLab now serves issues as work items
  and answers `/-/issues` with 404 to any signed-out, non-browser client, on
  every project on the site; a browser is redirected (302) to `/-/work_items`,
  so the link works for a reader. The previous submission's comments explain
  why no gitlab.com address clears both checks.

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
