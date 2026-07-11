# Split hosts into subdomain, registrant label, and public suffix

Split hosts into subdomain, registrant label, and public suffix

## Usage

``` r
suffix_extract(
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

A base [data.frame](https://rdrr.io/r/base/data.frame.html) with one row
per input and columns, in order: `input` (original, unchanged), `host`
(canonical host in `output` form), `subdomain` (labels left of the
registrable domain; `""` when none), `domain` (the single registrant
label left of the suffix), `suffix` (the public suffix), and
`registrable_domain` (eTLD+1). `domain`, `subdomain`, and
`registrable_domain` are `NA` when the host is itself a public suffix.
If public-suffix resolution is `NA`, every derived column except `input`
and a successfully normalized `host` is `NA`. Zero-length input returns
a zero-row frame; all-invalid input keeps one row per input. Root dots
are preserved on `host`, `suffix`, and `registrable_domain` only.

## Input contract

`NA` is treated as missing (returns `NA`), not invalid. Invalid elements
include empty or whitespace-only strings, leading or consecutive dots,
URL syntax, IPv6 addresses, canonical dotted-decimal IPv4 literals, and
labels that fail hostname/IDNA validation. Wrong argument types and
non-scalar or unknown option values always abort regardless of
`invalid`.

## See also

[`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md),
[`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md)

## Examples

``` r
suffix_extract("www.example.co.uk")
#>               input              host subdomain  domain suffix
#> 1 www.example.co.uk www.example.co.uk       www example  co.uk
#>   registrable_domain
#> 1      example.co.uk
suffix_extract(c("example.com", "com", NA))
#>         input        host subdomain  domain suffix registrable_domain
#> 1 example.com example.com           example    com        example.com
#> 2         com         com      <NA>    <NA>    com               <NA>
#> 3        <NA>        <NA>      <NA>    <NA>   <NA>               <NA>
```
