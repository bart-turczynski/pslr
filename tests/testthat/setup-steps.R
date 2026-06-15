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
}
