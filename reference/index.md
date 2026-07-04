# Package index

## Querying

Extract public suffixes and registrable domains from hostname strings.

- [`public_suffix()`](https://bart-turczynski.github.io/pslr/reference/public_suffix.md)
  : Public suffix of a host
- [`registrable_domain()`](https://bart-turczynski.github.io/pslr/reference/registrable_domain.md)
  : Registrable domain of a host
- [`is_public_suffix()`](https://bart-turczynski.github.io/pslr/reference/is_public_suffix.md)
  : Is a host itself a public suffix?
- [`suffix_extract()`](https://bart-turczynski.github.io/pslr/reference/suffix_extract.md)
  : Split hosts into subdomain, registrant label, and public suffix
- [`public_suffix_rule()`](https://bart-turczynski.github.io/pslr/reference/public_suffix_rule.md)
  : Inspect the prevailing PSL rule for each host

## PSL Metadata

Inspect the active Public Suffix List snapshot.

- [`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md)
  : Identity of the active Public Suffix List
- [`psl_rules()`](https://bart-turczynski.github.io/pslr/reference/psl_rules.md)
  : Rules of the active Public Suffix List
- [`psl_outdated()`](https://bart-turczynski.github.io/pslr/reference/psl_outdated.md)
  : Is the active Public Suffix List snapshot stale?

## List Management

Refresh or switch the active PSL source. The bundled snapshot is used by
default; these functions let you update it or point to a local file.

- [`psl_refresh()`](https://bart-turczynski.github.io/pslr/reference/psl_refresh.md)
  : Refresh the cached Public Suffix List from upstream
- [`psl_use()`](https://bart-turczynski.github.io/pslr/reference/psl_use.md)
  : Choose the active Public Suffix List for this session
