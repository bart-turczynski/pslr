# The result cache is owned by the `psl_engine` that holds the matcher it caches
# for (PSLR-bcgedhmy). Two engines built from two snapshots must therefore have
# independent caches: a store into one cannot be observed through the other.

test_that("each engine owns an isolated result cache", {
  rules <- active_rules()
  meta <- active_meta()
  engine_a <- new_psl_engine(new_psl_snapshot(rules, meta))
  engine_b <- new_psl_engine(new_psl_snapshot(rules, meta))

  # Distinct cache objects, both starting empty once initialised.
  expect_false(identical(engine_a$cache, engine_b$cache))
  psl_cache_ensure(engine_a$cache)
  psl_cache_ensure(engine_b$cache)
  expect_identical(engine_a$cache$n, 0L)
  expect_identical(engine_b$cache$n, 0L)

  # Storing into engine A's cache leaves engine B's cache untouched. The store
  # payload is the compact structural record the cache actually holds, built by
  # the same producer the resolver uses.
  records <- psl_match_structural(engine_a$matcher, "example.com", 2L)
  psl_cache_store(engine_a$cache, "2|example.com", records)
  expect_identical(engine_a$cache$n, 1L)
  expect_identical(engine_b$cache$n, 0L)
})

# The public constructor `psl_engine()` builds a fully-formed engine bound to a
# specific snapshot (PSLR-ntqoiglh), never touching the session-global default.

test_that("psl_engine('bundled') builds a bundled engine", {
  e <- psl_engine("bundled")
  expect_s3_class(e, "psl_engine")
  expect_named(e, c("snapshot", "matcher", "cache"))
  expect_s3_class(e$snapshot, "psl_snapshot")
  expect_identical(e$snapshot$meta$source, "bundled")
  expect_false(is.na(e$snapshot$meta$url))
})

test_that("psl_engine('path') builds a path engine from a source file", {
  e <- psl_engine("path", path = bundled_dat_path())
  expect_s3_class(e, "psl_engine")
  expect_identical(e$snapshot$meta$source, "path")
})

test_that("psl_engine validates source and path", {
  expect_error(psl_engine("path"), "single file path")
  expect_error(psl_engine("path", path = tempfile()), "not found")
  expect_error(psl_engine("bundled", path = "x"), "only used when")
  expect_error(psl_engine("nope"), "must be one of")
})

test_that("psl_engine does not disturb the session-global default engine", {
  local_pslr_clean()
  before <- psl_default_engine()
  psl_engine("bundled")
  psl_engine("path", path = bundled_dat_path())
  expect_identical(psl_default_engine(), before)
})

# The `engine =` argument on the public query functions routes a query at a
# specific snapshot instead of the session-global list (PSLR-hflrsfgp). A custom
# path engine carrying a rule absent from the bundled list is the observable
# oracle: its novel suffix resolves through the custom engine but not the
# default.

test_that("engine = queries the intended snapshot, distinct from the default", {
  dat <- withr::local_tempfile(fileext = ".dat")
  writeLines(
    c(
      "// ===BEGIN ICANN DOMAINS===",
      "zzzcustomtld",
      "// ===END ICANN DOMAINS===",
      "// ===BEGIN PRIVATE DOMAINS===",
      "example.zzzcustomtld",
      "// ===END PRIVATE DOMAINS==="
    ),
    dat
  )
  custom <- psl_engine("path", path = dat)

  # The novel suffix resolves through the custom engine but is unknown to the
  # default; `unknown = "na"` makes the difference observable.
  expect_true(is_public_suffix("zzzcustomtld", engine = custom, unknown = "na"))
  expect_identical(is_public_suffix("zzzcustomtld", unknown = "na"), NA)
  expect_identical(
    public_suffix("foo.zzzcustomtld", engine = custom, unknown = "na"),
    "zzzcustomtld"
  )
  expect_identical(
    public_suffix("foo.zzzcustomtld", unknown = "na"),
    NA_character_
  )
})

test_that("engine = psl_default_engine() matches an omitted engine", {
  expect_identical(
    public_suffix("www.example.com", engine = psl_default_engine()),
    public_suffix("www.example.com")
  )
  expect_identical(
    registrable_domain("www.example.co.uk", engine = psl_default_engine()),
    registrable_domain("www.example.co.uk")
  )
})

test_that("a non-engine `engine` argument errors", {
  the_snapshot <- psl_engine("bundled")$snapshot
  expect_error(public_suffix("x", engine = "not an engine"), "psl_engine")
  expect_error(public_suffix("x", engine = the_snapshot), "psl_engine")
})

test_that("print methods summarise without dumping internals", {
  e <- psl_engine("bundled")
  expect_output(print(e), "<psl_engine>")
  expect_output(print(e), "process-local compiled matcher")
  expect_output(print(e), "bundled")
  expect_output(print(e$snapshot), "<psl_snapshot>")
  capture.output(res <- withVisible(print(e)))
  expect_false(res$visible)
})
