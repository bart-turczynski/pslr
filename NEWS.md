# pslr 1.2.0

* **Parsing the Public Suffix List is roughly 7x faster.** `parse_psl_lines()` preallocated its rule columns but then wrote each row through a helper function, which made the columns referenced twice and copied all of them on every rule -- quadratic in the number of rules, defeating the preallocation it was paired with. The writes are now in place. On the bundled list (10,323 rules) `read_psl_file()` drops from 11.97s to 1.69s with byte-identical output, and the package's own test suite drops from 486s to 201s. No behavior changes (PSLR-ufhllfer).

* The bundled Public Suffix List snapshot is updated from upstream commit `9186eeed` (2026-06-13) to `46ae48ce` (2026-09-05), a net +140 / -29 rules, 10212 to 10323. **This changes query results for real domains.** Notable additions: `*.eth.limo` and `*.eth.link`, `*.aivencloud.com`, `*.cursorusercontent.com`, `claudeusercontent.com`, `mygov.scot`, the `web` gTLD, a block of 72 regional `*-01.azurewebsites.net` entries, and the Norwegian renames `audnedaln.no` to `audnedal.no` and `hamarøy.no`. Notable removals: `aivencloud.com` (narrowed to the wildcard form), `adaptable.app`, `deta.app`, `deta.dev`, `ac.tj`, `biz.at`, `info.at`, `mayfirst.org`, `protonet.io` and `xnbay.com`. The official upstream test vectors are unchanged between the two commits and still pass (PSLR-ucvugmsw).

* **Breaking:** `psl_snapshots()`'s `normalization_profile` column is renamed `first_normalization_profile`, and is documented as first-publication provenance. A snapshot descriptor records the normalizer that was installed when those bytes were first published, but pslr re-parses source bytes under the *runtime* normalizer at every load, so after a punycoder upgrade the inventory reported a profile that was no longer in use anywhere -- contradicting `psl_version()` about the same active snapshot in the same session. The column now says in its name which of the two facts it carries; `psl_version()` remains the profile a query actually runs under. The value is also read from the location the row describes rather than coalesced across storage locations, because two locations holding identical bytes can honestly disagree about it. Query results are unaffected (PSLR-girwpagy).

* The built pkgdown site is no longer packaged. `_pkgdown.yml` writes to `site/`, which `.Rbuildignore` never learned about when the destination changed, so 3.5 MB of generated documentation was carried into the tarball and every `R CMD check` reported a non-standard top-level directory (PSLR-epkkemop).

* `tools/verify.sh` no longer reports a passing `cran` tier for an `R CMD check` that aborted. The tier inlined its own `rcmdcheck()` call to enable the CRAN incoming checks and did not carry over the `00check.log` guard that `run_check()` exists to apply, so a timeout fetching CRAN's `archive.rds` halted the check at its first step and was summarised as "0 errors | 0 warnings | 0 notes". Both tiers now go through `run_check`, and the remote form raises the child process's download timeout past R's 60-second default (PSLR-zibafvbq).

* GitHub is fully retired from the repository. New commits are authored to <bartek@turczynski.pl> rather than a noreply address on the suspended GitHub account, and a `.mailmap` makes the 172 existing commits read the same way without rewriting published history. The last `.github` reference in `.Rbuildignore` is gone with the directory it ignored. The remaining `github.com` links in the tree are all third-party — pandoc releases, pak, and the upstream Public Suffix List itself (PSLR-thcaqtnw).

* Hosted CI is now two named pipelines and nothing else: `CRAN_PREP=1` runs the pre-submission gate (lint, `--as-cran`, README and NEWS guards, coverage, the R 4.5/4.6/devel matrix and the OSV, OSS Index and upstream-PSL audits), and `DEPLOY_PAGES=1` republishes the documentation site. No pipeline is created by a push, a merge request, a tag or a schedule; the everyday gate is `tools/verify.sh` on the maintainer's machine (PSLR-ugxanxne, PSLR-totktvlq).

* The documentation site no longer publishes the repository's agent-instruction files (`AGENTS.md`, `CLAUDE.md`, `FP_AGENTS.md`, `FP_CLAUDE.md`). pkgdown renders every root-level Markdown file it does not otherwise recognize, so all four were reachable on the public site and their text was folded into the site search index, where it outranked the reference documentation on ordinary queries (PSLR-wclmdkju).

* The project's declared homepage and bug tracker moved from GitHub to GitLab: `URL` is now the pkgdown site <https://bart-turczynski.gitlab.io/pslr/> and the GitLab repository, followed by the canonical CRAN and r-universe pages, and `BugReports` is the GitLab issue tracker. The GitLab repository and its documentation site are public, so every declared URL resolves for anyone; the GitHub URLs, including the old `github.io` pkgdown site, no longer do (PSLR-thcaqtnw).

