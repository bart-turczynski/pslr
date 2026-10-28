# pslr (development version)

# pslr 1.2.2

* The bundled index is built under `punycoder` 1.3.0, and `Imports:` now requires `punycoder (>= 1.3.0)`, so loading pslr no longer rebuilds it (PSLR-fjkaqckg).
* A v1 cache whose recorded checksum pslr cannot verify, such as `SHA256:nothex`, gets one diagnosis everywhere, and `psl_status("cache")` reports it as `unknown` (PSLR-izeypfus).
* `psl_refresh()` sends an `ETag` back byte for byte, even one that is not valid UTF-8, and a `200` with a new body drops the old body's validator (PSLR-tiugfvxh).
* A cache whose recorded checksum is not valid UTF-8 is read as a malformed checksum instead of failing with an encoding error (PSLR-vqrwsjar).
* `psl_refresh()` reads response headers that are not valid UTF-8, and classes a libcurl failure by curl's error class, not by the host name (PSLR-mlnfdltl).
* A cache checksum spelled in upper or mixed case, such as `SHA256:<hex>`, now reads as that checksum in activation, migration and status (PSLR-nffupurr).
* `psl_refresh()` reports a libcurl failure whose message is not valid UTF-8 as a classed transport error (PSLR-ejksqarh).
* The bundled list loads, and lowercase comparisons hold, under a Turkish or Azerbaijani locale (PSLR-yomylzid).
* New `vignette("comparison")` compares pslr with other PSL libraries (SEOR-kqmqosji).
* `cucumber` is no longer in `Suggests` (PSLR-lohhvukn).

# pslr 1.2.1

* Parsing the Public Suffix List is roughly 7x faster: `read_psl_file()` on the bundled list drops from 11.97s to 1.69s, with byte-identical output (PSLR-ufhllfer).
* `BugReports` points at the GitLab `/-/issues` form that CRAN's incoming check requires; GitLab redirects browsers from it to `/-/work_items` (PSLR-cmkufiww).

# pslr 1.2.0

* The bundled Public Suffix List moves from upstream `9186eeed` (2026-06-13) to `46ae48ce` (2026-09-05), 10,212 to 10,323 rules. **This changes query results for real domains** (PSLR-ucvugmsw).
* **Breaking:** `psl_snapshots()`'s `normalization_profile` column is renamed `first_normalization_profile`, the profile its bytes were first published under; `psl_version()` reports the one queries run under (PSLR-girwpagy).
* **Breaking:** `psl_outdated()` is removed; use `psl_status()` for freshness and `psl_reminder()` for a periodic nudge (PSLR-hvjaloik).
* **Breaking:** `psl_refresh()`'s `activate` and `force` are named-only, after `...`; a positional `psl_refresh(url, TRUE)` is now an error (PSLR-nngpirsm).
* **Breaking:** the v1 cache is superseded by a content-addressed snapshot store; the first `psl_refresh()` or `psl_cache_prune()` migrates it, and v1 files are never deleted (PSLR-vlkspnkb).
* New `psl_diff(old, new)` reports rules added, removed or changed between two locally available snapshots, offline and without activating either (PSLR-aeuaykkf).
* New `psl_status()` reports offline the strongest freshness claim the local evidence supports: `confirmed_current`, `check_due`, `update_available`, `never_checked`, `untracked`, `missing` or `unknown` (PSLR-sbuyclkb).
* `psl_refresh()` sends a conditional request and returns a `psl_refresh_result` naming one of `skipped_recently`, `not_modified`, `downloaded_unchanged` or `updated`; failures signal classed errors rooted at `pslr_refresh_error` (PSLR-cldlmtiy).
* `psl_refresh()` sends `If-None-Match` or `If-Modified-Since`, waits at least 24 hours between downloads, and caps responses at 16 MiB; `force = TRUE` skips only the courtesy window (PSLR-nohexwgs).
* `psl_refresh()` accepts only an absolute `https` URL without userinfo, query or fragment, and follows at most five same-origin `https` redirects (PSLR-tvjzlksq).
* Snapshots are identified by SHA-256 of their source bytes and kept until pruned; `digest` moves from `Suggests` to `Imports` (PSLR-vlkspnkb).
* Concurrent refreshes of one source are serialized, and an interrupted or failed refresh leaves the cache, the selected snapshot and the active matcher unchanged (PSLR-owqhbrli).
* A source's `retrieved_at` and `checked_at` no longer move backwards when the system clock does (PSLR-usocggvm).
* New `psl_reminder(enable, every)` sets an opt-in, offline freshness reminder that `library(pslr)` prints at most once per session (PSLR-zfdsaciu).
* New `psl_snapshots()` lists every locally resolvable snapshot with its `integrity`; `verify = TRUE` rehashes the stored bytes (PSLR-umwatxje).
* `psl_cache_prune()` keeps every snapshot that is selected, active or named by a source, plus the `keep` most recently retrieved, and prunes nothing when state is unreadable (PSLR-kdjvxtpk).
* A fresh install reports the bundled snapshot as `never_checked` instead of `untracked`, since it now records the canonical refresh endpoint (PSLR-jujniexk).
* The bundled index is built under CRAN's `punycoder` 1.2.1, so loading pslr no longer rebuilds it in memory, which cost about 2.75 s per session (PSLR-fjkaqckg).
* Queries and reading a PSL source file no longer depend on the session locale; under a non-UTF-8 locale, non-ASCII hosts returned `NA` and the reader truncated the list (PSLR-jzdhhugc).
* Undecodable input is reported as invalid, so `invalid = "na"` returns `NA`, instead of aborting with an internal regex error (PSLR-jzdhhugc).
* Loading pslr no longer warns `strings not representable in native encoding` under a non-UTF-8 locale; non-ASCII results carry UTF-8 marks (PSLR-jzdhhugc).
* `URL` and `BugReports` now name GitLab and the site <https://bart-turczynski.gitlab.io/pslr/>; the GitHub URLs no longer resolve (PSLR-thcaqtnw).
* The vignette, README and reference index document freshness, the refresh outcomes, reminders, scheduling `pslr::psl_refresh()` and snapshot pruning (PSLR-hvjaloik).
* `?pslr` now carries a runnable quick tour of the core queries (PSLR-aquayvhw).

