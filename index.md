# pslr

A focused, spec-complete implementation of the [Public Suffix
List](https://publicsuffix.org) (PSL) for R. `pslr` bundles a
reproducible, pinned PSL snapshot and implements the official
prevailing-rule algorithm to answer public-suffix (eTLD) and
registrable-domain (eTLD+1) queries.

- Distinguishes the **ICANN** and **PRIVATE** rule sections.
- Accepts Unicode, ASCII, and A-label hostnames via `punycoder`
  canonicalization; returns ASCII or Unicode output.
- Works fully **offline** from the bundled snapshot; an explicit,
  validated
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)
  is the only network path.
- Matcher compiled with `cpp11`; **no external system library**
  required.

## Installation

Install the released version from CRAN:

``` r

install.packages("pslr")
```

Or the development version from GitHub:

``` r

# install.packages("pak")
pak::pak("bart-turczynski/pslr")
```

`pslr` depends on
[`punycoder`](https://cran.r-project.org/package=punycoder), which is
installed automatically from CRAN.

## Usage

``` r

library(pslr)

public_suffix("www.example.co.uk")
#> [1] "co.uk"
registrable_domain("www.example.co.uk")
#> [1] "example.co.uk"

# ICANN vs PRIVATE sections
public_suffix("user.github.io")
#> [1] "github.io"
public_suffix("user.github.io", section = "icann")
#> [1] "io"

# Explicit membership vs the implicit default rule
is_public_suffix("madeuptld")                 # implicit "*"
#> [1] TRUE
is_public_suffix("madeuptld", unknown = "na") # explicit only
#> [1] NA

# Split a host, or inspect the prevailing rule
suffix_extract("blog.user.github.io")
#>                 input                host subdomain domain    suffix
#> 1 blog.user.github.io blog.user.github.io      blog   user github.io
#>   registrable_domain
#> 1     user.github.io
public_suffix_rule("a.b.kobe.jp")
#>         input  host_ascii      rule     kind rule_section public_suffix_ascii
#> 1 a.b.kobe.jp a.b.kobe.jp *.kobe.jp wildcard        icann           b.kobe.jp
```

See
[`vignette("introduction", package = "pslr")`](https://bart-turczynski.github.io/pslr/articles/introduction.md)
for the full tour: section choice, the unknown-suffix policy, IDN
output, terminal dots, refresh and activation, reproducibility, and
security notes.

## Reproducibility

A result depends on both which list answered and how hosts were
normalized.
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
reports the active-list provenance plus the runtime normalization
identifiers; record it alongside reproducibility-sensitive output.

## How pslr compares to other PSL libraries

The [Public Suffix List website](https://publicsuffix.org/learn/)
catalogs implementations in C, C#, C++, Go, Haskell, Java, JavaScript,
Perl, PHP, Python, Ruby, Rust, Swift, and more — but no R. `pslr` fills
that gap, and it is built to be a *reproducibility- and
correctness-first* engine rather than a quick suffix splitter.

The table compares `pslr` with a representative set of the most
established libraries from that catalog, across the dimensions that
matter for correct, auditable suffix handling. ✅ first-class · ◐
partial/limited · ❌ absent.

| Library (language) | Full algorithm (`*`/`!`) | ICANN / PRIVATE / both | IDN + Punycode | Offline default + explicit refresh | Queryable provenance | Compiled core | Strict input validation | Unlisted-TLD policy configurable |
|----|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **pslr (R)** | ✅ | ✅ 3-way | ✅ in & out | ✅ bundled; validated HTTPS-only [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md) | ✅ list **and** normalization identity | ✅ `cpp11` | ✅ rejects URLs, IPv4, IPv6 | ✅ `unknown=` |
| libpsl (C) | ✅ | ✅ 3-way | ✅ | ✅ bundled; OS-package update | ◐ sha1 + mtime | ✅ | ◐ | ✅ |
| x/net/publicsuffix (Go) | ✅ | ◐ `icann` flag | ❌ ASCII only | ✅ embedded; bump module | ◐ date constant | ✅ | ◐ | ❌ |
| publicsuffix-go (Go) | ✅ | ◐ toggle private | ✅ | ✅ embedded | ❌ | ❌ | ◐ | ✅ |
| psl crate (Rust) | ✅ | ◐ per-suffix type | ✅ | ✅ compiled-in | ◐ dated releases | ✅ | ❌ | ◐ |
| tldextract (Python) | ✅ | ◐ private on/off | ✅ | ⚠️ network-first; offline opt-in | ❌ | ❌ | ◐ | ❌ |
| publicsuffixlist (Python) | ✅ | ◐ exclude private | ✅ | ✅ bundled + updater | ◐ date in version | ❌ | ❌ | ❌ |
| public_suffix (Ruby) | ✅ | ◐ `ignore_private` | ❌ caller pre-encodes | ✅ bundled | ❌ | ❌ | ◐ | ✅ |
| php-domain-parser (PHP) | ✅ | ✅ 3-way | ✅ | ⚠️ not bundled; PSR-16 cache | ◐ `isKnown` flags | ❌ | ◐ | ◐ |
| tldts (JS/TS) | ✅ | ◐ `allowPrivateDomains` | ✅ | ✅ embedded; npm bump | ◐ submodule pin | ◐ optional WASM | ✅ | ◐ |
| Guava `InternetDomainName` (Java) | ◐ | ✅ registry vs public | ✅ | ◐ in-jar; bump Guava | ❌ | ❌ | ◐ | ❌ |

### What `pslr` does differently

- **Provenance is best-in-class.**
  [`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
  records the list identity (source, commit, date, SHA-256) *and* the
  normalization identity (normalizer package + version, profile, Unicode
  version). A PSL answer depends on both *which list* answered and *how
  the host was normalized* — `pslr` is the only surveyed library that
  surfaces both, so a result is genuinely reproducible.
- **Conformance is verified.** The package ships the official upstream
  `tests.txt` vectors, pinned in lockstep with the bundled snapshot and
  run on every check.
- **Offline by default, one hardened network path.** Every query works
  with zero network access;
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)
  is the *only* code that touches the network — HTTPS-only, credential-
  and downgrade-rejecting, size-capped, atomically committed. This is
  stricter than network-first designs and pairs with the reproducibility
  story rather than fighting it.
- **Strict, policy-driven validation.** URLs, IPv6, dotted-decimal IPv4,
  and malformed labels are rejected; `invalid = "na"` / `"error"` lets
  you choose silent `NA` or a hard stop. Many libraries are deliberately
  lenient.
- **Vectorized, `NA`-safe, name-preserving.** Every function operates on
  a whole character vector — the idiomatic shape for data work in R.

### Trade-offs

- **Session-global active list.** There is no per-call list switching
  yet; the active list is per-session state
  ([`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
  /
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)).
- **Hostnames, not URLs.** URL-shaped input is rejected by design; parse
  the host out first or use
  [`rurl`](https://bart-turczynski.github.io/rurl/).
- **No network-first auto-fetch.** Refreshing is always explicit — a
  deliberate choice for reproducibility, not a convenience feature.

## Development

Install dependencies plus the dev tooling used by the checks:

``` sh
Rscript -e 'pak::local_install_deps(dependencies = TRUE)'
```

Run the same verification CI runs (lint + `R CMD check --as-cran`):

``` sh
Rscript -e 'lints <- lintr::lint_package(); if (length(lints)) { print(lints); quit(status = 1) }' && Rscript -e 'rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")'
```

`R CMD check` runs the testthat and cucumber specs, so the behaviour
specs are verified as part of the check. A non-CRAN performance
benchmark and its release gate live in
[`bench/benchmark.R`](https://github.com/bart-turczynski/pslr/blob/main/bench/benchmark.R);
recorded reference results are in
[`docs/benchmarks.md`](https://github.com/bart-turczynski/pslr/blob/main/docs/benchmarks.md).

### Project layout

- `R/` — package source (edit roxygen comments here, not `man/` or
  `NAMESPACE`).
- `src/` — the `cpp11` matcher core.
- `man/` — generated help pages (`devtools::document()`).
- `tests/testthat/` — testthat tests and cucumber feature specs.
- `vignettes/` — long-form documentation.
- `data-raw/` — the deterministic snapshot regeneration pipeline.
- `docs/` — durable project context (`PRD.md`, `architecture.md`,
  `benchmarks.md`).

## Acknowledgments

These packages build on data, libraries, and prior work from many
others. See
[ACKNOWLEDGMENTS.md](https://bart-turczynski.github.io/pslr/ACKNOWLEDGMENTS.md)
for the full list of thanks.

## Related packages

`pslr` is part of a small ecosystem of R packages by the same author:

- **[punycoder](https://bart-turczynski.github.io/punycoder/)** — the
  Punycode and IDNA codec that `pslr` uses for host canonicalization
  before PSL matching. Use it directly for raw Unicode ↔︎ ACE
  round-trips.
- **[rurl](https://bart-turczynski.github.io/rurl/)** — full URL
  parsing, normalization, cleaning, and joining toolkit. Uses `pslr` as
  its PSL engine; reach for it when you need more than domain
  extraction.

## License

Package code is MIT licensed. The bundled Public Suffix List data
(`inst/extdata/`) is distributed under the Mozilla Public License 2.0;
see `inst/NOTICE` and `inst/extdata/PSL-LICENSE`.