* New `psl_diff(old, new)` reports which rules were added, removed, or changed between two Public Suffix List snapshots that are already available locally. Either side accepts `"bundled"`, `"cache"`, a source-file path, a `psl_engine`, or a `psl_rules()` table; rows are keyed on a rule's canonical labels with any `*.` or `!` marker removed, so a kind change or an ICANN/PRIVATE move is one `changed` row rather than an unrelated removal and addition. It resolves no dates, downloads nothing, and activates neither side (PSLR-aeuaykkf).

* **Breaking:** `psl_outdated()` is removed. It answered "is the active list's `list_date` older than N days?" but named the answer *outdated*, conflating snapshot age with knowledge of the upstream endpoint, and returned `NA` for any snapshot whose upstream date is unknown. Use `psl_status()` for the freshness claim the local evidence actually supports, and `psl_reminder()` for the periodic nudge (PSLR-hvjaloik).

* **Breaking:** `psl_refresh()`'s `activate` and `force` are now named-only, after `...`. Both are logical and both mean "do more than a bare check", so a positional `psl_refresh(url, TRUE)` was unreadable whichever it meant; it is now a clear error rather than a silent change of meaning (PSLR-nngpirsm).

* **Breaking:** the v1 on-disk cache schema (`psl-<hex>.dat` plus a `current.rds` commit marker) is superseded by a content-addressed snapshot store with append-only per-source state and cache selections. Migration is lazy and idempotent: `psl_status()` and `psl_snapshots()` read v1 state without rewriting it, the first `psl_refresh()` or `psl_cache_prune()` migrates it under the publication lock, and v1 files are never deleted (PSLR-vlkspnkb, PSLR-abcfaxud).

* New `psl_status(snapshot = "active")` reports, entirely offline, the strongest freshness claim the local evidence supports about one snapshot: `confirmed_current`, `check_due`, `update_available`, `never_checked`, `untracked`, `missing`, or `unknown`. Elapsed time alone is only ever `check_due`; `update_available` requires that a successful check actually observed a different checksum. A missing cache or corrupt local state is reported as status with remediation rather than raised as an error (PSLR-sbuyclkb).

* `psl_refresh()` is now a conditional revalidation with four named outcomes: `skipped_recently` (no request, the last successful check is inside its courtesy window), `not_modified` (one conditional request answered `304`, no body), `downloaded_unchanged` (one `200` whose validated bytes hash to the snapshot already held), and `updated` (one `200` carrying a new snapshot). It returns a `psl_refresh_result` invisibly and signals classed errors rooted at `pslr_refresh_error` for every operational failure, instead of undocumented result variants (PSLR-cldlmtiy, PSLR-hjrpayus).

* `psl_refresh()` sends `If-None-Match` (preferring `ETag`) or `If-Modified-Since`, honors the list's request to download no more than daily with a 24-hour courtesy floor extended by advertised server freshness up to 30 days, and caps decoded responses at 16 MiB with no automatic retries. `force = TRUE` bypasses the local courtesy window only — it still sends a validator, so it is not an unconditional download (PSLR-nohexwgs, PSLR-jsaohjpq).

* `psl_refresh()` accepts only an absolute `https` URL with no userinfo, query string, or fragment, follows at most five same-origin `https` redirects, and clears a stored validator before any changed redirect target. The normalized URL is source identity and is stored under a digest of itself, so no filename carries URL text (PSLR-tvjzlksq).

* Snapshots are identified by SHA-256 over their exact source bytes, and each distinct validated download is preserved until explicit pruning. HTTP validators are treated purely as opaque, source-scoped revalidation tokens and never as an integrity or authenticity check; `digest` moves from `Suggests` to `Imports` (PSLR-vlkspnkb).

* Refreshes of one source are serialized across processes, so a slower concurrent response can no longer overwrite newer source state, and publication is append-only, so an interrupted commit exposes either the prior generation or a complete new one on both POSIX and Windows. A failed refresh records only a coarse attempt and leaves the cache, the selected snapshot, and the active matcher byte-identical (PSLR-owqhbrli, PSLR-ygsehtko).

* A source's `retrieved_at` and `checked_at` can no longer regress when the system clock moves backwards, as an NTP correction or a wrong container clock will do: a refresh publishes the later of the stored and observed times, and the returned `psl_refresh_result` reports the confirmation that was actually persisted (PSLR-usocggvm).

* New `psl_reminder(enable, every)` persists an opt-in, offline, weekly-by-default freshness reminder: a direct `library(pslr)` may then print one startup message per session, and only for `never_checked`, `check_due`, or `update_available`. Reminders are off until enabled, the preference is configuration rather than cache so pruning never clears it, disabling retains the interval, and no part of the reminder path makes a request (PSLR-zfdsaciu).

