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
