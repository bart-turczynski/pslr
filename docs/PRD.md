# pslr - Product Requirements and Design Specification

> Status: reviewed draft; decisions below are normative unless explicitly marked
> "deferred".
>
> Audience: package maintainer and implementation agents.
>
> Scope: `pslr` itself. The downstream `rurl` migration is a separate
> deliverable with its own release and compatibility checks.

## 1. Product definition

`pslr` is a focused R implementation of the
[Public Suffix List](https://publicsuffix.org/) (PSL). It owns:

1. a reproducible PSL snapshot;
2. parsing and validation of PSL-format data;
3. the official prevailing-rule algorithm; and
4. vectorised APIs for public suffix and registrable-domain queries.

It answers:

- What is the public suffix (eTLD) of this host?
- What is its registrable domain (eTLD+1)?
- Is this host itself a public suffix?
- Which PSL rule produced the result?

It supports ICANN, PRIVATE, or combined rule selection and accepts both Unicode
U-label and ASCII A-label hostnames. It does not parse URLs, perform DNS
lookups, determine whether a domain is registered, or decide whether a host is
trustworthy.

## 2. Motivation

- Existing R options do not expose the complete PSL algorithm and data model in
  a maintained, reusable package.
- `rurl` contains useful PSL code, but its current matcher omits the implicit
  default `*` rule and applies normalization inconsistently across code paths.
- PSL behavior is independently useful and should not be coupled to URL
  parsing.
- One implementation should provide the matching, section, IDN, refresh, and
  test behavior used by `rurl` and other R packages.

## 3. Goals and non-goals

### 3.1 Goals

- Implement the official PSL algorithm, including normal, wildcard, exception,
  and implicit default rules.
- Preserve the distinction between ICANN and PRIVATE rules.
- Normalize host input and list rules to one canonical comparison form.
- Be vectorised, deterministic, NA-safe, and suitable as a package dependency.
- Work offline using a bundled, pinned list.
- Offer an explicit, validated refresh path without automatic network access.
- Ship complete API documentation, official test-vector coverage, regression
  tests, and license notices suitable for CRAN.
- Use a compiled matcher without requiring an external system library.

### 3.2 Non-goals

- URL parsing, authority extraction, port removal, or IP-address parsing.
- DNS resolution, domain availability, WHOIS/RDAP, ownership, or liveness.
- Cookie policy, certificate policy, phishing detection, or security decisions
  beyond returning PSL-derived boundaries.
- Implementing Punycode or IDNA inside `pslr`.
- Maintaining or submitting changes to the upstream PSL.
- Exposing a general-purpose PSL linter in version 1. Internal validation needed
  to load lists is in scope.

## 4. Dependency architecture

The packages form this acyclic dependency graph:

```text
punycoder   canonical hostname normalization and A-label/U-label conversion
    ^
    | Imports
  pslr      PSL data, parser, matcher, and query APIs
    ^
    | Imports
  rurl      URL parsing; delegates PSL queries to pslr
```

Rules:

- `punycoder` must never import or suggest `pslr`.
- `pslr` imports a released `punycoder` version that provides one documented
  canonical-host normalization function. That function must perform Unicode
  NFC normalization, case normalization, label validation, and conversion to
  lowercase ASCII A-labels while preserving whether the input had one terminal
  root dot.
- The existing `punycoder::puny_encode()` function alone is not assumed to
  satisfy that complete contract. Adding and releasing the normalization API is
  a prerequisite for `pslr` IDN completion.
- The normalization contract must produce the same accepted/rejected inputs and
  canonical outputs with `punycoder`'s in-tree fallback backend and its optional
  `libidn2` backend. The exact IDNA profile and Unicode-version policy must be
  documented by `punycoder`, not inferred by `pslr`.
- `pslr` must install and pass its normalization and query tests when
  `punycoder` is built without `libidn2`. Optional `libidn2` availability may
  improve implementation performance but must not change behavior or be
  required for installation.
- `pslr` must call `punycoder`'s canonical-host normalization API directly
  rather than the low-level raw codec; behavior must not depend on the
  process-wide `punycoder.strict` option.
- `rurl` migration starts only after a released `pslr` API passes its own
  acceptance gates.

## 5. Input contract

### 5.1 Accepted input

`domain` is a character vector of DNS hostnames, not URLs. Each non-missing
element may be:

- a lowercase or mixed-case ASCII hostname;
- a Unicode hostname;
- an A-label hostname;
- a single DNS label;
- a hostname with exactly one terminal root dot.

The matcher does not verify that an otherwise valid hostname exists in DNS or
is fully qualified.

### 5.2 Invalid input

The following are invalid host elements:

- `""` or whitespace-only strings;
- leading dots, consecutive dots, or more than one terminal dot;
- URL syntax, user information, ports, paths, queries, or fragments;
- bracketed or unbracketed IPv6 addresses;
- canonical dotted-decimal IPv4 address literals: exactly four dot-separated
  ASCII decimal components, each written without leading zeros except `"0"`
  itself and having a numeric value from 0 through 255;
- labels or total names that fail the canonical normalization/IDNA contract;
- labels containing forbidden hostname characters.

`NA_character_` is missing, not invalid.

All query functions have `invalid = c("na", "error")`:

- `"na"` is the default and returns a typed `NA` for each invalid element,
  without a warning;
- `"error"` aborts the whole call and identifies the first invalid element and
  its one-based index.

Wrong argument types, non-scalar option arguments, and unknown option values
always abort; `invalid` does not suppress programming errors.

The IPv4 predicate applies to the entire input after removing one terminal root
dot. Thus `"1.2.3.4"` and `"1.2.3.4."` are invalid address literals,
`"1.2.3.4.example"` is not an address literal, and `"999.1.1.1"` is not IPv4
and therefore continues through ordinary hostname validation and PSL matching.

### 5.3 Canonicalization

For each valid element:

1. record and temporarily remove one terminal root dot;
2. normalize and validate through the required `punycoder` API;
3. compare lowercase ASCII A-labels only;
4. restore the terminal dot on hostname-shaped outputs; and
5. optionally decode outputs to Unicode.

`pslr` retains the terminal-dot distinction, consistent with the PSL format
specification. This is a package contract covered by direct tests rather than
assumed to be covered by upstream test vectors. For example,
`public_suffix("example.com.")` returns `"com."`, not `"com"`.

## 6. Matching contract

The implementation follows the official
[PSL format and algorithm](https://github.com/publicsuffix/list/wiki/Format).

For a selected rule set:

1. Match the canonical host right-to-left.
2. A normal rule matches equal labels.
3. A wildcard rule matches exactly one complete label in its leftmost
   position. A wildcard does not imply its parent rule.
4. An exception rule takes precedence over every other matching rule.
5. Otherwise, the matching rule with the most labels prevails.
6. If no explicit rule matches, the implicit default `*` rule prevails.
7. For an exception, remove its leftmost label before deriving the public
   suffix.
8. The public suffix is the host labels selected by the effective prevailing
   rule.
9. The registrable domain is the public suffix plus one host label to its left.
   It is `NA_character_` when no such label exists.

Rule and host data are canonicalized identically before comparison.

### 6.1 Section semantics

Every query has `section = c("all", "icann", "private")`; `"all"` is the
default because it matches mainstream PSL boundary behavior and current
`rurl` defaults.

- `"all"` makes ICANN and PRIVATE rules eligible.
- `"icann"` makes only ICANN rules eligible.
- `"private"` makes only PRIVATE rules eligible.
- The implicit default `*` rule is always available unless unknown-suffix
  handling is disabled.

Section filtering happens before prevailing-rule selection. `"private"` does
not silently add ICANN rules. Consequently, a host that matches no PRIVATE rule
falls through to the default rule.

For example, `public_suffix("example.com", section = "private")` returns
`"com"` through the default rule, not through an explicit PRIVATE rule. Callers
that mean "resolve only when an explicit PRIVATE rule matches" must also set
`unknown = "na"`. This interaction must be shown in the vignette.

### 6.2 Unknown-suffix semantics

Every core query has `unknown = c("default", "na")`:

- `"default"` applies the spec's implicit `*` rule and is the default;
- `"na"` returns typed `NA` when no explicit rule in the selected section
  matches.

`unknown` is separate from `invalid`: a syntactically valid unlisted suffix is
not malformed input.

Under `unknown = "default"`, `is_public_suffix("madeuptld")` is `TRUE` because
the implicit `*` rule makes an unknown single label its own public suffix.
Callers asking whether a suffix is explicitly present in the selected PSL
section must use `unknown = "na"`.

Examples under `section = "all"`:

```r
registrable_domain("foo.madeuptld")
# "foo.madeuptld"

registrable_domain("foo.madeuptld", unknown = "na")
# NA

public_suffix("madeuptld")
# "madeuptld"

registrable_domain("madeuptld")
# NA
```

### 6.3 Output form

Hostname-shaped query outputs have `output = c("ascii", "unicode")`; `"ascii"`
is the default because it is canonical, locale-independent, and safe for
programmatic comparison.

- `"ascii"` returns lowercase A-labels.
- `"unicode"` decodes A-labels through `punycoder` after matching.
- A terminal root dot is preserved in either form.
- Rule text returned for auditing is canonical ASCII and uses PSL markers
  (`*.` or `!`) regardless of `output`.

## 7. Public API

Names and schemas in this section are the version 1 contract.

### 7.1 Core functions

```r
public_suffix(
  domain,
  section = c("all", "icann", "private"),
  output = c("ascii", "unicode"),
  unknown = c("default", "na"),
  invalid = c("na", "error")
)

registrable_domain(
  domain,
  section = c("all", "icann", "private"),
  output = c("ascii", "unicode"),
  unknown = c("default", "na"),
  invalid = c("na", "error")
)

is_public_suffix(
  domain,
  section = c("all", "icann", "private"),
  unknown = c("default", "na"),
  invalid = c("na", "error")
)
```

- Character-returning functions return a character vector with
  `length(domain)`.
- `is_public_suffix()` returns a logical vector with `length(domain)`.
- `is_public_suffix(x)` is `TRUE` exactly when valid canonical `x` equals its
  public suffix under the selected policy. It returns `NA` whenever
  `public_suffix(x)` would return `NA`.
- Names on `domain` are preserved by vector-returning functions.
- Zero-length input returns a zero-length output of the correct type.
- Attributes other than names are not preserved.
- No `registered_domain` alias is exported in version 1. Documentation may
  mention "registered domain" as a synonym, but one canonical function name
  avoids a permanent duplicate API.

### 7.2 Extraction function

```r
suffix_extract(
  domain,
  section = c("all", "icann", "private"),
  output = c("ascii", "unicode"),
  unknown = c("default", "na"),
  invalid = c("na", "error")
)
```

Returns a base `data.frame` with one row per input and exactly these columns:

| Column | Type | Meaning |
|---|---|---|
| `input` | character | Original input, unchanged |
| `host` | character | Canonical host in `output` form |
| `subdomain` | character | Labels left of the registrable domain |
| `domain` | character | Single registrant label immediately left of suffix |
| `suffix` | character | Public suffix |
| `registrable_domain` | character | eTLD+1 |

Rules:

- `subdomain` is `""` when a registrable domain exists but has no subdomain.
- `domain`, `subdomain`, and `registrable_domain` are `NA` when the host itself
  is a public suffix.
- If public-suffix resolution is `NA`, every derived column except `input` and
  a successfully normalized `host` is `NA`.
- A root dot is preserved on `host`, `suffix`, and `registrable_domain`; it is
  not appended to the label-only `domain` or `subdomain` columns.
- Row names are automatic and input names are not converted into row names.
- Zero-length input returns a zero-row `data.frame` with the documented columns
  in the documented order and types.
- All-invalid input under `invalid = "na"` retains one row per input and the
  documented column types; it is not collapsed to a zero-row result.

This schema is migration-friendly but does not claim byte-for-byte compatibility
with `urltools::suffix_extract()`.

### 7.3 Rule inspection

```r
public_suffix_rule(
  domain,
  section = c("all", "icann", "private"),
  unknown = c("default", "na"),
  invalid = c("na", "error")
)
```

Returns a base `data.frame` with one row per input:

| Column | Type | Meaning |
|---|---|---|
| `input` | character | Original input |
| `host_ascii` | character | Canonical A-label host |
| `rule` | character | Canonical rule, including `*.` or `!`; `"*"` for default |
| `kind` | character | `normal`, `wildcard`, `exception`, or `default` |
| `rule_section` | character | `icann`, `private`, or `NA` for default/no result |
| `public_suffix_ascii` | character | Derived A-label public suffix |

Invalid rows contain `NA` in all derived columns. A valid host unresolved under
`unknown = "na"` retains `host_ascii` while rule and suffix columns are `NA`.
Exception `rule` retains `!` for auditability even though suffix derivation
removes its leftmost label.

Zero-length input returns a zero-row `data.frame` with the documented columns
in the documented order and types. All-invalid input under `invalid = "na"`
retains one row per input.

### 7.4 Data management

```r
psl_refresh(
  url = "https://publicsuffix.org/list/public_suffix_list.dat",
  force = FALSE,
  activate = FALSE
)

psl_use(source = c("bundled", "cache", "path"), path = NULL)

psl_version()

psl_rules(section = c("all", "icann", "private"))
```

`psl_refresh()`:

- performs network access only when called explicitly;
- accepts only an absolute `https` URL, rejects embedded credentials, and does
  not follow a redirect to a non-HTTPS scheme;
- reuses a successfully validated cache younger than 24 hours unless
  `force = TRUE`, respecting upstream download guidance; cache age is measured
  from the successful network retrieval timestamp, reuse does not advance that
  timestamp, and `activate = TRUE` activates the reused snapshot just as it
  would a newly downloaded snapshot;
- downloads to a temporary file in binary mode;
- enforces a documented maximum byte size before parsing;
- validates UTF-8, section markers, rule grammar, conflicting rules, and
  successful canonicalization of every rule;
- warns once and deduplicates exact same-section duplicate rules after
  canonicalization, retaining the first source occurrence;
- publishes source and metadata only after validation succeeds, using an atomic
  commit protocol that never exposes a mismatched or partial snapshot;
- never replaces a valid cache or active matcher after a failed refresh;
- returns `psl_version()`-shaped metadata for the selected cache snapshot
  invisibly, whether or not that snapshot is activated;
- activates the selected snapshot only when `activate = TRUE`.

`psl_use()`:

- `"bundled"` loads the package snapshot;
- `"cache"` loads the latest successfully validated user-cache snapshot and
  errors with remediation text if none exists;
- `"path"` requires one readable, PSL-format UTF-8 file;
- requires `path` only for `"path"` and rejects it otherwise;
- validates before changing session state;
- changes only the current R session;
- invalidates all match-result caches after a successful switch;
- returns metadata for the newly active list invisibly.

`psl_use("path")` applies the same runtime duplicate policy as
`psl_refresh()`: exact same-section duplicates warn and deduplicate, while
conflicting rule kinds are fatal.

Custom path files must contain exactly one complete ICANN section and one
complete PRIVATE section using official markers. Supporting unsectioned custom
rule sets is deferred.

`psl_version()` returns a one-row base `data.frame` with stable columns:
`source`, `path`, `retrieved_at`, `list_date`, `commit`, `size`, `checksum`,
`normalizer`, `normalizer_version`, `normalization_profile`, and
`unicode_version`.

- `normalizer` identifies the dependency providing canonicalization, initially
  `"punycoder"`.
- `normalizer_version` is its installed package version.
- `normalization_profile` is the dependency's stable identifier for its
  case-mapping, IDNA-processing, validation, and conversion policy.
- `unicode_version` identifies the Unicode data version used by that profile.
- Backend selection is not part of result identity because backend parity is a
  release requirement; it may be exposed separately for diagnostics.
- Unavailable metadata is typed `NA`, not omitted. `checksum` includes its
  algorithm prefix.

The normalization identifiers describe the implementation used by the current
R session, including when the active list came from the package, cache, or a
custom path.

`psl_rules()` returns a base `data.frame` with stable columns:
`rule`, `canonical_rule`, `kind`, `section`, and `labels`. `labels` is integer
rule depth including a wildcard label. Results are ordered first by section and
then by the source-file order. The implicit default rule is not included.

## 8. Engine and data design

### 8.1 Parser

The parser must:

- read UTF-8 without locale-dependent conversion;
- ignore blank lines and full-line comments;
- read rule content only up to the first whitespace, per the format spec;
- recognize official ICANN and PRIVATE boundaries;
- permit `*` only as a complete leftmost label;
- permit `!` only as the first character of an exception rule;
- reject empty labels and malformed marker nesting;
- retain original rule text and source order for inspection;
- parse `*` and `!` as structural markers and never pass them to hostname
  normalization;
- canonicalize only literal rule labels with the same dependency used for host
  labels; and
- emit actionable errors containing a source line number and reason.

Duplicate policy depends on trust boundary:

- the maintainer build pipeline for the bundled snapshot rejects exact
  same-section duplicates so upstream anomalies are reviewed before release;
- runtime refreshes and custom path loads warn once and deduplicate exact
  same-section duplicates, retaining the first source occurrence, so a benign
  upstream duplication cannot indefinitely block refresh; and
- conflicting rule kinds for the same canonical labels within one section are
  rejected in every mode.

The same rule may appear once in each section because section membership is
part of its identity.

### 8.2 Matcher

- Use `cpp11` for parsing the prepared rule index and matching host vectors.
- R wrappers own argument matching, normalization calls, result shaping, and
  user-facing errors.
- The active matcher is immutable after construction.
- Build partitioned normal, wildcard, and exception indexes for each section.
- Matching work is proportional to hostname label count, not total rule count.
- Deduplicate canonical hosts within a vector call before crossing into C++.
- A bounded session cache may optimize repeated calls. Its key must include the
  canonical host, active-list identity, and section.
- The cache stores only canonical ASCII match results and rule metadata.
  `unknown` policy, `output = "unicode"` decoding, and terminal-dot restoration
  happen after cache retrieval, so `unknown` and `output` are intentionally not
  part of the cache key.
- Cache size and eviction policy must be documented. Switching lists clears the
  cache.
- Cache state must never change results.
- The compiled code must not call R APIs from parallel threads. Version 1 does
  not add internal multithreading.

Using `cpp11` despite `punycoder` using Rcpp is an accepted implementation
decision; consistency does not justify changing either package's public API.

### 8.3 Bundled data

- Ship the exact upstream `public_suffix_list.dat` source snapshot under
  `inst/` so recipients can inspect the MPL-covered source.
- Ship a generated internal index for fast startup.
- Record upstream commit SHA, source URL, retrieval timestamp, list date,
  byte size, checksum, normalization profile, and Unicode version used to
  generate the index.
- Generate the index only from the shipped source snapshot.
- At package load or in a build-time verification test, assert that metadata and
  generated index correspond to that source.
- Before activating a generated index, compare its normalization profile and
  Unicode version with the runtime normalizer. If either differs, rebuild the
  index in memory from the corresponding validated source before activation;
  never combine an index canonicalized under one profile with hosts
  canonicalized under another.
- `psl_version()` reports the runtime normalizer identifiers actually used by
  the active matcher. An in-memory compatibility rebuild does not alter the
  shipped source identity or checksum.
- The package must function fully offline with the bundled snapshot.
- Package load must not read or mutate the user cache and must not access the
  network.

Cache and custom-path snapshots are stored or read in source form and indexed
at activation under the runtime normalizer. The pre-generated index is shipped
only for the bundled list, so normalization-profile mismatch and compatibility
rebuild logic applies only to that generated bundled index.

An in-memory compatibility rebuild may add a one-time cold activation cost
because every rule must be canonicalized under the runtime normalizer. That cost
is outside the steady-state query threshold in section 11.4 and must be reported
separately by the benchmark script.

The update script in `data-raw/` must accept a pinned upstream commit, regenerate
all derived artifacts deterministically, and print the exact source and
checksum used. Maintainer updates must review the upstream diff before
committing regenerated data.

A bundled snapshot update must be released as a new package version because it
can change query results even when R and C++ code are unchanged.

### 8.4 Licensing

The package code remains under its package license. The bundled PSL source and
derived representation remain covered by
[MPL-2.0](https://github.com/publicsuffix/list/blob/main/LICENSE).

The source distribution must include:

- the upstream license text;
- a notice identifying the bundled and generated PSL files;
- source URL and pinned commit; and
- clear separation between the package-code license and PSL-data license.

The final file names and `DESCRIPTION` license declaration must be checked
against current CRAN guidance before release; copying the existing `rurl`
layout is not by itself acceptance evidence.

## 9. Failure and state guarantees

- Core matching is deterministic for a given package version, active-list
  identity, normalization identifiers, and arguments.
- Query functions never access the network or mutate the active list.
- Refresh and list activation failures leave the previous cache and matcher
  usable.
- A corrupt cache is never selected automatically; `psl_use("cache")` reports
  the validation failure.
- No partial vector results are returned when `invalid = "error"`.
- Interrupting parsing or activation cannot leave a partially constructed
  active matcher.
- User cache files are data, not trusted executable content.
- Error messages must not print an entire large input vector or file.

## 10. Versioning and reproducibility

Package code/API behavior, PSL data, and hostname normalization jointly
determine results, but they have different compatibility implications:

- public API, argument-default, return-schema, normalization-policy, and
  matching-policy changes follow semantic-versioning compatibility rules;
- every bundled PSL snapshot change requires a package version bump and a
  changelog entry containing the old and new upstream commit/checksum;
- under this project's documented release policy, a data-only refresh may use a
  patch release when it changes no package API or algorithm, even though
  individual domain results may change;
- the active list identity and normalization identifiers exposed by
  `psl_version()` are required to reproduce a query result; and
- reproducibility-sensitive workflows must pin both `pslr` and `punycoder`,
  verify the recorded normalization profile and Unicode version, and use the
  bundled source, or archive and activate a specific validated path with its
  checksum. The mutable `"cache"` source is not reproducible by package version
  alone.

No release may silently replace bundled PSL data without updating package
version, metadata, and changelog. A change to the required normalization
profile or its Unicode data requires a `pslr` compatibility review and an
appropriate package release before `pslr` raises its accepted dependency
version.

## 11. Verification and acceptance criteria

Version 1 is releasable only when all criteria below pass.

### 11.1 Correctness

- All applicable official PSL test vectors pass for the bundled snapshot.
- Normal, wildcard, exception, default-rule, and wildcard-parent behavior each
  have direct unit tests.
- The matrix of `section`, `unknown`, `output`, terminal-dot, and invalid-input
  behavior has direct tests.
- Unicode and equivalent A-label inputs produce equal ASCII results.
- NFC-equivalent Unicode inputs produce equal results.
- Mixed case, single-label names, missing values, zero-length vectors, invalid
  labels, IPv4, IPv6, URL-shaped input, and empty labels have direct tests.
- `suffix_extract()` and `public_suffix_rule()` schemas, types, row counts, and
  NA propagation are snapshot or explicit-contract tested, including
  zero-length and all-invalid input.
- Parser tests cover malformed markers, invalid wildcards, invalid exceptions,
  strict build-time duplicate rejection, runtime warn-and-deduplicate behavior,
  same-section conflicts, permitted cross-section duplicates, bad UTF-8,
  inline whitespace/comments, and canonicalization failures.
- Terminal-dot behavior has direct package tests; passing upstream vectors is
  not treated as evidence for this package-specific contract.

### 11.2 Dependency portability

- `punycoder` documents the exact normalization profile used by `pslr`.
- `punycoder` exposes stable machine-readable normalization-profile and Unicode
  version identifiers, and `psl_version()` reports them with its installed
  package version.
- `pslr` installs and its full normalization/query suite passes against a
  `punycoder` build with `libidn2` unavailable.
- Where `libidn2` is available, backend-parity tests prove identical normalized
  output and validation decisions for the PSL rules, official IDN fixtures, and
  package edge-case fixtures.
- At least one continuously tested Windows configuration exercises the fallback
  backend used when `libidn2` is absent.
- Tests using a dependency fixture or test double prove that a changed
  normalization profile, Unicode version, or `punycoder` version is observable
  through `psl_version()` metadata.

### 11.3 Data and refresh

- A clean install with network disabled passes all query tests.
- The bundled source, metadata, and generated index agree.
- Tests simulate a generated index whose normalization profile or Unicode
  version differs from the runtime normalizer and prove that activation rebuilds
  from source rather than using a mixed-profile index.
- Refresh tests use an injected downloader or local TLS fixture with controlled
  redirects; CI does not depend on publicsuffix.org availability.
- Refresh tests prove the 24-hour throttle, `force`, atomic replacement,
  activation of both reused and newly downloaded snapshots, HTTPS/redirect
  restrictions, size limit, duplicate handling, snapshot source/metadata
  coherence, reuse without retrieval-timestamp advancement, and rollback after
  every validation failure.
- Cache and custom-path activation tests prove that each source is indexed
  under the runtime normalizer and never reuses the bundled generated index.
- `R CMD check --as-cran` does not write outside R-approved temporary or user
  cache locations.

### 11.4 Performance

- Include a non-CRAN benchmark script with fixed fixtures for 1, 1,000, and
  100,000 hosts, including repeated and unique values, plus a separately
  reported cold bundled-index compatibility rebuild.
- Before release, record reference results in committed developer documentation.
- On the maintainer's reference machine, the 100,000-host ASCII benchmark must
  complete in no more than 2 seconds after matcher initialization.
- Repeated-host input must demonstrate that canonical-host deduplication avoids
  one normalization and C++ call per duplicate.
- Performance tests must verify results as well as timing.

The timing threshold is a release gate, not a unit test, because shared CI and
CRAN timing are not stable.

### 11.5 Package quality

- Exported functions have examples and complete argument/return documentation.
- A vignette explains PSL terminology, section choice, unknown-suffix policy,
  IDN output, terminal dots, `section = "private"` fall-through,
  explicit-membership queries, refresh behavior, reproducibility, and security
  limitations.
- `R CMD check --as-cran` has no errors or warnings and no unexplained notes.
- The repository verify command and pre-commit/pre-push hooks pass.
- No network access occurs in examples, tests, package load, or query paths.
- No `_scratch/`, `.fp/`, dependency, cache, secret, or build-output files are
  included in source control or the built package.

## 12. Downstream `rurl` migration

The migration is outside the `pslr` package release but must eventually:

1. replace embedded PSL matching and list data with `pslr`;
2. preserve `rurl`'s documented defaults unless a deliberate breaking release
   says otherwise;
3. map `rurl` source selection explicitly to `pslr::section`;
4. define whether `rurl` retains its historical Unicode output while `pslr`
   defaults to ASCII;
5. retain regression fixtures for existing `get_domain()` and `get_tld()`
   behavior;
6. document intentional changes caused by the spec-correct default rule,
   wildcard/exception handling, or invalid-input policy; and
7. remove obsolete bundled PSL data, caches, and normalization helpers only
   after parity tests pass.

`rurl` must not use `pslr` session-global list switching to implement
per-request behavior. If downstream callers need per-list queries concurrently,
an explicit matcher object API must be designed in a later `pslr` release.

## 13. Delivery phases

1. **Dependency prerequisite**: specify, implement, test, and release the
   canonical-host normalization API in `punycoder`.
2. **Parser and bundled data**: deterministic update pipeline, metadata,
   licensing, validation, and generated indexes.
3. **Core matcher**: cpp11 indexes and prevailing-rule implementation with
   official vectors.
4. **Public query API**: input policy, sections, unknown policy, output forms,
   extraction, rule inspection, and bounded caching.
5. **Refresh and activation**: user cache, validation, atomic updates, metadata,
   and failure recovery.
6. **Release hardening**: benchmarks, documentation, offline checks, CRAN checks,
   and acceptance review.
7. **Downstream migration**: separately tracked `rurl` integration and release.

## 14. Deferred items

The following are explicitly not blockers for version 1:

- a public custom-list lint command;
- unsectioned custom lists;
- matcher objects for multiple simultaneously active lists;
- internal multithreading;
- automatic scheduled refresh;
- compatibility aliases beyond the API in section 7; and
- URL-accepting convenience wrappers.

Adding a deferred item requires a new design decision and must not silently
change the version 1 defaults or return schemas.
