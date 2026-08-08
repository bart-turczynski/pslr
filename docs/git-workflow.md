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
tools/verify.sh cran       # full + matrix + remote incoming checks; pre-submission
```

`R CMD check --as-cran` sits in `full`, not `standard`, on purpose: at ~5 minutes
it made the pre-push hook something to be skipped rather than run, and a gate
that is habitually bypassed protects nothing.

### Pre-push

On `git push`, the `verify` hook runs `tools/verify.sh standard` — lint plus the
test suite, about two minutes — and then prints a staleness line for the `full`
tier.

This hook is no longer a mirror of CI — it **is** the gate. GitLab runner minutes
are a paid resource, so the hosted pipeline runs only on a `v*` tag and on manual
trigger; nothing checks a branch push server-side. Everything CI used to do
weekly is in `tools/verify.sh full`, run locally.

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
