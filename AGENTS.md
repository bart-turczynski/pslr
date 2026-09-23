# pslr

R package implementing the Public Suffix List: eTLD and eTLD+1 queries against a
pinned, bundled snapshot.

`tools/verify.sh` is the single definition of the verify gate; the pre-push hook,
dev loop and release checklist all call it. Run `tools/verify.sh --staleness`
when a session starts — on `STALE` or `NEVER`, offer `tools/verify.sh full`
(~15 min) rather than starting it.

`man/`, `NAMESPACE`, `R/cpp11.R` and the cpp11 glue in `src/` are generated. Edit
roxygen comments in `R/`, then `devtools::document()`; after a changed
`[[cpp11::register]]` signature, `cpp11::cpp_register()`.

`docs/` is committed source, not a pkgdown build — `_pkgdown.yml` sets
`destination: site`.

Every user-facing change gets a one-line `NEWS.md` bullet with the issue id in
parentheses.

Scratch and planning notes live in `_scratch/`. Never commit `_scratch/` or
`.fp/`.

For R style, tests, roxygen and new-function requirements, see
docs/r-conventions.md.
For pre-commit, verify tiers and the tracker snapshot, see docs/git-workflow.md.
For the normative contract, see docs/PRD.md; the code map is
docs/architecture.md and the rationale log is docs/decisions.md.

## A red gate on an untouched tree

Toolchain drift makes the verify gate go red on a tree nobody changed, and it
looks exactly like a defect in the change being made. `scripts/check-toolchain.R`
runs ahead of the expensive step and names it in one line: roxygen2's installed
version against this package's `Config/roxygen2/version`, and any installed
package built under a newer R than the one running. Both have happened, and both
cost an afternoon (SEOR-tcytizic).

If that check passes and the gate is still red on a tree you have not touched,
say so and keep the evidence rather than assuming your change caused it.

@FP_AGENTS.md
