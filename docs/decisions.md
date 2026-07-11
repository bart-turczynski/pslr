# Design decisions

A log of the load-bearing decisions behind `pslr` and *why* they hold — the
context a future change needs before it reverses one of them. The normative
contract is in [PRD.md](./PRD.md); the code map is in
[architecture.md](./architecture.md). Each entry is: **Decision → Context →
Consequences**. Status is `accepted` unless noted.

---

## D1 — A PSL engine separate from URL parsing

**Decision.** `pslr` owns only PSL data, parsing, matching, and queries.
URL parsing lives in `rurl`, which depends on `pslr`.

**Context.** PSL behavior is independently useful and was previously tangled
inside `rurl`, whose matcher omitted the implicit default `*` rule and applied
normalization inconsistently. One correct implementation should serve `rurl` and
any other R package.

**Consequences.** URL-shaped input is rejected by design (D8). The `rurl`
migration is a separate deliverable gated on `pslr` passing its own acceptance
criteria.

---

## D2 — Delegate all host normalization to `punycoder`; implement no IDNA here

**Decision.** All Unicode NFC/case normalization, label validation, and
A-label/U-label conversion is delegated to `punycoder::host_normalize()`.
`pslr` adds only IPv4-literal rejection and the missing-vs-invalid distinction.

**Context.** IDNA is intricate and version-sensitive; duplicating it would risk
`pslr` and `punycoder` diverging. The dependency DAG is strict:
`punycoder ← pslr ← rurl`, and `punycoder` must never depend on `pslr`.

**Consequences.** Rule labels and host labels are canonicalized by the *same*
dependency, so comparison is apples-to-apples. The normalizer's profile and
Unicode version become part of result identity (D12) and drive the compatibility
rebuild (D13). Behavior must not depend on `punycoder`'s process-wide `strict`
option, and must be identical with or without the optional `libidn2` backend.
Ref: `R/canonicalize.R`, `R/parser.R:9`.

---

## D3 — Compiled matcher via `cpp11`, no external system library

**Decision.** The prevailing-rule matcher is C++ compiled with `cpp11`
(`src/matcher.cpp`); it requires no external system library.

**Context.** Matching must be fast and vectorized. `punycoder` happens to use
Rcpp, but forcing one binding framework across packages is not a reason to change
either public API.

**Consequences.** The matcher is built once into an immutable, external-pointer
index and reused; matching is proportional to a host's label count, not the total
rule count. C++ sees only canonical ASCII and returns byte offsets so R derives
all strings with one vectorized `substr()` per column (byte offset == char offset
on ASCII). `src/cpp11.cpp` / `R/cpp11.R` are generated — regenerate with
`cpp11::cpp_register()`. Ref: `src/matcher.cpp:31`, `:99`.

---

## D4 — Offline by default; one explicit, hardened network path

**Decision.** Every query works fully offline from the bundled snapshot.
`psl_refresh()` is the *only* code that touches the network, and only when called
explicitly.

**Context.** Reproducibility and CRAN-friendliness require that package load,
examples, tests, and queries never reach the network. Network-first designs fight
reproducibility.

**Consequences.** `psl_refresh()` accepts only an absolute `https` URL, rejects
embedded credentials, refuses a redirect to a non-HTTPS effective URL, caps the
download size, validates before publishing, and commits atomically. The
downloader is an injected seam (`getOption("pslr.downloader")`) so CI never
depends on publicsuffix.org. Ref: `R/refresh.R:224`, `:312`.

---

## D5 — Three-way `section`, defaulting to `"all"`; filter before matching

**Decision.** Every query takes `section = c("all", "icann", "private")`.
Section filtering happens *before* prevailing-rule selection.

**Context.** `"all"` matches mainstream PSL boundary behavior and existing `rurl`
defaults. Keeping ICANN and PRIVATE distinct is a core PSL feature.

**Consequences.** `"private"` does not silently add ICANN rules, so a host
matching no PRIVATE rule falls through to the implicit default (D6) — e.g.
`public_suffix("example.com", section = "private")` returns `"com"` via the
default rule. "Resolve only on an explicit PRIVATE match" requires
`unknown = "na"` as well. Under `"all"`, ICANN wins a cross-section tie
(`src/matcher.cpp`).

---

## D6 — `unknown` policy separate from `invalid`; default `"default"`

**Decision.** Core queries take `unknown = c("default", "na")`, independent of
`invalid`. `"default"` applies the spec's implicit `*` rule.

**Context.** A syntactically valid but unlisted suffix is not malformed input —
conflating "unlisted" with "invalid" would be wrong.

**Consequences.** `is_public_suffix("madeuptld")` is `TRUE` under the default
rule; callers asking whether a suffix is *explicitly present* must pass
`unknown = "na"`. Ref: `R/query.R:102` (the default rule's derived fields are
erased when `unknown = "na"`).

