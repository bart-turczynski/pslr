# pslr 0.0.0.9000

* Initial scaffold.
* Bundled the Public Suffix List snapshot pinned to upstream commit
  `9186eee` (list date 2026-06-13), with a deterministic `data-raw/`
  regeneration script, an internal validated rule index, generation metadata
  (commit, source URL, checksum, normalization profile, Unicode version), and
  MPL-2.0 data licensing separate from the package's MIT code license.
* Added the public query API: `public_suffix()`, `registrable_domain()`,
  `is_public_suffix()`, `suffix_extract()`, and `public_suffix_rule()`. All are
  vectorised, length- and name-preserving, NA-safe, and share the
  `section` / `output` / `unknown` / `invalid` policies. Input is canonicalized
  through `punycoder` with terminal-dot preservation and dotted-decimal IPv4
  literal rejection, and repeated queries are served from a bounded session
  cache keyed by host, active-list identity, and section.
