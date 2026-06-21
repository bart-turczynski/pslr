# Choose the active Public Suffix List for this session

Switches the list backing every query in the current R session. The
change is session-only and is validated before any session state
changes; a failure leaves the previously active list usable. A
successful switch invalidates the match-result cache.

## Usage

``` r
psl_use(source = c("bundled", "cache", "path"), path = NULL)
```

## Arguments

- source:

  Where to load the list from: `"bundled"` (the pinned package
  snapshot), `"cache"` (the latest successfully validated snapshot from
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)),
  or `"path"` (a custom file).

- path:

  For `source = "path"`, a single readable PSL-format UTF-8 file
  containing one complete ICANN section and one complete PRIVATE
  section, using official markers. Must be `NULL` for any other source.

## Value

Invisibly, the
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
row for the newly active list.

## Details

A custom path is held to the same runtime duplicate policy as
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md):
exact same-section duplicates warn once and are deduplicated, while
conflicting rule kinds for the same labels are fatal. Cache and
custom-path sources are read in source form and indexed under the
runtime normalizer; they never reuse the bundled generated index.

## See also

[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md),
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md),
[`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md)

## Examples

``` r
psl_use("bundled")
if (FALSE) { # \dontrun{
psl_use("cache")
psl_use("path", path = "my_list.dat")
} # }
```