---

## D7 — ASCII output by default

**Decision.** Hostname-shaped outputs take `output = c("ascii", "unicode")`,
defaulting to `"ascii"`.

**Context.** ASCII A-labels are canonical, locale-independent, and safe for
programmatic comparison.

**Consequences.** `"unicode"` decodes through `punycoder` *after* matching.
Rule text returned for auditing is always canonical ASCII with PSL markers
(`*.`, `!`) regardless of `output`. Because decoding is post-match, `output` is
not part of the cache key (D11).

---

## D8 — Strict, policy-driven input validation

**Decision.** URLs, IPv6, canonical dotted-decimal IPv4 literals, and malformed
labels are rejected. `invalid = c("na", "error")` chooses silent typed `NA`
(default) or a hard abort naming the first bad element and its 1-based index.
`NA_character_` is *missing*, not invalid.

**Context.** Many PSL libraries are deliberately lenient; `pslr` targets correct,
auditable boundary handling. The IPv4 predicate is exact — four dot-separated
decimals, no leading zeros except `"0"`, each 0–255 — so `"999.1.1.1"` is *not*
IPv4 and continues through ordinary matching.

**Consequences.** Wrong argument types and non-scalar/unknown option values
always abort — `invalid` never suppresses a programming error (D14). Ref:
`R/canonicalize.R:24`.

---

## D9 — Preserve the terminal-root-dot distinction

**Decision.** One terminal root dot is recorded, removed for matching, and
restored on hostname-shaped outputs. `public_suffix("example.com.")` returns
`"com."`, not `"com"`.

**Context.** This is a PSL-format contract, not something upstream test vectors
cover, so it is a package-specific guarantee with its own direct tests.

**Consequences.** The dot is preserved on `host`, `suffix`, and
`registrable_domain` outputs but not appended to label-only columns
(`domain`, `subdomain`). Dot restoration is post-match, so it is not in the cache
key (D11).

---

## D10 — Session-global active list; no matcher objects in v1

**Decision.** The active list is per-session state, switched by `psl_use()` /
`psl_refresh()`. There is no per-call list switching and no user-facing matcher
object in version 1.

**Context.** A single active matcher keeps the API small and the common case
fast. Multiple simultaneously active lists is a real but deferred need.

**Consequences.** State lives in one atomic slot (`the_matcher$state`): the
matcher is built *before* a single-assignment swap, so an interrupt or failed
activation never exposes a half-built matcher, and switching lists clears the
cache. `rurl` must not use global switching to implement per-request behavior; a
matcher-object API is a future release. Ref: `R/matcher.R:15`, `:66`.
Status: **accepted (v1 scope); revisit if concurrent per-list queries are needed.**

---

## D11 — Bounded columnar cache keyed on host + list identity + section only

**Decision.** A bounded session cache keys on canonical host, active-list
identity, and section. `unknown`, `output`, and terminal-dot restoration are
applied *after* retrieval and are deliberately **excluded** from the key. Default
bound 200,000 entries; eviction is a full flush.

**Context.** The cache must never change a result. Keeping post-match shaping out
of the key means one cached core answer serves every `unknown`/`output`/dot
variant. The store is columnar (a key→index env plus parallel column vectors)
sharing one schema across `cache.R`, `matcher.R`, and `query.R` so they cannot
drift. The bound was raised 50,000 → 200,000 because the columnar store costs
~80 bytes/entry (~16 MB full) and memory scales with live entries; a
200,000-unique re-query drops from ~1.63 s (flush and re-derive) to ~0.83 s (a
true hit, ~2×). `options(pslr.cache = FALSE)` disables it entirely.

**Consequences.** Cache-off output is byte-identical because misses use the same
derivation path. A batch larger than capacity is matched but not cached. Full
flush was chosen over LRU for simplicity and predictable memory. Ref:
`R/cache.R:38`, `:55`; `R/matcher.R:229`.

---

## D12 — Provenance covers list identity *and* normalization identity

**Decision.** `psl_version()` reports both the list identity (source, path,
retrieved-at, list date, commit, size, `sha256:` checksum) and the normalization
identity (normalizer package + version, profile, Unicode version).

**Context.** A PSL answer depends on *which list* answered and *how the host was
normalized*. Reporting only one makes results non-reproducible. No surveyed PSL
library in any language surfaces both.

**Consequences.** Reproducibility-sensitive workflows pin both `pslr` and
`punycoder` and record `psl_version()`. Unavailable metadata is typed `NA`, not
omitted; the checksum carries its algorithm prefix. Ref: `R/metadata.R:69`.

---

## D13 — In-memory compatibility rebuild on normalizer mismatch

