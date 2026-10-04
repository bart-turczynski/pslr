# Architecture

`pslr` is a [Public Suffix List](https://publicsuffix.org/) engine: a
`cpp11`-compiled prevailing-rule matcher under a vectorized, `NA`-safe R query
API, backed by a pinned PSL snapshot bundled with the package, with a bounded
session cache and an explicit, validated refresh path.

```text
punycoder   canonical host normalization + A-label/U-label conversion (IDNA)
    ^ Imports
  pslr      PSL data, parser, matcher, query APIs
    ^ Imports
  rurl      URL parsing; delegates PSL queries to pslr
```

The full map lives in `docs/`, which is committed source here (pkgdown builds
into `site/`):

- [docs/architecture.md](https://gitlab.com/bart-turczynski/pslr/-/blob/main/docs/architecture.md):
  the layers a query passes through, the R modules, the compiled matcher in
  `src/`, the bundled data and its provenance, the test suite and the verify
  gate, and where to change what.
- [docs/PRD.md](https://gitlab.com/bart-turczynski/pslr/-/blob/main/docs/PRD.md):
  the normative contract, what the package must do.
- [docs/decisions.md](https://gitlab.com/bart-turczynski/pslr/-/blob/main/docs/decisions.md):
  the rationale log for the load-bearing choices.

## Repository layout

- `R/`: package source. Edit the roxygen comments here, not `man/` or
  `NAMESPACE`.
- `src/`: the `cpp11` matcher core.
- `man/`: generated help pages (`devtools::document()`).
- `tests/testthat/`: testthat tests.
- `vignettes/`: long-form documentation.
- `data-raw/`: the deterministic snapshot regeneration pipeline.
- `bench/`: the performance benchmark, kept out of the package build.
- `docs/`: durable project context, the documents listed above plus
  `benchmarks.md`.
