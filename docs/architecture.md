# Architecture

How `pslr` is actually built, for maintainers and future dev sessions. For
*what* the package must do and *why* (the normative contract), see
[PRD.md](./PRD.md); for the load-bearing choices and their rationale, see
[decisions.md](./decisions.md). This document describes the code as it stands.

## What it is

`pslr` is a [Public Suffix List](https://publicsuffix.org/) engine: a
`cpp11`-compiled prevailing-rule matcher under a vectorized, `NA`-safe R query
API, backed by a pinned PSL snapshot in `R/sysdata.rda`, with a bounded columnar
session cache and an explicit, validated offline-refresh path. The only runtime
dependency for host canonicalization is
[`punycoder`](https://bart-turczynski.github.io/punycoder/).

It answers four questions over a character vector of hostnames: what is the
public suffix (eTLD), what is the registrable domain (eTLD+1), is a host itself a
public suffix, and which PSL rule produced the answer. It does **not** parse
URLs, do DNS, or make security decisions.

## Dependency boundary

```text
punycoder   canonical host normalization + A-label/U-label conversion (IDNA)
    ^ Imports
  pslr      PSL data, parser, matcher, query APIs   <- you are here
    ^ Imports
  rurl      URL parsing; delegates PSL queries to pslr
```

`pslr` implements **no** IDNA/Punycode itself — all normalization, case-mapping,
and label validation is delegated to `punycoder::host_normalize()`. `pslr` adds
only the IPv4-literal rejection and the missing-vs-invalid distinction on top.
The normalizer's profile and Unicode version are recorded in list metadata and
drive an in-memory compatibility rebuild (see [Bundled data](#bundled-data-and-provenance)).

## Layering

Top to bottom, a query flows:

```text
query.R            public API: option policy, unknown/output/dot shaping, framing
  -> canonicalize.R    domain vector -> canonical ASCII hosts + ok/na/invalid status
  -> matcher.R         active-list state, matcher build, C++ result -> strings
       -> cache.R      bounded columnar session cache (miss -> derive -> store)
       -> src/matcher.cpp   prevailing-rule algorithm over immutable rule indexes
```

Provenance and lifecycle sit alongside: `metadata.R` (`psl_version`,
`psl_outdated`, `psl_rules`), `refresh.R` (`psl_refresh`, `psl_use`, the only
network path), `parser.R` (PSL-format parsing), `duplicates.R` (duplicate/conflict
policy).

## Public API surface

Ten exports (see `NAMESPACE`):

| Function | Defined at | Purpose |
|---|---|---|
| `public_suffix()` | `R/query.R:188` | eTLD of each host |
| `registrable_domain()` | `R/query.R:229` | eTLD+1 of each host |
| `is_public_suffix()` | `R/query.R:274` | `TRUE` iff host equals its own public suffix |
| `suffix_extract()` | `R/query.R:338` | data.frame splitting subdomain/domain/suffix |
| `public_suffix_rule()` | `R/query.R:401` | data.frame of the prevailing rule per host |
| `psl_use()` | `R/refresh.R:413` | switch active list (bundled/cache/path) |
| `psl_refresh()` | `R/refresh.R:304` | download + validate + publish a list to the user cache |
| `psl_version()` | `R/metadata.R:69` | one-row data.frame: identity of the active list |
| `psl_outdated()` | `R/metadata.R:125` | offline staleness check vs `list_date` |
| `psl_rules()` | `R/metadata.R:159` | data.frame of the active list's explicit rules |

Shared query options (`section`, `output`, `unknown`, `invalid`) are documented
in the PRD §6–7; their defaults and semantics are captured as decisions in
[decisions.md](./decisions.md).

## The R modules

### `R/query.R` — public query API

Thin vectorized wrappers; each owns its `section` / `output` / `unknown` /
`invalid` policy. Key internals:

- `match_opt()` (`R/query.R:18`) — scalar option matcher. It detects "was this
  argument supplied?" via `missing()`, **not** value-equality, so an explicit
  non-scalar equal to the default still aborts. `invalid` never suppresses these
  programming errors.
- `psl_query_cols()` (`R/query.R:102`) — the shared per-element result builder:
  canonicalize, resolve valid cores once, and apply `unknown = "na"` by erasing
  the implicit-default rule's derived fields. Returns a **bare list**, not a
  data.frame, to avoid ~0.1–0.2 ms of `data.frame()` construction per call; only
  the two frame-returning functions pay that cost, once, at the end.
- `psl_slice_registrant()` (`R/query.R:304`) — slices the registrant label and
  subdomain from the C++ byte offsets instead of per-row `strsplit()`.
- `unknown` and `output` are applied **here**, after the cache, so they never
  enter the cache key.

### `R/canonicalize.R` — input contract

Turns a user `domain` vector into canonical lowercase ASCII hosts plus a status,
delegating normalization/IDNA to `punycoder`. `psl_canonicalize(domain, invalid)`
(`R/canonicalize.R:101`) returns equal-length `input`, `status`
(`"ok"`/`"na"`/`"invalid"`), `host` (ASCII with terminal dot), `core` (ASCII, no
dot), and `had_dot`. Notable helpers: `is_ipv4_literal()`
(`R/canonicalize.R:24`, canonical dotted-decimal predicate that rejects leading
zeros and >255), `psl_normalize_unique_hosts()` (`R/canonicalize.R:58`, dedups
before calling `punycoder` then re-expands via `match()`), and
`trunc_for_msg()` (`R/canonicalize.R:12`, keeps error messages from echoing a
whole input vector). A non-character `domain` always aborts.

### `R/parser.R` — PSL-format parser

Turns PSL `.dat` text into a validated, canonicalized rule table. Structural
parse + grammar validation + per-rule canonicalization only — no duplicate
policy (that is `duplicates.R`), no size/network limits (that is `refresh.R`).
`parse_psl_lines()` (`R/parser.R:257`) → data.frame with `line, raw, section,
kind, canonical_rule, canonical_key, labels`; `read_psl_file()`
(`R/parser.R:317`) reads a UTF-8 file into it. Errors raise a structured
`pslr_parse_error` carrying the offending source line
(`psl_parse_abort()`, `R/parser.R:26`). The structural markers `*` and `!` are
parsed as structure and **never** passed to the normalizer.

### `R/duplicates.R` — duplicate / conflict policy

`apply_duplicate_policy(rules, mode)` (`R/duplicates.R:27`) enforces policy on a
parsed table. Conflicting rule kinds for the same `(section, canonical_key)` are
fatal in every mode. Exact same-section duplicates are fatal under `"strict"`
(the maintainer build) but warn-once-and-dedup, keeping the first, under
`"lenient"` (runtime refresh / custom path). Cross-section duplicates are always
allowed — section membership is part of a rule's identity.

### `R/matcher.R` — R engine over the cpp11 matcher

Owns active-list state, matcher construction, C++-result → strings, and the
cache-aware core resolver.

- Session state lives in one env slot, `the_matcher$state` (`R/matcher.R:15`), so
  activation is a single atomic assignment — an interrupt or failed activation
  can never expose a half-built matcher. `psl_set_active()` (`R/matcher.R:66`)
  builds the matcher, *then* swaps, *then* clears the cache.
- `build_matcher()` (`R/matcher.R:24`) calls into C++ (`psl_build_matcher`).
- `activate_bundled()` / `rebuild_bundled_rules()` (`R/matcher.R:96`/`:82`) — the
  compatibility rebuild: if the shipped index's `normalization_profile` /
  `unicode_version` differ from the runtime `punycoder`, re-parse
  `inst/extdata/*.dat` in memory (lenient) before activating, preserving the
  shipped source identity.
- `psl_match_records()` (`R/matcher.R:162`) calls `psl_match` (C++) and derives
  `public_suffix` / `registrable_domain` / `rule` / `kind` / `rule_section` from
  1-based byte offsets with one vectorized `substr()` per column.
- `psl_resolve_cores()` (`R/matcher.R:229`) is the cache-aware resolver: honors
  the `pslr.cache = FALSE` escape hatch, builds the key prefix
  `identity|section_code|`, dedups cores, looks up hits, derives misses, stores,
  and maps back to per-input.

### `R/cache.R` — bounded columnar session cache

Keyed by canonical host + active-list identity + section. Because `unknown`,
`output`, and terminal-dot restoration are applied *after* retrieval, they are
deliberately **not** in the key — the cache can never change a result. The store
is columnar: a key→index env plus eight parallel column vectors sharing the same
schema (`psl_cache_cols`, `R/cache.R:55`) used by `matcher.R` and `query.R`, so
allocate/grow/store/resolve never drift. Default bound is 200,000 entries
(`R/cache.R:38`); eviction is a documented **full flush** — when a store would
exceed capacity the whole table is dropped and rebuilt, and a batch larger than
capacity is matched but not cached. Growth within the bound doubles via
`length<-` for amortized O(1) (`psl_cache_grow()`, `R/cache.R:97`).

### `R/metadata.R` — active-list metadata

`psl_version()` (`R/metadata.R:69`) renders the 11-column one-row identity
data.frame (`source, path, retrieved_at, list_date, commit, size, checksum,
normalizer, normalizer_version, normalization_profile, unicode_version`), shared
with `psl_refresh()`. `psl_outdated(max_age = 180)` (`R/metadata.R:125`) is a
purely offline staleness check derived from `list_date`, returning a logical with
an `"age_days"` attribute. `psl_rules()` (`R/metadata.R:159`) returns the active
list's explicit rules (ICANN before PRIVATE, then source order; the implicit `*`
is not included).

### `R/refresh.R` — refresh and activation

The only network access in the package, and only on an explicit `psl_refresh()`.

- **Downloader seam**: `psl_default_download()` (`R/refresh.R:224`) requires
  `curl`, follows redirects but refuses a non-HTTPS effective URL, caps size, and
  errors on HTTP ≥ 400. It is injected via
  `getOption("pslr.downloader", psl_default_download)` (`R/refresh.R:312`) — the
  test seam that keeps CI off publicsuffix.org.
- **Atomic commit**: `psl_publish_download()` (`R/refresh.R:133`) writes a
  content-addressed, immutable `psl-<hex>.dat` first, then atomically renames a
  commit marker (`current.rds`) as the single commit point — a partial or
  mismatched snapshot is never exposed, and a failed refresh leaves the prior
  cache and active matcher usable. `psl_atomic_rename()` (`R/refresh.R:43`)
  handles the Windows "rename onto existing dest" case.
- Config seams via options: `pslr.max_bytes` (default 16 MiB), `pslr.cache_dir`
  (default `tools::R_user_dir("pslr", "cache")`), `pslr.downloader`.
- `psl_use(source, path)` (`R/refresh.R:413`) switches the active list to
  bundled / cache / a custom path, validating before it changes any session
  state.

## The compiled matcher (`src/`)

`src/matcher.cpp` indexes the immutable rule set as a **reverse-label trie**
behind an external pointer and runs the official prevailing-rule algorithm
right-to-left in time proportional to the host's label count, not the rule
count. R owns normalization, dot handling, shaping, and user-facing errors; C++
sees only canonical lowercase ASCII hosts. (The trie replaced an equivalent
hash-set matcher for ~2× faster direct matching with byte-identical output — see
D18.)

- `struct TrieNode` (`src/matcher.cpp:74`): `bool ends[2][3]` — indexed
  `[section][kind]` (ICANN/PRIVATE × normal/wildcard/exception) — flags whether a
  rule of that kind **ends** at this node's path, plus an
  `unordered_map<string, unique_ptr<TrieNode>> children` keyed by label. Rules
  are inserted by walking their canonical key's labels **right-to-left**, so the
  path to a node is a right-anchored suffix. For a wildcard the stored key is its
  **parent** labels; for an exception, the full post-`!` labels; for a normal
  rule, the key as-is. `struct TrieMatcher` owns the root and cascade-frees the
  tree in its finalizer.
- Entry points (`[[cpp11::register]]`): `psl_build_matcher()`
  (`src/matcher.cpp:118`) validates its parallel-vector inputs (matching lengths,
  in-range section, known kind), builds the trie via a `unique_ptr` released only
  after the external pointer and finalizer are registered, and returns the opaque
  pointer; `psl_match()` (`src/matcher.cpp:176`) guards against a NULL pointer,
  then returns a named list of `ps_depth, kind, section, ps_start, rd_start,
  ps1_start`.
- Algorithm (`src/matcher.cpp:203`): one descent from the root consumes the
  host's labels right-to-left; at depth `d` the current node is the depth-`d`
  suffix, and a missing child ends the descent (no deeper rule can match).
  Exceptions take precedence over everything (longest wins; a matched exception's
  suffix depth is `depth - 1`). Otherwise the longest matching normal rule wins;
  a wildcard `*.s` matches only when a label exists to its left and counts the
  `*` in its depth, with a normal rule of equal length winning the tie. Because
  the descent runs depth-**ascending** (where the old suffix scan ran
  depth-descending), that "normal wins the tie" rule is made explicit rather than
  falling out of visit order. With no match, the implicit default `*` makes the
  rightmost label its own suffix (`kind = default`, `section = NA`). Under
  `section = "all"`, ICANN wins a cross-section tie. Results are returned as
  **byte offsets** (computed from cumulative label lengths) so R can slice every
  output string with a single vectorized `substr()` — valid because canonical
  ASCII means byte offset == character offset.

`src/cpp11.cpp` and `R/cpp11.R` are **generated** registration glue — never
edit them by hand; regenerate with `cpp11::cpp_register()` after changing a
`[[cpp11::register]]` signature.

## Bundled data and provenance

- `R/sysdata.rda` holds a single object `pslr_bundled = list(rules, meta)`:
  the validated rule table (~10k rows) plus the 11-field metadata (source,
  pinned commit SHA, list date, size, `sha256:` checksum, normalizer identity,
  normalization profile, Unicode version).
- `inst/extdata/public_suffix_list.dat` is the exact MPL-2.0 source snapshot,
  shipped so recipients can inspect the covered source; `inst/extdata/PSL-LICENSE`
  and `inst/NOTICE` document the MIT-code / MPL-2.0-data license split.
- `data-raw/update_psl.R` is the maintainer-run, deterministic regeneration
  pipeline. From a pinned 40-char commit SHA it downloads the list, license, and
  official test vectors; reads the commit date for `list_date`; parses via the
  in-tree parser with strict duplicate policy; and regenerates
  `inst/extdata/*.dat`, `inst/NOTICE`, `R/sysdata.rda`, and the test-vector
  fixture. A bundled-data update changes query results, so it must ship as a new
  package version with a changelog entry recording the old/new commit and
  checksum.

## Testing architecture

- `R CMD check` runs everything below — the behavior specs included.
- **Unit tests** (`tests/testthat/test-*.R`) cover each module: parser, dedup,
  duplicates, canonicalize, matcher, cache, query, extract, refresh, use,
  version/rules, bundled-data, profile-rebuild, and the official PSL vectors
  (`test-psl-vectors.R` against `fixtures/psl-vectors.txt`).
- **Differential oracle** (`helper-oracle.R`, `test-oracle.R`): pins current
  outputs across a function × option matrix over an 80+ host corpus into a
  checked-in RDS baseline, so refactors can *prove* they did not change
  observable behavior. The corpus is authored ASCII-only via `intToUtf8()` for
  byte-stable regeneration.
- **Cucumber / BDD** (`*.feature` + `setup-steps.R` run by `test-cucumber.R`):
  acceptance scenarios executed inside the normal test pass, guarded on
  `cucumber` being installed so `_R_CHECK_DEPENDS_ONLY_=true` degrades
  gracefully.
- **Helpers**: `helper-active.R` provides `fake_downloader` (the injected
  network double) and `local_pslr_clean` (isolates the cache dir and resets
  active state per test).
- Coverage is 100%; the one unreachable spot is `src/matcher.cpp:97`, a closing
  brace to which gcov attributes an epilogue basic block no test can reach —
  excluded with `// # nocov` rather than chased.

## Verify gate

CI and the pre-push hook run the same chain (see `AGENTS.md`):

```sh
Rscript -e 'lints <- lintr::lint_package(); if (length(lints)) { print(lints); quit(status = 1) }' \
  && Rscript -e 'rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")'
```

Air owns formatting (`air.toml`, a pre-commit hook); lintr owns logic lints.
Non-CRAN performance benchmarks and their release gate live in `bench/`, with
recorded reference numbers in [benchmarks.md](./benchmarks.md).

## Where to change what

| To change… | Edit | Then |
|---|---|---|
| Query option behavior / API | `R/query.R` | `devtools::document()`, update tests + vignette |
| Input validation (IPv4, missing/invalid) | `R/canonicalize.R` | update `test-canonicalize.R` |
| The matching algorithm | `src/matcher.cpp` | `cpp11::cpp_register()`, update `test-matcher.R` |
| Cache behavior / bound | `R/cache.R` | keep the shared schema in sync with `matcher.R` |
| Refresh / download / activation | `R/refresh.R` | use the `pslr.downloader` seam in tests |
| Metadata / provenance columns | `R/metadata.R` | update `psl_version_df` + `test-version-rules.R` |
| The bundled snapshot | run `data-raw/update_psl.R` | new version + `NEWS.md` entry with old/new commit |

Never hand-edit generated files: `NAMESPACE`, `man/`, `R/cpp11.R`, `src/cpp11.cpp`.
