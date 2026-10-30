# Git workflow and the verify gate

Hooks, the verify tiers, CI, and the one piece of project state that git does
not carry on its own. For how to write the code these gates check, see
[r-conventions.md](./r-conventions.md).

pslr runs fleet-ci's tiered CI (seor ADR 0012). `.gitlab-ci.yml` includes
fleet-ci's `templates/r-package.yml`, pinned by commit SHA, and sets only
package variables plus three `x-*` jobs; `.fleet-ci.yml` holds the local
gate's settings, and `.fleet-ci/` is fleet-ci's vendored gate (re-run
fleet-ci's `bin/vendor`, never edit it). The job names below are the
template's.

## The tiers

| Tier | Where | What runs |
| --- | --- | --- |
| hygiene hooks | pre-commit, at commit and at push | `.pre-commit-config.yaml`. At commit and again at push: the hygiene fixers (end of file, trailing whitespace, line endings), the large-file, merge-conflict, YAML, TOML and case-conflict checks, Air and codespell. At push only: the citation, BugReports, NEWS and toolchain checks, the `check-citation.py`, `check-bugreports.py`, `check-news.py` and `bestpractices-url.py` self-tests when those scripts change, and the warn-only `fleet-ci-hook-installed` check |
| T0 | every push whose diff against `main` is docs-only (`docs/**/*.md`, `design/**/*.md`, `_pkgdown.yml`), locally, the pre-push hook | the gate's docs tier, `.fleet-ci/gate` in the fleet image (`fleet-r-idn2`): spelling and `pkgdown::check_pkgdown()` |
| T1 | every other push, locally, the pre-push hook | the gate's full tier: T0's checks, then on the host the NEWS heading and tag check (`scripts/check-news-version.sh`), and in the image punycoder rebuilt from source with libidn2 and asserted (`scripts/punycoder-backend.R`), docs drift (`scripts/check-docs-drift.R`), lintr, README drift (`scripts/check-readme-drift.sh`), the URL check (`tools/check-urls.R`), one `R CMD check --as-cran` (`NOT_CRAN=true`, incoming checks off) against the rebuilt punycoder, and one more check under `LC_ALL=C.UTF-8` followed by the case-folding locale assertion (`scripts/check-locale-legs.R`). Before docs drift, what `cpp11::cpp_register()` needs (decor) goes into the run library (`scripts/cpp-register-needs.R`) |
| T2 | the weekly `deep-check` schedule; every T3 run | `t2-check-release`, `t2-check-oldrel`, `t2-check-devel`, `t2-floor` (R 4.1.3), `t2-sanitizers` (R-hub clang-ASAN/UBSAN), `t2-locale` (the case-folding locales, a `LC_ALL=C.UTF-8` check and the assertion), `t2-ascran` (incoming on, its remote half off), `coverage` (fails below 95%), `osv-audit`, `security-audit`, `citation-version`, and pslr's `x-check-idn2` (punycoder rebuilt with libidn2, asserted) and `x-sanitizers-gcc` (gcc ASAN/UBSAN, natively on arm64) |
| T3 | a `RELEASE=1` web pipeline on `main`; a `v*` tag | all of T2 plus `t3-manual` (the PDF manual) and pslr's `x-psl-upstream-check` (allowed to fail); the tag, or `RELEASE=1` on a tag, adds `pages` |

Pushes to `main` or a branch, merge requests and API pipelines (`glab ci run`)
create no pipeline at all. An empty pipeline list is not a pass: the merge
gate is the local gate (T0 or T1), run before the branch leaves the machine.

Before a CRAN submission, start T3 on `main` from **Build > Pipelines > Run
pipeline**, ref `main`, variable `RELEASE=1` (see
[`design/release-deltas.md`](../design/release-deltas.md)). `PAGES=1` on a
`v*` tag runs `pages` alone.

## Hooks

This project uses the [pre-commit](https://pre-commit.com) framework. Its config
(`.pre-commit-config.yaml`) is cloned with the repo. `pre-commit` is a Python
tool: `uv tool install pre-commit` or `pipx install pre-commit`. Each clone
installs the hooks once, from the package root:

```bash
pre-commit install
.fleet-ci/pre-push --install
```

`pre-commit install` writes both hook types (`default_install_hook_types`);
`.fleet-ci/pre-push --install` then replaces the pre-push one with fleet-ci's,
which runs the gate on each pushed ref's tip and then the pre-commit pre-push
stage. Two commands drop it: `pre-commit install -f`, and
`pre-commit install -f --hook-type pre-push`; re-run the install after either.
Without `-f`, `pre-commit install` (with or without `--hook-type pre-push`)
moves the hook to `hooks/pre-push.legacy` (pre-commit's migration mode), which
still runs the gate first; `-f --hook-type pre-commit` leaves it alone.
`.fleet-ci/gate auto` (or `tools/verify.sh`, a thin wrapper that also keeps
the local-only `sanitize` and `psl-upstream` checks) runs the gate by hand on
`HEAD`.
A pass is stamped by tree, tier, classifier version, image and (full tier)
resolved dependency lock, and a stamped commit is skipped.

The gate refuses a push carrying more than one ref to `main` or adding more
than one first-parent merge to it. It skips a push to a local mirror: when the
push URL is local by git's rule (a path, as `backup`'s is) it prints
`gate: skipped, <remote> is a local mirror` and exits 0, so pushing `backup`
needs no `--no-verify`.

### Formatting

R sources are formatted with [Air](https://posit-dev.github.io/air/)
(`air.toml`), which runs as a per-commit hook and auto-fixes layout. Air owns
formatting; lintr (in the gate) owns logic and best-practice lints. Don't
reformat code unrelated to your change. The linter set and its deviations are in
[r-conventions.md](./r-conventions.md#the-linter-set).

### The docs-drift gate

`man/` and `NAMESPACE` are generated, and a stale `.Rd` is still valid `.Rd`, so
lint, spelling and `R CMD check` all pass it. The logo sweep added
`man/figures/logo.svg` without re-running `devtools::document()`, and
`man/pslr-package.Rd` stayed stale until it was fixed by hand (SEOR-nwfmerhu).
`scripts/check-docs-drift.R`, seor's copy, regenerates both with roxygen2 and
fails, printing the diff, when they or `DESCRIPTION` (whose `Collate` roxygen2
writes from `@include` tags) differ from what is committed. It is a T1 cheap
gate, so it runs on the gate's export of the pushed commit, never the working
tree, under the roxygen2 the fleet image pins. Its roxygen2 run compiles
`src/` and runs `cpp11::cpp_register()`, which rewrites `R/cpp11.R` and
`src/cpp11.cpp` in the export, so the gate runs it through
`scripts/check-docs-drift-glue.sh`, which also fails when either differs
from the committed copy. Run against a working tree
(`Rscript scripts/check-docs-drift.R`), it leaves the regenerated files in
place, so the fix only needs committing; it refuses to run when the installed
roxygen2 differs from `Config/roxygen2/version`, which the `check-toolchain`
hook names first.

### The sanitize tier

`tools/verify.sh sanitize` is the dynamic analysis of the C++ matcher that
`.github/workflows/rhub.yaml` used to provide. R-hub could not be ported: rhub v2
dispatches to the maintainer's own GitHub Actions runners and needs a GitHub
repository, which the account suspension removed. It runs two Docker legs, each
building the package from a copy of the tree so instrumented objects never reach
the working directory:

1. **ASAN + UBSAN.** `-fsanitize=address,undefined` with
   `-fno-sanitize-recover=all`, so undefined behavior aborts instead of printing
   a line the exit status ignores. `detect_leaks=0` — R itself is not
   instrumented, so leak detection here would report R's allocations, not the
   package's. T2 runs the same leg as `x-sanitizers-gcc`, and the template's
   `t2-sanitizers` runs R-hub's clang-asan container besides.
2. **valgrind memcheck**, from a separate uninstrumented build, since valgrind
   cannot run ASAN-instrumented code. The gate is invalid reads and writes;
   `--errors-for-leak-kinds=none` keeps R's own un-freed allocations from failing
   the leg on every run, and the leak summary is left for a human to read. It
   runs only here, not in CI.

   Baseline for reading that summary: the full suite reports on the order of 25 kB
   "definitely lost", and none of it is the package's. Re-running restricted to
   the test files that exercise the matcher (`matcher|query|extract|parser|engine`)
   reports 0 bytes in 0 blocks. If a future run shows definite loss under that
   filter, it is the package's and worth chasing.

The legs build with the host's toolchain rather than the
`ghcr.io/r-hub/containers/*` images, which are published amd64-only and would run
under emulation on an arm64 host — the wrong architecture on which to be testing
pointer arithmetic.

### If a hook is killed, unstaged changes can disappear

pre-commit stashes unstaged changes to
`~/.cache/pre-commit/patch<timestamp>-<pid>` before running a hook and restores
them when it finishes. A hook that *fails* still reaches the restore step; a hook
that is **killed** does not, and the working tree silently loses those changes.
Before concluding the work is gone, look in `~/.cache/pre-commit/` for the
orphaned patch and restore it with `git apply`.

## Project settings CI depends on, which are not in this repository

These live in GitLab's project settings, so a clone does not carry them:

- **Pipeline schedule 4472812** (Build > Pipeline schedules), "Weekly deep
  check (fleet standard)", `0 22 * * 3` Europe/Warsaw on `main`, carrying
  `SCHEDULE_KIND=deep-check`. Required: it is T2's only unattended run, and
  every pipeline on `main` carries `coverage`, so the coverage badge reads it.
- **Pipeline schedule 4467477**, `SCHEDULE_KIND=dependency-audit`. The
  template starts no pipeline for it any more (the audits run in T2); its
  removal is owner-gated, seor SEOR-uldurjev.
- **`OSSINDEX_USER` / `OSSINDEX_TOKEN`** (Settings > CI/CD > Variables;
  `OSSINDEX_TOKEN` masked; the user is the literal `x`). `security-audit`
  sets `OSSINDEX_AUDIT_REQUIRED=true`, so without them it fails rather than
  passing having audited nothing.
- **`PSL_BOT_TOKEN`**, a project access token with `api` and
  `write_repository` scopes, for `x-psl-upstream-check`. It is not set, so the
  job reports red (it is allowed to fail).
- **The project runner** `pslr-local-docker` (`54981995`, Docker executor),
  which runs untagged jobs. While the Mac it runs on sleeps, jobs sit pending.
  The template's jobs carry no `tags:`, so the former
  `default: tags: [local-docker]` is gone. The tag existed to keep jobs off
  GitLab's shared runners (SEOR-hhtzaknn). Shared runners are disabled for
  pslr (project setting `shared_runners_enabled` false, read 2026-10-30), so
  an untagged job has only the project runner to land on. Enabling shared
  runners would send every job there.
- **Pages**: the site lives at `https://bart-turczynski.gitlab.io/pslr/`,
  which `_pkgdown.yml` and `DESCRIPTION` name. `pages` publishes pkgdown's
  `destination`, `site/` here (`docs/` is committed source), and only the
  top-level `.md` files on `.fleet-ci.yml`'s `pages_keep`.

Never set `SCHEDULE_KIND` as a project or group variable: every schedule would
inherit it.

## Gaps accepted in the fleet-ci migration

- **The template's release legs check the fallback build of punycoder.**
  `t2-check-release`, `t2-ascran` and `coverage` run on `fleet-r-idn2`
  (`FLEET_RELEASE_VARIANT`, which must equal `.fleet-ci.yml`'s `variant`),
  but they install punycoder as Posit Package Manager's binary, which is
  built without libidn2 (SEOR-vpihrxww), as do the oldrel, devel, floor,
  sanitizer and locale legs. Those legs are the fallback cell; nothing
  asserts their backend. The libidn2 cell is `x-check-idn2` in T2 and the
  local gate before every push: each rebuilds punycoder from source in
  `fleet-r-idn2` and asserts the libidn2 backend. The former CI had no
  libidn2 cell at all. Coverage measures the fallback build.
- **The case-folding locale legs run on one R version.** The former `.r-deps`
  setup built `tr_TR.UTF-8` and `az_AZ.UTF-8` in every job that installed the
  package, so `check`, `coverage`, every `full-check` leg (devel, 4.6, 4.5,
  4.1.3) and `sanitizers` ran `test-parser.R`'s legs, and `check` and each
  `full-check` leg asserted them. Now only `t2-locale` (the release image)
  and the local gate build them and run the assertion; `t2-check-release`,
  `t2-check-oldrel`, `t2-check-devel`, `t2-floor`, both sanitizer legs and
  `coverage` skip those legs.
- **The locale leg runs under `C.UTF-8`, not `C`** (`.fleet-ci.yml`'s
  `locale_legs`). Under `LC_ALL=C` the session charset is ASCII, R cannot
  translate `test-diff.R`'s UTF-8 literals, and two of its tests fail; R CMD
  check also warns that it cannot switch to `en_US.UTF-8` to parse the
  sources. The former CI never ran a `C` leg. The case-folding locales run
  inside `test-parser.R` whatever the leg.
- **No server-side cheap gates.** The former `lint`, `spelling`,
  `news-version`, `citation-version`, `readme` and `docs-drift` jobs ran on
  every push to `main`, which caught a web edit, a server-side merge and a
  `--no-verify` push. Those runs are gone; only the local gate and the
  pre-push hooks run them, and T2's `citation-version` runs
  `check-citation.py` alone. The `check-citation.py` and
  `check-bugreports.py` self-tests run as pre-push hooks when their script
  changes.
- **NOTEs from `R CMD check` don't fail the gate or any CI leg, as before:**
  `.fleet-ci.yml` sets no `allowed_notes`, because the former checks failed on
  ERRORs and WARNINGs only.
- **`test-security.R`'s offline allow-list tests are out of T1.**
  `exclude_tests` drops the whole file from the gate's check, so its two
  offline tests (the allow-list is well formed, the validator rejects
  non-decisions) run only in `security-audit` and the T2 check legs. The
  former `check` job ran them on every push to `main`. Moving them to a file
  of their own needs a `tests/` change, a follow-up.
- **`NOT_CRAN=true` in T1 and the T2 check legs.** The former `check` job ran
  `R CMD check` with `NOT_CRAN` unset and the former `tools/verify.sh
  standard` ran `test_local()` with it set; now one check, with
  `NOT_CRAN=true`, does both, so `test-profile-rebuild.R`'s `skip_on_cran()`
  test runs in the T2 check legs (T1 excludes the file, below). The T2
  check legs also run `test-osv.R` (OSV) and
  `test-security.R` (OSS Index) against the network; T1 excludes both
  (`.fleet-ci.yml`'s `exclude_tests`), and `osv-audit` and `security-audit`
  run them.
- **The live OSS Index audit runs in every `NOT_CRAN=true` job, not only in
  `security-audit`.** `OSSINDEX_USER` and `OSSINDEX_TOKEN` are project
  variables, and every pipeline on `main` (the schedule, `RELEASE=1`) and on
  a protected `v*` tag gets them in every job, protected or not. oysteR is in
  `Suggests`, so with `NOT_CRAN=true` `test-security.R`'s audit test finds
  the credentials and calls OSS Index in `t2-check-release`,
  `t2-check-oldrel`, `t2-check-devel`, `t2-locale`, `t2-sanitizers`,
  `t3-manual`, `x-check-idn2` and `x-sanitizers-gcc`. The former CI set
  `NOT_CRAN` in the two audit jobs only. An OSS Index outage, an HTTP 429, or
  the shutdown of the legacy endpoint oysteR calls (2026-12-31) turns all of
  them red, and on a `v*` tag that blocks `pages`. Scoping the credentials to
  the audit job is a fleet follow-up (seor SEOR-yrsmlrvp).
- **`test-profile-rebuild.R` runs in T2 only.** Its no-rebuild test skips
  unless the installed punycoder is the version the bundled index records,
  and the skip reason names both versions. The gate fails on any skip not in
  `allowed_skips`, which matches reasons exactly, so once CRAN ships a newer
  punycoder that skip would fail T1 on every unrelated branch, and no stable
  entry can list it. `.fleet-ci.yml`'s `exclude_tests` drops the whole file
  from T1, its four other tests with it; the T2 check legs run it, where
  the skip is acceptable. Narrowing this needs a `tests/` change, a
  follow-up.
- **`--as-cran` with incoming checks runs on release R only.** The former
  `full-check` ran `R CMD check --as-cran` (incoming on, its remote half off)
  under devel, 4.6, 4.5 and 4.1.3. Now only `t2-ascran` (release R) runs
  `--as-cran` with incoming on; `t2-check-oldrel` and `t2-check-devel` run a
  plain `R CMD check`, and `t2-floor` keeps `--as-cran` with incoming off. No
  `x-*` job runs `--as-cran`.
- **The floor leg is unproven.** `t2-floor` installs every dependency,
  `Suggests` included, from one dated snapshot (`FLEET_FLOOR_SNAPSHOT`,
  fleet-ci's p3m date, 2026-10-28), because `punycoder (>= 1.3.0)` is newer
  than any snapshot inside R 4.1's support window. The former `full-check`
  4.1.3 leg resolved current packages the same way. If the first T2 run
  shows a dependency that no longer supports R 4.1, move the date or record
  `FLEET_FLOOR: "false"` here with the reason.
- **No `CRAN_PREP` or `DEPLOY_PAGES` pipeline.** `RELEASE=1` on `main` is the
  pre-submission run, and `pages` deploys from a `v*` tag only (or `PAGES=1`
  on one), not on every push to `main`, so the site documents the release
  CRAN serves.
- **`x-psl-upstream-check` runs in every T3 pipeline**, a `v*` tag included,
  not only before a submission. It is idempotent (an existing branch for the
  upstream commit stops it) and allowed to fail. It works on the default
  branch's tip, which it fetches, not the pipeline's commit, so on a tag its
  branch still starts from the branch its merge request targets.
- **The upstream-PSL watcher runs only when asked.** The former
  `tools/verify.sh full` warned when upstream had moved; now
  `tools/verify.sh psl-upstream` does, by hand, and T3's
  `x-psl-upstream-check` before a release, so between releases nothing says
  the bundled snapshot is behind unless someone runs it.
- **The R-hub clang-asan leg runs emulated.** `t2-sanitizers` uses R-hub's
  amd64-only container, which the arm64 runner runs under emulation. The
  native gcc leg, `x-sanitizers-gcc`, is the former `sanitizers` job; valgrind
  stays local.
- **Comments in `tests/` still name the former jobs and tiers**
  (`test-security.R`); a CI migration does not edit `tests/`.
- **Pandoc** comes from the fleet image (`.fleet-ci/toolchain`, 3.10), which
  reproduces the committed `README.md`. `scripts/check-toolchain.R` checks a
  local pandoc against it, and `data-raw/update_psl.R` refuses to re-knit the
  README under another.

## The tracker is not in git unless it is snapshotted

`.fp/` is gitignored, so the issue tracker is a local database that no commit, no
clone and no bundle has ever contained — while `NEWS.md`, the design documents
under `docs/` and the test suite all cite `PSLR-*` ids as the reasoning behind
what they assert. Regenerate the one copy that is in git with:

```bash
sh data-raw/snapshot-tracker.sh
```

It writes [tracker-snapshot.md](./tracker-snapshot.md), beside the documents
whose citations it backs up. `docs/` is committed source here — pkgdown builds
into `site/` because `_pkgdown.yml` sets `destination: site` — so unlike a
package that publishes from `docs/`, the snapshot lands in a directory that
actually reaches a commit.

`fp` stays authoritative — nothing reads the snapshot back, `fp context <id>` is
still the way to read an issue, and **every run overwrites the file wholesale**,
so hand-edits to it are lost.

**Refresh it before taking any copy you intend to keep** — a mirror push to the
`backup` remote (`git remote -v` resolves it; it is a local path, so a fresh
clone has no such remote and must add one), or a `git bundle create <path>
--all`. A bundle taken without refreshing carries a stale copy of the only
tracker reasoning in git, and a snapshot that is never regenerated is worse than
none, because it looks current. A push to `backup` needs no `--no-verify`: the
gate skips a local mirror, so a mirror captures whatever state exists,
including a red one.
