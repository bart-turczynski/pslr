# R package conventions

How to write, test and document code in `pslr`. For the workflow around a
change — hooks, the verify gate, the tracker snapshot — see
[git-workflow.md](./git-workflow.md); for what the package must do, see
[PRD.md](./PRD.md).

Follow the tidyverse [style guide](https://style.tidyverse.org) and
[design guide](https://design.tidyverse.org).

## Dev loop

- Load for interactive work: `devtools::load_all()` (or `pkgload::load_all()`).
- Run tests: `testthat::test_local(reporter = "check")`; a single file with
  `testthat::test_local(filter = "matcher")` (matches `test-matcher.R`).
- Regenerate docs: `devtools::document()` — rebuilds `man/` and `NAMESPACE` from
  the roxygen comments in `R/`.
- After changing any `[[cpp11::register]]` signature in `src/`, run
  `cpp11::cpp_register()` to regenerate `R/cpp11.R` and the C bindings.
- Verify gate — `tools/verify.sh`. See
  [git-workflow.md](./git-workflow.md#the-verify-gate) for the tiers and when
  each one runs.
- When no R REPL is available, run snippets with `Rscript -e "..."`.

## Code style

- Base pipe `|>`, never magrittr `%>%`.
- `\(x) ...` for one-line anonymous functions; `function(x) { ... }` otherwise.
  This shorthand is why `DESCRIPTION` declares `R (>= 4.1.0)` — a deliberate
  floor, not an accident (see [decisions.md](./decisions.md), D21).
- `snake_case` for functions and arguments; explicit `pkg::fn()` prefixes.
- Layout is automated by Air (see
  [git-workflow.md](./git-workflow.md#formatting)) — don't restyle code
  unrelated to your change, and don't modify deprecated functions.

## Tests

- testthat edition 3. `R/foo.R` is tested by `tests/testthat/test-foo.R`.
- Keep all code inside `test_that()` blocks; shared setup lives in `helper-*.R` /
  `setup-*.R`.
- Prefer specific expectations over `expect_true()` / `expect_false()`.
- Use `expect_snapshot()` for printed output and `expect_snapshot(error = TRUE)`
  for errors.
- Behavior specs are Cucumber `.feature` files under `tests/testthat/`, with
  steps in `setup-steps.R` run via `test-cucumber.R`; `R CMD check` exercises
  them.
- New code requires tests.

## Documentation

- Roxygen2 with markdown (`Roxygen: list(markdown = TRUE)`). `man/` and
  `NAMESPACE` are generated — never edit them by hand; edit the roxygen comments
  in `R/` and re-run `devtools::document()`.
- Every exported function needs a title, a `@param` per argument, `@return`, and
  runnable `@examples`. Internal helpers stay unexported and undocumented.
- Wrap roxygen comments at 80 columns; add new help topics to `_pkgdown.yml`.

## New functions

Ship each new user-facing function with: runnable examples, tests, full argument
docs, `snake_case` arguments with sensible defaults, and argument validation.
Where a `...` separates required from optional arguments, guard it against
unexpected (e.g. misspelled) arguments.

## NEWS and generated files

- Add a `NEWS.md` bullet for every user-facing change — one line, no wrapping,
  with the issue/PR number in parentheses. Internal-only refactors go under an
  `## Internal` heading (see the existing entries) or are omitted.
- Never hand-edit generated files: `NAMESPACE`, anything under `man/`, or
  `R/cpp11.R` and the cpp11 glue in `src/`.
