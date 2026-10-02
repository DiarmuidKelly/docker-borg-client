#!/bin/bash
set -e

# Auto-release script for docker-borg-client
# Updates VERSION file and creates git tag

BUMP_TYPE="${1:-patch}"
CURRENT_VERSION=$(cat VERSION)

echo "Current version: $CURRENT_VERSION"
echo "Bump type: $BUMP_TYPE"

# Parse version
IFS='.' read -ra VERSION_PARTS <<< "$CURRENT_VERSION"
MAJOR="${VERSION_PARTS[0]}"
MINOR="${VERSION_PARTS[1]}"
PATCH="${VERSION_PARTS[2]}"

# Bump version based on type
case "$BUMP_TYPE" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
  *)
    echo "Invalid bump type: $BUMP_TYPE"
    exit 1
    ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "New version: $NEW_VERSION"

# Update VERSION file
echo "$NEW_VERSION" > VERSION

# Promote the CHANGELOG [Unreleased] section to the version being released, and
# leave a fresh empty [Unreleased] for the next PR to write into. Done here so
# the edit lands in the same commit the tag points at.
RELEASE_DATE=$(date +%Y-%m-%d)
CHANGELOG_UPDATED=false

if [ -f CHANGELOG.md ]; then
  if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    # If nothing was recorded, say so explicitly rather than publishing a
    # version heading with nothing under it. The pre-merge gate in
    # pr-validation.yml should prevent this, but a release that slips through
    # its skip rules should still produce an honest section.
    UNRELEASED_BODY=$(awk '
      /^## \[Unreleased\]/ { in_section = 1; next }
      in_section && /^## \[/ { exit }
      in_section {
        if ($0 ~ /^[[:space:]]*$/) next
        if ($0 ~ /^###/) next
        print
      }' CHANGELOG.md)

    if [ -z "$UNRELEASED_BODY" ]; then
      echo "⚠️  [Unreleased] is empty - recording that explicitly for $NEW_VERSION"
      sed -i "s|^## \[Unreleased\]|## [Unreleased]\n\n## [${NEW_VERSION}] - ${RELEASE_DATE}\n\n_No changelog entries were recorded for this release._|" CHANGELOG.md
    else
      sed -i "s|^## \[Unreleased\]|## [Unreleased]\n\n## [${NEW_VERSION}] - ${RELEASE_DATE}|" CHANGELOG.md
    fi

    # Re-point the Unreleased compare link at the new tag and add one for the
    # release. The base URL is taken from the existing link so the repository
    # location is not duplicated here.
    BASE_URL=$(sed -n 's|^\[Unreleased\]: \(.*\)/compare/.*|\1|p' CHANGELOG.md | head -1)
    if [ -n "$BASE_URL" ]; then
      sed -i "s|^\[Unreleased\]: .*|[Unreleased]: ${BASE_URL}/compare/v${NEW_VERSION}...HEAD\n[${NEW_VERSION}]: ${BASE_URL}/compare/v${CURRENT_VERSION}...v${NEW_VERSION}|" CHANGELOG.md
    else
      echo "⚠️  No [Unreleased] link reference found - skipping link updates"
    fi

    CHANGELOG_UPDATED=true
    echo "CHANGELOG.md: [Unreleased] promoted to [$NEW_VERSION] - $RELEASE_DATE"
  else
    echo "⚠️  CHANGELOG.md has no '## [Unreleased]' heading - skipping promotion"
  fi
else
  echo "No CHANGELOG.md - skipping promotion"
fi

# Create git tag
git add VERSION
if [ "$CHANGELOG_UPDATED" = "true" ]; then
  git add CHANGELOG.md
fi
git commit -m "chore: bump version to $NEW_VERSION"
git tag "v$NEW_VERSION"

echo "✅ Version bumped to $NEW_VERSION"
echo "✅ Tag v$NEW_VERSION created"
if [ "$CHANGELOG_UPDATED" = "true" ]; then
  echo "✅ CHANGELOG.md section created for $NEW_VERSION"
fi
