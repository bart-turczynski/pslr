# Identity of the active Public Suffix List

Returns a one-row [data.frame](https://rdrr.io/r/base/data.frame.html)
describing the list currently active in this R session: its
source-snapshot provenance and the normalization identifiers actually
used to index the active matcher. Reproducing a query result requires
both the active-list identity and these normalization identifiers (PRD
s10), so a reproducibility-sensitive workflow should record this row.

## Usage

``` r
psl_version()
```

## Value

A one-row base [data.frame](https://rdrr.io/r/base/data.frame.html) with
the columns described in Details.

## Details

The columns, in order, are:

- `source`:

  `"bundled"`, `"cache"`, or `"path"`.

- `url`:

  Source URL of the active snapshot: the upstream download URL for the
  bundled list; `NA` for a `"cache"` or `"path"` source.

- `path`:

  File path of a `"cache"` or `"path"` source; `NA` otherwise.

- `retrieved_at`:

  Network retrieval timestamp, or `NA`.

- `list_date`:

  Upstream list date, or `NA` when unknown.

- `commit`:

  Upstream commit SHA, or `NA` when unknown.

- `size`:

  Source byte size (integer).

- `checksum`:

  Source checksum, including its algorithm prefix (e.g. `"sha256:..."`).

- `normalizer`:

  The dependency providing canonicalization, currently `"punycoder"`.

- `normalizer_version`:

  Its installed package version.

- `normalization_profile`:

  Its stable case-mapping / IDNA / validation profile identifier.

- `unicode_version`:

  The Unicode data version used by that profile.

Unavailable metadata is a typed `NA`, never omitted. The normalization
identifiers describe the implementation used by the current session,
whether the active list came from the bundled snapshot, the user cache,
or a custom path; an in-memory compatibility rebuild (PRD s8.3) updates
them without altering the shipped source identity or checksum.

## See also

[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md),
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md),
[`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md)

## Examples

``` r
psl_version()
#>    source
#> 1 bundled
#>                                                                                                                   url
#> 1 https://raw.githubusercontent.com/publicsuffix/list/9186eeeda85cef35b1551d00731464939c765cab/public_suffix_list.dat
#>   path            retrieved_at            list_date
#> 1 <NA> 2026-06-15 16:18:34 UTC 2026-06-13T21:47:08Z
#>                                     commit   size
#> 1 9186eeeda85cef35b1551d00731464939c765cab 332703
#>                                                                  checksum
#> 1 sha256:54fb5c65a1e21aad963acd74a204370b5f517071e8b8e140c48de40727f0171c
#>   normalizer normalizer_version         normalization_profile unicode_version
#> 1  punycoder              1.1.0 uts46-nontransitional-std3-v1          16.0.0
```
