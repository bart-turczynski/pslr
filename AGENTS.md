# pslr

R package implementing the Public Suffix List: eTLD and eTLD+1 queries against a
pinned, bundled snapshot.

`man/`, `NAMESPACE`, `R/cpp11.R` and the cpp11 glue in `src/` are generated. Edit
roxygen comments in `R/`, then `devtools::document()`; after a changed
`[[cpp11::register]]` signature, `cpp11::cpp_register()`.

`docs/` is committed source, not a pkgdown build — `_pkgdown.yml` sets
`destination: site`.

`NEWS.md` gets one terse line per change a package user acts on or notices:
behavior, API, dependencies, R or system requirements, installation. Where a standard decides
it, cite the clause in a few words; the reasoning goes in the issue. At most one
issue or MR reference, at the end. No housekeeping bullets (CI, gates, lint,
repository metadata such as `codemeta.json`, `CITATION.cff` and keywords,
agent files) and no Internal section. The `news-terse` hook enforces
this rule at push.

Scratch and planning notes live in `_scratch/`. Never commit `_scratch/` or
`.fp/`.

Git follows the house `agent-workflow` skill. fp status changes stay decoupled
from git (the `fp` skill's `references/decoupling.md`).

`backup` is a local mirror, which fleet-ci's gate skips (a path URL), so neither
the owner nor an agent passes `--no-verify` to push it. Every other remote is
gated, and the gate refuses a push carrying more than one ref to `main` or
adding more than one first-parent merge to it: push one merge at a time.

## Verification

Gate: local
Verify: .fleet-ci/gate auto

The merge gate is fleet-ci's local gate, run in the fleet image (`fleet-r-idn2`) by the pre-push hook; install it once per clone with `.fleet-ci/pre-push --install`, and its settings are `.fleet-ci.yml`. A diff against `main` the classifier calls docs-only (`docs/**/*.md`, `design/**/*.md`, `_pkgdown.yml`) gets T0, spelling and `pkgdown::check_pkgdown()`; any other gets T1: punycoder rebuilt with libidn2, docs drift, lintr, README drift, the URL check, the NEWS/tag check, one `R CMD check` and the case-folding locale assertion.
Branch pushes, merge requests and pushes to `main` create no pipeline, so an empty pipeline list is not a pass. CI runs fleet-ci's template: T2 on the weekly `deep-check` schedule, T3 on a `RELEASE=1` web pipeline and on the `v*` tag (seor ADR 0012; docs/git-workflow.md).

For R style, tests, roxygen and new-function requirements, see
docs/r-conventions.md.
For the hooks, the tiers, the CI jobs, the gaps the fleet-ci migration accepted
and the tracker snapshot, see docs/git-workflow.md.
For the normative contract, see docs/PRD.md; the code map is
docs/architecture.md and the rationale log is docs/decisions.md.

## A red gate on an untouched tree

The gate runs in the fleet image, so this machine's R library cannot turn it
red. What can is this machine's toolchain writing files the gate then refuses:
a local `devtools::document()` under another roxygen2, or a README knit under
another pandoc. The `check-toolchain` pre-push hook (`scripts/check-toolchain.R`)
names that in one line: roxygen2's installed version against
`Config/roxygen2/version`, any installed package built under a newer R than the
one running, and the local pandoc against `.fleet-ci/toolchain` (SEOR-tcytizic).

If that check passes and the gate is still red on a tree you have not touched,
say so and keep the evidence rather than assuming your change caused it.
