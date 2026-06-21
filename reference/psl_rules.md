# Rules of the active Public Suffix List

Returns the explicit rules of the active list as a base
[data.frame](https://rdrr.io/r/base/data.frame.html), one row per rule.
The implicit default `*` rule is not included.

## Usage

``` r
psl_rules(section = c("all", "icann", "private"))
```

## Arguments

- section:

  Which rule sections to return: `"all"` (default), `"icann"`, or
  `"private"`.

## Value

A base [data.frame](https://rdrr.io/r/base/data.frame.html) with
columns, in order: `rule` (original source rule text), `canonical_rule`
(the canonicalized rule, including the `*.` or `!` marker), `kind`
(`"normal"`, `"wildcard"`, or `"exception"`), `section` (`"icann"` or
`"private"`), and `labels` (integer rule depth, counting a wildcard
label). Rows are ordered first by section (ICANN before PRIVATE) and
then by source-file order.

## See also

[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md),
[`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md)

## Examples

``` r
head(psl_rules("icann"))
#>     rule canonical_rule   kind section labels
#> 1     ac             ac normal   icann      1
#> 2 com.ac         com.ac normal   icann      2
#> 3 edu.ac         edu.ac normal   icann      2
#> 4 gov.ac         gov.ac normal   icann      2
#> 5 mil.ac         mil.ac normal   icann      2
#> 6 net.ac         net.ac normal   icann      2
nrow(psl_rules("private"))
#> [1] 3279
```
