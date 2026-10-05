# Contributing

Report bugs and request features in the GitLab issue tracker:
<https://gitlab.com/bart-turczynski/pslr/-/work_items>. Report security issues
privately as described in `SECURITY.md`. Send changes as merge requests on
GitLab; the GitHub repository is a read-only mirror.

New code needs tests, and each user-facing change needs one `NEWS.md` bullet.
A merge request must pass the verification command below.

Install dependencies:

```sh
Rscript -e 'pak::local_install_deps(dependencies = TRUE)'
```

Run verification:

```sh
tools/verify.sh            # standard: lint + spelling + URLs + tests (the pre-push gate, ~2 min)
tools/verify.sh tests      # the test stage alone, exactly as standard runs it
tools/verify.sh full       # + R CMD check --as-cran and the release audits
```

`tools/verify.sh` is the single definition of the gate — the pre-push hook and
the release checklist call it too, so running the underlying `lintr` and
`rcmdcheck` commands by hand checks less than a push does. See
[docs/git-workflow.md](docs/git-workflow.md#the-verify-gate) for every tier.

The test suite is plain testthat, run by `R CMD check`. A performance benchmark
and its release gate, kept out of CRAN, live in
[`bench/benchmark.R`](bench/benchmark.R); the recorded reference results are in
[`docs/benchmarks.md`](docs/benchmarks.md).

Format R sources with [Air](https://posit-dev.github.io/air/) (a fast,
R-free formatter; config in `air.toml`):

```sh
air format .
```

Air runs automatically as a pre-commit hook, so you rarely need to invoke it by
hand. Air owns layout; lintr (in the verify gate above) owns logic and
best-practice lints. Don't reformat code unrelated to your change.

Edit roxygen comments in `R/`, never the generated `man/` or `NAMESPACE`; the
full repository layout is in [ARCHITECTURE.md](ARCHITECTURE.md#repository-layout).

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.

## Release process

Follow the fleet checklist,
[seor `design/release-checklist.md`](https://gitlab.com/bart-turczynski/seor/-/blob/main/design/release-checklist.md).
pslr's deltas:

- **Step 3: refresh the bundled PSL snapshot first.** Before any release
  that should ship a current list, regenerate the snapshot, review it, and
  commit the regenerated artifacts in the release-prep commit, with a
  `NEWS.md` entry recording its provenance. The procedure is
  [Bundled PSL snapshot](#bundled-psl-snapshot) below.
- **Step 5: `tools/verify.sh cran` is the local pre-submission run.** It
  runs the `full`, `matrix` and `sanitize` tiers plus the remote incoming
  checks, and `sanitize` is the only place the C++ matcher gets ASAN, UBSAN
  and valgrind. The hosted counterpart is
  `glab ci run --branch main --variables CRAN_PREP:1` (agent+go), which also
  runs `psl-upstream-check`. See
  [docs/git-workflow.md](docs/git-workflow.md#the-verify-gate).
  Also run the suite against the current CRAN punycoder built from source
  with libidn2 (`pkg-config` finds it, as on CRAN's Debian flavors).
  The Unicode output path (`decode_ascii_pool()` in `R/query.R`) calls
  `punycoder::puny_decode()`, which tries libidn2 first when punycoder was
  built with it, and that build can decode differently:
  rurl 3.1.0's first upload failed CRAN's Debian pre-test on such a
  difference (SEOR-hxxxkmws).
- **Step 14: the concept DOI is `10.5281/zenodo.20973660`.** Its
  `<concept-recid>` in the Zenodo API query is `20973660`. Create the GitHub
  Release with `--title "pslr <version>" --notes-file <notes>`. Two older
  records read `1.0.2`: v1.1.0 and v1.1.1 deposited under the previous
  version before the citation gate (`scripts/check-citation.py`) existed.
  The step stays manual by decision: automating it from the GitLab tag
  pipeline would need a second GitHub credential with Contents write, and
  the push mirror is meant to be the only writer to GitHub.

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

The steps above are the snapshot procedure and stay manual. What it does not
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
the MR body. It should equal the `punycoder` floor in `DESCRIPTION`'s
`Imports:`, which `test-profile-rebuild.R` also checks. A different version,
such as a development build, means the index must be regenerated before it
ships to CRAN.

`data-raw/psl_snapshot_meta.R` prints a snapshot's provenance as `KEY=VALUE`
lines straight from `R/sysdata.rda`. The job uses it to build that summary,
and it is useful by hand for the same reason:

```sh
Rscript data-raw/psl_snapshot_meta.R
```
