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
