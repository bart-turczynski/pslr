# Inspect the prevailing PSL rule for each host

Inspect the prevailing PSL rule for each host

## Usage

``` r
public_suffix_rule(
  domain,
  section = "all",
  unknown = "default",
  invalid = "na"
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

A base [data.frame](https://rdrr.io/r/base/data.frame.html) with one row
per input and columns, in order: `input` (original), `host_ascii`
(canonical A-label host), `rule` (the canonical rule including `*.` or
`!`, `"*"` for the implicit default), `kind` (`"normal"`, `"wildcard"`,
`"exception"`, or `"default"`), `rule_section` (`"icann"`, `"private"`,
or `NA` for the default/no result), and `public_suffix_ascii` (the
derived A-label public suffix). Invalid rows are `NA` in every derived
column. A valid host left unresolved by `unknown = "na"` keeps
`host_ascii` while the rule and suffix columns are `NA`. An exception
`rule` retains its `!` for auditability. Zero-length input returns a
zero-row frame; all-invalid input keeps one row per input.

## Input contract

`NA` is treated as missing (returns `NA`), not invalid. Invalid elements
include empty or whitespace-only strings, leading or consecutive dots,
URL syntax, IPv6 addresses, canonical dotted-decimal IPv4 literals, and
labels that fail hostname/IDNA validation. Wrong argument types and
non-scalar or unknown option values always abort regardless of
`invalid`.

## See also

[`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md),
[`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md)

## Examples

``` r
public_suffix_rule("www.example.co.uk")
#>               input        host_ascii  rule   kind rule_section
#> 1 www.example.co.uk www.example.co.uk co.uk normal        icann
#>   public_suffix_ascii
#> 1               co.uk
public_suffix_rule("madeuptld")
#>       input host_ascii rule    kind rule_section public_suffix_ascii
#> 1 madeuptld  madeuptld    * default         <NA>           madeuptld
```
