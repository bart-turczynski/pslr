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

## The linter set

`.lintr` is intentionally aligned with the linter set `goodpractice::gp()` runs
(`goodpractice:::linters_to_lint()`), so the local and CI `lintr::lint_package()`
gate surfaces the same findings as the goodpractice report reviewers run. Without
that alignment a package passes its own lint gate and then trips a pile of
goodpractice findings later. Regenerate the list after a goodpractice upgrade,
comparing against `names(goodpractice:::linters_to_lint())`.

**Keep `.lintr` free of `#` comments.** It is parsed with `read.dcf()`, which
only learned to skip comment lines in R 4.6. On R 4.5 and older a single comment
makes `lint_package()` abort with `Invalid DCF format`, so the rationale lives
here instead. Keep it ASCII too: a non-ASCII byte in `.lintr` comes back
`bytes`-encoded on older R and makes any config error surface as a confusing
`sprintf()` failure instead of the real message.

Documented deviations from the goodpractice set — test-idiom and public-API
reasons a real package hits as it grows:

- `object_name_linter` / `object_usage_linter`: not part of the goodpractice set
  and deliberately NOT added. The testthat helpers read as undefined globals
  to `object_usage_linter`, and packages commonly expose mixed-case or dotted
  public parameters plus `._`-prefixed internal helpers that
  `object_name_linter` would flag.
- `expect_identical_linter`: off. Suites routinely rely on `expect_equal()`'s
  numeric tolerance (`expect_equal(nrow(x), 2)` compares integer vs double) and
  its string-encoding normalization, both of which `identical()` rejects; a
  wholesale swap means retyping literals for no behavioral gain.
- `implicit_assignment_linter`: off. Tests use the standard
  `expect_warning(res <- f(), "msg")` idiom to capture both the warning and the
  return value (`expect_warning()` returns the condition, not the value).
- `library_require_linter`: off. `tests/testthat.R` and vignette setup chunks
  legitimately call `library()`.
- `undesirable_operator_linter`: configured to keep flagging `<<-`/`->>` but
  allow `:::`, which tests use to reach internal (unexported) functions.

`strings_as_factors_linter` is off, as in goodpractice, which dropped it in 1.2.0
(ropensci-review-tools/goodpractice#321). It only guarded the pre-R-4.0
`data.frame()` default, and this package Depends on R >= 4.1.0. The existing
`stringsAsFactors = FALSE` arguments stay; they are harmless here.

## Tests

- testthat edition 3. `R/foo.R` is tested by `tests/testthat/test-foo.R`.
- Keep all code inside `test_that()` blocks; shared setup lives in `helper-*.R` /
  `setup-*.R`.
- Prefer specific expectations over `expect_true()` / `expect_false()`.
- Use `expect_snapshot()` for printed output and `expect_snapshot(error = TRUE)`
  for errors.
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
