# pslr threat model

## What this project does and where untrusted input enters

`pslr` is an R package that answers Public Suffix List (PSL) queries: the
public suffix (eTLD) and registrable domain (eTLD+1) of a host name, under the
official prevailing-rule algorithm, against a pinned list bundled with the
package. Host normalization and IDNA are delegated to `punycoder`; matching
runs in a `cpp11` C++ trie in `src/matcher.cpp`. `rurl` imports it for domain
extraction, and its results reach security decisions downstream (same-site
and cookie-scope checks, allowlists keyed on registrable domain, and the
`ssrfr` SSRF guard through `rurl`).

Untrusted input:

- Host strings passed to the five query functions: `public_suffix()`,
  `registrable_domain()`, `is_public_suffix()`, `suffix_extract()` and
  `public_suffix_rule()`. Treat every byte as attacker-controlled: any
  length, any encoding mark, invalid UTF-8, embedded dots, IDNA edge cases,
  IPv4-looking and IPv6-looking strings, URL syntax.
- The HTTP response to an explicit `psl_refresh()`: status, headers (`ETag`,
  `Last-Modified`, `Location`, `Retry-After`), redirect targets and the body.
  The body is a PSL-format file that goes through `R/parser.R` and then into
  `psl_build_matcher()`. The rules a list server publishes are its choice; the
  bytes it sends must still not crash, hang or exhaust the process, escape the
  16 MiB decoded-body ceiling, or get activated without passing validation.

Trusted: the calling R code and its arguments other than the host vector
(`section`, `output`, `unknown`, `invalid`, `engine`), R options (`pslr.*`,
including `pslr.transport`, `pslr.cache_dir`, `pslr.config_dir`,
`pslr.max_bytes`), the URL passed to `psl_refresh()`, files the caller names
through `psl_use("path", path = file)`, `psl_engine("path", path = file)` (both
refuse `path` under any other `source`) or `psl_diff()`, the package's
bundled data (`R/sysdata.rda`, `inst/extdata/public_suffix_list.dat`), and the
user's own cache and config directories. Cache files are data, not code
(`docs/PRD.md` s9): malformed cache content must fail cleanly, but an attacker
who can write the user's cache directory is out of scope.

## Components that matter most / least

Most:

- `src/matcher.cpp`: `psl_build_matcher()` and `psl_match()`. `split_labels()`,
  the right-to-left trie descent, the `suffix_len` arithmetic, the `int` casts
  and the 1-based byte offsets (`ps_start`, `rd_start`, `ps1_start`) that the R
  layer feeds to `substr()`. The C++ assumes canonical lowercase ASCII hosts;
  check whether any input the R layer lets through breaks that assumption.
- `R/canonicalize.R`: the input contract in front of the C++. Encoding
  resolution (`psl_declare_utf8()`), undecodable-byte handling, the IPv4
  literal predicate (`is_ipv4_literal()`), terminal-dot handling, and the
  hand-off to `punycoder::host_normalize()`.
- `R/query.R` and `R/matcher.R`: slicing results from the C++ byte offsets
  (`psl_slice_registrant()`, `psl_derive_strings()`), `unknown = "na"`
  handling, and the cache-aware resolver `psl_resolve_cores()`.
- `R/cache.R`: the bounded per-engine result cache. Cached results must never
  differ from uncached ones, and the 200,000-entry bound must hold.
- The refresh path: `R/url-policy.R` (HTTPS only, no userinfo, query or
  fragment, same-origin redirects, at most five hops, validator scoping),
  `R/http-transport.R` (header normalization, request-header injection checks,
  the size ceiling), `R/validator-policy.R`, `R/refresh-machine.R`,
  `R/parser.R`, `R/duplicates.R` and `R/publication.R`. Also `R/refresh.R`:
  `psl_refresh()` builds the complete candidate engine before anything is
  committed and activates it only after publication, and `psl_load_source()`
  refuses a source file over `pslr.max_bytes` (16 MiB by default) before it is
  parsed and requires both official sections. `R/generation-store.R`: state,
  cache selection and reminder records are append-only generation files,
  written to a temporary file and renamed onto a name that does not yet exist,
  never overwritten; a reader validates every generation and takes the newest
  valid one, and compaction never removes the only valid or a newer corrupt
  generation. `R/locking.R`: one lock per source held across the whole
  refresh, a publish lock for publication, the source-then-publish order
  enforced in-process, a bounded wait, and one reclaim of a stale lock.

Less: `R/status.R`, `R/reminder.R`, `R/snapshots.R`, `R/prune.R`,
`R/diff.R`, `R/metadata.R` (offline, over trusted local state).

Out of scope: `src/cpp11.cpp` and `R/cpp11.R` (generated glue), `bench/`,
`data-raw/` (maintainer-run regeneration), `scripts/`, `tools/`, `docs/`,
and dependencies (`punycoder`, `curl`/libcurl, `digest`) unless `pslr` uses
them unsafely. A `punycoder` result that `pslr` passes to the C++ unchecked
is in scope.

## How to exercise it

The image has the source at `/src`, `pslr` installed from it with `-g -O1
-fno-omit-frame-pointer`, Imports and Suggests installed, `gdb` and
`valgrind` installed, the `tr_TR.UTF-8` and `az_AZ.UTF-8` locales the
case-folding tests need, and no network at audit time. The build itself has
network, so its smoke test leaves the live advisory audits (`test-osv.R`,
`test-security.R`) out; in the offline audit they skip on their own. All
refresh tests use an injected fake transport (`local_fake_transport()` in
`tests/testthat/helper-active.R`).

