# Introduction to pslr

``` r

library(pslr)
```

## What pslr does

The [Public Suffix List](https://publicsuffix.org) (PSL) is a
community-curated list of the domain suffixes under which Internet users
can directly register names. `pslr` bundles a pinned snapshot of that
list and implements the official *prevailing-rule* algorithm to answer
two core questions about a hostname:

- **Public suffix** (also called the effective top-level domain,
  *eTLD*): the suffix below which registrations happen, e.g. `co.uk` for
  `example.co.uk`.
- **Registrable domain** (*eTLD+1*): the public suffix plus the one
  label to its left that a registrant actually controls,
  e.g. `example.co.uk`.

``` r

public_suffix("www.example.co.uk")
#> [1] "co.uk"
registrable_domain("www.example.co.uk")
#> [1] "example.co.uk"
```

The matcher is compiled with `cpp11` and needs no external system
library. Hostname canonicalization (case folding and Unicode/IDNA
handling) is delegated to the
[`punycoder`](https://github.com/bart-turczynski/punycoder) package.

## Terminology

- **Rule** — a line in the list, such as `com`, `*.ck`, or `!www.ck`.
- **Normal rule** — a literal suffix (`com`, `co.uk`).
- **Wildcard rule** — `*.ck` means *every* label directly under `ck` is
  itself a public suffix.
- **Exception rule** — `!www.ck` carves a single name back out of a
  wildcard.
- **Default rule** — the spec’s implicit `*`: any unlisted TLD label is
  treated as a public suffix.
- **Section** — the list is split into an **ICANN** part (the official
  domain hierarchy) and a **PRIVATE** part (suffixes operated by
  companies, e.g. `github.io`).

The prevailing rule is chosen as: an exception beats a wildcard, the
longest match beats shorter matches, and the implicit default applies
only when nothing else does.

``` r

public_suffix("a.b.kobe.jp") # a wildcard match under kobe.jp
#> [1] "b.kobe.jp"
public_suffix("city.kobe.jp") # an exception match under kobe.jp
#> [1] "kobe.jp"
```

## Choosing a section

`section` selects which rules are eligible. Filtering happens *before*
prevailing-rule selection, so asking for one section never silently
borrows a rule from the other.

``` r

# github.io is a PRIVATE rule sitting under the ICANN suffix io.
public_suffix("user.github.io", section = "all") # default scope, both sections
#> [1] "github.io"
public_suffix("user.github.io", section = "icann") # the ICANN rule for io
#> [1] "io"
public_suffix("user.github.io", section = "private")
#> [1] "github.io"
```

### `section = "private"` fall-through

When you restrict to a section and the host matches no explicit rule
there, the query falls through to the implicit default rule rather than
failing. A plain ICANN host queried under `section = "private"`
therefore resolves to its own last label via the default rule:

``` r

public_suffix("example.com", section = "private")
#> [1] "com"
```

To distinguish “no explicit rule matched” from a real match, combine the
section with `unknown = "na"` (below).

## Unknown-suffix policy

By default an unlisted suffix is handled by the implicit `*` rule, so a
made-up TLD still yields a public suffix. Pass `unknown = "na"` to
require an *explicit* rule and get `NA` otherwise.

``` r

public_suffix("example.madeuptld") # default rule
#> [1] "madeuptld"
public_suffix("example.madeuptld", unknown = "na") # explicit-only
#> [1] NA
```

### Explicit-membership queries

[`is_public_suffix()`](https://bart-turczynski.github.io/pslr/reference/is_public_suffix.md)
reports whether a host is itself a public suffix. Under the default
policy an unlisted single label is `TRUE` via the implicit rule; use
`unknown = "na"` to test explicit list membership instead.

``` r

is_public_suffix("co.uk")
#> [1] TRUE
is_public_suffix("madeuptld") # TRUE via the implicit default rule
#> [1] TRUE
is_public_suffix("madeuptld", unknown = "na") # explicit membership only
#> [1] NA
```

## Unicode and ASCII output

Input may be ASCII, Unicode, or A-label (`xn--`) hostnames; equivalent
spellings canonicalize to the same answer. Output is ASCII A-labels by
default; pass `output = "unicode"` to decode them.

``` r

public_suffix("example.рф") # ASCII A-label by default
#> [1] "xn--p1ai"
public_suffix("example.рф", output = "unicode") # decoded to Unicode
#> [1] "рф"
public_suffix("example.xn--p1ai") # the A-label spelling agrees
#> [1] "xn--p1ai"
```

## Terminal dots

A single terminal root dot is preserved on hostname-shaped output, so a
fully-qualified name round-trips:

``` r

public_suffix("www.example.com.")
#> [1] "com."
registrable_domain("www.example.com.")
#> [1] "example.com."
```

## Extracting and inspecting

[`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md)
splits each host into subdomain, registrant label, and suffix;
[`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md)
reports which rule prevailed, useful for auditing.

``` r

suffix_extract("blog.user.github.io")
#>                 input                host subdomain domain    suffix
#> 1 blog.user.github.io blog.user.github.io      blog   user github.io
#>   registrable_domain
#> 1     user.github.io
public_suffix_rule(c("www.ck", "a.b.kobe.jp", "example.madeuptld"))
#>               input        host_ascii      rule      kind rule_section
#> 1            www.ck            www.ck   !www.ck exception        icann
#> 2       a.b.kobe.jp       a.b.kobe.jp *.kobe.jp  wildcard        icann
#> 3 example.madeuptld example.madeuptld         *   default         <NA>
#>   public_suffix_ascii
#> 1                  ck
#> 2           b.kobe.jp
#> 3           madeuptld
```

All query functions are vectorised, length- and name-preserving, and
NA-safe. Invalid input (URLs, IPv6, empty labels, dotted-decimal IPv4
literals, …) is `NA` by default; pass `invalid = "error"` to abort on
the first invalid element.

## Refresh and the active list

The package ships with a pinned snapshot, so it works fully offline and
the bundled list is the default for every query.
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)
is the *only* function that touches the network: an explicit,
HTTPS-only, validated download into a user cache.
[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
chooses which list backs the session.

``` r

# Download and validate a fresh list into the user cache, then activate it:
psl_refresh(activate = TRUE)

# Switch the active list for this session:
psl_use("cache") # the latest refreshed snapshot
psl_use("bundled") # back to the shipped snapshot
psl_use("path", path = "my_list.dat") # a custom file
```

Activation is session-only and validated before any state changes; a
failed refresh never replaces a working cache or active list.

## Reproducibility

A public-suffix result depends on both *which list* answered and *how
hosts were normalized*.
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
reports both — the source-snapshot provenance and the runtime
normalization identifiers — so a result can be reproduced later. Record
this row alongside reproducibility-sensitive output.

``` r

psl_version()
#>    source path            retrieved_at            list_date
#> 1 bundled <NA> 2026-06-15 16:18:34 UTC 2026-06-13T21:47:08Z
#>                                     commit   size
#> 1 9186eeeda85cef35b1551d00731464939c765cab 332703
#>                                                                  checksum
#> 1 sha256:54fb5c65a1e21aad963acd74a204370b5f517071e8b8e140c48de40727f0171c
#>   normalizer normalizer_version         normalization_profile unicode_version
#> 1  punycoder              1.2.0 uts46-nontransitional-std3-v1          16.0.0
```

[`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md)
exposes the active rule table itself:

``` r

nrow(psl_rules("icann"))
#> [1] 6933
head(psl_rules("private"), 3)
#>      rule canonical_rule   kind section labels
#> 1  co.krd         co.krd normal private      2
#> 2 edu.krd        edu.krd normal private      2
#> 3  art.pl         art.pl normal private      2
```

If the shipped index was generated under a different normalization
profile or Unicode version than the installed `punycoder`, the list is
transparently rebuilt in memory from source on activation, so an index
is never mixed with hosts normalized under a different profile.

The list drifts from the live upstream over time, so
[`psl_outdated()`](https://bart-turczynski.github.io/pslr/reference/psl_outdated.md)
offers an offline staleness check against the active `list_date` — the
cue to consider a
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md).
It never touches the network; the snapshot age in days is returned in
the `"age_days"` attribute.

``` r

psl_outdated() # older than the 180-day default?
#> [1] FALSE
#> attr(,"age_days")
#> [1] 22.89732
attr(psl_outdated(), "age_days") # active snapshot age, in days
#> [1] 22.89732
```

## Security and scope notes

- **Hostnames, not URLs.** The query functions accept DNS hostnames.
  URL-shaped input is rejected as invalid; parse the host out of a URL
  first.
- **Explicit network only.** Nothing in package load, queries, examples,
  or tests touches the network. Only
  [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)
  does, and only when you call it. It is HTTPS-only, rejects embedded
  credentials and downgrade redirects, and enforces a source-size
  ceiling.
- **The PSL is advisory.** It is a best-effort community list, not an
  authoritative statement of ownership or a security boundary by itself.
  Treat a registrable-domain result as a heuristic for grouping, not
  proof of control.
- **Session-global active list.** The active list is per-session global
  state; there is no per-call list switching. Concurrent per-list
  queries are out of scope for this release.

## See also

`pslr` is part of a small ecosystem of R packages by the same author:

- **[punycoder](https://bart-turczynski.github.io/punycoder/)** — the
  Punycode and IDNA codec that `pslr` uses for host canonicalization.
  Use it directly for raw Unicode ↔︎ ACE round-trips outside the PSL
  context.
- **[rurl](https://bart-turczynski.github.io/rurl/)** — full URL
  parsing, normalization, cleaning, and joining toolkit that uses `pslr`
  as its PSL engine. Reach for it when you need to work with complete
  URLs rather than bare hostnames.

## Acknowledgments

`pslr` serves the [Public Suffix List](https://publicsuffix.org),
maintained by Mozilla and the wider community under the Mozilla Public
License 2.0, and delegates host normalization (UTS \#46 / IDNA) to the
sibling `punycoder` package. Its matcher is built on `cpp11`.

The full list of credits — prior art, dependencies, the standards this
code implements, and the data sources it serves — is in
[`ACKNOWLEDGMENTS.md`](https://github.com/bart-turczynski/pslr/blob/main/ACKNOWLEDGMENTS.md).
