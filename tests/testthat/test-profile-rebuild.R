# Profile-mismatch in-memory index rebuild (PRD s8.3, s11.3).
#
# When the shipped generated index was canonicalized under a different
# normalization profile or Unicode version than the runtime normalizer,
# activation must rebuild the index from the bundled source rather than mix
# profiles. The mismatch is simulated by overriding the runtime identifiers.

# Whether the shipped index needs a rebuild is a property of the punycoder that
# happens to be installed, not of pslr, so the expectation is derived from the
# same comparison `bundled_snapshot()` makes rather than hardcoded. Asserting
# FALSE pinned a build-time coincidence -- that the index was generated under
# the profile the installed punycoder reports -- and failed against any
# punycoder that had since moved its Unicode pin (PSLR-rnfnzwqu).
test_that("the shipped index rebuilds exactly on a profile mismatch", {
  local_pslr_clean()
  bundled <- pslr_bundled$meta
  runtime <- runtime_normalizer_meta()
  expected <- !identical(
    bundled$normalization_profile,
    runtime$normalization_profile
  ) ||
    !identical(bundled$unicode_version, runtime$unicode_version)

  psl_use("bundled")
  expect_identical(the_matcher$state$snapshot$rebuilt, expected)
})

# The release contract (PSLR-fjkaqckg): the shipped index is built under the
# punycoder that `Imports:` names as its floor, so a user at that floor takes
# the no-rebuild path and saves every session about 2.75 s. This half needs no
# particular punycoder installed, so it runs everywhere, CRAN included: it
# catches an index regenerated under a newer punycoder while `Imports:` still
# names the old floor, and a floor raised without regenerating the index.
test_that("the shipped index is built under the punycoder Imports floor", {
  imports <- utils::packageDescription("pslr")$Imports
  imports_floor <- regmatches(
    imports,
    regexec("punycoder[[:space:]]*\\(>=[[:space:]]*([0-9.-]+)\\)", imports)
  )[[1]][2]

  expect_identical(pslr_bundled$meta$normalizer_version, imports_floor)
})

# The other half: against that punycoder, `bundled_snapshot()` never calls the
# rebuild, which fails the test outright. It runs only where the installed
# punycoder is the one the index records. It skips on CRAN and under any other
# punycoder, since a later one that moves its Unicode pin makes loading slower
# without making pslr wrong; failing there would redden CRAN's
# reverse-dependency check (PSLR-rnfnzwqu) and the gate on every unrelated
# branch. A development build (last version component 9000 or above) skips
# too, as its pin can run ahead of the shipped index.
test_that("the shipped index takes the no-rebuild path", {
  skip_on_cran()
  installed <- utils::packageVersion("punycoder")
  components <- unlist(installed)
  skip_if(
    components[length(components)] >= 9000L,
    paste("punycoder", installed, "is a development build")
  )
  skip_if_not(
    installed == pslr_bundled$meta$normalizer_version,
    paste(
      "punycoder",
      installed,
      "is not the",
      pslr_bundled$meta$normalizer_version,
      "the index was built under"
    )
  )
  testthat::local_mocked_bindings(
    rebuild_bundled_rules = function() {
      stop("bundled_snapshot() rebuilt the shipped index", call. = FALSE)
    }
  )

  snapshot <- bundled_snapshot()

  expect_false(snapshot$rebuilt)
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
