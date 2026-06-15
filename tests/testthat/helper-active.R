# Test helpers for refresh / activation (PRD s7.4, s11.3).

# Path to the bundled PSL source snapshot used as an offline download fixture.
bundled_dat_path <- function() {
  system.file("extdata", "public_suffix_list.dat", package = "pslr")
}

# A downloader test double that copies a local file into place instead of
# touching the network. Defaults to the bundled snapshot; pass another path to
# simulate a different upstream response.
fake_downloader <- function(src = bundled_dat_path()) {
  force(src)
  function(url, destfile, max_bytes) {
    if (!file.copy(src, destfile, overwrite = TRUE)) {
      stop("fake downloader could not stage fixture", call. = FALSE)
    }
    invisible(destfile)
  }
}

# Isolate session state for one test: a private cache directory, no leaked
# downloader, and a reset active list before and after the test body.
local_pslr_clean <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(
    pslr.cache_dir = dir, pslr.downloader = NULL, pslr.max_bytes = NULL,
    .local_envir = env
  )
  psl_reset_active()
  withr::defer(psl_reset_active(), envir = env)
  dir
}
