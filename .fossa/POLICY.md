# FOSSA license findings — rationale for `pslr`

This file is the **reviewable, version-controlled record** of why each FOSSA
license finding for `pslr` is acceptable.

Custom FOSSA **Policies** are a paid feature not available on this account, so
these decisions are **not** enforced server-side and `.fossa.yml` binds no
policy. Instead, the chosen disposition is to treat FOSSA as **informational**
(not a required, deploy-blocking status check), because — as documented below —
none of the findings are a real licensing risk for an MIT project. This file is
the written justification for that decision.

## Project license

`pslr` is **MIT** (code) plus a bundled **MPL-2.0** data file (the Public
Suffix List). Its runtime dependency graph (`Imports`) is fully permissive —
`punycoder` (MIT) plus base R `tools`/`utils`; the matcher links `cpp11`
(MIT). Every other finding comes from **`Suggests`** packages: dev/test/doc
tooling that is optional, conditionally loaded, and **never distributed at
runtime**.

## Allow-list (approve these licenses)

| License | Why it is allowed |
|---|---|
| MIT, BSD-2/3-Clause, Apache-2.0, ISC | Permissive; the baseline for this project. |
| MPL-2.0 | Weak (file-level) copyleft, MIT-compatible. This is `pslr`'s **own** bundled Public Suffix List data; attribution already complete (see below). |
| Ubuntu Font License 1.0 (`ubuntu-font-1.0`) | Free font license; only reaches us via dev-only `rmarkdown`. |
| GPL-2.0 / GPL-3.0 in **`Suggests`** | Dev/test/doc tooling only — optional, conditionally loaded, not linked, not in any distributed artifact. Does not infect `pslr`'s MIT code. |

## Per-dependency resolutions

Each flagged dependency, the finding, the scope, and the disposition.

### `pslr` (own bundled data) — MPL-2.0 — **shipped data** — APPROVE
- **Why flagged:** `pslr` bundles the Public Suffix List, published by Mozilla
  under MPL-2.0 (the package *code* is MIT).
- **Disposition:** real but benign. MPL-2.0 is file-level copyleft and does
  **not** infect `pslr`'s MIT code. Attribution obligations are **already
  fully satisfied**:
  - `inst/extdata/PSL-LICENSE` — verbatim MPL-2.0 text
  - `inst/NOTICE` — separates MIT (code) from MPL-2.0 (data); pins upstream
    commit + sha256
  - bundled `public_suffix_list.dat` retains the MPL Exhibit A header
  - NOTICE declares the derived `R/sysdata.rda` index is also MPL-2.0
- **Action:** approve MPL-2.0 for `pslr`. No code change.

### `digest` — GPL-2.0-or-later, GPL-2.0-only — **dev-only (`Suggests`)** — IGNORE (scope)
- **Why flagged:** `digest`'s declared license is `GPL (>= 2)`; the
  GPL-2.0-only hit is a deep-scan match on an embedded file.
- **Disposition:** dev/test/maintenance tooling only. Used for sha256
  checksums in `R/refresh.R` (guarded by `requireNamespace("digest")` with a
  **base-R MD5 fallback**), in `tests/testthat/test-bundled-data.R` (guarded by
  `skip_if_not_installed("digest")`), and in the maintainer-only
  `data-raw/update_psl.R`. It is optional, conditionally loaded, not linked,
  and never in a distributed/deployed artifact, so GPL does not infect `pslr`.
- **Action:** ignore these issues — note "dev/test only — Suggests, optional
  with base-R fallback, not distributed at runtime".

### `knitr` — GPL-3.0-only — **dev-only (`Suggests`)** — IGNORE (scope)
- **Why flagged:** `knitr`'s declared license is GPL-3.
- **Disposition:** vignette builder (`VignetteBuilder: knitr`). Not linked,
  not installed at runtime, not in any distributed/deployed artifact.
- **Action:** exclude the dev/test scope from the gate, or ignore this issue.

### `rmarkdown` — GPL-3.0-only, LGPL-3.0-or-later, ubuntu-font-1.0 — **dev-only (`Suggests`)** — IGNORE (scope)
- **Why flagged:** GPL-3 (declared license), LGPL-3 (a bundled JS/CSS web
  asset), Ubuntu Font License (a bundled font).
- **Disposition:** vignette/doc tooling only. Same reasoning as `knitr`.
- **Action:** exclude the dev/test scope from the gate, or ignore these issues.

### `testthat` — GPL-2.0-or-later — **dev-only (`Suggests`)** — IGNORE (scope)
- **Why flagged:** deep-scan hit on an embedded file; `testthat` itself is
  declared MIT.
- **Disposition:** test framework only; never distributed at runtime.
- **Action:** exclude the dev/test scope from the gate, or ignore this issue.

## How this is handled (free tier — no custom policies)

Custom policies are paywalled, so the findings cannot be approved/allowed
server-side for this account.

**FOSSA gates nothing in GitHub.** As verified on the sibling `rurl` repo,
`main` has no branch protection and no rulesets, and FOSSA posts no commit
status/check to the repo. The red "failing" state is internal to the FOSSA
dashboard (its default policy flags copyleft); it does not block merges, the
gh-pages/pkgdown deploy, or `R-CMD-check` — all of which pass. There is
therefore nothing to "unblock."

Disposition:

1. **Treat FOSSA as informational.** Since the red is cosmetic and internal to
   FOSSA, and every finding is benign for an MIT project, no action is required
   to keep deploying. This file is the justification.
2. **Optional — keep the dashboard green** by ignoring each `Suggests` finding
   in the FOSSA UI with the "build only" / dev-only note above.
3. **Optional — disconnect FOSSA.** If the red dashboard is unwanted, remove the
   `pslr` project in FOSSA or de-scope the FOSSA GitHub App for this repo.

## Notes
- If a paid plan with policies is ever adopted, the allow-list table above maps
  directly onto a named policy; bind it via `project.policy` in `.fossa.yml`.
- Anything genuinely runtime + strong-copyleft (GPL/AGPL without exception,
  in `Imports` or `LinkingTo`) is **not** covered here and must be reviewed,
  not auto-allowed.
