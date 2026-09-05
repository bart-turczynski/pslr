# `psl_snapshots()` is pure inspection: every test here runs offline, against a
# private cache directory. Nothing in this file makes a request, and the
# inventory is driven by publishing snapshots and records directly.

# Publish bytes into the snapshot store and return their checksum identity.
# The bytes are opaque unless a test activates them -- the inventory never
# parses a list.
publish_inventory_bytes <- function(text = "// psl bytes\n", ...) {
  path <- tempfile("pslr-inventory-", fileext = ".dat")
  con <- file(path, open = "wb")
  writeBin(charToRaw(text), con)
  close(con)
  psl_with_publish_lock(psl_publish_snapshot(path, ...))$checksum
}

publish_inventory_source <- function(checksum, url = psl_official_url, ...) {
  psl_with_publish_lock(
    psl_publish_source_state(url, checksum = checksum, ...)
  )
}

publish_inventory_selection <- function(checksum, url = psl_official_url) {
  psl_with_publish_lock(psl_publish_selection(checksum, request_url = url))
}

# The row for one checksum, as a one-row inventory.
inventory_row <- function(snapshots, checksum) {
  snapshots[snapshots$checksum == checksum, ]
}

# Overwrite published bytes without touching their descriptor.
overwrite_inventory_bytes <- function(checksum, text) {
  path <- psl_snapshot_bytes_path(checksum)
  con <- file(path, open = "wb")
  writeBin(charToRaw(text), con)
  close(con)
  invisible(path)
}

# Replace the newest generation of a stream with unreadable bytes.
corrupt_inventory_stream <- function(dir) {
  generations <- psl_generation_numbers(dir)
  target <- if (length(generations)) max(generations) else 1L
  writeLines("not an rds file", file.path(dir, psl_generation_name(target)))
  invisible(dir)
}

# Every file in the cache tree with its size and modification time, which is
# what a read-only call must leave untouched.
cache_fingerprint <- function(dir) {
  files <- sort(
    list.files(dir, recursive = TRUE, all.files = TRUE, no.. = TRUE),
    method = "radix"
  )
  info <- file.info(file.path(dir, files))
  list(files = files, size = info$size, mtime = info$mtime)
}

inventory_lines <- function(x) paste(format(x), collapse = "\n")

test_that("the inventory has the documented columns, types, and shape", {
  local_pslr_clean()
  snapshots <- psl_snapshots()
  expect_s3_class(snapshots, "psl_snapshots")
  expect_s3_class(snapshots, "data.frame")
  expect_named(
    snapshots,
    c(
      "checksum",
      "path",
      "size",
      "content_date",
      "first_retrieved_at",
      "origin_url",
      "first_normalization_profile",
      "bundled",
      "selected_cache",
      "active",
      "current_for_any_source",
      "source_count",
      "integrity"
    )
  )
  expect_type(snapshots$checksum, "character")
  expect_type(snapshots$path, "character")
  expect_type(snapshots$size, "integer")
  expect_s3_class(snapshots$content_date, "POSIXct")
  expect_s3_class(snapshots$first_retrieved_at, "POSIXct")
  expect_type(snapshots$origin_url, "character")
  expect_type(snapshots$first_normalization_profile, "character")
  expect_type(snapshots$bundled, "logical")
  expect_type(snapshots$selected_cache, "logical")
  expect_type(snapshots$active, "logical")
  expect_type(snapshots$current_for_any_source, "logical")
  expect_type(snapshots$source_count, "integer")
  expect_type(snapshots$integrity, "character")
})

test_that("an empty cache still inventories the bundled snapshot", {
  local_pslr_clean()
  snapshots <- psl_snapshots()
  expect_identical(nrow(snapshots), 1L)
  expect_identical(snapshots$checksum, pslr_bundled$meta$checksum)
  expect_true(snapshots$bundled)
  expect_identical(snapshots$integrity, "ok")
  expect_identical(snapshots$path, bundled_dat_path())
  expect_identical(snapshots$size, as.integer(pslr_bundled$meta$size))
  expect_false(is.na(snapshots$content_date))
  expect_identical(snapshots$origin_url, pslr_bundled$meta$url)
  expect_identical(
    snapshots$first_normalization_profile,
    pslr_bundled$meta$normalization_profile
  )
  expect_identical(snapshots$source_count, 0L)
  expect_false(snapshots$selected_cache)
  expect_false(snapshots$current_for_any_source)
})

test_that("the bundled snapshot is the active one by default", {
  local_pslr_clean()
  snapshots <- psl_snapshots()
  expect_true(snapshots$active)
})

test_that("each distinct checksum is exactly one row, ordered by checksum", {
  local_pslr_clean()
  first <- publish_inventory_bytes("// one\n")
  second <- publish_inventory_bytes("// two\n")
  snapshots <- psl_snapshots()
  expect_identical(nrow(snapshots), 3L)
  expect_identical(anyDuplicated(snapshots$checksum), 0L)
  expect_setequal(
    snapshots$checksum,
    c(pslr_bundled$meta$checksum, first, second)
  )
  expect_identical(
    snapshots$checksum,
    sort(snapshots$checksum, method = "radix")
  )
})

