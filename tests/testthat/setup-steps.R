# Cucumber step definitions. testthat sources `setup-*.R` before the test files,
# which registers these steps before `cucumber::run()` executes the features.
#
# Guarded on `cucumber` being installed so the suggests-only R CMD check
# (`_R_CHECK_DEPENDS_ONLY_=true`, which CRAN runs) degrades gracefully: with the
# package absent the steps simply are not registered and test-cucumber.R skips.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  when("I query the host {string}", function(host, context) {
    context$public_suffix <- public_suffix(host)
    context$registrable_domain <- registrable_domain(host)
  })

  when(
    "I query the host {string} in section {string}",
    function(host, section, context) {
      context$public_suffix <- public_suffix(host, section = section)
      context$registrable_domain <- registrable_domain(host, section = section)
    }
  )

  then("the public suffix is {string}", function(expected, context) {
    expect_identical(context$public_suffix, expected)
  })

  then("the registrable domain is {string}", function(expected, context) {
    expect_identical(context$registrable_domain, expected)
  })

  then("the public suffix is missing", function(context) {
    expect_true(is.na(context$public_suffix))
  })

  # Freshness scenarios run against a private cache and config directory, so a
  # scenario that publishes snapshots never touches the user's cache and never
  # leaks state into the next one. The hooks are global; for the query feature
  # they are simply an unused temporary directory.
  before(function(context, scenario) {
    context$cache <- tempfile("pslr-feature-cache-")
    dir.create(context$cache, recursive = TRUE)
    context$options <- options(
      pslr.cache_dir = context$cache,
      pslr.config_dir = file.path(context$cache, "config"),
      pslr.transport = NULL,
      pslr.clock = NULL
    )
    reset_active_for_test()
  })

  after(function(context, scenario) {
    options(context$options)
    unlink(context$cache, recursive = TRUE)
    reset_active_for_test()
  })

  # Publish opaque cache bytes -- freshness advice never parses a list -- and
  # return their checksum identity.
  publish_feature_bytes <- function(text) {
    path <- tempfile("pslr-feature-", fileext = ".dat")
    con <- file(path, open = "wb")
    writeBin(charToRaw(text), con)
    close(con)
    psl_with_publish_lock(psl_publish_snapshot(path))$checksum
  }

  given(
    "a cached snapshot that was never checked against its source",
    function(context) {
      context$checksum <- publish_feature_bytes("// unchecked bytes\n")
      psl_with_publish_lock(
        psl_publish_source_state(psl_official_url, checksum = context$checksum)
      )
      psl_with_publish_lock(
        psl_publish_selection(context$checksum, request_url = psl_official_url)
      )
    }
  )

  given("a cached snapshot confirmed {int} days ago", function(days, context) {
    context$checksum <- publish_feature_bytes("// confirmed bytes\n")
    confirmed <- psl_format_time(psl_now() - days * 86400)
    psl_with_publish_lock(psl_publish_source_state(
      psl_official_url,
      checksum = context$checksum,
      checked_at = confirmed,
      retrieved_at = confirmed
    ))
    psl_with_publish_lock(
      psl_publish_selection(context$checksum, request_url = psl_official_url)
    )
  })

  given(
    "a newer snapshot has been downloaded for the same source",
    function(context) {
      newer <- publish_feature_bytes("// newer bytes\n")
      # The source now knows about newer bytes; the selection still names the
      # snapshot from before, which is exactly "downloaded but not activated".
      psl_with_publish_lock(psl_publish_source_state(
        psl_official_url,
        checksum = newer,
        checked_at = psl_format_time(psl_now() - 3600)
      ))
    }
  )

  given("a list loaded from a file of my own", function(context) {
    psl_use("path", path = write_test_list())
  })

  when("I ask pslr about the {string} snapshot", function(which, context) {
    context$status <- psl_status(which)
  })

  then("the freshness state is {string}", function(expected, context) {
    expect_identical(context$status$state, expected)
  })

  then("the report says {string}", function(expected, context) {
    expect_match(
      paste(format(context$status), collapse = "\n"),
      expected,
      fixed = TRUE
    )
  })

  then("the report does not call the list outdated", function(context) {
    report <- paste(format(context$status), collapse = "\n")
    expect_no_match(report, "outdated", ignore.case = TRUE)
    expect_no_match(report, "update available", ignore.case = TRUE)
  })
}
