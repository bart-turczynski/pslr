# Public suffix of a host

Returns the public suffix (effective top-level domain, eTLD) of each
host under the selected Public Suffix List policy, following the
official prevailing-rule algorithm.

## Usage

``` r
public_suffix(
  domain,
  section = "all",
  output = "ascii",
  unknown = "default",
  invalid = "na",
  engine = psl_default_engine()
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

- output:

  `"ascii"` (default) returns lowercase A-labels; `"unicode"` decodes
  them after matching. A terminal root dot is preserved either way.

- unknown:

  `"default"` (default) applies the spec's implicit `*` rule, so an
  unlisted single label is its own public suffix; `"na"` returns `NA`
  when no explicit rule in the selected section matches.

- invalid:

  `"na"` (default) returns `NA` for each invalid element without a
  warning; `"error"` aborts on the first invalid element, reporting its
  1-based index.

- engine:

  The `psl_engine` to query against; defaults to the session-global
  engine selected by
  [`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md),
  so most callers never set it. Pass an engine from
  [`psl_engine()`](https://bart-turczynski.github.io/pslr/reference/psl_engine.md)
  to resolve hosts against a specific snapshot in isolation.

## Value

A character vector with `length(domain)`, preserving the names of
`domain`. Other attributes are dropped.

## Input contract

`NA` is treated as missing (returns `NA`), not invalid. Invalid elements
include empty or whitespace-only strings, leading or consecutive dots,
URL syntax, IPv6 addresses, canonical dotted-decimal IPv4 literals, and
labels that fail hostname/IDNA validation. Wrong argument types and
non-scalar or unknown option values always abort regardless of
`invalid`.

## See also

[`registrable_domain()`](https://bart-turczynski.github.io/pslr/reference/registrable_domain.md),
[`is_public_suffix()`](https://bart-turczynski.github.io/pslr/reference/is_public_suffix.md),
[`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md),
[`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md)

## Examples

``` r
public_suffix("www.example.com")
#> [1] "com"
public_suffix("example.co.uk")
#> [1] "co.uk"
public_suffix("example.com.")
#> [1] "com."
public_suffix("madeuptld", unknown = "na")
#> [1] NA
```
