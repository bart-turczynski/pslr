# psl_cache_prune(): disk-cache retention for the content-addressed
# psl-<hex>.dat snapshots (PSLR-nwdejhkf). Distinct from the in-memory
# psl_cache_clear() flush.

# Write `n` snapshot files into `dir` with strictly increasing mtimes (older
# first) and return their paths oldest-first. Returns the created `.dat` paths.
seed_snapshots <- function(dir, names) {
  paths <- file.path(dir, names)
  base <- Sys.time() - as.difftime(length(names), units = "hours")
  for (i in seq_along(paths)) {
    writeLines(paste0("snapshot ", i), paths[i])
    Sys.setFileTime(paths[i], base + as.difftime(i, units = "hours"))
  }
  paths
}

# Point the commit marker at one of the snapshots (by basename).
point_marker_at <- function(dir, dat_name) {
  saveRDS(
    list(
      dat_file = dat_name,
      meta = list(
        checksum = "sha256:x",
        retrieved_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
        size = 1L
      )
    ),
    file.path(dir, "current.rds")
  )
}

test_that("default prune keeps the active snapshot and one most-recent other", {
  dir <- local_pslr_clean()
  seed_snapshots(dir, c("psl-a.dat", "psl-b.dat", "psl-c.dat"))
  # Active is the oldest; b and c are the newer others.
  point_marker_at(dir, "psl-a.dat")

  removed <- psl_cache_prune()

  # Only the oldest other (b) is removed; active (a) and newest other (c) stay.
  expect_identical(basename(removed), "psl-b.dat")
  expect_true(file.exists(file.path(dir, "psl-a.dat")))
  expect_true(file.exists(file.path(dir, "psl-c.dat")))
  expect_false(file.exists(file.path(dir, "psl-b.dat")))
})

test_that("keep controls how many previous snapshots survive", {
  dir <- local_pslr_clean()
  seed_snapshots(dir, c("psl-a.dat", "psl-b.dat", "psl-c.dat", "psl-d.dat"))
  point_marker_at(dir, "psl-a.dat") # oldest is the active snapshot

  removed <- psl_cache_prune(keep = 2L)

  # Two newest others (c, d) plus the active (a) survive; b is removed.
  expect_identical(basename(removed), "psl-b.dat")
  expect_true(file.exists(file.path(dir, "psl-c.dat")))
  expect_true(file.exists(file.path(dir, "psl-d.dat")))
})

test_that("the active snapshot is never removed, even with keep = 0", {
  dir <- local_pslr_clean()
  seed_snapshots(dir, c("psl-a.dat", "psl-b.dat", "psl-c.dat"))
  point_marker_at(dir, "psl-a.dat") # oldest is the active snapshot

  removed <- psl_cache_prune(keep = 0L)

  # Every non-active snapshot is removed; the active one stays.
  expect_setequal(basename(removed), c("psl-b.dat", "psl-c.dat"))
  expect_true(file.exists(file.path(dir, "psl-a.dat")))
  expect_false(file.exists(file.path(dir, "psl-b.dat")))
  expect_false(file.exists(file.path(dir, "psl-c.dat")))
})

test_that("nothing is removed when only the active snapshot exists", {
  dir <- local_pslr_clean()
  seed_snapshots(dir, "psl-a.dat")
  point_marker_at(dir, "psl-a.dat")

  removed <- psl_cache_prune(keep = 0L)

  expect_identical(removed, character(0))
  expect_true(file.exists(file.path(dir, "psl-a.dat")))
})

test_that("no marker is a clean no-op that removes nothing", {
  dir <- local_pslr_clean()
  seed_snapshots(dir, c("psl-a.dat", "psl-b.dat"))
  # No current.rds written.

  removed <- psl_cache_prune()

  expect_identical(removed, character(0))
  expect_true(file.exists(file.path(dir, "psl-a.dat")))
  expect_true(file.exists(file.path(dir, "psl-b.dat")))
})

test_that("a missing cache directory is a clean no-op", {
  local_pslr_clean()
  withr::local_options(
    pslr.cache_dir = file.path(tempdir(), "pslr-absent-cache-dir")
  )
  expect_identical(psl_cache_prune(), character(0))
})

test_that("keep must be a single non-negative whole number", {
  local_pslr_clean()
  expect_error(psl_cache_prune(keep = -1L), "non-negative whole number")
  expect_error(psl_cache_prune(keep = 1.5), "non-negative whole number")
  expect_error(psl_cache_prune(keep = NA_integer_), "non-negative whole number")
  expect_error(psl_cache_prune(keep = c(1L, 2L)), "non-negative whole number")
  expect_error(psl_cache_prune(keep = "1"), "non-negative whole number")
})

test_that("prune leaves a real refreshed cache activatable via psl_use", {
  dir <- local_pslr_clean()
  withr::local_options(pslr.downloader = fake_downloader())
  psl_refresh(force = TRUE)

  # Seed extra stale snapshots alongside the genuine one, then prune them.
  active <- readRDS(file.path(dir, "current.rds"))$dat_file
  seed_snapshots(dir, c("psl-stale1.dat", "psl-stale2.dat"))

  psl_cache_prune(keep = 0L)

  expect_true(file.exists(file.path(dir, active)))
  expect_identical(psl_use("cache")$source, "cache")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})
