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

Its five query functions answer what the public suffix (eTLD) is, what the
registrable domain (eTLD+1) is, whether a host is itself a public suffix, which
PSL rule produced the answer, and how the host decomposes around that boundary.
It does **not** parse URLs, do DNS, or make security decisions.

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
query.R            public API: engine selection, option policy, shaping, framing
  -> canonicalize.R    domain vector -> canonical ASCII hosts + ok/na/invalid status
  -> matcher.R         snapshots, engines, C++ match result -> strings
       -> cache.R      bounded per-engine columnar cache (miss -> derive -> store)
       -> src/matcher.cpp   prevailing-rule algorithm over immutable rule indexes
```

Provenance and lifecycle sit alongside: `metadata.R` (`psl_version`,
`psl_rules`), `refresh.R` (`psl_refresh`, `psl_use`, the only network path),
`status.R` / `reminder.R` / `snapshots.R` / `prune.R` (the offline freshness
subsystem), `parser.R` (PSL-format parsing), `duplicates.R` (duplicate/conflict
policy).

## Public API surface

Fourteen exports (see `NAMESPACE`):

| Function | Defined at | Purpose |
|---|---|---|
| `public_suffix()` | `R/query.R:247` | eTLD of each host; optional isolated engine |
| `registrable_domain()` | `R/query.R:282` | eTLD+1 of each host; optional isolated engine |
| `is_public_suffix()` | `R/query.R:321` | `TRUE` iff host equals its own public suffix |
| `suffix_extract()` | `R/query.R:386` | data.frame splitting subdomain/domain/suffix |
| `public_suffix_rule()` | `R/query.R:460` | data.frame of the prevailing rule per host |
| `psl_engine()` | `R/matcher.R:276` | construct an isolated bundled/path engine |
| `psl_use()` | `R/refresh.R:612` | switch default list (bundled/cache/path) |
| `psl_refresh()` | `R/refresh.R:457` | conditional revalidate + validate + publish |
| `psl_status()` | `R/status.R:581` | offline freshness claim for one snapshot |
| `psl_reminder()` | `R/reminder.R:163` | opt-in offline attach-time reminder preference |
| `psl_snapshots()` | `R/snapshots.R:437` | offline inventory of locally resolvable snapshots |
| `psl_cache_prune()` | `R/prune.R:337` | remove unreferenced on-disk cache snapshots |
| `psl_version()` | `R/metadata.R:72` | one-row data.frame: identity of the default list |
| `psl_rules()` | `R/metadata.R:113` | data.frame of the default list's explicit rules |

Shared query options (`section`, `output`, `unknown`, `invalid`) are documented
in the PRD §6–7; their defaults and semantics are captured as decisions in
[decisions.md](./decisions.md).

## The R modules

### `R/query.R` — public query API

Thin vectorized wrappers; each resolves its engine and owns its `section` /
`output` / `unknown` / `invalid` policy. Key internals:

- `check_choice()` / `resolve_common_opts()` (`R/query.R:18`/`:36`) — scalar
  option validation shared by all query wrappers. `invalid` never suppresses
  these programming errors.
- `psl_query_cols()` (`R/query.R:111`) — the shared per-element result builder:
  canonicalize, resolve valid cores once, and apply `unknown = "na"` by erasing
  the implicit-default rule's derived fields. Returns a **bare list**, not a
  data.frame, to avoid ~0.1–0.2 ms of `data.frame()` construction per call; only
  the two frame-returning functions pay that cost, once, at the end.
- `psl_slice_registrant()` (`R/query.R:352`) — slices the registrant label and
  subdomain from the C++ byte offsets instead of per-row `strsplit()`.
- Every wrapper passes one `psl_engine` explicitly. Its default expression
  resolves the process-wide engine selected by `psl_use()`; a caller can instead
  provide an independently constructed engine.
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

Owns snapshot and engine objects, default-engine state, matcher construction,
C++-result → strings, and the cache-aware core resolver.

- A `psl_snapshot` carries rules and provenance; a process-local `psl_engine`
  carries one snapshot, its compiled matcher, and its own result cache
  (`R/matcher.R:131`, `:152`). `psl_engine()` constructs independent bundled or
  path engines without changing the default.
- Default session state lives in one env slot, `the_matcher$state`
  (`R/matcher.R:16`). `psl_activate_snapshot()` (`R/matcher.R:170`) builds a
  complete engine before one atomic assignment, so failure or interruption
  cannot expose a half-built matcher or cache.
- `build_matcher()` (`R/matcher.R:25`) calls into C++ (`psl_build_matcher`).
- `bundled_snapshot()` / `rebuild_bundled_rules()`
  (`R/matcher.R:200`/`:184`) implement the
  compatibility rebuild: if the shipped index's `normalization_profile` /
  `unicode_version` differ from the runtime `punycoder`, re-parse
  `inst/extdata/*.dat` in memory (lenient) before activating, preserving the
  shipped source identity.
- `psl_match_structural()` / `psl_derive_strings()`
  (`R/matcher.R:387`/`:407`) separate the compact C++ result from projected
  user-facing strings, deriving requested string columns with vectorized
  `substr()` calls.
- `psl_resolve_cores()` (`R/matcher.R:501`) is the cache-aware resolver: honors
  the `pslr.cache = FALSE` escape hatch, dedups cores, uses keys of
  `section_code|host`, derives misses, stores them in that engine's cache, and
  maps back to per-input.

### `R/cache.R` — bounded per-engine columnar cache

Keyed by canonical host + section. Snapshot identity is unnecessary because
each cache belongs to exactly one engine and matcher. Because `unknown`,
`output`, and terminal-dot restoration are applied *after* retrieval, they are
deliberately **not** in the key — the cache can never change a result. The store
is columnar: a key→index env plus six parallel integer vectors sharing the
`psl_cache_cols` schema (`R/cache.R:55`). Strings are reconstructed from the
cached depths, offsets, and enum codes. Default bound is 200,000 entries
(`R/cache.R:48`); eviction is a documented **full flush** when an ordinary
store would exceed capacity. A batch larger than capacity is matched but not
cached and leaves an existing warm set intact. Growth within the bound doubles
via `length<-` for amortized O(1) (`psl_cache_grow()`, `R/cache.R:116`).

### `R/metadata.R` — active-list metadata

`psl_version()` (`R/metadata.R:72`) renders the 12-column one-row identity
data.frame (`source, url, path, retrieved_at, list_date, commit, size, checksum,
normalizer, normalizer_version, normalization_profile, unicode_version`), shared
with `psl_refresh()`. `psl_parse_list_date()` (`R/metadata.R:80`) is the shared
lenient timestamp reader (`NA` in / unparseable in → `NA` out) used by
`psl_status()` and `psl_snapshots()`. `psl_rules()` (`R/metadata.R:113`) returns
the default list's explicit rules (ICANN before PRIVATE, then source order; the
implicit `*` is not included).

### `R/refresh.R` — refresh and activation

The only network access in the package, and only on an explicit `psl_refresh()`.

- `psl_refresh(url, ..., activate, force)` (`R/refresh.R:457`) resolves the
  URL policy, takes the source lock, runs the state machine, publishes, and
  optionally activates. `...` sits before the two flags so both are named-only.
- **Transport seam**: `R/http-transport.R` owns the `curl` request, the
  `pslr/<version>` user agent, timeouts, the 16 MiB decoded-body ceiling, and
  header sanitization. It is injected via `getOption("pslr.transport")` — the
  test seam that keeps CI off publicsuffix.org.
- **Append-only publication**: `R/publication.R` writes snapshot bytes and their
  descriptor before any reference to them, then appends a new source-state and
  selection generation. Published generation files are never overwritten, so a
  crash exposes a safe older generation or a complete newer one on both POSIX
  and Windows. A failed refresh records only a coarse attempt.
- Config seams via options: `pslr.max_bytes` (default 16 MiB), `pslr.cache_dir`
  (default `tools::R_user_dir("pslr", "cache")`), `pslr.config_dir`,
  `pslr.transport`.
- `psl_use(source, path)` (`R/refresh.R:612`) switches the default engine to
  bundled / cache / a custom path, validating before it changes any session
  state. Independent engines are unaffected.

### The freshness subsystem

Freshness v2 keeps *immutable snapshot identity* strictly apart from *mutable
knowledge about a remote endpoint*. A snapshot is named by the SHA-256 of its
exact source bytes and never changes; what a source last said about it lives in
a separate append-only stream. Snapshot age can recommend a check; only a
validated `200` or a usable `304` can establish remote freshness.

| Module | Owns |
|---|---|
| `R/freshness-schema.R` | versioned snapshot / source-state / selection / preference records |
| `R/generation-store.R` | append-only generation streams; readers take the greatest valid generation |
| `R/locking.R` | advisory source and publish locks, bounded wait; order is source → publish |
| `R/url-policy.R` | HTTPS-only absolute URLs, normalization to source identity, redirect scoping |
| `R/validator-policy.R` | `ETag` / `Last-Modified` selection, sanitization, and rotation |
| `R/http-transport.R` | injectable transport, user agent, timeouts, size ceiling |
| `R/refresh-conditions.R` | classed errors rooted at `pslr_refresh_error` |
| `R/refresh-machine.R` | the skip / `304` / `200` decision and its four success outcomes |
| `R/publication.R` | validated publication of bytes, descriptor, source state, selection |
| `R/migration.R` | lazy, idempotent, write-free-on-read v1 → v2 cache migration |
| `R/status.R` | offline status state machine and its print contract |
| `R/reminder.R` | opt-in preference (config, not cache) and the attach-time message |
| `R/snapshots.R` | distinct-checksum inventory with per-row `integrity` |
| `R/prune.R` | reference-safe deletion under the publish lock |

Two invariants drive most of the code. First, **an observed checksum difference
is `update_available`; elapsed time alone is only `check_due`** — status never
translates age into a claim about upstream. Second, **`checked_at` advances only
on a validated `200` or a usable `304`**; a failure may update attempt
diagnostics but neither freshness timestamp, so a working cache and active
matcher survive every failed operation byte-identically.

Same-source refreshes serialize across the whole network operation (source lock
held from the state read through commit), which trades parallel requests to one
endpoint for a simple non-regression guarantee. Different sources may download
concurrently; only their short publication phases serialize.

Naming footgun worth remembering: `psl_cache_prune()` deletes snapshot files
from the *disk* cache, while the internal `psl_cache_clear()` (`R/cache.R:96`)
only resets an engine's *in-memory match-result* cache and deletes nothing.
They are unrelated subsystems that happen to share the word "cache".

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
- **Helpers**: `helper-active.R` provides `local_fake_transport()` (the injected
  network double, scripted per request with status, headers, and body),
  `seed_legacy_cache()` (a v1 cache to migrate from), and `local_pslr_clean()`
  (isolates the cache and config dirs and resets active state per test).
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
| Refresh / download / activation | `R/refresh.R`, `R/refresh-machine.R` | use the `pslr.transport` seam in tests |
| Freshness status / reminders / inventory | `R/status.R`, `R/reminder.R`, `R/snapshots.R` | keep the state precedence in PRD §7.5 in sync |
| Persisted record shapes | `R/freshness-schema.R` | bump the schema version; extend `R/migration.R` |
| Metadata / provenance columns | `R/metadata.R` | update `psl_version_df` + `test-version-rules.R` |
| The bundled snapshot | run `data-raw/update_psl.R` | new version + `NEWS.md` entry with old/new commit |

Never hand-edit generated files: `NAMESPACE`, `man/`, `R/cpp11.R`, `src/cpp11.cpp`.
