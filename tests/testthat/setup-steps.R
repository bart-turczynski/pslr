# Cucumber step definitions. testthat sources `setup-*.R` before the test files,
# which registers these steps before `cucumber::run()` executes the features.
#
# Guarded on `cucumber` being installed so the suggests-only R CMD check
# (`_R_CHECK_DEPENDS_ONLY_=true`, which CRAN runs) degrades gracefully: with the
# package absent the steps simply are not registered and test-cucumber.R skips.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  when("I check the scaffold", function(context) {
    context$ready <- scaffold_ready()
  })

  then("it reports ready", function(context) {
    expect_true(context$ready)
  })
}
