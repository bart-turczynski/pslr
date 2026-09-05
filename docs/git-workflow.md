# Git workflow and the verify gate

Hooks, the verify tiers, and the one piece of project state that git does not
carry on its own. For how to write the code these gates check, see
[r-conventions.md](./r-conventions.md).

## Hooks

This project uses the [pre-commit](https://pre-commit.com) framework. Its config
(`.pre-commit-config.yaml`) is cloned with the repo; each clone enables the hooks
once:

```bash
pre-commit install && pre-commit install --hook-type pre-push
```

`pre-commit` is a Python tool. For non-Python templates, install it with
`uv tool install pre-commit` or `pipx install pre-commit`.

### Per-commit checks

On every commit, lightweight hooks run: end-of-file fixer, trailing-whitespace
trimming, merge-conflict detection, YAML validation, mixed-line-ending and
case-conflict guards, and `check-added-large-files` — a portable 5 MB size guard
that blocks accidentally committing heavy blobs (a big blob bloats `.git` history
even after deletion).

### Formatting

R sources are formatted with [Air](https://posit-dev.github.io/air/)
(`air.toml`), which runs as a per-commit hook and auto-fixes layout. Air owns
formatting; lintr (in the verify gate) owns logic and best-practice lints. Don't
reformat code unrelated to your change.

## The verify gate

`tools/verify.sh` is the single definition of the gate. The pre-push hook, the
dev loop and the release checklist all call it rather than restating the command:

```sh
tools/verify.sh            # standard: lint + tests (the pre-push gate, ~2 min)
tools/verify.sh full       # + R CMD check --as-cran, NEWS/version, README, coverage, audits, PSL
tools/verify.sh matrix     # R 4.5 / 4.6 / devel via Docker
tools/verify.sh sanitize   # the suite over src/ under ASAN+UBSAN, then valgrind
tools/verify.sh cran       # full + matrix + sanitize + remote incoming; pre-submission
```

`R CMD check --as-cran` sits in `full`, not `standard`, on purpose: at ~5 minutes
it made the pre-push hook something to be skipped rather than run, and a gate
that is habitually bypassed protects nothing.

### The sanitize tier

`sanitize` is the dynamic analysis of the C++ matcher that
`.github/workflows/rhub.yaml` used to provide. R-hub could not be ported: rhub v2
dispatches to the maintainer's own GitHub Actions runners and needs a GitHub
repository, which the account suspension removed. It runs two Docker legs, each
building the package from a copy of the tree so instrumented objects never reach
the working directory:

1. **ASAN + UBSAN.** `-fsanitize=address,undefined` with
   `-fno-sanitize-recover=all`, so undefined behaviour aborts instead of printing
   a line the exit status ignores. `detect_leaks=0` — R itself is not
   instrumented, so leak detection here would report R's allocations, not the
   package's.
2. **valgrind memcheck**, from a separate uninstrumented build, since valgrind
   cannot run ASAN-instrumented code. The gate is invalid reads and writes;
   `--errors-for-leak-kinds=none` keeps R's own un-freed allocations from failing
   the leg on every run, and the leak summary is left for a human to read.

   Baseline for reading that summary: the full suite reports on the order of 25 kB
   "definitely lost", and none of it is the package's. Re-running restricted to
   the test files that exercise the matcher (`matcher|query|extract|parser|engine`)
   reports 0 bytes in 0 blocks. If a future run shows definite loss under that
   filter, it is the package's and worth chasing.

The legs build with the host's toolchain rather than the
`ghcr.io/r-hub/containers/*` images, which are published amd64-only and would run
under emulation on an arm64 host — the wrong architecture on which to be testing
pointer arithmetic.

### Pre-push

On `git push`, the `verify` hook runs `tools/verify.sh standard` — lint plus the
test suite, about two minutes — and then prints a staleness line for the `full`
tier.

This hook is no longer a mirror of CI — it **is** the everyday gate. GitLab
runner minutes are a paid resource, so no hosted pipeline is created by a branch
push, a merge request, a tag or a schedule; nothing checks a push server-side.
Everything CI used to do weekly is in `tools/verify.sh full`, run locally.

The staleness line is deliberately non-blocking. A hook that refused a push until
a fifteen-minute check had run would be met with `--no-verify` within a
fortnight, and then neither tier would run.

### Keeping the full tier from going stale

At the start of a session in this repository, run `tools/verify.sh --staleness`.
It prints one line beginning `FRESH`, `STALE` or `NEVER`, and always exits 0. If
it reports `STALE` or `NEVER`, say so and offer to run `tools/verify.sh full` —
don't start it unasked, it takes about fifteen minutes.

Key the decision on that command's output, never on the calendar. A rule like
"run it on Saturdays" fires repeatedly on a working Saturday and never at all in
a week you don't open the repo; elapsed time since the last successful run is the
thing that actually matters.

## The remote pipeline

There are two pipelines and they answer different questions.

**Local** — `tools/verify.sh`, described above. It runs on every push, it is the
only place the `sanitize` tier (clang-ASAN, UBSAN, valgrind over `src/`) exists,
and it is the only leg that can check macOS behaviour, because that is the
machine it runs on.

**Remote** — `.gitlab-ci.yml`, and it assembles only when asked by name:

```sh
glab ci run --branch main --variables CRAN_PREP:1     # the pre-submission gate
glab ci run --branch main --variables DEPLOY_PAGES:1  # republish the docs site
```

A run with neither variable creates no pipeline at all; GitLab reports it as
filtered out by workflow rules, and the fix is to pass the variable.

`CRAN_PREP=1` runs lint, the NEWS/version guard, `R CMD check --as-cran`, the
README drift check, coverage, the R 4.5 / 4.6 / devel matrix, and the OSV, OSS
Index and upstream-PSL audits. Its value is not that it repeats the local check —
it is that it repeats it *somewhere else*: three R versions, a dependency
closure resolved from scratch, and a machine where your `~/.Renviron` does not
exist. That last one catches a check that only passes because of something
installed locally.

`security-audit` and `psl-upstream-check` are advisory (`allow_failure: true`)
because they depend on credentials that may be absent; `codemeta` is manual
because it commits back to `main`. None of the three are set as CI/CD variables
on the project today, so expect them loud on the first hosted run. Locally the
OSS Index pair is read from `~/.Renviron` instead — see
[the verify gate](#the-verify-gate) — so the same audit that skips in CI runs
for real on this machine.

What the remote leg cannot give you: no macOS, no Windows — GitLab.com shared
runners are Linux-only — and no sanitizers. Cross-platform assurance before a
submission comes from `devtools::check_win_devel()` and
`devtools::check_mac_release()`, and dynamic analysis from `tools/verify.sh
sanitize`. Neither leg is a superset of the other, which is why both exist.

### Running the hosted pipeline with no compute minutes

The namespace is on the free plan and exhausted its monthly compute minutes on
2026-08-07, after which every job on a shared runner failed immediately with
`ci_quota_exceeded`. That is the spend the two named pipelines exist to ration,
but rationing does not help when the quota is already gone and you need a
CRAN-prep run today.

The way out is a **project runner**, which is not subject to the namespace quota
block at all — established by running the full thirteen-job pipeline on one
while the quota was exhausted, not from the documentation. `pslr` has one
registered: `54981995`, `pslr-local-docker`, Docker executor,
`pull_policy = if-not-present`, configured in `~/.gitlab-runner/config.toml` and
started at login by brew services. So `glab ci run --branch main --variables
CRAN_PREP:1` works whether or not the namespace has minutes left; it simply runs
on this machine.

Two things to know before doing that. It is single-concurrency, so the jobs run
one after another rather than in parallel — a full CRAN-prep run is long. And
`pages` declares `needs: []`, so it starts without waiting for the check stage;
if the site is all you want, `DEPLOY_PAGES=1` is the pipeline to raise rather
than starting `CRAN_PREP=1` and cancelling the rest.

Running the pipeline locally used to need one more step, and no longer does.
`.gitlab-ci.yml` hardcoded pandoc's `.deb` as `-amd64`, which is correct on
GitLab.com's x86_64 fleet and fatal here: Docker on Apple Silicon resolves
`rocker/r-ver` to arm64, the Docker executor cannot request a platform, and
`dpkg -i` then killed every job that needed pandoc. The workaround was to pin
each `rocker/r-ver` tag to its amd64 digest by hand before every run. The
architecture is derived from `dpkg --print-architecture` now (PSLR-wcjcywea), so
there is nothing to pin — but it is worth knowing that this is the class of
bug a local runner exposes and the hosted fleet hides.

### If a hook is killed, unstaged changes can disappear

pre-commit stashes unstaged changes to
`~/.cache/pre-commit/patch<timestamp>-<pid>` before running a hook and restores
them when it finishes. A hook that *fails* still reaches the restore step; a hook
that is **killed** does not, and the working tree silently loses those changes.

This is the expected case here rather than a rare one: the standard tier takes
about two minutes, which is exactly where some interactive runners cap. Before
concluding the work is gone, look in `~/.cache/pre-commit/` for the orphaned
patch and restore it with `git apply`.

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
none, because it looks current. Push to `backup` with `--no-verify`: a mirror
must capture whatever state exists, including a red one.
