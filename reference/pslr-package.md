# pslr: Public Suffix List Engine

A focused implementation of the Public Suffix List (PSL). Bundles a
reproducible, pinned PSL snapshot and implements the official
prevailing-rule algorithm to answer public-suffix (eTLD) and
registrable-domain (eTLD+1) queries. Distinguishes ICANN and PRIVATE
rule sections, accepts Unicode and ASCII hostnames via 'punycoder'
canonicalization, and supports an explicit, validated offline refresh
path. The matcher is compiled with 'cpp11' and requires no external
system library. Used as the PSL engine by the 'rurl' package.

## See also

Core queries:
[`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md),
[`registrable_domain()`](https://bart-turczynski.github.io/pslr/reference/registrable_domain.md),
[`is_public_suffix()`](https://bart-turczynski.github.io/pslr/reference/is_public_suffix.md),
[`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md),
[`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md).
List management and provenance:
[`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md),
[`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md),
[`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md),
[`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md).

The `introduction` vignette is a full tour:
[`vignette("introduction", package = "pslr")`](https://bart-turczynski.github.io/pslr/articles/introduction.md).

## Author

**Maintainer**: Bart Turczynski <bartek@turczynski.pl>
([ORCID](https://orcid.org/0000-0002-8788-7980))

Authors:

- Bart Turczynski <bartek@turczynski.pl>
  ([ORCID](https://orcid.org/0000-0002-8788-7980))
