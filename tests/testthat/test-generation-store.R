test_that("generation names are fixed-width and round-trip", {
  expect_identical(psl_generation_name(1L), "00000001.rds")
  expect_identical(psl_generation_name(42), "00000042.rds")
  expect_identical(psl_generation_name(99999999L), "99999999.rds")
  expect_error(psl_generation_name(0L), "single positive whole number")
  expect_error(psl_generation_name(1.5), "single positive whole number")
  expect_error(psl_generation_name(NA_integer_), "single positive whole number")
  expect_error(psl_generation_name(100000000), "stream limit")
})

test_that("directory seams stay hermetic and option-driven", {
  cache <- withr::local_tempdir()
  config <- withr::local_tempdir()
  withr::local_options(pslr.cache_dir = cache, pslr.config_dir = config)
  expect_identical(psl_config_dir(), config)
  expect_identical(psl_selection_stream_dir(), file.path(cache, "selections"))
  expect_identical(psl_reminder_stream_dir(), file.path(config, "reminder"))
  expect_identical(
    psl_source_stream_dir("https://example.test/list.dat"),
    file.path(
      cache,
      "sources",
      psl_source_stream_name("https://example.test/list.dat")
    )
  )
})

test_that("an empty or absent stream reads as empty", {
  dir <- withr::local_tempdir()
  missing <- file.path(dir, "never-created")
  expect_identical(psl_store_read(missing)$status, "empty")
  expect_null(psl_store_read(missing)$record)
  expect_identical(psl_store_read(dir)$status, "empty")
  expect_identical(psl_store_read(dir)$generation, NA_integer_)
  expect_length(psl_generation_numbers(missing), 0L)
})

test_that("appending publishes consecutive immutable generations", {
  dir <- file.path(withr::local_tempdir(), "selections")
  checksum <- paste0("sha256:", strrep("a", 64L))
  stamp <- "2026-01-01T00:00:00Z"
  first <- psl_store_append(
    dir,
    \(g) new_psl_selection(checksum, generation = g),
    validate_psl_selection
  )
  expect_identical(basename(first), "00000001.rds")
  second <- psl_store_append(
    dir,
    \(g) new_psl_selection(checksum, generation = g, selected_at = stamp),
    NULL
  )
  expect_identical(basename(second), "00000002.rds")
  expect_identical(psl_generation_numbers(dir), c(1L, 2L))
  # The first generation is still byte-identical: publication never overwrites.
  expect_identical(readRDS(first)$selected_at, NA_character_)
  expect_identical(readRDS(second)$selected_at, stamp)
})

test_that("the appended record's generation matches its file name", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("b", 64L))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$status, "ok")
  expect_identical(read$generation, 2L)
  expect_identical(read$record$generation, 2L)
})

test_that("appending refuses a record stamped with another generation", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("c", 64L))
  expect_error(
    psl_store_append(dir, \(g) new_psl_selection(checksum, generation = 7L)),
    "does not match published generation"
  )
  expect_length(psl_generation_numbers(dir), 0L)
})

test_that("appending validates before publishing anything", {
  dir <- withr::local_tempdir()
  expect_error(
    psl_store_append(
      dir,
      \(g) list(schema_version = 1L, generation = g),
      validate_psl_selection
    ),
    "missing field"
  )
  expect_length(psl_generation_numbers(dir), 0L)
  expect_error(psl_store_append(dir, "not a function"), "must be a function")
})

test_that("readers ignore an interrupted write's temporary file", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("d", 64L))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  # Simulate a crash between temporary write and rename.
  writeBin(as.raw(c(0L, 1L, 2L)), file.path(dir, "tmp-crash.part"))
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$status, "ok")
  expect_identical(read$generation, 1L)
  expect_identical(psl_generation_numbers(dir), 1L)
  # The next append still lands on generation 2, ignoring the debris.
  path <- psl_store_append(dir, \(g) {
    new_psl_selection(checksum, generation = g)
  })
  expect_identical(basename(path), "00000002.rds")
  expect_true(file.exists(file.path(dir, "tmp-crash.part")))
})

test_that("a malformed newest generation is recovered, not passed off as ok", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("e", 64L))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  writeBin(as.raw(c(3L, 4L, 5L)), file.path(dir, "00000003.rds"))
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$status, "recovered")
  expect_identical(read$generation, 2L)
  expect_length(read$faults, 1L)
  expect_identical(read$faults[[1L]]$generation, 3L)
  expect_identical(read$faults[[1L]]$reason, "unreadable")
})

test_that("a structurally broken generation is reported as invalid", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("f", 64L))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  broken <- new_psl_selection(checksum, generation = 2L)
  broken$checksum <- "not-a-checksum"
  saveRDS(broken, file.path(dir, "00000002.rds"))
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$status, "recovered")
  expect_identical(read$generation, 1L)
  expect_identical(read$faults[[1L]]$reason, "invalid")
})

test_that("an unknown schema version is classified as such", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("a", 64L))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  future <- new_psl_selection(checksum, generation = 2L)
  future$schema_version <- 99L
  saveRDS(future, file.path(dir, "00000002.rds"))
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$status, "recovered")
  expect_identical(read$faults[[1L]]$reason, "unsupported_schema")
})

