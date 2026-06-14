# Runs every .feature file in this directory as part of `R CMD check`. In R the
# BDD specs execute inside the normal test pass, so there is no separate verify
# step the way the Python/TypeScript templates need for behave/cucumber-js.
test_that("acceptance specs pass", {
  skip_if_not_installed("cucumber")
  # Working directory during the test run is tests/testthat/, where the .feature
  # files live; steps were registered by setup-steps.R.
  cucumber::run(".")
})
