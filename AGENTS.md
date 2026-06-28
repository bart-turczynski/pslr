# Agent Instructions

Use committed docs for durable project knowledge. Keep raw planning notes, temporary context, and generated scratch work in `_scratch/`.

Do not commit `_scratch/`, `.fp/`, secrets, dependencies, build outputs, or local caches.

## R package conventions

Follow the tidyverse [style guide](https://style.tidyverse.org) and [design guide](https://design.tidyverse.org).

### Dev loop

- Load for interactive work: `devtools::load_all()` (or `pkgload::load_all()`).
- Run tests: `testthat::test_local(reporter = "check")`; a single file with `testthat::test_local(filter = "matcher")` (matches `test-matcher.R`).
- Regenerate docs: `devtools::document()` — rebuilds `man/` and `NAMESPACE` from the roxygen comments in `R/`.
- After changing any `[[cpp11::register]]` signature in `src/`, run `cpp11::cpp_register()` to regenerate `R/cpp11.R` and the C bindings.
- Verify gate (mirrors CI; the pre-push hook runs exactly this):

  ```sh
  Rscript -e 'lints <- lintr::lint_package(); if (length(lints)) { print(lints); quit(status = 1) }' \
    && Rscript -e 'rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")'
  ```

- When no R REPL is available, run snippets with `Rscript -e "..."`.

### Code style

- Base pipe `|>`, never magrittr `%>%`.
- `\(x) ...` for one-line anonymous functions; `function(x) { ... }` otherwise.
- `snake_case` for functions and arguments; explicit `pkg::fn()` prefixes.
- Layout is automated by Air (see [Formatting](#formatting)) — don't restyle code unrelated to your change, and don't modify deprecated functions.

### Tests

- testthat edition 3. `R/foo.R` is tested by `tests/testthat/test-foo.R`.
- Keep all code inside `test_that()` blocks; shared setup lives in `helper-*.R` / `setup-*.R`.
- Prefer specific expectations over `expect_true()` / `expect_false()`.
- Use `expect_snapshot()` for printed output and `expect_snapshot(error = TRUE)` for errors.
- Behavior specs are Cucumber `.feature` files under `tests/testthat/`, with steps in `setup-steps.R` run via `test-cucumber.R`; `R CMD check` exercises them.
- New code requires tests.

### Documentation

- Roxygen2 with markdown (`Roxygen: list(markdown = TRUE)`). `man/` and `NAMESPACE` are **generated — never edit them by hand**; edit the roxygen comments in `R/` and re-run `devtools::document()`.
- Every exported function needs a title, a `@param` per argument, `@return`, and runnable `@examples`. Internal helpers stay unexported and undocumented.
- Wrap roxygen comments at 80 columns; add new help topics to `_pkgdown.yml`.

### New functions

Ship each new user-facing function with: runnable examples, tests, full argument docs, `snake_case` arguments with sensible defaults, and argument validation. Where a `...` separates required from optional arguments, guard it against unexpected (e.g. misspelled) arguments.

### NEWS and generated files

- Add a `NEWS.md` bullet for every user-facing change — one line, no wrapping, with the issue/PR number in parentheses. Internal-only refactors go under an `## Internal` heading (see the existing entries) or are omitted.
- Never hand-edit generated files: `NAMESPACE`, anything under `man/`, or `R/cpp11.R` and the cpp11 glue in `src/`.

## Git hygiene

This project uses the [pre-commit](https://pre-commit.com) framework. Its config (`.pre-commit-config.yaml`) is cloned with the repo; each clone enables the hooks once:

```bash
pre-commit install && pre-commit install --hook-type pre-push
```

`pre-commit` is a Python tool. For non-Python templates, install it with `uv tool install pre-commit` or `pipx install pre-commit`.

### Per-commit checks

On every commit, lightweight hooks run: end-of-file fixer, trailing-whitespace trimming, merge-conflict detection, YAML/TOML validation, mixed-line-ending and case-conflict guards, and `check-added-large-files` — a portable 5 MB size guard that blocks accidentally committing heavy blobs (a big blob bloats `.git` history even after deletion).

### Formatting

R sources are formatted with [Air](https://posit-dev.github.io/air/) (`air.toml`),
which runs as a per-commit hook and auto-fixes layout. Air owns formatting; lintr
(in the verify gate) owns logic and best-practice lints. Don't reformat code
unrelated to your change.

### Pre-push verify gate

On `git push`, the `verify` hook runs the project's verify command — the same chain CI runs. Server-side branch protection is unavailable on this GitHub plan, so this local pre-push gate is the stand-in for branch protection: it blocks a push whose tree would turn CI red.

@FP_AGENTS.md
