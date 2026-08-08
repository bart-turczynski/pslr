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
- Verify gate — `tools/verify.sh`, which is the single definition of the gate. The pre-push hook, this dev loop and the release checklist all call it rather than restating the command:

  ```sh
  tools/verify.sh            # standard: lint + tests (the pre-push gate, ~2 min)
  tools/verify.sh full       # + R CMD check --as-cran, NEWS/version, README, coverage, audits, PSL
  tools/verify.sh matrix     # R 4.5 / 4.6 / devel via Docker
  tools/verify.sh cran       # full + matrix + remote incoming checks; pre-submission
  ```

  `R CMD check --as-cran` sits in `full`, not `standard`, on purpose: at ~5 minutes it made the pre-push hook something to be skipped rather than run, and a gate that is habitually bypassed protects nothing.

- When no R REPL is available, run snippets with `Rscript -e "..."`.

#### Keeping the full tier from going stale

**At the start of a session in this repository, run `tools/verify.sh --staleness`.** It prints one line beginning `FRESH`, `STALE` or `NEVER`, and always exits 0. If it reports `STALE` or `NEVER`, say so and offer to run `tools/verify.sh full` — don't start it unasked, it takes about fifteen minutes.

Key the decision on that command's output, never on the calendar. A rule like "run it on Saturdays" fires repeatedly on a working Saturday and never at all in a week you don't open the repo; elapsed time since the last successful run is the thing that actually matters.

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

On `git push`, the `verify` hook runs `tools/verify.sh standard` — lint plus the test suite, about two minutes — and then prints a staleness line for the `full` tier.

This hook is no longer a mirror of CI — it **is** the gate. GitLab runner minutes are a paid resource, so the hosted pipeline runs only on a `v*` tag and on manual trigger; nothing checks a branch push server-side. Everything CI used to do weekly is in `tools/verify.sh full`, run locally.

The staleness line is deliberately non-blocking. A hook that refused a push until a fifteen-minute check had run would be met with `--no-verify` within a fortnight, and then neither tier would run.

#### If a hook is killed, unstaged changes can disappear

pre-commit stashes unstaged changes to `~/.cache/pre-commit/patch<timestamp>-<pid>` before running a hook and restores them when it finishes. A hook that *fails* still reaches the restore step; a hook that is **killed** does not, and the working tree silently loses those changes.

This is the expected case here rather than a rare one: the standard tier takes about two minutes, which is exactly where some interactive runners cap. Before concluding the work is gone, look in `~/.cache/pre-commit/` for the orphaned patch and restore it with `git apply`.

### The tracker is not in git unless it is snapshotted

`.fp/` is gitignored, so the issue tracker is a local database that no commit, no clone and no bundle has ever contained — while `NEWS.md`, the design documents under `docs/` and the test suite all cite `PSLR-*` ids as the reasoning behind what they assert. Regenerate the one copy that is in git with:

```bash
sh data-raw/snapshot-tracker.sh
```

It writes `docs/tracker-snapshot.md`, beside the documents whose citations it backs up. `docs/` is committed source here — pkgdown builds into `site/` because `_pkgdown.yml` sets `destination: site` — so unlike a package that publishes from `docs/`, the snapshot lands in a directory that actually reaches a commit.

`fp` stays authoritative — nothing reads the snapshot back, `fp context <id>` is still the way to read an issue, and **every run overwrites the file wholesale**, so hand-edits to it are lost.

**Refresh it before taking any copy you intend to keep** — a mirror push to the `backup` remote at `~/Projects/_backups/pslr.git`, or a `git bundle create <path> --all`. Both exist for this repository as of 2026-08-01. A bundle taken without refreshing carries a stale copy of the only tracker reasoning in git, and a snapshot that is never regenerated is worse than none, because it looks current. Push to `backup` with `--no-verify`: a mirror must capture whatever state exists, including a red one.

@FP_AGENTS.md
