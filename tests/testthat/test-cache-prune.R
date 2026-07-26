# `psl_cache_prune()` is the one explicit destructive storage operation
# (PSLR-kdjvxtpk). Every test here is offline and runs against a private cache
# directory: nothing makes a request, and nothing writes outside its temporary
# directory.

# Publish snapshot bytes with a chosen first-retrieval time and return their
# checksum identity. The bytes only have to be a valid PSL when a test
# activates them, so they default to opaque filler.
publish_prune_bytes <- function(text = NULL, retrieved = "2024-01-01") {
  path <- tempfile("pslr-prune-", fileext = ".dat")
  if (is.null(text)) {
    text <- paste0("// prune fixture ", basename(path), "\n")
  }
  con <- file(path, open = "wb")
  writeBin(charToRaw(text), con)
  close(con)
  psl_with_publish_lock(
    psl_publish_snapshot(
      path,
      first_retrieved_at = as.POSIXct(retrieved, tz = "UTC")
    )
  )$checksum
}

# Publish a real Public Suffix List so the snapshot can also be activated.
publish_prune_list <- function(extra = character(), retrieved = "2024-01-01") {
  publish_prune_bytes(
    paste(readLines(write_test_list(extra)), collapse = "\n"),
    retrieved = retrieved
  )
}

publish_prune_source <- function(checksum, url = psl_official_url) {
  psl_with_publish_lock(
    psl_publish_source_state(url, checksum = checksum)
  )
}

publish_prune_selection <- function(checksum, url = psl_official_url) {
  psl_with_publish_lock(psl_publish_selection(checksum, request_url = url))
}

snapshot_pair_exists <- function(checksum) {
  c(
    bytes = file.exists(psl_snapshot_bytes_path(checksum)),
    descriptor = file.exists(psl_snapshot_descriptor_path(checksum))
  )
}

# Replace the newest generation of a stream with bytes that are not an RDS
# object, which is what a `recovered` read looks like on disk.
corrupt_newest_generation <- function(dir) {
  generations <- psl_generation_numbers(dir)
  target <- if (length(generations)) max(generations) else 1L
  writeLines("not an rds file", file.path(dir, psl_generation_name(target)))
  invisible(dir)
}

# Every file under `dir` with its size and modification time.
tree_fingerprint <- function(dir) {
  files <- sort(
    list.files(dir, recursive = TRUE, all.files = TRUE, no.. = TRUE),
    method = "radix"
  )
  info <- file.info(file.path(dir, files))
  list(files = files, size = info$size, mtime = info$mtime)
}

test_that("the selected cache snapshot survives even with keep = 0", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  stale <- publish_prune_bytes()
  publish_prune_selection(selected)

  removed <- psl_cache_prune(keep = 0L)

  expect_identical(removed$checksum, stale)
  expect_true(all(snapshot_pair_exists(selected)))
  expect_false(any(snapshot_pair_exists(stale)))
})

test_that("every source stream protects the snapshot it references", {
  local_pslr_clean()
  official <- publish_prune_bytes()
  custom <- publish_prune_bytes()
  stale <- publish_prune_bytes()
  publish_prune_source(official)
  publish_prune_source(custom, url = "https://example.org/custom.dat")

  removed <- psl_cache_prune(keep = 0L)

  # Both sources are references, even though neither is the selection.
  expect_identical(removed$checksum, stale)
  expect_true(all(snapshot_pair_exists(official)))
  expect_true(all(snapshot_pair_exists(custom)))
})

test_that("the snapshot active in this process survives", {
  local_pslr_clean()
  active <- publish_prune_list()
  other <- publish_prune_list(extra = "example.test")
  publish_prune_selection(active)
  psl_use("cache")
  # Move both the selection and the only source off the active snapshot, so
  # nothing but this session's engine still refers to it.
  publish_prune_selection(other)
  publish_prune_source(other)

  removed <- psl_cache_prune(keep = 0L)

  expect_identical(nrow(removed), 0L)
  expect_true(all(snapshot_pair_exists(active)))
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})