* New `psl_snapshots()` inventories every snapshot this installation can resolve, one row per distinct SHA-256, with per-row `integrity` of `ok`, `missing`, `checksum_mismatch`, or `unknown_schema`. It repairs nothing and makes no request; `verify = TRUE` rehashes stored bytes instead of classifying from recorded sizes. Source association is reported only as a count, because request URLs of custom sources may be private (PSLR-umwatxje).

* `psl_cache_prune()` is now reference-safe across the whole v2 store: it protects the selected cache snapshot, every snapshot any source record names, the snapshot active in the calling session, and the `keep` most recently first-retrieved snapshots beyond those. Retention is ordered by first retrieval rather than file mtime, it collects nothing at all when any source or selection stream is unreadable, and it never touches the reminder preference (PSLR-kdjvxtpk).

* The bundled snapshot now records the canonical refresh endpoint alongside its immutable raw-commit origin, so a fresh install reports `never_checked` about bytes that plainly came from the PSL instead of `untracked`. It asserts provenance only: no validator is seeded, so the first refresh stays unconditional and a fresh install is never reported as `confirmed_current` (PSLR-jujniexk).

* The vignette, README, and reference index document the v2 model: why "check due" is not "update available", `ETag`/`Last-Modified` versus SHA-256, the four refresh outcomes and their request and body behavior, opt-in reminders and how to turn them off, running `pslr::psl_refresh()` from a scheduler you already have (`pslr` installs none), and snapshot retention, explicit pruning, and the checksum seam a later comparison feature needs (PSLR-hvjaloik).

* The package landing page (`help(package = "pslr")`, `?pslr`) now carries a runnable quick tour covering both core queries, vectorized input, explicit section selection, Unicode round-tripping, and rule/list provenance (PSLR-aquayvhw).

* Queries no longer depend on the session locale. A non-ASCII host whose encoding is undeclared — what a caller holds after reading from most sources — previously canonicalized correctly under a UTF-8 locale but returned `NA` under a non-UTF-8 one; callers had to set `Encoding(host) <- "UTF-8"` themselves. `pslr` now resolves the encoding of its own inputs (PSLR-jzdhhugc).

* Reading a PSL source file is locale-independent. Under a non-UTF-8 locale the reader previously transcoded into the native encoding, which aborted at the first non-ASCII byte and silently truncated the list — 780 of 16386 lines under `LC_ALL=C` — affecting `psl_refresh()` and the profile-mismatch rebuild (PSLR-jzdhhugc).

* Undecodable input is now reported as invalid rather than aborting with an internal regex error, so `invalid = "na"` returns `NA` and `invalid = "error"` reports the position as documented (PSLR-jzdhhugc).

* Loading `pslr` no longer warns `strings not representable in native encoding` under a non-UTF-8 locale, which every dependent package inherited on CRAN's Windows checks and win-builder. Non-ASCII strings in the bundled index now carry explicit UTF-8 marks, as do non-ASCII query results (PSLR-jzdhhugc).

* Security reports now go to the maintainer by email. `SECURITY.md` named GitHub private vulnerability reporting as the preferred channel and told reporters to use the repository's Security tab; that channel stopped resolving with the account suspension, so the documented way to report a vulnerability privately led nowhere (PSLR-cftgnuxo).

## Internal

* The OSS Index dependency audit in `tests/testthat/test-security.R` scopes to hard dependencies (`Depends` + `Imports`) instead of the `Suggests` tree. `oysteR::expect_secure()` audits `Suggests` too, which pulled in oysteR's own recursive dependencies --- `curl` among them --- and failed the pre-push gate on a vulnerability in the auditor rather than in anything pslr ships. Scoped to hard dependencies the audit covers 6 packages and is clean; the old scope covered 82 (PSLR-xqedxjeb).

* `tmp/` is now `.Rbuildignore`d. It is gitignored, so a clean clone never had it, but any build from a working tree that had run the verify gate carried the gate's logs into the tarball and `R CMD check` reported `Non-standard file/directory found at top level: 'tmp'` (PSLR-rnfnzwqu).

* The profile-rebuild and dedup tests no longer assume the installed `punycoder` reports the same normalization profile the bundled index was generated under. `test-profile-rebuild.R` asserted `rebuilt` was `FALSE` for the shipped index, which is a build-time coincidence rather than the contract; it now derives the expectation from the same bundled-versus-runtime comparison `bundled_snapshot()` makes, so it holds under either profile and still pins both branches. The dedup tests measured normalizer crossings across a region that also contained one-time activation, so an activation that rebuilt the index charged all 10,212 source-rule normalizations to a query the test expected to cost one; they now activate before measuring. Together these are what let a released pslr pass `R CMD check` against both `punycoder` 1.2.1 and the forthcoming 1.3.0 — CRAN's reverse-dependency check on 1.3.0 currently fails against pslr 1.1.1 for exactly these four assertions (PSLR-rnfnzwqu).