# pslr 1.1.1

* `pslr` installs from CRAN alone: `punycoder (>= 1.1.0)` replaces the development `Remotes:` pin, and `punycoder` 1.2.x is supported (PSLR-xwcqnnls).
* A one-shot query with more distinct hosts than the result cache holds no longer flushes the existing cache entries (PSLR-wyvauroc).

# pslr 1.1.0

* The core matcher is a reverse-label trie, roughly halving direct-match time on cache-cold, large-batch and cache-disabled workloads; results are byte-identical (PSLR-rqcslhfc).
* The five query functions gain an optional `engine=` argument to query a specific `psl_engine()` snapshot instead of the session-global list (PSLR-hflrsfgp).
* New `psl_engine()` builds a self-contained, process-local engine from the bundled list or a path, without `psl_use()` (PSLR-ntqoiglh).
* `psl_version()` gains a `url` column: the upstream download URL for the bundled list, `NA` for cache or custom-path sources (PSLR-qcvrfoun).
* `output = "unicode"` decodes each distinct A-label once per call, so batches with repeated hosts are markedly faster (PSLR-cpzrjksw).
* Queries skip a per-call `strsplit()`, and the result cache is pre-sized to a large cold batch instead of rehashing as it fills; results are unchanged (PSLR-gtvggjmd).
* Queries are faster: the result cache is columnar, misses derive strings with vectorized `substr()`, and a warm scalar `registrable_domain()` costs roughly half.
* The default session-cache bound rises from 50,000 to 200,000 entries, about 16 MB when full.
* Rebuilding the list from source is roughly 3x faster; output is byte-identical (PSLR-wanopbqy).
* New `psl_cache_prune()` removes superseded cache snapshots, keeping the active one plus the `keep` most recent (PSLR-nwdejhkf).
* Cache checksums are verified with the algorithm their `sha256:` or `md5:` prefix names, so a cache no longer reads as corrupt on a machine without `digest` (PSLR-mxohlxiq).
* A malformed `current.rds` cache marker raises the cache-corruption error advising `psl_refresh(force = TRUE)` instead of silently reading `NULL` (PSLR-nwdejhkf).
* New `psl_outdated()` reports whether the active snapshot is older than a threshold, 180 days by default, with its age in the `"age_days"` attribute (#62).
* New `options(pslr.cache = FALSE)` disables the session result cache; results are byte-identical, and one-shot batches of mostly unique hosts run faster.

# pslr 1.0.2

* Calls `punycoder::host_normalize()` without the `strict` argument, which the upcoming `punycoder` release removes, so pslr stays installable against it.

# pslr 1.0.1

Launch-readiness audit follow-ups (no API changes).

* `suffix_extract(output = "unicode")` reports an absent subdomain as `""`, not `NA`, as `"ascii"` output does.
* Choice-style option arguments such as `section` and `invalid` abort on a non-scalar value instead of silently using the first choice.
* A corrupt `current.rds` cache marker no longer leaks a raw `readRDS()` error: `psl_refresh(force = TRUE)` republishes, and `psl_use("cache")` reports cache corruption.
* PSL sources with a repeated ICANN or PRIVATE section are rejected.
* A zero-length non-character `domain`, such as `NULL`, aborts with the documented type error; `character(0)` still returns a zero-length result.

# pslr 1.0.0

First public release: a spec-complete Public Suffix List engine for R.

* Bundles the Public Suffix List pinned to upstream commit `9186eee` (2026-06-13), with generation metadata and MPL-2.0 data licensing separate from the MIT code.
* Query API: `public_suffix()`, `registrable_domain()`, `is_public_suffix()`, `suffix_extract()` and `public_suffix_rule()`, vectorized, NA-safe, canonicalized through `punycoder`, with a bounded session cache.
* `psl_refresh()` is the only network path: https-only, size-capped, validated, throttled to once a day, and atomically published, never replacing a valid cache after a failure.
* `psl_use()` switches the active list between the bundled snapshot, the cache and a custom path; `psl_version()` and `psl_rules()` report the active list.
* A repeated host costs one `punycoder` normalization and one matcher call.
