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

Verification is fleet-ci's local gate, which runs in the fleet Docker image
(settings in `.fleet-ci.yml`), so it needs Docker, python3, Ruby and git, and
a `docker login registry.gitlab.com`. Install the hooks once per clone, from
the package root:

```sh
pre-commit install
.fleet-ci/pre-push --install
```

From then on the gate runs on every push, on each pushed ref's tip, followed
by the pre-commit pre-push hooks (the citation, BugReports, NEWS and toolchain
checks). `pre-commit install -f` (which installs both hook types, from
`.pre-commit-config.yaml`'s `default_install_hook_types`) and
`pre-commit install -f --hook-type pre-push` replace that hook and drop the
gate; re-run `.fleet-ci/pre-push --install` after either. Without `-f`,
`pre-commit install` keeps the gate (pre-commit's migration mode). To run the
gate by hand on `HEAD`:

```sh
.fleet-ci/gate auto
```

The gate checks the committed tree, never uncommitted edits. Its full tier
rebuilds punycoder with libidn2, then runs docs drift, lintr, spelling, README
drift, the URL check, the NEWS heading and tag check, one
`R CMD check --as-cran` and the case-folding locale assertion. See
[docs/git-workflow.md](docs/git-workflow.md) for every tier, the CI jobs and
the project settings they depend on.

Format R sources with [Air](https://posit-dev.github.io/air/) (`air format .`;
it also runs as a pre-commit hook), and don't reformat code unrelated to your
change. Details:
[docs/git-workflow.md](https://gitlab.com/bart-turczynski/pslr/-/blob/main/docs/git-workflow.md#formatting).

Edit roxygen comments in `R/`, never the generated `man/` or `NAMESPACE`; the
full repository layout is in [ARCHITECTURE.md](ARCHITECTURE.md#repository-layout).

The CRAN release deltas, including the bundled PSL snapshot procedure, are
in [`design/release-deltas.md`](https://gitlab.com/bart-turczynski/pslr/-/blob/main/design/release-deltas.md).

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.