* New `tools/verify.sh sanitize` tier runs the test suite over the C++ matcher under ASAN and UBSAN, then under valgrind, restoring the dynamic analysis that `.github/workflows/rhub.yaml` provided until it was deleted. R-hub itself could not be ported — rhub v2 dispatches to the maintainer's own GitHub Actions runners — and the published R-hub containers are amd64-only, so both legs build natively with the host toolchain instead. The tier also runs as part of `cran` (PSLR-avwlybsw).

* The `.github/` tree is removed. The nine workflows had already been replaced by named jobs in `.gitlab-ci.yml` (PSLR-totktvlq) and the GitHub repository now returns 403, so nothing could trigger them; `dependabot.yml` and the issue and pull-request templates are GitHub-only surfaces that GitLab never reads. `data-raw/psl_snapshot_meta.R` named one of the deleted workflows as its consumer and now names the `psl-upstream-check` job that actually calls it (PSLR-bbuuafin).

* Agent instructions are consolidated: `AGENTS.md` now carries only what is true for every task and points at `docs/r-conventions.md` and `docs/git-workflow.md`, and `CLAUDE.md` is the single line `@AGENTS.md`. It had reached 1197 words while `CLAUDE.md` imported `FP_CLAUDE.md` alongside it, so every request loaded that file plus a near-duplicate of `FP_AGENTS.md`. The audit also found `AGENTS.md` claiming TOML validation the hooks did not do and `CONTRIBUTING.md` naming a `features/` directory that does not exist and a hand-run `lintr`/`rcmdcheck` pair that bypasses `tools/verify.sh`; `check-toml` is added, both claims are corrected, `man/`, `NAMESPACE` and the cpp11 glue are marked `linguist-generated`, and `_pkgdown.yml` records why it builds into `site/` (PSLR-yddiszjh).

* The `matrix` tier of `tools/verify.sh` now installs the `libcurl` and `libssl` headers in its containers, so the R devel leg can bootstrap `pak`. `pak` installs a package's system requirements, but only once `pak` itself is installed; released R gets a prebuilt `pak` binary and never compiles, while devel has none and must build `pak`'s embedded `curl` from source, which failed on a missing `curl/curl.h` before any check ran. All three legs (R 4.5, 4.6 and devel) now pass (PSLR-alwcualu).

* `.verify-stamp` is now in `.Rbuildignore`. It was gitignored but not build-ignored, and `tools/verify.sh full` writes it to the package root *after* its check passes, so every later `R CMD check` swept it into the tarball and reported it under "checking for hidden files and directories". The gate quietly poisoned its own next run: the first `full` was clean only because the stamp did not exist yet (PSLR-alwcualu).

* `tests/testthat/_snaps/` is no longer gitignored. The rule came from the initial scaffold rather than a decision, and it silently disarmed the snapshot testing `AGENTS.md` prescribes: with the directory ignored, every run would write a fresh baseline instead of comparing against a committed one, so `expect_snapshot()` could never fail. Nothing used it yet, so no assertion was actually weakened (PSLR-alwcualu).

* The verify gate moved out of CI and into `tools/verify.sh`, which is now its single definition — the pre-push hook, the `AGENTS.md` dev loop and the release checklist all call it. Four tiers: `standard` (lint plus the test suite, what the hook runs), `full` (adds `R CMD check --as-cran`, the NEWS/version and README guards, coverage, the OSV and OSS Index audits and the upstream-PSL comparison), `matrix` (R 4.5/4.6/devel under Docker) and `cran` (everything, plus the remote incoming checks that CI has to disable). GitLab runner minutes are a paid resource, so the hosted pipeline now runs only on a `v*` tag and on manual trigger, and the weekly schedules are replaced by `tools/verify.sh full` run locally; `--staleness` reports how overdue that is and the pre-push hook prints it as a non-blocking nudge (PSLR-ugxanxne).

* CI moved from GitHub Actions to GitLab CI: `.gitlab-ci.yml` runs the `AGENTS.md` verify command — `lintr::lint_package()` then `R CMD check --as-cran` with `error_on = "warning"` — on every push and merge request, alongside the README-sync and NEWS/version guards, coverage, a Linux R devel/release/oldrel-1 matrix, and the weekly OSV, OSS Index and upstream-PSL jobs. The nine `.github/workflows/` files had stopped running entirely, leaving the local pre-push hook as the only gate. GitLab's shared runners are Linux-only, so the macOS and Windows legs and the R-hub workflow have no equivalent; those move to win-builder and mac-builder before a submission (PSLR-totktvlq).

