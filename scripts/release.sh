#!/usr/bin/env bash
# Cut a GitHub Release for the version in VERSION (see docs/dev/releasing.md).
#
#   scripts/release.sh            test, build, zip, tag, push the tag, publish the release
#   scripts/release.sh --dry-run  everything except tag, push and publish
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
DRY="${1:-}"

die() { echo "release: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
command -v gh >/dev/null || die "needs the GitHub CLI (gh)"

# The notes are this version's section of the changelog, heading excluded.
NOTES="$(awk -v v="## $VERSION " 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || die "CHANGELOG.md has no '## $VERSION' section"

bash tests/run-tests.sh || die "tests failed"
bash scripts/build.sh --package
ZIP="dist/Switchboard-$VERSION.zip"

if [[ "$DRY" == "--dry-run" ]]; then
  echo "dry run: would tag $TAG and publish $ZIP with notes:"
  echo "$NOTES"
  exit 0
fi

git tag -a "$TAG" -m "Switchboard $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "Switchboard $VERSION" --notes "$NOTES"
echo "released $TAG"
