# Contributing

Install dependencies:

``` sh
Rscript -e 'pak::local_install_deps(dependencies = TRUE)'
```

Run verification:

``` sh
Rscript -e 'lints <- lintr::lint_package(); if (length(lints)) { print(lints); quit(status = 1) }' && Rscript -e 'rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")'
```

Format R sources with [Air](https://posit-dev.github.io/air/) (a fast,
R-free formatter; config in `air.toml`):

``` sh
air format .
```

Air runs automatically as a pre-commit hook, so you rarely need to
invoke it by hand. Air owns layout; lintr (in the verify gate above)
owns logic and best-practice lints. Don’t reformat code unrelated to
your change.

Source lives in `src/`, behavior features live in `features/`, tests
live in `tests/`, and durable project context lives in `docs/`.

Keep local-only planning state in `_scratch/`. Do not commit
`_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or
generated caches.

## Release process

### Bundled PSL snapshot

The bundled Public Suffix List snapshot
(`inst/extdata/public_suffix_list.dat`, `R/sysdata.rda`, `inst/NOTICE`,
and the conformance vectors in
`tests/testthat/fixtures/psl-vectors.txt`) must be regenerated before
any release that should ship a current list. This is a deliberate,
maintainer-gated step — do NOT automate it as a silent commit or CI job
(CRAN/package policy forbids network access at build/check time).

Run from the package root in a network-enabled maintainer environment:

``` sh
Rscript data-raw/update_psl.R [<new-40-char-commit-sha>]
```

Omit the SHA to re-pin the same upstream commit (idempotent check);
supply a new 40-character SHA to advance the snapshot to a later
upstream commit.

After running the script, complete these steps before committing:

1.  **Review the upstream diff.** A bundled-data change alters query
    results and is release-shaped — it must land as a new package
    version, not a silent commit. Inspect
    `git diff inst/extdata/public_suffix_list.dat`.
2.  **Run `R CMD check --as-cran` in full.** The conformance vectors in
    `tests/testthat/fixtures/psl-vectors.txt` are re-pinned in lockstep;
    they must stay green.
3.  **Add a NEWS.md entry** recording the new `list_date`, `commit`, and
    `checksum` from
    [`psl_version()`](https://bart-turczynski.github.io/pslr/reference/psl_version.md).
4.  **Commit the regenerated artifacts** (`inst/extdata/`,
    `inst/NOTICE`, `R/sysdata.rda`,
    `tests/testthat/fixtures/psl-vectors.txt`) as part of the release
    commit.
