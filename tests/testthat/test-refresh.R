# psl_refresh() argument and URL policy, the source-checksum helpers, and the
# activation paths of psl_use("cache") (PRD s7.4, s9, s11.3). The v2 refresh
# outcomes themselves live in test-refresh-integration.R. Nothing here touches
# the network.

test_that("the refresh URL must be absolute https without credentials", {
  local_pslr_clean()
  expect_error(psl_refresh("http://psl.example/list.dat"), "not an https URL")
  expect_error(psl_refresh("ftp://x/list.dat"), "not an https URL")
  expect_error(psl_refresh("https://u:p@x/list.dat"), "embed credentials")
  expect_error(psl_refresh(url = NA_character_), "single non-empty string")
})

test_that("the refresh URL must not carry a query string or fragment", {
  local_pslr_clean()
  # Request URLs are persisted, so a query -- where a token would hide -- is
  # rejected rather than stripped.
  expect_error(psl_refresh("https://x/list.dat?t=1"), "query string")
  expect_error(psl_refresh("https://x/list.dat#top"), "fragment")
})

test_that("a rejected URL is refused before any request is made", {
  local_pslr_clean()
  transport <- local_fake_transport()
  expect_error(psl_refresh("http://psl.example/list.dat"))
  expect_identical(request_count(transport), 0L)
})

test_that("force/activate must be logical scalars", {
  local_pslr_clean()
  expect_error(psl_refresh(force = "yes"), "single TRUE or FALSE")
  expect_error(psl_refresh(activate = NA), "single TRUE or FALSE")
})

test_that("the source checksum is always a sha256 identity", {
  # `digest` is a hard dependency, so a newly recorded checksum is SHA-256 on
  # every install -- there is no MD5-writing fallback that could mint a weaker
  # identity.
  expect_match(
    psl_source_checksum(bundled_dat_path()),
    "^sha256:[0-9a-f]{64}$"
  )
})

test_that("an md5-recorded checksum verifies against md5 with digest present", {
  # The recorded algorithm drives verification, so a cache recorded as md5 on a
  # digest-less machine still verifies TRUE where digest is now available --
  # rather than being spuriously rejected because digest would prefer sha256.
  path <- bundled_dat_path()
  recorded <- paste0("md5:", unname(tools::md5sum(path)))
  expect_true(requireNamespace("digest", quietly = TRUE))
  expect_true(psl_verify_checksum(path, recorded))
})

test_that("an sha256-recorded checksum verifies against the recorded bytes", {
  # Verification reproduces the recorded algorithm, so the identity written by
  # psl_source_checksum() round-trips and a different digest is rejected.
  path <- bundled_dat_path()
  expect_true(psl_verify_checksum(path, psl_source_checksum(path)))
  expect_false(
    psl_verify_checksum(path, paste0("sha256:", strrep("0", 64L)))
  )
})

test_that("an unreadable source file is rejected before parsing", {
  expect_error(
    psl_load_source(tempfile(), "custom path list"),
    "not readable"
  )
})

test_that("psl_use('cache') activates the selected v2 snapshot", {
  local_pslr_clean()
  local_fake_transport()
  psl_refresh(force = TRUE)
  v <- psl_use("cache")
  expect_identical(v$source, "cache")
  expect_identical(psl_version()$source, "cache")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})

test_that("psl_use('cache') reports missing selected bytes with remediation", {
  local_pslr_clean()
  local_fake_transport()
  result <- psl_refresh(force = TRUE)
  unlink(psl_snapshot_bytes_path(result$checksum))

  expect_error(psl_use("cache"), "source file is missing")
  expect_error(psl_use("cache"), "psl_refresh\\(force = TRUE\\)")
})

test_that("psl_use('cache') reports tampered selected bytes as corruption", {
  local_pslr_clean()
  local_fake_transport()
  result <- psl_refresh(force = TRUE)
  writeLines("changed", psl_snapshot_bytes_path(result$checksum))

  expect_error(psl_use("cache"), "cache is corrupt: checksum mismatch")
  expect_error(psl_use("cache"), "psl_refresh\\(force = TRUE\\)")
})

test_that("psl_use('cache') falls back to an unmigrated legacy cache", {
  # Migration runs only from an explicit mutator, so a user who upgrades and
  # calls psl_use("cache") without refreshing must still get their v1 cache.
  dir <- local_pslr_clean()
  seed_legacy_cache(dir)
  expect_identical(psl_use("cache")$source, "cache")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})

test_that("psl_use('cache') reports a corrupt legacy marker with remediation", {
  dir <- local_pslr_clean()
  seed_legacy_cache(dir)
  writeBin(as.raw(0:7), file.path(dir, "current.rds")) # not a serialized object

  expect_error(psl_use("cache"), "cache is corrupt")
  expect_error(psl_use("cache"), "psl_refresh\\(force = TRUE\\)")
})

test_that("psl_use('cache') rejects a readable but malformed legacy marker", {
  dir <- local_pslr_clean()
  marker <- file.path(dir, "current.rds")
  # A readable RDS that deserializes fine but is structurally wrong: `meta`
  # lacks the identity fields the reader consumes. Left unchecked this would
  # yield silent NULL `$` reads downstream instead of a clean corruption error.
  saveRDS(list(dat_file = "psl-x.dat", meta = list()), marker)

  expect_error(psl_use("cache"), "cache is corrupt")
  expect_error(psl_use("cache"), "psl_refresh\\(force = TRUE\\)")

  # A marker missing `dat_file` entirely is likewise rejected.
  saveRDS(list(meta = list(checksum = "sha256:x")), marker)
  expect_error(psl_use("cache"), "cache is corrupt")
})

test_that("psl_use('cache') reports legacy content tampering as corruption", {
  dir <- local_pslr_clean()
  dat_file <- seed_legacy_cache(dir)
  # Tamper with the source bytes so the recorded checksum no longer matches.
  writeLines("changed", file.path(dir, dat_file))

  expect_error(psl_use("cache"), "cache is corrupt: checksum mismatch")
})

test_that("psl_use('cache') reports a missing legacy source file", {
  dir <- local_pslr_clean()
  dat_file <- seed_legacy_cache(dir)
  unlink(file.path(dir, dat_file))

  expect_error(psl_use("cache"), "source file is missing")
  expect_error(psl_use("cache"), "psl_refresh\\(force = TRUE\\)")
})
