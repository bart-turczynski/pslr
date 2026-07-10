# Is the active Public Suffix List snapshot stale?

An offline staleness check: compares the `list_date` of the list
currently active in this session (see
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md))
against the current time and reports whether it is older than `max_age`
days. The Public Suffix List changes continually upstream, so a
long-lived bundled snapshot drifts from the live list over time; this is
the signal to consider
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md).

## Usage

``` r
psl_outdated(max_age = 180)
```

## Arguments

- max_age:

  Maximum age, in days, before the active snapshot is considered
  outdated. A single positive number; defaults to 180.

## Value

A single logical, with an `"age_days"` attribute: `TRUE` when the active
list is more than `max_age` days old, `FALSE` when it is fresher, and
`NA` when its date is unknown.

## Details

The check reads only the already-loaded active metadata: it never
touches the network and never activates a different list. When the
active list's `list_date` is unknown (`NA`) or cannot be parsed, the
result is `NA` – staleness is undetermined rather than assumed either
way.

The age of the active snapshot in days is attached to the result as the
`"age_days"` attribute (a double, or `NA` when the date is unknown), so
a caller that wants the magnitude as well as the verdict need not
recompute it.

## See also

[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md),
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)

## Examples

``` r
# Is the active snapshot older than the default threshold?
psl_outdated()
#> [1] FALSE
#> attr(,"age_days")
#> [1] 26.94429

# The age in days is available without recomputing it:
attr(psl_outdated(), "age_days")
#> [1] 26.94429

# Use a stricter threshold:
psl_outdated(max_age = 30)
#> [1] FALSE
#> attr(,"age_days")
#> [1] 26.94429
```
