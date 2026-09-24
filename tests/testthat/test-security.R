# OSS Index dependency vulnerability audit (oysteR / Sonatype).
#
# `oysteR::audit_description()` resolves the installed DESCRIPTION and audits
# pslr's hard dependencies against the Sonatype OSS Index. It is a network test
# that requires OSS Index credentials (OSSINDEX_USER / OSSINDEX_TOKEN): the API
# rejects unauthenticated requests with HTTP 401.
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
#
# The contract is "every reported advisory has a current, explicit
# disposition": the allow-list and the rules that keep it honest are in
# helper-security.R (SEOR-fftbjnpl).
#
# WHERE THIS RUNS, AND WHY THE PRECONDITIONS ARE NOT ALWAYS SKIPS.
#
# Everywhere ordinary -- a local `testthat::test_local()`, a plain
# `R CMD check --as-cran` -- a missing precondition is a skip. That is right: a
# developer without OSS Index credentials is not a security regression.
#
# Where the audit is the point, it is not right. A skip there reports success
# having audited nothing, and a green result that audited nothing is worse than
# no result, because it answers a question it was never asked (the failure
# `PUNY-rsxtbbln` records in punycoder). pslr has two such places, and both set
# OSSINDEX_AUDIT_REQUIRED=true, under which every precondition below becomes a
# hard failure with a message naming what is missing:
#
#   - the `security-audit` job in .gitlab-ci.yml, inside the CRAN_PREP gate;
#   - the `full` (and so `cran`) tier of tools/verify.sh, which replaced the
#     weekly CI schedules and is therefore the audit that actually recurs.
#
# NOTE ON THE PRE-PUSH HOOK. The hook runs `tools/verify.sh standard`, whose
# test step is `testthat::test_local()`. That function sets NOT_CRAN=true
# itself, so `skip_on_cran()` below never fired there and, with credentials in
# `~/.Renviron`, this audit ran live on every push -- which nobody chose, and
# which blocked a merge on 2026-09-09. The standard tier now excludes this file
# and test-osv.R by name; the `full` tier runs both deliberately.

test_that("the OSS Index allow-list is well formed", {
  expect_equal(oss_index_allowlist_violations(oss_index_allowlist), character())
})

test_that("the allow-list validator rejects rows that are not decisions", {
  sound <- list(
    id = "CVE-2026-18924",
    package = "curl",
    version_seen = "8.0.0",
    review = as.Date("2026-12-01"),
    reason = paste(
      "A rationale long enough to be an argument rather than a placeholder,",
      "naming the advisory, the exposure assessed and why it is accepted."
    )
  )
  expect_equal(oss_index_allowlist_violations(list(sound)), character())

  broken <- function(field, value) {
    row <- sound
    row[[field]] <- value
    oss_index_allowlist_violations(list(row))
  }

  expect_match(
    broken("id", "GHSA-xxxx"),
    "single CVE identifier",
    fixed = TRUE
  )
  expect_match(broken("package", ""), "single package name", fixed = TRUE)
  expect_match(
    broken("version_seen", "not-a-version"),
    "parseable version",
    fixed = TRUE
  )
  expect_match(broken("review", "2026-12-01"), "single Date", fixed = TRUE)
  expect_match(
    broken("reason", "unfixable"),
    "too short to be an argument",
    fixed = TRUE
  )

  expect_match(
    oss_index_allowlist_violations(list(sound[-5])),
    "missing field(s): reason",
    fixed = TRUE
  )
  expect_match(
    oss_index_allowlist_violations(list(c(sound, list(owner = "me")))),
    "unknown field(s): owner",
    fixed = TRUE
  )
  expect_match(
    oss_index_allowlist_violations(list(sound, sound)),
    "duplicate allow-list id",
    fixed = TRUE
  )
})

test_that("hard dependencies report only allow-listed OSS Index advisories", {
  # The dedicated, credentialed audit job. A precondition it cannot meet is a
  # failure there, never a skip -- see the header.
  required <- identical(Sys.getenv("OSSINDEX_AUDIT_REQUIRED"), "true")
  no_credentials <- Sys.getenv("OSSINDEX_USER") == "" ||
    Sys.getenv("OSSINDEX_TOKEN") == ""

  if (required) {
    if (!requireNamespace("oysteR", quietly = TRUE)) {
      stop(
        "OSSINDEX_AUDIT_REQUIRED is set but {oysteR} is not installed, so ",
        "this job cannot audit anything. Install it or unset the flag; do ",
        "not let the job report success."
      )
    }
    if (no_credentials) {
      stop(
        "OSSINDEX_AUDIT_REQUIRED is set but OSSINDEX_USER / OSSINDEX_TOKEN ",
        "are absent, so OSS Index would reject every request with HTTP 401 ",
        "and this job would report success having audited nothing. Add both ",
        "as masked CI/CD variables (project Settings > CI/CD > Variables), ",
        "OSSINDEX_USER as the literal 'x'; see TOKENS in the .gitlab-ci.yml ",
        "header and PSLR-njeqwltb."
      )
    }
    # Deliberately no skip_if_offline() on this path: a network the job cannot
    # reach is the same vacuous green as a credential it does not have, so let
    # the audit attempt the call and fail on the transport error.
  } else {
    skip_on_cran()
    skip_if_not_installed("oysteR")
    skip_if_offline()
    skip_if(
      no_credentials,
      "OSS Index credentials (OSSINDEX_USER / OSSINDEX_TOKEN) not set"
    )
  }

  old_repos <- getOption("repos")
  on.exit(options(repos = old_repos), add = TRUE)
  options(repos = c(CRAN = "https://cran.rstudio.com"))

  audit <- oysteR::audit_description(
    dirname(system.file("DESCRIPTION", package = "pslr")),
    fields = c("Depends", "Imports"),
    verbose = FALSE
  )
  found <- oss_index_reported(audit)
  allowed <- vapply(oss_index_allowlist, function(row) row$id, character(1))

  # An audit that resolved nothing is not a clean audit. Without this an empty
  # result satisfies rules A and B vacuously, which is the same green-on-
  # nothing failure the credential guard above exists to stop.
  expect_gt(nrow(audit), 0)

  # Rule A -- an advisory reported and not allow-listed.
  expect_equal(sort(setdiff(found$id, allowed)), character())

  # Rule B -- an allow-listed advisory no longer reported. The list may not
  # over-permit, so a row that has outlived its justification fails here.
  expect_equal(sort(setdiff(allowed, found$id)), character())

  # Rule C -- drift warns, never fails. See helper-security.R.
  for (row in oss_index_allowlist) {
    if (Sys.Date() > row$review) {
      warning(
        sprintf(
          "OSS Index allow-list row %s is past its %s review date.",
          row$id,
          format(row$review)
        ),
        call. = FALSE
      )
    }
    hit <- found[found$id == row$id, ]
    if (
      nrow(hit) > 0 &&
        package_version(hit$version[1]) > package_version(row$version_seen)
    ) {
      warning(
        sprintf(
          paste(
            "OSS Index allow-list row %s was written against %s %s;",
            "the audit now reports %s. Re-read the advisory."
          ),
          row$id,
          row$package,
          row$version_seen,
          hit$version[1]
        ),
        call. = FALSE
      )
    }
  }
})
