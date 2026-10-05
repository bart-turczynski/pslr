
<!-- README.md is generated from README.Rmd. Please edit that file -->

<!-- Regenerate with: devtools::build_readme() -->

<!-- CI (the `readme` job in .gitlab-ci.yml) fails if README.md is out of sync with README.Rmd. -->

# pslr <img src="man/figures/logo.png" align="right" height="139" alt="hex logo, white on black" />

<!-- badges: start -->

[![CRAN status](https://www.r-pkg.org/badges/version/pslr)](https://CRAN.R-project.org/package=pslr)
[![CRAN downloads](https://cranlogs.r-pkg.org/badges/pslr)](https://CRAN.R-project.org/package=pslr)
[![CRAN checks](https://badges.cranchecks.info/worst/pslr.svg)](https://cran.r-project.org/web/checks/check_results_pslr.html)
[![r-universe](https://bart-turczynski.r-universe.dev/pslr/badges/version)](https://bart-turczynski.r-universe.dev/pslr)
[![Pipeline](https://gitlab.com/bart-turczynski/pslr/badges/main/pipeline.svg)](https://gitlab.com/bart-turczynski/pslr/-/pipelines)
[![Coverage](https://gitlab.com/bart-turczynski/pslr/badges/main/coverage.svg)](https://gitlab.com/bart-turczynski/pslr/-/pipelines)
[![Docs](https://img.shields.io/website?url=https%3A%2F%2Fbart-turczynski.gitlab.io%2Fpslr%2F&label=docs&logo=gitlab&logoColor=white&up_message=pkgdown&up_color=1f75cb)](https://bart-turczynski.gitlab.io/pslr/)
[![Lifecycle: stable](https://img.shields.io/badge/lifecycle-stable-brightgreen.svg)](https://lifecycle.r-lib.org/articles/stages.html#stable)
[![Project Status: Active](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20973660.svg)](https://doi.org/10.5281/zenodo.20973660)
[![Zenodo](https://img.shields.io/badge/Zenodo-all_software-1682D4?logo=zenodo&logoColor=white)](https://zenodo.org/search?q=metadata.creators.person_or_org.identifiers.identifier:0000-0002-8788-7980)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13430/badge)](https://www.bestpractices.dev/projects/13430)
[![License](https://img.shields.io/gitlab/license/bart-turczynski%2Fpslr)](https://gitlab.com/bart-turczynski/pslr/-/blob/main/LICENSE.md)
[![Dependencies](https://tinyverse.netlify.app/badge/pslr)](https://CRAN.R-project.org/package=pslr)
[![Last commit](https://img.shields.io/gitlab/last-commit/bart-turczynski%2Fpslr)](https://gitlab.com/bart-turczynski/pslr/-/commits/main)
<!-- badges: end -->

A focused, spec-complete implementation of the
[Public Suffix List](https://publicsuffix.org) (PSL) for R. `pslr` bundles a
reproducible, pinned PSL snapshot and implements the official prevailing-rule
algorithm to answer public-suffix (eTLD) and registrable-domain (eTLD+1)
queries.

- Distinguishes the **ICANN** and **PRIVATE** rule sections.
- Accepts Unicode, ASCII, and A-label hostnames via `punycoder`
  canonicalization; returns ASCII or Unicode output.
- Works fully **offline** from the bundled snapshot; an explicit, validated
  `psl_refresh()` is the only network path.
- Matcher compiled with `cpp11`; **no external system library** required.

## Installation

Install the released version from CRAN:

``` r
install.packages("pslr")
```

Or the development version from r-universe:

``` r
install.packages(
  "pslr",
  repos = c("https://bart-turczynski.r-universe.dev", "https://cloud.r-project.org")
)
```

`pslr` depends on [`punycoder`](https://cran.r-project.org/package=punycoder),
which is installed automatically from CRAN.

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

See `vignette("introduction", package = "pslr")` for the full tour: section
choice, the unknown-suffix policy, IDN output, terminal dots, refresh and
activation, freshness and scheduling, reproducibility, and security notes.

## Freshness

`psl_status()` reports, entirely offline, the strongest claim the locally stored
evidence supports about the active snapshot — whether it was confirmed current
against its source, whether a check is merely due, or whether a check actually
observed a newer list. Elapsed time alone is never reported as an update:
“a check is due” and “upstream changed” are different statements, and `pslr`
only makes the second one after a real check.

``` r
psl_status()
#> <psl_status: never_checked>
#>   Never checked against its source.
#>   No successful check has confirmed these bytes against the source. Run
#>   psl_refresh() to check.
#>   snapshot:     active (bundled)
#>   checksum:     sha256:00dda6fa8406...
#>   source:       https://publicsuffix.org/list/public_suffix_list.dat
#>   content date: 2026-09-05 14:17 UTC
#>   retrieved:    2026-10-05 08:46 UTC
```

`psl_refresh()` is the only network path. It sends a conditional request when it
can, honors the list’s no-more-than-daily download guidance, and returns one of
four outcomes: `skipped_recently` (no request), `not_modified` (`304`, no body),
`downloaded_unchanged`, or `updated`. Opt in to a weekly offline reminder with
`psl_reminder(enable = TRUE)`; for automation, run `pslr::psl_refresh()` from
cron or any scheduler you already have — `pslr` installs none and runs no
background task.

## Reproducibility

A result depends on both which list answered and how hosts were normalized.
`psl_version()` reports the active-list provenance plus the runtime
normalization identifiers; record it alongside reproducibility-sensitive output.

## How pslr compares to other PSL libraries

The [Public Suffix List website](https://publicsuffix.org/learn/) catalogs
implementations in a dozen languages but none in R. `pslr` fills that gap as a
reproducibility- and correctness-first engine: it records which list answered
and how hosts were normalized, runs the official upstream test vectors on every
check, works offline by default, and can diff two snapshots.
`vignette("comparison", package = "pslr")` sets it against ten established
libraries, from libpsl to tldts, and lists its trade-offs.

## Acknowledgments

These packages build on data, libraries, and prior work from many others.
See [ACKNOWLEDGMENTS.md](https://gitlab.com/bart-turczynski/pslr/-/blob/main/ACKNOWLEDGMENTS.md) for the full list of thanks.

## Related packages

`pslr` is part of a small ecosystem of R packages by the same author:

- **[punycoder](https://CRAN.R-project.org/package=punycoder)** — the Punycode and IDNA codec that `pslr` uses for host canonicalization before PSL matching. Use it directly for raw Unicode ↔ ACE round-trips.
- **[rurl](https://CRAN.R-project.org/package=rurl)** — full URL parsing, normalization, cleaning, and joining toolkit. Uses `pslr` as its PSL engine; reach for it when you need more than domain extraction.

## Citation

If you use `pslr` in your work, please cite it. Run `citation("pslr")` for the
current citation, or see [`CITATION.cff`](https://gitlab.com/bart-turczynski/pslr/-/blob/main/CITATION.cff).

Each release is archived on Zenodo. Cite the concept DOI
[10.5281/zenodo.20973660](https://doi.org/10.5281/zenodo.20973660) to refer to
the software in general (it always resolves to the latest version), or the
version-specific DOI shown on the [Zenodo
record](https://doi.org/10.5281/zenodo.20973660) for a particular release.

## License

Package code is MIT licensed. The bundled Public Suffix List data
(`inst/extdata/`) is distributed under the Mozilla Public License 2.0; see
`inst/NOTICE` and `inst/extdata/PSL-LICENSE`.