test_that("republishing the same bytes does not add a second row", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// same\n")
  again <- publish_inventory_bytes("// same\n")
  expect_identical(again, checksum)
  expect_identical(nrow(psl_snapshots()), 2L)
})

test_that("duplicate storage locations collapse into one preferred row", {
  local_pslr_clean()
  # The bundled bytes published into the cache are the same identity in two
  # places: one row, and the cache copy is the preferred path.
  staged <- tempfile("pslr-bundled-", fileext = ".dat")
  file.copy(bundled_dat_path(), staged)
  checksum <- psl_with_publish_lock(psl_publish_snapshot(staged))$checksum
  expect_identical(checksum, pslr_bundled$meta$checksum)
  snapshots <- psl_snapshots()
  expect_identical(nrow(snapshots), 1L)
  expect_true(snapshots$bundled)
  expect_identical(snapshots$path, psl_snapshot_bytes_path(checksum))
  expect_identical(snapshots$integrity, "ok")
})

test_that("provenance comes from the snapshot descriptor", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes(
    "// described\n",
    content_date = "2026-05-01T00:00:00Z",
    origin_url = "https://example.org/psl.dat",
    first_retrieved_at = "2026-05-02T03:04:05Z"
  )
  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(
    format(row$content_date, "%Y-%m-%d", tz = "UTC"),
    "2026-05-01"
  )
  expect_identical(
    format(row$first_retrieved_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "2026-05-02T03:04:05Z"
  )
  expect_identical(row$origin_url, "https://example.org/psl.dat")
  expect_identical(
    row$first_normalization_profile,
    psl_runtime_snapshot_profile()$normalization_profile
  )
  expect_identical(row$size, 13L)
})

# PSLR-girwpagy. The normalization fields on a descriptor record the normalizer
# that was installed when the bytes were first published, not the one a later
# session queries under. The inventory column says so in its name, and the two
# public provenance APIs are no longer permitted to contradict each other about
# what they mean.
test_that("the inventory reports first-publication normalization provenance", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// published under the old profile\n")
  published_under <- psl_runtime_snapshot_profile()$normalization_profile

  # A later session with a different normalizer installed.
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

  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(row$first_normalization_profile, published_under)
  expect_identical(psl_version()$normalization_profile, "fake-profile")
  # Distinct facts, distinctly named: the stale value is never presented as the
  # profile in use.
  expect_false(
    identical(
      row$first_normalization_profile,
      psl_version()$normalization_profile
    )
  )
})

# Re-publishing must not rewrite the recorded profile: it is what these bytes
# were first published under, and that does not become untrue later.
test_that("republishing under a new profile keeps the first one recorded", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// stable provenance\n")
  published_under <- psl_runtime_snapshot_profile()$normalization_profile
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
  again <- publish_inventory_bytes("// stable provenance\n")
  expect_identical(again, checksum)
  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(row$first_normalization_profile, published_under)
})

test_that("absent bytes report integrity missing", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// gone\n")
  unlink(psl_snapshot_bytes_path(checksum))
  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(row$integrity, "missing")
  expect_identical(row$path, NA_character_)
})

test_that("a reference to a pruned snapshot is inventoried as missing", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// pruned\n")
  publish_inventory_selection(checksum)
  unlink(list.files(psl_snapshot_dir(), full.names = TRUE))
  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(nrow(row), 1L)
  expect_identical(row$integrity, "missing")
  expect_true(row$selected_cache)
})

test_that("an unreadable descriptor reports integrity unknown_schema", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// schema\n")
  saveRDS(
    list(schema_version = 99L),
    file.path(
      psl_snapshot_dir(),
      paste0(sub(":", "-", checksum, fixed = TRUE), ".rds")
    )
  )
  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(row$integrity, "unknown_schema")
})

test_that("bytes of the wrong size are a mismatch without rehashing", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// original bytes\n")
  overwrite_inventory_bytes(checksum, "// short\n")
  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(row$integrity, "checksum_mismatch")
})

test_that("same-size corruption is only caught by verify = TRUE", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// aaaaaaa\n")
  overwrite_inventory_bytes(checksum, "// bbbbbbb\n")
  expect_identical(inventory_row(psl_snapshots(), checksum)$integrity, "ok")
  verified <- inventory_row(psl_snapshots(verify = TRUE), checksum)
  expect_identical(verified$integrity, "checksum_mismatch")
})

test_that("the selected cache snapshot is flagged", {
  local_pslr_clean()
  selected <- publish_inventory_bytes("// selected\n")
  other <- publish_inventory_bytes("// other\n")
  publish_inventory_selection(selected)
  snapshots <- psl_snapshots()
  expect_true(inventory_row(snapshots, selected)$selected_cache)
  expect_false(inventory_row(snapshots, other)$selected_cache)
  expect_identical(sum(snapshots$selected_cache), 1L)
})