* A weekly `Upstream PSL check` workflow reports when `publicsuffix/list` has a newer commit to `public_suffix_list.dat` than the pinned bundled snapshot, regenerating it via `data-raw/update_psl.R` and opening a review PR. Discovery only: it never commits to `main`, never merges, and leaves `NEWS.md` and the package version to the maintainer, so the release checklist in `CONTRIBUTING.md` is unchanged (PSLR-wzhnvyiv).

* The NEWS/version CI guard now also asserts that every released version (one `v*` tag each) still has its own `# pslr X.Y.Z` heading in `NEWS.md`, so deleting or mistyping a shipped release section fails the build instead of silently reparenting its bullets under the section above (PSLR-stnequvi).

* The bundled index ships built under the `punycoder` that CRAN serves — 1.2.1, profile `uts46-nontransitional-std3-v1`, Unicode 16.0.0 — so `bundled_snapshot()` takes its fast path for everyone rather than rebuilding in memory on load. During development the index was built under punycoder's unreleased Unicode 17.0.0 pin, with a temporary `Remotes:` pin to match; both are reverted here. That rebuild is not free: measured at 2.75 s per session over 10,323 rules, and it would have been charged to every user, because the punycoder that produces a matching `-v2` stamp is not published yet. The rule set is byte-identical under either normalizer at the same pinned upstream commit — 10,323 rules, 0 differing cells across all seven columns — so only the recorded normalization identity ever moved. The index will be rebuilt under Unicode 17.0.0 once punycoder 1.3.0 is on CRAN (PSLR-fjkaqckg, PSLR-cmkufiww).

# pslr 1.1.1

* `pslr` now installs from CRAN alone: the `punycoder` dependency floor is `>= 1.1.0` (the current CRAN release) and the development `Remotes:` pin is dropped. `pslr` uses only `punycoder` API present since 1.1.0 and is forward-compatible with `punycoder` 1.2.x, whose default `host_normalize()` output is byte-identical (PSLR-xwcqnnls).

* The result cache no longer evicts on an oversized one-shot query: a single call with more distinct hosts than the whole cache capacity is still matched-but-not-cached, but it now leaves any existing warm entries intact instead of flushing the table to make room it could never use (PSLR-wyvauroc).

## Internal

* Addressed `goodpractice` style findings: brought `valid_psl_manifest()`, `parse_psl_lines()`, and `psl_validate_keep()` under the cyclomatic-complexity threshold, dropped a `<<-` out of the cache-marker reader, deduplicated the `path` argument docs via `@inheritParams`, tightened the freshness-corpus tests to `expect_identical()`, and extended `inst/WORDLIST`; no user-facing change (PSLR-cftnwsxa).

