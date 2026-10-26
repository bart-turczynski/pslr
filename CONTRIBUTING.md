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
tools/verify.sh            # standard: lint + docs drift + spelling + URLs + tests (the pre-push gate, ~2 min)
tools/verify.sh tests      # the test stage alone, exactly as standard runs it
tools/verify.sh docs       # the docs-drift stage alone, exactly as standard runs it
tools/verify.sh full       # + R CMD check --as-cran and the release audits
```

`tools/verify.sh` is the single definition of the gate — the pre-push hook and
the release checklist call it too, so running the underlying `lintr` and
`rcmdcheck` commands by hand checks less than a push does. See
[docs/git-workflow.md](docs/git-workflow.md#the-verify-gate) for every tier.

Format R sources with [Air](https://posit-dev.github.io/air/) (`air format .`;
it also runs as a pre-commit hook), and don't reformat code unrelated to your
change. Details:
[docs/git-workflow.md](https://gitlab.com/bart-turczynski/pslr/-/blob/main/docs/git-workflow.md#formatting).

Edit roxygen comments in `R/`, never the generated `man/` or `NAMESPACE`; the
full repository layout is in [ARCHITECTURE.md](ARCHITECTURE.md#repository-layout).

The CRAN release deltas, including the bundled PSL snapshot procedure, are
in [`design/release-deltas.md`](https://gitlab.com/bart-turczynski/pslr/-/blob/main/design/release-deltas.md).

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.