test_that("keep retains that many otherwise-unreferenced snapshots", {
  local_pslr_clean()
  selected <- publish_prune_bytes(retrieved = "2024-01-01")
  oldest <- publish_prune_bytes(retrieved = "2024-02-01")
  middle <- publish_prune_bytes(retrieved = "2024-03-01")
  newest <- publish_prune_bytes(retrieved = "2024-04-01")
  publish_prune_selection(selected)

  removed <- psl_cache_prune(keep = 2L)

  expect_identical(removed$checksum, oldest)
  expect_true(all(snapshot_pair_exists(middle)))
  expect_true(all(snapshot_pair_exists(newest)))
})

test_that("retention follows first retrieval, not file modification time", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  publish_prune_selection(selected)
  older <- publish_prune_bytes(retrieved = "2024-01-01")
  newer <- publish_prune_bytes(retrieved = "2024-06-01")
  # Make mtime contradict retrieval order: the snapshot retrieved FIRST is the
  # one whose files were touched most recently. Ordering by mtime would keep
  # `older` and delete `newer`.
  touch <- function(checksum, when) {
    Sys.setFileTime(psl_snapshot_bytes_path(checksum), when)
    Sys.setFileTime(psl_snapshot_descriptor_path(checksum), when)
  }
  touch(newer, as.POSIXct("2020-01-01", tz = "UTC"))
  touch(older, as.POSIXct("2030-01-01", tz = "UTC"))

  removed <- psl_cache_prune(keep = 1L)

  expect_identical(removed$checksum, older)
  expect_true(all(snapshot_pair_exists(newer)))
})

test_that("a snapshot is removed strictly as a .dat/.rds pair", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  stale <- publish_prune_bytes()
  publish_prune_selection(selected)

  removed <- psl_cache_prune(keep = 0L)

  expect_identical(removed$bytes_path, psl_snapshot_bytes_path(stale))
  expect_identical(
    removed$descriptor_path,
    psl_snapshot_descriptor_path(stale)
  )
  expect_identical(unname(snapshot_pair_exists(stale)), c(FALSE, FALSE))
  expect_identical(unname(snapshot_pair_exists(selected)), c(TRUE, TRUE))
})

test_that("keep = 0 removes nothing when every snapshot is referenced", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  referenced <- publish_prune_bytes()
  publish_prune_selection(selected)
  publish_prune_source(referenced, url = "https://example.org/custom.dat")

  removed <- psl_cache_prune(keep = 0L)

  expect_identical(nrow(removed), 0L)
  expect_true(all(snapshot_pair_exists(selected)))
  expect_true(all(snapshot_pair_exists(referenced)))
})

test_that("an empty or absent store is a safe no-op", {
  local_pslr_clean()
  expect_identical(nrow(psl_cache_prune()), 0L)

  withr::local_options(
    pslr.cache_dir = file.path(tempdir(), "pslr-absent-cache-dir")
  )
  expect_identical(nrow(psl_cache_prune()), 0L)
})

test_that("the result has the documented columns and is returned invisibly", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  stale <- publish_prune_bytes()
  publish_prune_selection(selected)
  size <- sum(file.size(c(
    psl_snapshot_bytes_path(stale),
    psl_snapshot_descriptor_path(stale)
  )))

  expect_invisible(removed <- psl_cache_prune(keep = 0L))

  expect_s3_class(removed, "data.frame")
  expect_named(
    removed,
    c("checksum", "bytes_path", "descriptor_path", "bytes_reclaimed")
  )
  expect_identical(nrow(removed), 1L)
  expect_type(removed$bytes_reclaimed, "double")
  expect_identical(removed$bytes_reclaimed, as.numeric(size))
})

test_that("keep must be a single non-negative whole number", {
  local_pslr_clean()
  expect_error(psl_cache_prune(keep = -1L), "non-negative whole number")
  expect_error(psl_cache_prune(keep = 1.5), "non-negative whole number")
  expect_error(psl_cache_prune(keep = NA_integer_), "non-negative whole number")
  expect_error(psl_cache_prune(keep = c(1L, 2L)), "non-negative whole number")
  expect_error(psl_cache_prune(keep = "1"), "non-negative whole number")
})

