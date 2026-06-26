# Refresh the cached Public Suffix List from upstream

Downloads, validates, and publishes a fresh Public Suffix List into the
user cache. This is the only function in the package that accesses the
network, and only when you call it explicitly.

## Usage

``` r
psl_refresh(
  url = "https://publicsuffix.org/list/public_suffix_list.dat",
  force = FALSE,
  activate = FALSE
)
```

## Arguments

- url:

  Absolute `https` URL of the list source. Defaults to the official
  list. URLs with another scheme or embedded credentials are rejected,
  and a redirect to a non-HTTPS URL is refused.

- force:

  When `FALSE` (default), a successfully validated cache younger than 24
  hours is reused without a download, respecting upstream download
  guidance. `TRUE` forces a fresh download.

- activate:

  When `TRUE`, the resulting snapshot becomes the active list for the
  session, exactly as
  [`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
  would activate it. When `FALSE` (default), the cache is updated but
  the active list is unchanged.

## Value

Invisibly, a one-row
[data.frame](https://rdrr.io/r/base/data.frame.html) shaped like
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
describing the selected cache snapshot, whether or not it was activated.

## Details

Cache age is measured from the successful network retrieval timestamp;
reusing a fresh cache does not advance that timestamp. The download goes
to a temporary file in binary mode and must be no larger than a
documented maximum (16 MiB). The source is then fully validated – UTF-8,
section markers, rule grammar, conflicting rules, and successful
canonicalization of every rule – and exact same-section duplicates warn
once and are deduplicated. Source and metadata are published only after
validation succeeds, using an atomic commit that never exposes a partial
or mismatched snapshot. A failed refresh never replaces a valid cache or
the active matcher.

## See also

[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md),
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)

## Examples

``` r
if (interactive()) {
  psl_refresh()
  psl_refresh(force = TRUE, activate = TRUE)
}
```
