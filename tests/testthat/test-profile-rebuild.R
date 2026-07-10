# Profile-mismatch in-memory index rebuild (PRD s8.3, s11.3).
#
# When the shipped generated index was canonicalized under a different
# normalization profile or Unicode version than the runtime normalizer,
# activation must rebuild the index from the bundled source rather than mix
# profiles. The mismatch is simulated by overriding the runtime identifiers.

test_that("a matching profile uses the shipped index without rebuilding", {
  local_pslr_clean()
  psl_use("bundled")
  expect_false(the_matcher$state$snapshot$rebuilt)
})

test_that("a mismatched Unicode version rebuilds from source", {
  local_pslr_clean()
  testthat::local_mocked_bindings(
    runtime_normalizer_meta = function() {
      list(
        normalizer = "punycoder",
        normalizer_version = "9.9.9",
        normalization_profile = "fake-profile",
        unicode_version = "0.0.0"
      )
    }
  )
  psl_use("bundled")
  expect_true(the_matcher$state$snapshot$rebuilt)
  # The active matcher still resolves correctly after the in-memory rebuild.
  expect_identical(public_suffix("a.b.example.co.uk"), "co.uk")
  expect_identical(public_suffix("foo.github.io"), "github.io")
})

test_that("psl_version reports the runtime normalizer after a rebuild", {
  local_pslr_clean()
  testthat::local_mocked_bindings(
    runtime_normalizer_meta = function() {
      list(
        normalizer = "punycoder",
        normalizer_version = "9.9.9",
        normalization_profile = "fake-profile",
        unicode_version = "0.0.0"
      )
    }
  )
  psl_use("bundled")
  v <- psl_version()
  expect_identical(v$normalization_profile, "fake-profile")
  expect_identical(v$unicode_version, "0.0.0")
  expect_identical(v$normalizer_version, "9.9.9")
  # The shipped source identity is unchanged by an in-memory rebuild.
  expect_identical(v$checksum, pslr_bundled$meta$checksum)
  expect_identical(v$commit, pslr_bundled$meta$commit)
})