test_that("an unreadable selection stream flags no snapshot as selected", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// selected\n")
  publish_inventory_selection(checksum)
  corrupt_inventory_stream(psl_selection_stream_dir())
  expect_identical(sum(psl_snapshots()$selected_cache), 0L)
})

test_that("the active cache snapshot is flagged", {
  local_pslr_clean()
  path <- write_test_list()
  checksum <- psl_source_checksum(path)
  publish_inventory_bytes(readChar(path, file.size(path), useBytes = TRUE))
  publish_inventory_selection(checksum)
  psl_use("cache")
  snapshots <- psl_snapshots()
  expect_true(inventory_row(snapshots, checksum)$active)
  expect_false(inventory_row(snapshots, pslr_bundled$meta$checksum)$active)
})

test_that("source_count counts every source that names the same bytes", {
  local_pslr_clean()
  shared <- publish_inventory_bytes("// shared\n")
  lonely <- publish_inventory_bytes("// lonely\n")
  publish_inventory_source(shared, url = psl_official_url)
  publish_inventory_source(shared, url = "https://mirror.example.net/psl.dat")
  snapshots <- psl_snapshots()
  expect_identical(inventory_row(snapshots, shared)$source_count, 2L)
  expect_true(inventory_row(snapshots, shared)$current_for_any_source)
  expect_identical(inventory_row(snapshots, lonely)$source_count, 0L)
  expect_false(inventory_row(snapshots, lonely)$current_for_any_source)
})

test_that("a recovered source stream counts but confirms nothing", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// recovered\n")
  publish_inventory_source(checksum)
  publish_inventory_source(checksum)
  corrupt_inventory_stream(psl_source_stream_dir(psl_official_url))
  row <- inventory_row(psl_snapshots(), checksum)
  expect_identical(row$source_count, 1L)
  expect_false(row$current_for_any_source)
})

test_that("the inventory never exposes a source request URL", {
  local_pslr_clean()
  secret <- "https://internal.example.com/private-suffix-list.dat"
  checksum <- publish_inventory_bytes("// private\n")
  publish_inventory_source(checksum, url = secret)
  publish_inventory_selection(checksum, url = secret)
  snapshots <- psl_snapshots()
  host <- "internal.example.com"
  cells <- unlist(lapply(snapshots, as.character), use.names = FALSE)
  expect_false(any(grepl(host, cells, fixed = TRUE)))
  expect_false(any(grepl(host, names(snapshots), fixed = TRUE)))
  expect_no_match(inventory_lines(snapshots), host, fixed = TRUE)
  expect_identical(inventory_row(snapshots, checksum)$source_count, 1L)
})

test_that("the inventory writes nothing, even when verifying", {
  local_pslr_clean()
  dir <- getOption("pslr.cache_dir")
  checksum <- publish_inventory_bytes("// untouched\n")
  publish_inventory_source(checksum)
  publish_inventory_selection(checksum)
  before <- cache_fingerprint(dir)
  psl_snapshots()
  psl_snapshots(verify = TRUE)
  after <- cache_fingerprint(dir)
  expect_identical(after$files, before$files)
  expect_identical(after$size, before$size)
  expect_identical(after$mtime, before$mtime)
})

test_that("the inventory creates no cache directory at all", {
  local_pslr_clean()
  dir <- file.path(getOption("pslr.cache_dir"), "absent")
  withr::local_options(pslr.cache_dir = dir)
  expect_identical(nrow(psl_snapshots()), 1L)
  expect_false(dir.exists(dir))
})

test_that("unexpected arguments and a bad verify flag are errors", {
  local_pslr_clean()
  expect_error(psl_snapshots(TRUE), "Unexpected argument")
  expect_error(psl_snapshots(nonsense = TRUE), "Unexpected argument")
  expect_error(psl_snapshots(verify = NA), "`verify` must be")
  expect_error(psl_snapshots(verify = c(TRUE, TRUE)), "`verify` must be")
})

test_that("printing describes each snapshot and its role", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// printed\n")
  publish_inventory_selection(checksum)
  printed <- inventory_lines(psl_snapshots())
  expect_match(printed, "<psl_snapshots: 2 snapshots>")
  expect_match(printed, "bundled, active")
  expect_match(printed, "selected")
  expect_match(printed, substr(sub("^sha256:", "", checksum), 1L, 12L))
})

test_that("printing marks a damaged snapshot", {
  local_pslr_clean()
  checksum <- publish_inventory_bytes("// damaged\n")
  unlink(psl_snapshot_bytes_path(checksum))
  printed <- inventory_lines(psl_snapshots())
  expect_match(printed, "[missing]", fixed = TRUE)
  expect_match(printed, "unreferenced")
})

test_that("a column subset prints as an ordinary data frame", {
  local_pslr_clean()
  columns <- psl_snapshots()[c("checksum", "integrity")]
  expect_output(print(columns), "integrity")
  expect_no_match(paste(format(columns), collapse = "\n"), "<psl_snapshots")
})

test_that("print returns the inventory invisibly", {
  local_pslr_clean()
  snapshots <- psl_snapshots()
  expect_output(returned <- print(snapshots), "psl_snapshots")
  expect_identical(returned, snapshots)
})