After patching any file under `src/` (C++ source or header), rebuild with
`R CMD INSTALL --preclean /src`: the build and `test_local()`'s `load_all()`
leave object files in `/src/src`, and R's build rules (the package has no
`src/Makevars`) declare no header dependencies, so a plain reinstall can link
stale objects.

```sh
Rscript -e 'testthat::test_local("/src")'
Rscript -e 'pslr::registrable_domain(c("www.example.co.uk", "a.b.ck", "www.ck"))'
Rscript -e 'pslr::suffix_extract("x.github.io", section = "private")'
Rscript -e 'system.time(pslr::public_suffix_rule(strrep("a.", 1e5)))'
R -d gdb --debugger-args='-batch -ex run -ex bt' -e 'pslr::public_suffix(c("", ".", "a..b", "1.2.3.4."))'
R -d valgrind -e 'pslr::registrable_domain(rawToChar(as.raw(c(0x61, 0xff, 0x2e, 0x63, 0x6f, 0x6d))))'
```

The C++ entry points can be driven directly, bypassing the R input contract:
`e <- pslr::psl_engine(); pslr:::psl_match(e$matcher, hosts, 2L)` (section
code 0 ICANN, 1 PRIVATE, 2 all) and
`pslr:::psl_build_matcher(keys, kinds, sections)`. A crash that needs a host
the R layer would never pass is Low; find the exported-API path first.

To exercise refresh offline, inject a transport: `options(pslr.transport =
function(request) ...)` returning `pslr:::new_psl_transport_response(...)`, and
point `pslr.cache_dir` / `pslr.config_dir` at a temporary directory.

Corpora: `tests/testthat/fixtures/psl-vectors.txt` (the official PSL test
vectors), the 80+ host differential-oracle corpus in
`tests/testthat/helper-oracle.R` with its baseline
`fixtures/oracle-baseline.rds`, `fixtures/case-folding-locales.txt`, and the
bundled list `inst/extdata/public_suffix_list.dat`.

## How you rate severity

- **Critical**: memory corruption in `src/matcher.cpp` (out-of-bounds write,
  use-after-free, double free) reachable from a host string passed to an
  exported query function, or from a list body served to `psl_refresh()`.
- **High**: any other out-of-bounds read, use-after-free or uninitialized read
  reachable from untrusted input, even without a demonstrated exploit. A
  result under the default bundled list that makes a caller's security
  decision wrong: a registrable domain that merges two registrants (a boundary
  shallower than the prevailing rule, an exception or wildcard misapplied, a
  PRIVATE rule ignored under `section = "all"`), a host canonicalized
  differently from how `punycoder`, WHATWG host parsing or a fetching client
  reads it so that an allowlist keyed on the result is bypassed, or a
  canonical IPv4 literal accepted as a domain name. On the refresh path: a
  validator or credential sent to a different origin, a redirect off HTTPS or
  off-origin that is followed, header injection into a request, or an
  unvalidated list getting activated or published.
- **Medium**: denial of service from small untrusted input: CPU or memory
  super-linear in host length or label count, a refresh body that gets past the
  16 MiB decoded-body ceiling (including through `gzip` content encoding), a
  cache that grows past its bound, a crash of the R process (a segfault, not an
  R error). A failed refresh that corrupts or replaces the working cache or
  active matcher.
- **Low**: wrong results with no security consequence, including
  nonconformance with the PSL algorithm on lists the caller supplies; an
  allowlist bypass, for a caller using `pslr` directly, through a
  non-canonical IPv4 string matched as a host name (see below); problems that
  need `:::` internals, a hand-built `psl_engine` object, a
  hostile R option, or a hostile file the caller chose to load.

## Anything to leave alone

Documented design choices (`docs/PRD.md`, `docs/decisions.md`):

- An R-level `stop()` on wrong argument types, unknown option values, or any
  invalid host under `invalid = "error"`. `NA` for invalid hosts under the
  default `invalid = "na"`.
- `unknown = "default"` applies the implicit `*` rule, so an unlisted TLD is
  its own public suffix; `unknown = "na"` is the opt-out.
- `"999.1.1.1"`, `"01.2.3.4"` and `"127.1"` are not canonical IPv4 literals
  and are matched as host names; only canonical dotted-decimal IPv4 is
  rejected (PRD s5.2). IP parsing and URL parsing are non-goals; URL syntax is
  invalid input. Keep that behavior. A caller that uses `pslr` directly and
  keys an allowlist on its result can still be misled by such a string, which
  a fetching client may read as an address: report that as Low, not as out of
  scope.
- The terminal root dot is kept on outputs: `public_suffix("example.com.")`
  is `"com."`.
- Under `section = "all"`, ICANN wins a cross-section tie.
- The result cache flushes in full when a store would exceed its bound.
- `psl_refresh()` is the only network access and runs only when called; the
  rules a list server publishes are not a vulnerability.
- Generated files (`src/cpp11.cpp`, `R/cpp11.R`, `NAMESPACE`, `man/`).

Patches: a minimal R or C++ fix in the package's style (roxygen-documented R,
Air formatting, no new dependencies); a `testthat` regression test in the
matching `tests/testthat/test-*.R` file (`test-matcher.R` for the C++,
`test-canonicalize.R` for input handling, `test-url-policy.R` or
`test-http-transport.R` for refresh); and a one-line `NEWS.md` bullet under
the development version that ends with the issue id in parentheses, as every
bullet there does (`pslr`'s `AGENTS.md`), and cites the PSL format or
algorithm clause, or the RFC and section, when the fix is a conformance fix.
