# v1 acceptance sign-off

This document records that every version-1 acceptance gate in
[PRD](./PRD.md) §11 is satisfied, with a pointer to the evidence. Re-verify
before any subsequent release.

Release: **pslr 1.0.0**. `R CMD check --as-cran`: **0 errors, 0 warnings, 1
note** (new submission + the `Remotes` field; see `cran-comments.md`).

## §11.1 Correctness

| Gate | Evidence |
|------|----------|
| Official PSL test vectors pass for the bundled snapshot | `tests/testthat/test-psl-vectors.R`, fixtures `tests/testthat/fixtures/psl-vectors.txt` |
| Normal / wildcard / exception / default / wildcard-parent each unit-tested | `test-query.R`, `test-matcher.R` |
| `section` × `unknown` × `output` × terminal-dot × invalid matrix tested | `test-query.R`, `test-extract.R` |
| Unicode and A-label inputs give equal ASCII results | `test-query.R` ("U-label, A-label, and NFC-equivalent inputs give equal ASCII") |
| NFC-equivalent Unicode inputs give equal results | `test-query.R` (precomposed vs decomposed é) |
| Mixed case, single label, NA, zero-length, invalid labels, IPv4, IPv6, URL-shaped, empty labels | `test-canonicalize.R`, `test-query.R` |
| `suffix_extract()` / `public_suffix_rule()` schema, types, counts, NA propagation, zero-length, all-invalid | `test-extract.R` |
| Parser: malformed markers, invalid wildcards/exceptions, strict duplicate rejection, runtime warn-and-dedup, same-section conflicts, permitted cross-section duplicates, bad UTF-8, inline whitespace/comments, canonicalization failures | `test-parser.R`, `test-duplicates.R` |
| Terminal-dot behavior has direct package tests (not relying on upstream vectors) | `test-canonicalize.R`, `test-query.R` |

## §11.2 Dependency portability

| Gate | Evidence |
|------|----------|
| `punycoder` documents the normalization profile used | `punycoder` (dependency); reported via `normalization_profile_info()` |
| Stable machine-readable profile + Unicode identifiers, surfaced by `psl_version()` | `R/metadata.R`, `test-version-rules.R` |
| Installs and full suite passes against `punycoder` built without `libidn2` | Windows CI job (`.github/workflows/full-check.yml`) builds `punycoder` from source without `libidn2` |
| Backend-parity where `libidn2` is available | `punycoder` parity tests (dependency, P1) |
| At least one continuously tested Windows config exercises the fallback backend | `full-check.yml` `windows-latest` |
| Changed profile / Unicode / `punycoder` version observable via `psl_version()` | `test-profile-rebuild.R`, `test-version-rules.R` |

## §11.3 Data and refresh

| Gate | Evidence |
|------|----------|
| Clean install, network disabled, passes all query tests | No network in load/queries; suite runs offline |
| Bundled source, metadata, and generated index agree | `test-bundled-data.R` (NOTICE/checksum/size coherence verified) |
| Profile/Unicode mismatch rebuilds from source, never mixing profiles | `test-profile-rebuild.R` |
| Refresh uses injected downloader / local fixture, no publicsuffix.org dependency | `tests/testthat/helper-active.R` (`fake_downloader`), `test-refresh.R` |
| 24h throttle, `force`, atomic replace, reuse + new-download activation, HTTPS/redirect restrictions, size limit, duplicate handling, source/metadata coherence, no timestamp advance on reuse, rollback on every failure | `test-refresh.R` |
| Cache and custom-path sources indexed under runtime normalizer, never reuse bundled index | `test-use.R`, `test-refresh.R` |
| No writes outside R-approved temp/user-cache locations | cache dir is `tools::R_user_dir("pslr", "cache")`; tests redirect to a tempdir (`helper-active.R`) |

## §11.4 Performance

| Gate | Evidence |
|------|----------|
| Non-CRAN benchmark, fixed fixtures 1/1k/100k, repeated + unique, separate cold rebuild | `bench/benchmark.R` |
| Reference results recorded in committed dev docs | `docs/benchmarks.md` |
| 100k ASCII ≤ 2s after init on reference machine | `docs/benchmarks.md` (0.93s — PASS) |
| Repeated input avoids one normalization and one C++ call per duplicate | `tests/testthat/test-dedup.R` (count-based), benchmark dedup proof |
| Performance tests verify results, not just timing | `bench/benchmark.R` (result assertions), `test-dedup.R` |

## §11.5 Package quality

| Gate | Evidence |
|------|----------|
| Exported functions have examples + complete arg/return docs | `man/*.Rd`, roxygen in `R/` |
| Vignette covers terminology, section choice, unknown policy, IDN output, terminal dots, `section="private"` fall-through, explicit-membership, refresh, reproducibility, security | `vignettes/introduction.Rmd` |
| `R CMD check --as-cran`: no errors/warnings, no unexplained notes | 0E / 0W / 1 note, all components explained in `cran-comments.md` |
| Repository verify command + pre-commit/pre-push hooks pass | `.pre-commit-config.yaml`; verify gate runs on every push |
| No network in examples / tests / load / queries | only `psl_refresh()` networks, and only when called; examples `\dontrun{}`, tests injected downloader |
| No `_scratch/` / `.fp/` / deps / caches / secrets / build output in source control or the built package | `.gitignore`, `.Rbuildignore` |
