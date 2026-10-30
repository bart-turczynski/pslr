#!/bin/sh
#
# The docs-drift gate, then a check that it left the committed cpp11 glue
# alone (.fleet-ci.yml's cheap_gates).
#
#   sh scripts/check-docs-drift-glue.sh
#
# scripts/check-docs-drift.R (seor's copy, not edited here) runs roxygen2,
# which loads pslr with pkgload, which compiles src/ and runs
# cpp11::cpp_register(). That rewrites R/cpp11.R and src/cpp11.cpp in place,
# and the gate runs it in its export of the pushed commit, ahead of R CMD
# check. Stale committed glue would be regenerated there and checked as if it
# had been committed. So the committed copies are saved first and compared
# byte for byte after the drift check: a difference fails the gate, with the
# diff. The export has no .git, so git diff against HEAD is not an option.
#
# Run from the package root. Exit 0 when both pass, 1 otherwise.

set -u

glue="R/cpp11.R src/cpp11.cpp"
saved="$(mktemp -d)"
trap 'rm -rf "$saved"' EXIT

for f in $glue; do
  if [ ! -f "$f" ]; then
    echo "check-docs-drift-glue: $f is missing" >&2
    exit 1
  fi
  mkdir -p "$saved/$(dirname "$f")"
  cp "$f" "$saved/$f"
done

status=0
Rscript scripts/check-docs-drift.R . || status=1

for f in $glue; do
  if ! cmp -s "$saved/$f" "$f"; then
    echo "check-docs-drift-glue: cpp11::cpp_register() rewrote $f; the committed glue is stale:" >&2
    diff -u "$saved/$f" "$f" >&2 || true
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "check-docs-drift-glue: R/cpp11.R and src/cpp11.cpp match what cpp11::cpp_register() writes."
else
  echo "check-docs-drift-glue: fix by running devtools::document() (or cpp11::cpp_register()) in your checkout and committing the result." >&2
fi
exit "$status"
