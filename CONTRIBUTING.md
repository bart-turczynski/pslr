# Contributing

Install dependencies:

```sh
Rscript -e 'pak::local_install_deps(dependencies = TRUE)'
```

Run verification:

```sh
tools/verify.sh            # standard: lint + tests (the pre-push gate, ~2 min)
tools/verify.sh full       # + R CMD check --as-cran and the release audits
```

`tools/verify.sh` is the single definition of the gate — the pre-push hook and
the release checklist call it too, so running the underlying `lintr` and
`rcmdcheck` commands by hand checks less than a push does. See
[docs/git-workflow.md](docs/git-workflow.md#the-verify-gate) for all four tiers.

Format R sources with [Air](https://posit-dev.github.io/air/) (a fast,
R-free formatter; config in `air.toml`):

```sh
air format .
```

Air runs automatically as a pre-commit hook, so you rarely need to invoke it by
hand. Air owns layout; lintr (in the verify gate above) owns logic and
best-practice lints. Don't reformat code unrelated to your change.

R sources live in `R/`, compiled sources in `src/`, tests and their Cucumber `.feature` specs in `tests/testthat/`, and durable project context in `docs/`.

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.

## Release process

### Bundled PSL snapshot

The bundled Public Suffix List snapshot (`inst/extdata/public_suffix_list.dat`,
`R/sysdata.rda`, `inst/NOTICE`, and the conformance vectors in
`tests/testthat/fixtures/psl-vectors.txt`) must be regenerated before any
release that should ship a current list. This is a deliberate, maintainer-gated
step — do NOT automate it as a silent commit or CI job (CRAN/package policy
forbids network access at build/check time).

Run from the package root in a network-enabled maintainer environment:

```sh
Rscript data-raw/update_psl.R [<new-40-char-commit-sha>]
```

Omit the SHA to re-pin the same upstream commit (idempotent check); supply a
new 40-character SHA to advance the snapshot to a later upstream commit.

After running the script, complete these steps before committing:

1. **Review the upstream diff.** A bundled-data change alters query results and
   is release-shaped — it must land as a new package version, not a silent
   commit. Inspect `git diff inst/extdata/public_suffix_list.dat`.
2. **Run `R CMD check --as-cran` in full.** The conformance vectors in
   `tests/testthat/fixtures/psl-vectors.txt` are re-pinned in lockstep; they
   must stay green.
3. **Add a NEWS.md entry** recording the new `list_date`, `commit`, and
   `checksum` from `psl_version()`.
4. **Commit the regenerated artifacts** (`inst/extdata/`, `inst/NOTICE`,
   `R/sysdata.rda`, `tests/testthat/fixtures/psl-vectors.txt`) as part of the
   release commit.

#### Knowing when upstream has moved

The checklist above is the release procedure and stays manual. What it does not
tell you is *when* it needs running — staleness used to surface only if someone
remembered to look.

The `psl-upstream-check` job in `.gitlab-ci.yml` is the discovery mechanism for
that, and a discovery mechanism only — it does not replace any step above. On a
weekly schedule (and on demand), it compares the latest upstream commit touching
`public_suffix_list.dat` against `default_commit` in `data-raw/update_psl.R`. If
they match it is a no-op. If they differ it runs `data-raw/update_psl.R` on a
network-enabled runner, advances the pin, and **opens a merge request** with the
regenerated artifacts and a summary of what changed (commit range, `list_date`,
`checksum`, rule counts, normalization identity).

It never commits to `main`, never merges, and never touches `NEWS.md` or the
package version — steps 1 to 3 above are still yours to do on that MR. It is
deliberately separate from the `check` and `full-check` jobs, which must stay
network-free per CRAN policy, and it shells out to `data-raw/update_psl.R`
rather than reimplementing regeneration, so the two paths cannot drift.

The schedule that fires it is a project-level object in GitLab, not a line in
`.gitlab-ci.yml`: it must exist under Settings > CI/CD > Schedules with
`SCHEDULED_TASK=psl-upstream`, and the job needs a `PSL_BOT_TOKEN` project
access token to push a branch and open the MR. Without both, upstream movement
goes unnoticed exactly as it did before this mechanism existed.

One review point specific to the automated MR: the regenerated index records
whichever normalizer the runner resolved, reported as `normalizer_version` in
the MR body. While the temporary `punycoder` `Remotes:` pin is in place that
will be a development version, which must not ship to CRAN.

`data-raw/psl_snapshot_meta.R` prints a snapshot's provenance as `KEY=VALUE`
lines straight from `R/sysdata.rda`. The job uses it to build that summary,
and it is useful by hand for the same reason:

```sh
Rscript data-raw/psl_snapshot_meta.R
```