test_that("a stream with no valid generation reads as corrupt", {
  dir <- withr::local_tempdir()
  writeBin(as.raw(c(9L, 9L)), file.path(dir, "00000001.rds"))
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$status, "corrupt")
  expect_null(read$record)
  expect_identical(read$generation, NA_integer_)
  expect_length(read$faults, 1L)
})

test_that("gaps inside the retained range are reported", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("b", 64L))
  for (generation in c(1L, 2L, 4L)) {
    saveRDS(
      new_psl_selection(checksum, generation = generation),
      file.path(dir, psl_generation_name(generation))
    )
  }
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$gaps, 3L)
  expect_identical(read$generation, 4L)
  # A stream trimmed from the bottom is not a gap: compaction does that.
  unlink(file.path(dir, "00000001.rds"))
  expect_identical(psl_store_read(dir, validate_psl_selection)$gaps, 3L)
  unlink(file.path(dir, "00000002.rds"))
  expect_length(psl_store_read(dir, validate_psl_selection)$gaps, 0L)
})

test_that("compaction retains the latest and at least one older generation", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("c", 64L))
  for (i in seq_len(5L)) {
    psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  }
  removed <- psl_store_compact(dir, keep = 2L, validate_psl_selection)
  expect_identical(
    basename(removed),
    c("00000001.rds", "00000002.rds", "00000003.rds")
  )
  expect_identical(psl_generation_numbers(dir), c(4L, 5L))
  read <- psl_store_read(dir, validate_psl_selection)
  expect_identical(read$status, "ok")
  expect_identical(read$generation, 5L)
  # Compaction never renumbers: the next append continues the sequence.
  path <- psl_store_append(dir, \(g) {
    new_psl_selection(checksum, generation = g)
  })
  expect_identical(basename(path), "00000006.rds")
})

test_that("compaction cannot remove the only valid generation", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("d", 64L))
  psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  expect_length(psl_store_compact(dir, keep = 2L, validate_psl_selection), 0L)
  expect_identical(psl_generation_numbers(dir), 1L)

  # Even surrounded by corruption, the sole valid generation survives.
  writeBin(as.raw(c(1L, 2L)), file.path(dir, "00000002.rds"))
  writeBin(as.raw(c(1L, 2L)), file.path(dir, "00000003.rds"))
  expect_length(psl_store_compact(dir, keep = 2L, validate_psl_selection), 0L)
  expect_identical(psl_generation_numbers(dir), c(1L, 2L, 3L))
})

test_that("compaction keeps corrupt newer generations so faults stay visible", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("e", 64L))
  for (i in seq_len(4L)) {
    psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  }
  writeBin(as.raw(c(7L, 7L)), file.path(dir, "00000005.rds"))
  psl_store_compact(dir, keep = 2L, validate_psl_selection)
  expect_identical(psl_generation_numbers(dir), c(3L, 4L, 5L))
  expect_identical(
    psl_store_read(dir, validate_psl_selection)$status,
    "recovered"
  )
})

test_that("compaction leaves temporary files to their writer", {
  dir <- withr::local_tempdir()
  checksum <- paste0("sha256:", strrep("f", 64L))
  for (i in seq_len(4L)) {
    psl_store_append(dir, \(g) new_psl_selection(checksum, generation = g))
  }
  tmp <- file.path(dir, "tmp-live.part")
  writeBin(as.raw(0L), tmp)
  psl_store_compact(dir, keep = 2L, validate_psl_selection)
  expect_true(file.exists(tmp))
})

test_that("compaction refuses a keep below two", {
  dir <- withr::local_tempdir()
  expect_error(psl_store_compact(dir, keep = 1L), "at least two")
  expect_error(psl_store_compact(dir, keep = 0L), "at least two")
  expect_error(psl_store_compact(dir, keep = 2.5), "at least two")
  expect_error(psl_store_compact(dir, keep = NA_integer_), "at least two")
})

test_that("the store carries reminder and source records unchanged", {
  cache <- withr::local_tempdir()
  config <- withr::local_tempdir()
  withr::local_options(pslr.cache_dir = cache, pslr.config_dir = config)

  psl_store_append(
    psl_reminder_stream_dir(),
    \(g) new_psl_reminder_pref(TRUE, interval = 3L, generation = g),
    validate_psl_reminder_pref
  )
  reminder <- psl_store_read(
    psl_reminder_stream_dir(),
    validate_psl_reminder_pref
  )
  expect_identical(reminder$status, "ok")
  expect_identical(reminder$record$interval, 3L)

  url <- "https://example.test/public_suffix_list.dat"
  psl_store_append(
    psl_source_stream_dir(url),
    \(g) new_psl_source_state(url, generation = g, last_result = "updated"),
    validate_psl_source_state
  )
  source_state <- psl_store_read(
    psl_source_stream_dir(url),
    validate_psl_source_state
  )
  expect_identical(source_state$record$request_url, url)
  expect_identical(source_state$record$last_result, "updated")
})
