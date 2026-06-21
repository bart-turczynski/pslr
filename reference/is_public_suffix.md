# Is a host itself a public suffix?

`TRUE` exactly when the valid canonical host equals its own public
suffix under the selected policy. Returns `NA` whenever
[`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md)
would return `NA` (missing or invalid input, or an unresolved host under
`unknown = "na"`). Under the default `unknown = "default"`, an unlisted
single label such as `"madeuptld"` is `TRUE` via the implicit `*` rule;
ask `unknown = "na"` to test explicit membership instead.

## Usage

``` r
is_public_suffix(
  domain,
  section = c("all", "icann", "private"),
  unknown = c("default", "na"),
  invalid = c("na", "error")
)
```

## Arguments

- domain:

  Character vector of DNS hostnames (not URLs). Each element may be a
  mixed-case ASCII, Unicode, or A-label hostname, a single label, or a
  hostname with exactly one terminal root dot. See **Input contract**.

- section:

  Which rule sections are eligible: `"all"` (default; ICANN and
  PRIVATE), `"icann"`, or `"private"`. Section filtering happens before
  prevailing-rule selection, so `"private"` does not silently add ICANN
  rules; a host matching no rule in the section falls through to the
  implicit default rule unless `unknown = "na"`.

- unknown:

  `"default"` (default) applies the spec's implicit `*` rule, so an
  unlisted single label is its own public suffix; `"na"` returns `NA`
  when no explicit rule in the selected section matches.

- invalid:

  `"na"` (default) returns `NA` for each invalid element without a
  warning; `"error"` aborts on the first invalid element, reporting its
  1-based index.

## Value

A logical vector with `length(domain)`, preserving the names of
`domain`.

## Input contract

`NA` is treated as missing (returns `NA`), not invalid. Invalid elements
include empty or whitespace-only strings, leading or consecutive dots,
URL syntax, IPv6 addresses, canonical dotted-decimal IPv4 literals, and
labels that fail hostname/IDNA validation. Wrong argument types and
non-scalar or unknown option values always abort regardless of
`invalid`.

## See also

[`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md)

## Examples

``` r
is_public_suffix("com")
#> [1] TRUE
is_public_suffix("example.com")
#> [1] FALSE
is_public_suffix("madeuptld")
#> [1] TRUE
is_public_suffix("madeuptld", unknown = "na")
#> [1] NA
```