**Decision.** Before activating the shipped generated index, compare its
normalization profile / Unicode version to the runtime `punycoder`. If either
differs, re-parse `inst/extdata/*.dat` in memory (lenient) before activating.

**Context.** An index canonicalized under one profile must never be matched
against hosts canonicalized under another. The shipped index is a startup
optimization for the bundled list only.

**Consequences.** A profile mismatch adds a one-time cold-activation cost
(reported separately by the benchmark), never a wrong answer. The rebuild does
not alter the shipped source identity or checksum. Cache and custom-path
snapshots are always indexed at activation under the runtime normalizer. Ref:
`R/matcher.R:82`, `:96`.

---

## D14 — Option detection via `missing()`, not value-equality

**Decision.** The scalar option matcher decides "was this supplied?" with
`missing()`, not by comparing to the default value.

**Context.** If detection compared to the default, an explicit but *invalid*
argument that happens to equal the default vector (e.g.
`invalid = c("na", "error")`) would slip through unvalidated.

**Consequences.** Explicit non-scalar or unknown option values always abort, and
`invalid` cannot suppress that. Ref: `R/query.R:18`.

---

## D15 — Duplicate policy differs by trust boundary

**Decision.** Exact same-section duplicate rules are **fatal** in the maintainer
build (`mode = "strict"`) but **warn-once-and-dedup** at runtime
(`mode = "lenient"`, refresh / custom path). Conflicting rule *kinds* for the
same labels+section are fatal everywhere. Cross-section duplicates are always
allowed.

**Context.** Upstream anomalies should be reviewed before a release, but a benign
upstream duplication must not indefinitely block a user's refresh.

**Consequences.** The bundled snapshot is built strict; `psl_refresh()` and
`psl_use("path")` run lenient. Section membership is part of rule identity, so the
same rule may legitimately appear once per section. Ref: `R/duplicates.R:27`.

---

## D16 — Differential-oracle / byte-identity testing

**Decision.** A checked-in RDS baseline pins outputs across a function × option
matrix over an 80+ host corpus; refactors must reproduce it byte-for-byte.

**Context.** The columnar cache and query rewrites were behavior-preserving by
intent; an oracle turns that intent into an enforced, reviewable guarantee.

**Consequences.** The corpus is authored ASCII-only via `intToUtf8()` so it
regenerates byte-stably. `NEWS.md` entries for those refactors state "the
differential oracle is unchanged." Ref: `tests/testthat/helper-oracle.R`,
`test-oracle.R`. Coverage is 100%, with `src/matcher.cpp:97` excluded via
`// # nocov` (an unreachable gcov epilogue block, not dead code).

---

## D17 — A bundled-snapshot change is a released version

**Decision.** Every change to the bundled PSL data requires a package version
bump and a `NEWS.md` entry recording the old and new upstream commit/checksum.

**Context.** Query results can change with the data alone, even when R and C++
code are unchanged. A data-only refresh may use a patch release when it changes
no API or algorithm.

**Consequences.** No release silently replaces bundled data. `data-raw/update_psl.R`
regenerates all derived artifacts deterministically from a pinned commit and
prints the exact source and checksum; the maintainer reviews the upstream diff
before committing. Ref: `data-raw/update_psl.R`.

---

## D18 — Reverse-label trie matcher: adopted by replacement (sole matcher)

**Decision.** The reverse-label trie **replaces** the hash-set matcher as the
single core matcher. Its bodies now stand behind the canonical registered names
`psl_build_matcher` / `psl_match` (`src/matcher.cpp`); the hash-set
implementation — its `Matcher` struct, `find_section()`, and hash-set bodies —
is deleted, and the prototype's `_trie` registered names are gone. This is
adoption by REPLACEMENT, not a second matcher kept alongside: there is exactly
ONE matcher, so the earlier maintenance objection (two code paths to keep in
lockstep) does not arise. The call was made once, on the evidence below, and is
settled.

**Context.** `bench/trie-vs-hashset.R` builds both matchers from the *same*
bundled rules (10,212 rules) and matches the *same* exactly-unique canonical
corpus (`psl_bench_unique_hosts`), asserting identical `ps_depth` **and** `kind`
across section codes 0/1/2 before trusting any timing — so a broken trie cannot
masquerade as a win. This isolates precisely what a trie changes (direct-match
cost) and mirrors the audit's methodology, which timed the hash-set matcher at
~0.45 s for 100,000 canonical hosts against the 2 s release gate and concluded
"current performance is already adequate." Timings below are relative, not
absolute — a laptop noisier than the maintainer's reference machine — so the
load-bearing figure is the trie/hash **ratio** (same machine, same run), stable
across three repeats.

Median elapsed seconds, section `"all"` (`section_code` 2, the realistic
default), R 4.6.0 on aarch64-apple-darwin23:

