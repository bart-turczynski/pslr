# Contributing

Development happens on [GitLab](https://gitlab.com/bart-turczynski/pslr):
open issues and merge requests there. The GitHub repository is a read-only
mirror, and pull requests opened on it are not reviewed.

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

Two mechanisms cover this, and neither replaces a step above. Locally,
`tools/verify.sh full` compares the pinned commit against upstream and reports
the difference; that is the one that runs often, and it is what first caught the
snapshot already being behind. Remotely, the `psl-upstream-check` job in
`.gitlab-ci.yml` goes further — it compares the latest upstream commit touching
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

There is no schedule firing it. Recurring hosted pipelines are the spend this
project cannot afford, so the job runs as part of the CRAN-prep pipeline
(`glab ci run --branch main --variables CRAN_PREP:1`) — the moment a stale
bundled snapshot most needs catching. It needs a `PSL_BOT_TOKEN` project access
token to push a branch and open the MR, and is marked `allow_failure: true` so
its absence reports loudly without vetoing the gate.

Between submissions, `tools/verify.sh full` is what tells you upstream has moved.
The accepted gap is that it only tells you when you run it: the list goes stale
because the world changed, not because this tree did, so a long absence from the
repository triggers no nudge at all.

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

### Archiving the release on Zenodo

Each release is archived on Zenodo under the concept DOI
[10.5281/zenodo.20973660](https://doi.org/10.5281/zenodo.20973660), which always
resolves to the newest version. The archive is **not** produced by the tag. It is
produced by a **GitHub Release** on the read-only mirror at
`github.com/bart-turczynski/pslr`, which fires a Zenodo webhook. A tag alone
deposits nothing.

This step stays **manual**, and deliberately so. Automating it from the GitLab
tag pipeline would need a second GitHub credential with Contents write, which is
exactly what the mirror policy forbids — the push mirror is the only thing
allowed to write to GitHub. Releases happen a few times a year; a job that runs
that rarely, holding a token that powerful, is a worse trade than one command.

After the tag is pushed to GitLab and the mirror has synced it:

1. **Check the tag reached GitHub with the same object id.** The mirror only
   carries protected tags, so a repository without a `v*` protected-tag rule
   never delivers release tags at all:

   ```sh
   git ls-remote --tags origin 'refs/tags/v*'
   git ls-remote --tags https://github.com/bart-turczynski/pslr.git 'refs/tags/v*'
   ```

2. **Create the release from that existing tag**, never letting GitHub create
   one. `--verify-tag` is what enforces that:

   ```sh
   gh release create v<version> -R bart-turczynski/pslr --verify-tag \
     --title "pslr <version>" --notes-file <notes>
   ```

3. **Confirm the deposit.** A new version should appear under the concept DOI,
   labeled with the version from `.zenodo.json`:

   ```sh
   curl -sSL -H 'Accept: application/json' \
     'https://zenodo.org/api/records?q=conceptrecid:20973660&all_versions=true'
   ```

   Zenodo takes `version` from the `.zenodo.json` in the tag's tarball, not from
   `DESCRIPTION` and not from the tag name. The citation gate
   (`scripts/check-citation.py`, pre-push and the `citation-version` CI job) is
   what keeps those in step — before it existed, v1.1.0 and v1.1.1 both deposited
   under the previous release's version number, which is why two Zenodo records
   read `1.0.2`.

4. **Record the new version DOI** in `CITATION.cff` under `identifiers`. The
   concept DOI and the README badge never change.

One quirk worth knowing: publishing a non-prerelease fires three `release`
webhook deliveries (`created`, `published`, `released`). Zenodo acts on one and
rejects the other two — a 500 and a 409 next to a 202 in the delivery log are
expected and do not mean the deposit failed. Judge it by step 3, not by the
delivery log.
