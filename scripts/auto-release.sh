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

# Create git tag
git add VERSION
git commit -m "chore: bump version to $NEW_VERSION"
git tag "v$NEW_VERSION"

echo "✅ Version bumped to $NEW_VERSION"
echo "✅ Tag v$NEW_VERSION created"