| implementation | build_s | match_s (n=100k) | match_s (n=10k) |
|:---------------|--------:|-----------------:|----------------:|
| hash-set | 0.013 | 0.357–0.376 | 0.036–0.038 |
| trie | 0.019 | 0.158–0.166 | 0.016–0.017 |

Headline **trie/hash match-time ratio** (< 1 = trie faster), median of three
runs: **0.44** for `"all"` (~2.25× faster) and **0.56** for `"icann"`
(~1.8× faster). Trie build is ~0.006 s slower — negligible, one-time. The trie
clears the ticket's speed threshold (~1.3–1.5×) decisively.

**Consequences.** The speedup is real, stable, and correctness-verified: the
trie gives ~2.25× faster direct matching under section `"all"` with
byte-identical output, gated by the differential oracle (D16). Adopting it by
replacement — rather than keeping it as a parallel second matcher — is what
answers the earlier maintenance objection: there is one implementation to test
and reason about, not two kept in lockstep, so the complexity cost the raw ratio
had to be weighed against simply does not exist. The direct-match cost remains a
second-order factor in the default cache-served path (D11), so the win is most
visible on cache-cold, large-batch, and cache-disabled workloads; the hash-set
baseline it replaced was already comfortably under the 2 s release gate, so this
is a headroom improvement, not a fix for a hot spot. The differential oracle
(D16) and Cucumber remain the correctness net now that the cross-check against a
second matcher is gone. Ref: the measurement table above is the durable
evidence; the retired prototype (both matchers side by side, and the deleted
`bench/trie-vs-hashset.R`) lives in the git history of branch
`feature/matcher-trie-prototype`. Status: **accepted.**

---

## D19 — Cache policy: keep the flat bound + full-flush; decline auto-bypass and generational eviction

**Decision.** The bounded columnar cache (D11) keeps its flat capacity and
whole-table eviction. Two behaviour-changing ideas floated in the refactoring
audit (§2.5) were evaluated against the benchmark harness and **not adopted**: a
`pslr.cache = "auto"` mode that would bypass the *store* on large mostly-unique
calls, and a two-generation eviction policy replacing the full flush. One
narrow, strictly-beneficial refinement in the same code path **was** adopted: an
oversized batch (unique misses exceeding the whole capacity) no longer evicts
the warm set — it returns before flushing, since it could never be cached
anyway.

**Context.** Both declined ideas are measurement-gated ("adopt only if measured
workloads justify"). The authoritative harness (`bench/benchmark.R`), 200,000
exactly-unique hosts through `registrable_domain()`, median of 5 reps, R 4.6.0
on aarch64-apple-darwin23:

| scenario        | seconds |
|:----------------|--------:|
| cold (cache-on) | 1.103   |
| warm (cache-on) | 0.836   |
| cache-off       | 0.878   |

- **`auto`-bypass.** The store cost on a one-shot 200k-unique batch is
  `cold − cache-off = 0.225 s` (~20 %). But the shipped
  `options(pslr.cache = FALSE)` escape hatch already lets a caller who *knows* a
  batch is one-shot take the cache-off path; an `"auto"` mode would instead have
  to *guess* reuse from batch size, and it guesses wrong for the re-query
  pattern — where warm saves `cold − warm = 0.267 s`. A third public cache mode
  plus a magic size threshold is not justified by a 20 % shave on a sub-second,
  never-reused operation that already has an explicit opt-out.
- **Two-generation eviction.** No measured workload crosses the 200,000-entry
  bound with re-query; the bound was raised 50k→200k (PSLR-ynbfnhkp) precisely to
  keep realistic working sets warm. At the honest ~600 bytes/entry retained-heap
  figure ([benchmarks.md](./benchmarks.md)) a full table is ~113 MB, so raising
  the flat bound — not generational machinery — is the cheap lever if a real
  workload ever needs it. Real LRU/generational structure (a second index,
  promotion/demotion, compaction of the append-only columnar store) is
  unjustified complexity absent that evidence.

The evaluation did surface a genuine wart: `psl_cache_store()` flushed the warm
table even when the incoming batch was itself larger than capacity (`m >
capacity`) — evicting the warm set to store *nothing*. That is pure loss under
any workload, so the store now returns before evicting in that case.

**Consequences.** The cache stays simple: one flat bound, one eviction rule,
one explicit on/off option — no size heuristics, no generations. The manual
`options(pslr.cache = FALSE)` hatch remains the supported lever for one-shot
mostly-unique batches. A warm working set now survives an oversized one-shot
query instead of being flushed for nothing (user-visible; tested in
`test-cache.R`, noted in `NEWS.md`). Both declined ideas can be reopened, but
only against a *measured* real workload that the numbers above do not already
answer. Status: **accepted** (declined the two headline ideas; adopted the
oversized-no-evict refinement).
