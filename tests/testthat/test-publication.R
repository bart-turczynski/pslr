# Publication tests operate on opaque bytes: nothing here parses a PSL, so a
# short deterministic body is enough to exercise identity and ordering.
local_publication_cache <- function(.env = parent.frame()) {
  cache <- withr::local_tempdir(.local_envir = .env)
  withr::local_options(pslr.cache_dir = cache, .local_envir = .env)
  withr::defer(psl_lock_state$held <- character(), envir = .env)
  cache
}

staged_bytes <- function(text = "// psl bytes\n") {
  path <- tempfile("pslr-staged-", fileext = ".dat")
  con <- file(path, open = "wb")
  writeBin(charToRaw(text), con)
  close(con)
  path
}

test_that("snapshot paths are content-addressed under snapshots/", {
  cache <- local_publication_cache()
  checksum <- paste0("sha256:", strrep("a", 64L))
  expect_identical(psl_snapshot_dir(), file.path(cache, "snapshots"))
  expect_identical(
    psl_snapshot_bytes_path(checksum),
    file.path(cache, "snapshots", paste0("sha256-", strrep("a", 64L), ".dat"))
  )
  expect_identical(
    psl_snapshot_descriptor_path(checksum),
    file.path(cache, "snapshots", paste0("sha256-", strrep("a", 64L), ".rds"))
  )
})

test_that("publishing a snapshot writes bytes and then its descriptor", {
  local_publication_cache()
  path <- staged_bytes()
  checksum <- psl_source_checksum(path)
  descriptor <- psl_with_publish_lock(psl_publish_snapshot(path))
  expect_identical(descriptor$checksum, checksum)
  expect_identical(descriptor$storage, "cache")
  expect_identical(descriptor$path, basename(psl_snapshot_bytes_path(checksum)))
  expect_identical(psl_snapshot_integrity(checksum, verify = TRUE), "ok")
  # The staged file was consumed, not left behind as cache debris.
  expect_false(file.exists(path))
})

test_that("published snapshot bytes and descriptors are immutable", {
  local_publication_cache()
  first <- staged_bytes()
  checksum <- psl_source_checksum(first)
  original <- psl_with_publish_lock(
    psl_publish_snapshot(first, first_retrieved_at = "2020-01-01T00:00:00Z")
  )
  second <- staged_bytes()
  again <- psl_with_publish_lock(
    psl_publish_snapshot(second, first_retrieved_at = "2026-06-06T00:00:00Z")
  )
  expect_identical(again$checksum, checksum)
  expect_identical(again$first_retrieved_at, original$first_retrieved_at)
})

test_that("publishing snapshot bytes rejects a mismatched checksum", {
  local_publication_cache()
  path <- staged_bytes()
  wrong <- paste0("sha256:", strrep("b", 64L))
  expect_error(
    psl_with_publish_lock(psl_publish_snapshot_bytes(path, wrong)),
    "Staged bytes do not match"
  )
  expect_false(file.exists(psl_snapshot_bytes_path(wrong)))
})

test_that("publication requires the publish lock", {
  local_publication_cache()
  path <- staged_bytes()
  checksum <- psl_source_checksum(path)
  expect_error(psl_publish_snapshot_bytes(path), "requires the \"publish\"")
  expect_error(
    psl_publish_snapshot_descriptor(checksum),
    "requires the \"publish\""
  )
  expect_error(psl_publish_selection(checksum), "requires the \"publish\"")
  expect_error(
    psl_publish_source_state("https://example.test/list.dat"),
    "requires the \"publish\""
  )
})

test_that("a reference to unpublished bytes is refused", {
  local_publication_cache()
  checksum <- paste0("sha256:", strrep("c", 64L))
  selection <- tryCatch(
    psl_with_publish_lock(psl_publish_selection(checksum)),
    pslr_publication_error = function(e) e
  )
  expect_s3_class(selection, "pslr_publication_error")
  expect_identical(selection$integrity, "missing")
  state <- tryCatch(
    psl_with_publish_lock(
      psl_publish_source_state(
        "https://example.test/list.dat",
        checksum = checksum
      )
    ),
    pslr_publication_error = function(e) e
  )
  expect_s3_class(state, "pslr_publication_error")
  # Nothing was written, so no reader can observe the dangling reference.
  expect_identical(psl_read_selection()$status, "empty")
  expect_identical(
    psl_read_source_state("https://example.test/list.dat")$status,
    "empty"
  )
})

test_that("bytes without a descriptor are not referenceable", {
  local_publication_cache()
  path <- staged_bytes()
  checksum <- psl_with_publish_lock(psl_publish_snapshot_bytes(path))
  expect_identical(psl_snapshot_integrity(checksum), "missing")
  expect_error(
    psl_with_publish_lock(psl_publish_selection(checksum)),
    "not published"
  )
})

