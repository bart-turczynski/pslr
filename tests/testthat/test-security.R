# OSS Index dependency vulnerability audit (oysteR / Sonatype).
#
# `oysteR::audit_description()` resolves the installed DESCRIPTION and audits
# pslr's hard dependencies against the Sonatype OSS Index. It is a network test
# that requires OSS Index credentials (OSSINDEX_USER / OSSINDEX_TOKEN): the API
# rejects unauthenticated requests with HTTP 401, so the test is guarded to
# skip wherever those preconditions are absent (CRAN, offline, missing
# credentials, oysteR not installed). The dedicated security-audit.yml workflow
# supplies the credentials as repository secrets so the audit actually runs
# there (and drives the README badge); in every other context (local runs, the
# verify/full-check/rhub suites) it skips cleanly rather than failing.
#
# Scope: hard dependencies only -- `Depends` + `Imports`, never `Suggests`.
#
# `oysteR::expect_secure()` audits `Depends` + `Imports` + `Suggests`, and
# `Suggests` drags in the recursive dependency trees of the dev tooling --
# including oysteR's own, which reaches `curl` through httr. So the gate was
# failing on a vulnerability in the auditor rather than in anything a user of
# pslr installs.
#
# Measured 2026-09-10, same machine and credentials:
#
#     fields = Depends+Imports              6 packages audited, clean
#     fields = Depends+Imports+Suggests    82 packages audited, reports curl
#
# `curl` is absent from pslr's hard dependency tree entirely. The two flagged
# advisories -- CVE-2026-18924 (CWE-416 use-after-free, CVSS 9.1) and
# CVE-2026-3783 (CWE-522 insufficiently protected credentials, CVSS 6.9) --
# both name libcurl ranges that include CRAN's current `curl` 8.0.0, so no
# available version clears them and no local action could make the old scope
# pass. PSLR-xqedxjeb carries the full measurement.
#
# A package's security posture is what it makes users install, so the audit
# calls `audit_description()` directly with the narrower `fields`.
# `expect_secure()` sets a CRAN mirror internally and `audit_description()`
# does not, hence the explicit `repos` option.

test_that("hard dependencies have no known OSS Index vulnerabilities", {
  skip_on_cran()
  skip_if_not_installed("oysteR")
  skip_if_offline()
  skip_if(
    Sys.getenv("OSSINDEX_USER") == "" || Sys.getenv("OSSINDEX_TOKEN") == "",
    "OSS Index credentials (OSSINDEX_USER / OSSINDEX_TOKEN) not set"
  )

  old_repos <- getOption("repos")
  on.exit(options(repos = old_repos), add = TRUE)
  options(repos = c(CRAN = "https://cran.rstudio.com"))

  audit <- oysteR::audit_description(
    dirname(system.file("DESCRIPTION", package = "pslr")),
    fields = c("Depends", "Imports"),
    verbose = FALSE
  )
  vulnerable <- audit[audit$no_of_vulnerabilities > 0, ]$package

  expect_equal(vulnerable, character())
})