* Added a PSL-freshness harm corpus (McQuistin et al., IMC '23, Table 2) that pins newly added multi-label eTLDs (e.g. `myshopify.com`, `netlify.app`, `*.digitaloceanspaces.com`) against the bundled snapshot, guarding against shipping a list stale enough to put the registrable-domain boundary above the tenant label (PSLR-cowbpwsy).

# pslr 1.1.0

* The core matcher is now a reverse-label trie: one right-to-left label descent per host replaces the previous per-suffix hash-set probes, roughly halving direct-match time on cache-cold, large-batch, and cache-disabled workloads; results are byte-identical (PSLR-rqcslhfc).

* The five query functions (`public_suffix()`, `registrable_domain()`, `is_public_suffix()`, `suffix_extract()`, `public_suffix_rule()`) gain an optional `engine=` argument to query a specific `psl_engine()` snapshot instead of the session-global list; omitting it is unchanged (PSLR-hflrsfgp).

* New `psl_engine()` constructs a self-contained, process-local PSL engine (`source = "bundled"` or `"path"`) for querying a specific snapshot without `psl_use()` (PSLR-ntqoiglh).

* `psl_version()` now reports the active snapshot's source `url` as a new column -- the upstream download URL for the bundled list; `NA` for cache or custom-path sources (PSLR-qcvrfoun).

* `output = "unicode"` now decodes each distinct A-label only once per call -- `suffix_extract()` pools its five columns into a single `punycoder::puny_decode()` crossing and every query deduplicates repeats -- so unicode output on batches with repeated or overlapping hosts is markedly faster; decoded output is byte-identical (PSLR-cpzrjksw).

* Every query no longer pays for a per-call `strsplit()` to count host labels; `is_public_suffix()` now reads the matcher's `ps_start` offset, which is equivalent, so results are unchanged (PSLR-rriiajin).

* The session result cache now pre-sizes its key index to the incoming unique-batch size, so a large cold batch fills a right-sized hash table in one shot instead of rehashing repeatedly during insertion; results are unchanged (PSLR-gtvggjmd).

* The PSL-format parser now preallocates its rule columns and fills them by index instead of growing them one accepted rule at a time, making a full list rebuild roughly 3x faster; output is byte-identical (PSLR-wanopbqy).

* New `psl_cache_prune()` removes superseded on-disk `psl-<hex>.dat` cache snapshots, always keeping the active snapshot plus the `keep` most-recent others (default one previous); a no-op when there is no cache or marker (PSLR-nwdejhkf).

* Cache checksum verification now recomputes the algorithm named by the recorded `sha256:`/`md5:` prefix instead of whichever hash `digest` availability picks at call time, so a cache is no longer spuriously reported as corrupt across machines that differ in the optional `digest` package; a missing `digest` for an `sha256`-recorded cache now raises an actionable install error rather than a corruption error (PSLR-mxohlxiq).

* The cache commit marker is now structurally validated when read, so a readable-but-malformed `current.rds` (missing `dat_file`, a short `meta`, or wrong field types) raises the actionable cache-corruption error advising `psl_refresh(force = TRUE)` instead of degrading into silent `NULL` reads; newly written markers carry a schema version and markers from earlier releases stay valid (PSLR-nwdejhkf).

* New `psl_outdated()` reports whether the active list snapshot is older than a threshold (default 180 days), purely offline from `psl_version()`'s `list_date`, as a nudge toward `psl_refresh()`; the snapshot age in days is returned in the `"age_days"` attribute (#62).

* New `options(pslr.cache = FALSE)` escape hatch disables the session result
  cache for the current session, skipping every cache read and write. It never
  changes a result -- misses are derived by the same code path -- so output is
  byte-identical to the cached path; it only controls whether entries are stored
  and read. Useful for one-shot batches of mostly-unique hosts, where within a
  single vectorized call `unique()` already deduplicates and the per-key cache
  read is pure overhead (roughly 1.5x faster with the cache off on a
  200,000-unique batch). Caching stays on by default.

## Internal

* The core C++ matcher hardened its construction: `psl_build_matcher()` now validates that its `keys`/`kinds`/`sections` columns share a length and that each section (0/1) and kind (`normal`/`wildcard`/`exception`) is in range -- an unknown kind now errors instead of being silently bucketed as an exception -- exact-reserves the six rule sets from a counting pass to avoid rehashing, and builds via a `std::unique_ptr` released only after the R external pointer is registered; `psl_match()` rejects a NULL external pointer before dereferencing. Behaviour on valid input is byte-identical (PSLR-sfppglqs).

* `psl_use()` now uses a scalar formal default validated by `check_choice()`, matching the query functions, and the sole-purpose `match_opt()` helper is removed; argument handling and every result/error are unchanged (PSLR-vmwsipkm).

* Added `^\.claude$` to `.Rbuildignore` so a contributor using Claude Code no longer sweeps the gitignored `.claude/` session directory into the build tarball, silencing the spurious `R CMD check` hidden-files NOTE; no package content changes (PSLR-juyrfjls).

* Query internals are now projection-aware: a query derives only the result string columns it consumes instead of all five on every call. `psl_query_cols()`/`psl_resolve_cores()`/`psl_derive_strings()` take a `fields` projection (the cheap `kind`/`rule_section` enum columns and the byte offsets stay always-derived; the substr-heavy `public_suffix`/`registrable_domain`/`rule` columns are gated), the compact structural cache is untouched, and `public_suffix()`/`registrable_domain()` now share one internal `psl_query_vector()`. Every result is byte-identical (differential oracle unchanged) (PSLR-sscuznba).

* The session result cache now stores only compact integer structural columns (public-suffix depth, the three byte offsets, and the `kind`/`section` enum codes) rather than the derived strings; the user-facing `public_suffix`/`registrable_domain`/`rule`/`kind`/`rule_section` columns are reconstructed on read by a new `psl_derive_strings()` after cache assembly, splitting the result schema (`psl_result_cols`) from the compact cache schema (`psl_cache_cols`). Results are byte-identical (differential oracle and cache-on/off identity unchanged) (PSLR-muyzxbpl).

* The global query functions now resolve a single process-wide default engine via `psl_default_engine()` and thread it explicitly through the internal match/cache path (`psl_query_cols` -> `psl_resolve_cores` -> `psl_match_records`), replacing the implicit global-state fetch; `psl_use()` and the refresh activation paths replace that default engine. Public signatures and behaviour are byte-identical (PSLR-cchcomkk).

* Moved result-cache ownership into the `psl_engine`: each engine mints its own `new_psl_cache()`, so activating a list swaps the whole engine (starting cold) instead of clearing a shared global, and the cache key drops the now-redundant list-identity prefix (keyed on section + canonical host); public behaviour is byte-identical, with new engine-cache isolation tests (PSLR-bcgedhmy).

* Modelled the active-list state as internal `psl_snapshot` (rules + metadata + source identity) and process-local `psl_engine` (snapshot + compiled matcher) objects, and unified the two cache-activation paths onto a shared `psl_load_cached_snapshot()` loader behind a single `psl_activate_snapshot()` choke-point; internal only, public behaviour byte-identical (PSLR-fvotbdti).

* The five public query functions and `psl_rules()` now carry scalar formal defaults validated by an internal `check_choice()`, dropping the `missing()`-based supplied-flag bookkeeping; argument handling and every result and error are unchanged (PSLR-adsnjbjg).

* Consolidated the snapshot-metadata field schema behind a single owner: `new_psl_meta()` (construction/defaults), `validate_psl_meta()` (checked boundary), and `as_psl_version_df()` (the one-row `psl_version()` frame) all read one `psl_meta_fields` schema, replacing the field lists that were re-spelled in `R/matcher.R`, `R/metadata.R`, and `data-raw/update_psl.R`; output is byte-identical (PSLR-bnrbjhur).

* Consolidated the two overlapping benchmark scripts into a single authoritative harness under `bench/` (shared fixtures/timing in `bench/helpers.R`), removed the unreferenced `inst/bench/match-bench.R`, and fixed two integrity defects: the "unique" corpus is now deterministic and exactly-n distinct (via the internal, unit-tested `psl_bench_unique_hosts()`), and every scenario resets its intended cache state inside each timed rep so a cold measurement is no longer contaminated by the previous rep's warm cache (PSLR-cefytpjr).

* Raised test coverage from 96% to 100% by exercising the previously-uncovered error and fallback branches across `refresh.R`, `matcher.R`, `cache.R`, `canonicalize.R`, `duplicates.R`, and `parser.R` (mocked downloader/`digest`/`curl`/`system.file` seams, crafted inputs); the one unreachable C++ epilogue brace in `matcher.cpp` is excluded with a `# nocov` marker. No behaviour change; the differential oracle is unchanged (#66).

* Collapsed the repeated `section`/`unknown`/`invalid` option-validation preamble across the five exported query functions into a shared `resolve_common_opts()` helper, factored `suffix_extract()`'s byte-offset slicing into `psl_slice_registrant()`, and drove `psl_query_cols()`'s eight match columns off the shared schema (reusing `psl_match_alloc()`, now `NA`-filled). Clears the remaining `goodpractice` function-length findings for `R/query.R`; results are byte-identical (oracle unchanged) (#65).

* Drove `psl_resolve_cores()`'s eight parallel match columns off the shared cache schema (`psl_cache_cols`) instead of spelling each column out four times, and factored the cache-index lookup into `psl_cache_lookup()`. Clears the `goodpractice` function-length finding; results are byte-identical (oracle and cache tests unchanged) (#64).

* Raised the default session-cache bound from 50,000 to 200,000 entries. The
  columnar store (from the P2-P4 rewrite) costs about 80 bytes per entry
  (~16 MB for a full 200,000-entry table) and memory scales with live entries,
  so small sessions pay nothing. The higher bound lets a large working set
  re-queried across calls stay warm instead of tripping the full-flush eviction
  cliff -- on a 200,000-unique benchmark the second pass drops from ~1.63 s
  (flush and re-derive) to ~0.83 s (a true cache hit). The full-flush eviction
  semantics above the bound are unchanged.

* The core C++ matcher (`psl_match()`) now also returns 1-based byte offsets
  into the canonical ASCII host (`ps_start` / `rd_start` / `ps1_start`). The R
  engine derives the public-suffix, registrable-domain, and rule strings for the
  whole miss vector at once with a single vectorized `substr()` per column,
  replacing the per-host `derive_one()`/`suffix_labels()` `paste()` loop (now
  removed). Pure internal restructuring; query results are byte-identical (the
  differential oracle is unchanged), but the miss-path string derivation is
  roughly 40x faster and drops out of the query profile.
* The session result cache is now columnar. Instead of one R list per host, it
  keeps a key -> integer-index environment alongside parallel column vectors
  (including the `ps_start` / `rd_start` byte offsets), grown by doubling. Cache
  hits resolve via a single `mget()` of indices plus vectorized column
  subsetting, and `psl_resolve_cores()` returns its columns directly, removing
  the six per-call `vapply()` reassembly passes over the whole unique-host list.
  Pure internal restructuring; the cache key semantics and the differential
  oracle are unchanged, but the warm-cache query path is dramatically faster.
* The shared per-element query builder (`psl_query_frame()`, now
  `psl_query_cols()`) returns a plain list of parallel column vectors instead of
  constructing a 12-column `data.frame` on every call. The length-preserving
  accessors (`public_suffix()` / `registrable_domain()` / `is_public_suffix()`)
  read the one or two columns they need directly; only `suffix_extract()` and
  `public_suffix_rule()` build a `data.frame`, once, at the end. `suffix_extract()`
  additionally drops its per-row `strsplit` loop, slicing the registrant label
  and subdomain out of the canonical host with vectorized `substr()` over the
  matcher's `ps_start` / `rd_start` byte offsets. Pure internal restructuring;
  query results and the differential oracle are unchanged, but the fixed
  per-call overhead falls sharply (warm scalar `registrable_domain()` roughly
  halves).

# pslr 1.0.2

## Internal

* Dropped the redundant `strict = TRUE` argument from `punycoder::host_normalize()`
  calls. `punycoder` removed the inert `strict` flag in favour of explicit
  UTS #46 flags (all defaulting to the strict profile), so the bare call is
  behavior-preserving and forward-compatible with that release. No user-visible
  change; this keeps `pslr` installable against the upcoming `punycoder` release.
* Refactored `psl_canonicalize()`, `parse_psl_lines()`, the core matcher
  resolution, and `psl_refresh()`/`psl_use()` into smaller helpers to clear
  `goodpractice` cyclomatic-complexity and function-length findings. Pure
  internal restructuring; no behavior or API change.

# pslr 1.0.1

Launch-readiness audit follow-ups (no API changes).

* `suffix_extract(output = "unicode")` no longer turns an empty subdomain into
  `NA`. An absent subdomain is reported as `""` for both `"ascii"` and
  `"unicode"` output, matching the documented schema.
* Choice-style option arguments (`section`, `output`, `unknown`, `invalid`, and
  `psl_use()`'s `source`) now abort when a caller supplies a non-scalar value,
  even one that happens to equal the formal's default vector (e.g.
  `invalid = c("na", "error")`). Previously such a call was mistaken for the
  untouched default and silently used the first choice. Omitted options still
  default to their first choice.
* A corrupt cache marker (`current.rds`) is now handled gracefully instead of
  leaking a raw `readRDS()` "unknown input format" error. `psl_refresh(force =
  TRUE)` ignores an unreadable marker and republishes a valid cache, and
  `psl_use("cache")` reports a pslr cache-corruption error with remediation.
* PSL sources with a repeated ICANN or PRIVATE section are now rejected. The
  official format carries exactly one complete section of each; a second
  `BEGIN` for either aborts the parse instead of loading both copies.
* A zero-length non-character `domain` (e.g. `numeric(0)`, `NULL`) now aborts
  with the documented type error instead of being silently coerced to an empty
  result. This is consistent with the input contract: a wrong argument type is
  a programming error regardless of length. The valid empty character vector
  `character(0)` still returns a zero-length result.

# pslr 1.0.0

First public release: a spec-complete Public Suffix List engine for R.

* Bundled the Public Suffix List snapshot pinned to upstream commit
  `9186eee` (list date 2026-06-13), with a deterministic `data-raw/`
  regeneration script, an internal validated rule index, generation metadata
  (commit, source URL, checksum, normalization profile, Unicode version), and
  MPL-2.0 data licensing separate from the package's MIT code license.
* Added the public query API: `public_suffix()`, `registrable_domain()`,
  `is_public_suffix()`, `suffix_extract()`, and `public_suffix_rule()`. All are
  vectorised, length- and name-preserving, NA-safe, and share the
  `section` / `output` / `unknown` / `invalid` policies. Input is canonicalized
  through `punycoder` with terminal-dot preservation and dotted-decimal IPv4
  literal rejection, and repeated queries are served from a bounded session
  cache keyed by host, active-list identity, and section.
* Added refresh and activation: `psl_refresh()`, `psl_use()`, `psl_version()`,
  and `psl_rules()`. `psl_refresh()` is the only network path -- an explicit,
  https-only, credential- and downgrade-redirect-rejecting download with a size
  ceiling, full validation, a 24-hour reuse throttle, and an atomic cache
  publish that never exposes a partial snapshot or replaces a valid cache after
  a failed refresh. `psl_use()` switches the session's active list between the
  bundled snapshot, the user cache, and a custom path, validating before any
  state changes and clearing the result cache on a successful switch. The
  bundled index is rebuilt in memory from source when its normalization profile
  or Unicode version differs from the runtime normalizer, never mixing profiles.
  `psl_version()` reports the active-list identity and runtime normalization
  identifiers needed to reproduce a result; `psl_rules()` exposes the active
  rule table.
* Canonical-host deduplication: a repeated host costs a single `punycoder`
  normalization and a single C++ matcher call regardless of multiplicity. A
  non-CRAN benchmark and its release gate live in `bench/benchmark.R`.