test_that("a full refresh commits bytes, state, and selection in order", {
  local_publication_cache()
  url <- "https://example.test/list.dat"
  path <- staged_bytes()
  checksum <- psl_source_checksum(path)
  result <- psl_with_source_lock(
    url,
    psl_publish_refresh(
      url,
      path = path,
      state = list(last_result = "updated", checked_at = "2026-01-01T00:00:00Z")
    )
  )
  expect_identical(result$checksum, checksum)
  expect_identical(psl_snapshot_integrity(checksum, verify = TRUE), "ok")
  state <- psl_read_source_state(url)
  expect_identical(state$status, "ok")
  expect_identical(state$record$checksum, checksum)
  expect_identical(state$record$last_result, "updated")
  selection <- psl_read_selection()
  expect_identical(selection$record$checksum, checksum)
  expect_identical(selection$record$request_url, url)
  expect_length(psl_locks_held(), 0L)
})

test_that("a refresh publication requires the caller's source lock", {
  local_publication_cache()
  url <- "https://example.test/list.dat"
  expect_error(
    psl_publish_refresh(url, path = staged_bytes()),
    "Publishing a refresh requires"
  )
})

test_that("a 304 commit reuses an already published snapshot", {
  local_publication_cache()
  url <- "https://example.test/list.dat"
  checksum <- psl_with_source_lock(
    url,
    psl_publish_refresh(url, path = staged_bytes())
  )$checksum
  again <- psl_with_source_lock(
    url,
    psl_publish_refresh(
      url,
      checksum = checksum,
      state = list(last_result = "not_modified")
    )
  )
  expect_identical(again$checksum, checksum)
  state <- psl_read_source_state(url)
  expect_identical(state$record$last_result, "not_modified")
  expect_identical(
    psl_generation_numbers(psl_source_stream_dir(url)),
    c(1L, 2L)
  )
})

test_that("selection can be withheld while source state still commits", {
  local_publication_cache()
  url <- "https://example.test/list.dat"
  psl_with_source_lock(
    url,
    psl_publish_refresh(url, path = staged_bytes(), select = FALSE)
  )
  expect_identical(psl_read_source_state(url)$status, "ok")
  expect_identical(psl_read_selection()$status, "empty")
})

test_that("an interrupt before the descriptor leaves no reference behind", {
  local_publication_cache()
  url <- "https://example.test/list.dat"
  path <- staged_bytes()
  checksum <- psl_source_checksum(path)
  withr::local_options(
    pslr.publish_interrupt = function(stage) {
      if (identical(stage, "descriptor")) stop("interrupted")
    }
  )
  expect_error(
    psl_with_source_lock(url, psl_publish_refresh(url, path = path)),
    "interrupted"
  )
  expect_true(file.exists(psl_snapshot_bytes_path(checksum)))
  expect_identical(psl_snapshot_integrity(checksum), "missing")
  expect_identical(psl_read_selection()$status, "empty")
  expect_identical(psl_read_source_state(url)$status, "empty")
  expect_length(psl_locks_held(), 0L)
})

test_that("an interrupt before the selection leaves the older one usable", {
  local_publication_cache()
  url <- "https://example.test/list.dat"
  first <- psl_with_source_lock(
    url,
    psl_publish_refresh(url, path = staged_bytes())
  )
  withr::local_options(
    pslr.publish_interrupt = function(stage) {
      if (identical(stage, "selection")) stop("interrupted")
    }
  )
  newer <- staged_bytes("// newer bytes\n")
  expect_error(
    psl_with_source_lock(url, psl_publish_refresh(url, path = newer)),
    "interrupted"
  )
  # Newer source knowledge is visible; the selection is the older safe one and
  # still resolves to published bytes.
  expect_identical(psl_read_selection()$record$checksum, first$checksum)
  expect_identical(
    psl_snapshot_integrity(psl_read_selection()$record$checksum),
    "ok"
  )
})

test_that("streams are compacted behind a publication", {
  local_publication_cache()
  url <- "https://example.test/list.dat"
  withr::local_options(pslr.stream_keep = 2L)
  first <- psl_with_source_lock(
    url,
    psl_publish_refresh(url, path = staged_bytes())
  )
  for (i in seq_len(3L)) {
    psl_with_source_lock(
      url,
      psl_publish_refresh(url, checksum = first$checksum)
    )
  }
  expect_length(psl_generation_numbers(psl_selection_stream_dir()), 2L)
  expect_identical(psl_read_selection()$generation, 4L)
})