test_that("a damaged source stream protects every snapshot", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  referenced <- publish_prune_bytes()
  unreferenced <- publish_prune_bytes()
  publish_prune_selection(selected)
  publish_prune_source(referenced, url = "https://example.org/custom.dat")
  publish_prune_source(referenced, url = "https://example.org/custom.dat")
  corrupt_newest_generation(
    psl_source_stream_dir("https://example.org/custom.dat")
  )
  expect_identical(
    psl_read_source_state("https://example.org/custom.dat")$status,
    "recovered"
  )

  removed <- psl_cache_prune(keep = 0L)

  # The unreadable generation could name anything, so nothing is collectable.
  expect_identical(nrow(removed), 0L)
  expect_true(all(snapshot_pair_exists(unreferenced)))
})

test_that("a damaged selection stream protects every snapshot", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  unreferenced <- publish_prune_bytes()
  publish_prune_selection(selected)
  corrupt_newest_generation(psl_selection_stream_dir())
  expect_identical(psl_read_selection()$status, "corrupt")

  removed <- psl_cache_prune(keep = 0L)

  expect_identical(nrow(removed), 0L)
  expect_true(all(snapshot_pair_exists(unreferenced)))
})

test_that("a partial deletion is a classed error naming what was removed", {
  local_pslr_clean()
  selected <- publish_prune_bytes()
  publish_prune_selection(selected)
  doomed <- publish_prune_bytes(retrieved = "2024-01-01")
  stubborn <- publish_prune_bytes(retrieved = "2024-02-01")
  protected <- psl_snapshot_bytes_path(stubborn)
  withr::local_options(
    pslr.prune_unlink = function(path) {
      if (identical(path, protected)) invisible(NULL) else unlink(path)
    }
  )

  condition <- tryCatch(psl_cache_prune(keep = 0L), error = identity)

  expect_s3_class(condition, "pslr_prune_partial_error")
  expect_s3_class(condition, "pslr_refresh_error")
  expect_identical(condition$failed, stubborn)
  # The sweep does not abort early, so the snapshot it could remove is gone
  # and is reported on the condition's result frame.
  expect_true(doomed %in% condition$result$checksum)
  expect_false(any(snapshot_pair_exists(doomed)))
  expect_true(file.exists(protected))
})

test_that("pruning never touches the reminder preference", {
  local_pslr_clean()
  psl_store_append(
    psl_reminder_stream_dir(),
    \(g) list(generation = g, enabled = TRUE)
  )
  before <- tree_fingerprint(psl_config_dir())
  selected <- publish_prune_bytes()
  publish_prune_selection(selected)
  publish_prune_bytes()

  psl_cache_prune(keep = 0L)

  expect_identical(tree_fingerprint(psl_config_dir()), before)
})

test_that("legacy v1 files survive a prune and the cache stays activatable", {
  dir <- local_pslr_clean()
  legacy <- seed_legacy_cache(dir)
  stale <- publish_prune_bytes()

  # Pruning is an explicit mutator, so it migrates the legacy cache first; the
  # migrated snapshot is then a reference and only `stale` is collectable.
  removed <- psl_cache_prune(keep = 0L)

  expect_identical(removed$checksum, stale)
  expect_true(file.exists(file.path(dir, legacy)))
  expect_true(file.exists(file.path(dir, "current.rds")))
  expect_identical(psl_use("cache")$source, "cache")
  expect_identical(public_suffix("www.example.co.uk"), "co.uk")
})

test_that("refresh still works after a prune", {
  local_pslr_clean()
  state <- local_fake_transport()
  psl_refresh(force = TRUE, activate = TRUE)
  stale <- publish_prune_bytes()

  psl_cache_prune(keep = 0L)

  expect_false(any(snapshot_pair_exists(stale)))
  result <- psl_refresh(force = TRUE, activate = TRUE)
  expect_identical(result$outcome, "downloaded_unchanged")
  expect_identical(psl_use("cache")$source, "cache")
  expect_gt(request_count(state), 1L)
})
