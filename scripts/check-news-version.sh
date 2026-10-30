#!/bin/sh
# news-version, a host gate of the fleet-ci local gate (.fleet-ci.yml):
#
#   sh scripts/check-news-version.sh      # from the package root
#
# 1. The top NEWS.md heading is either "(development version)" or exactly
#    DESCRIPTION's Version, which catches a stale heading left in at release.
# 2. Every `v*` tag has its `# pslr X.Y.Z` heading, so a released section is
#    never deleted or renamed into unreleased work.
#
# The body of the former `news-version` CI job, unchanged. Step 2 reads the
# tags, which the gate's export lacks, so this is a host gate: the gate runs
# it on the host, in a worktree of the pushed commit, with the repository's
# history. Pure shell.
set -eu

version="$(grep -E '^Version:' DESCRIPTION | head -n1 | sed -E 's/^Version:[[:space:]]*//')"
heading="$(grep -m1 -E '^# ' NEWS.md | sed -E 's/^#[[:space:]]+pslr[[:space:]]*//')"
echo "DESCRIPTION Version : '$version'"
echo "Top NEWS heading    : '$heading'"
if [ "$heading" = "(development version)" ] || [ "$heading" = "$version" ]; then
  echo "OK: NEWS heading and version are consistent."
else
  echo "ERROR: top NEWS.md heading ('$heading') is neither '(development version)' nor the DESCRIPTION Version ('$version'). Update NEWS.md before release."
  exit 1
fi

tags="$(git tag -l 'v*')"
if [ -z "$tags" ]; then
  echo "ERROR: no 'v*' tags found. Fetch the tags (git fetch --tags) for this check to mean anything."
  exit 1
fi
missing=0
for tag in $tags; do
  released="${tag#v}"
  # -x -F: whole line, literal, so the dots in a version are not regex.
  if ! grep -qxF "# pslr ${released}" NEWS.md; then
    echo "ERROR: tag ${tag} has no matching '# pslr ${released}' heading in NEWS.md. A released section was deleted or renamed; its bullets now read as unreleased work."
    missing=1
  fi
done
if [ "$missing" -eq 0 ]; then
  echo "OK: every v* tag has its NEWS.md heading."
fi
exit "$missing"
