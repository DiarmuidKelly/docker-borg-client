#!/usr/bin/env bats

# Test the changelog machinery:
#   check-changelog.sh - pre-merge check that a PR adds [Unreleased] entries
#   auto-release.sh    - promotes [Unreleased] to the released version

setup() {
    CHECK_SCRIPT="${BATS_TEST_DIRNAME}/../.github/scripts/check-changelog.sh"
    RELEASE_SCRIPT="${BATS_TEST_DIRNAME}/../.github/scripts/auto-release.sh"

    TEST_DIR="/tmp/test-changelog-$$"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"

    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    git checkout -q -b main 2>/dev/null || true

    echo "1.2.3" > VERSION
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# A changelog with no entries under [Unreleased]
write_empty_changelog() {
    cat > CHANGELOG.md << 'EOF'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-01-01

### Added

- Previous release thing

[Unreleased]: https://github.com/o/r/compare/v1.2.3...HEAD
[1.2.3]: https://github.com/o/r/compare/v1.2.2...v1.2.3
EOF
}

# A changelog with one entry under [Unreleased]
write_changelog_with_entry() {
    cat > CHANGELOG.md << 'EOF'
# Changelog

## [Unreleased]

### Changed

- Prune now runs after a fast backup. (#56)

## [1.2.3] - 2026-01-01

### Added

- Previous release thing

[Unreleased]: https://github.com/o/r/compare/v1.2.3...HEAD
[1.2.3]: https://github.com/o/r/compare/v1.2.2...v1.2.3
EOF
}

commit_all() {
    git add -A
    git commit -q -m "${1:-commit}"
}

# ---------- check-changelog.sh ----------

@test "check passes when the PR adds an entry to [Unreleased]" {
    write_empty_changelog
    commit_all "base"
    git branch -q base-ref

    write_changelog_with_entry
    commit_all "add entry"

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "new \[Unreleased\] entry line(s)"
    echo "$output" | grep -q "Prune now runs after a fast backup"
}

@test "check fails when the PR adds no entry" {
    write_empty_changelog
    commit_all "base"
    git branch -q base-ref

    echo "unrelated change" > other.txt
    commit_all "no changelog entry"

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "No new entries in the \[Unreleased\] section"
    echo "$output" | grep -q "no-changelog"
}

@test "check fails when only an older section is edited" {
    write_changelog_with_entry
    commit_all "base"
    git branch -q base-ref

    # Edit a released section, leaving [Unreleased] untouched
    sed -i 's/- Previous release thing/- Previous release thing, reworded/' CHANGELOG.md
    commit_all "edit old section"

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "No new entries in the \[Unreleased\] section"
}

@test "check ignores an empty scaffold of subheadings" {
    write_empty_changelog
    commit_all "base"
    git branch -q base-ref

    # Add only headings, no actual entries
    sed -i 's|^## \[Unreleased\]|## [Unreleased]\n\n### Added\n\n### Fixed|' CHANGELOG.md
    commit_all "headings only"

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "No new entries"
}

@test "check passes when a PR rewords one entry and adds another" {
    write_changelog_with_entry
    commit_all "base"
    git branch -q base-ref

    cat > CHANGELOG.md << 'EOF'
# Changelog

## [Unreleased]

### Changed

- Prune now runs after a fast backup, enforcing retention. (#56)
- Something genuinely new

## [1.2.3] - 2026-01-01

[Unreleased]: https://github.com/o/r/compare/v1.2.3...HEAD
EOF
    commit_all "reword and add"

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Something genuinely new"
}

@test "check passes when CHANGELOG.md does not exist on the base branch" {
    echo "placeholder" > other.txt
    commit_all "base without changelog"
    git branch -q base-ref

    write_changelog_with_entry
    commit_all "add changelog"

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 0 ]
}

@test "check fails when CHANGELOG.md is missing entirely" {
    commit_all() { :; }
    echo "x" > other.txt
    git add -A && git commit -q -m base
    git branch -q base-ref

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "CHANGELOG.md not found"
}

@test "check fails when the [Unreleased] heading is missing" {
    cat > CHANGELOG.md << 'EOF'
# Changelog

## [1.2.3] - 2026-01-01

- A thing
EOF
    git add -A && git commit -q -m base
    git branch -q base-ref

    run bash "$CHECK_SCRIPT" base-ref
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "no '## \[Unreleased\]' heading"
}

# ---------- auto-release.sh changelog promotion ----------

@test "release promotes [Unreleased] to the new version with today's date" {
    write_changelog_with_entry
    commit_all "base"

    run bash "$RELEASE_SCRIPT" minor
    [ "$status" -eq 0 ]

    TODAY=$(date +%Y-%m-%d)
    grep -q "^## \[1.3.0\] - ${TODAY}$" CHANGELOG.md
    echo "$output" | grep -q "promoted to \[1.3.0\]"
    echo "$output" | grep -q "CHANGELOG.md section created for 1.3.0"
}

@test "release leaves a fresh empty [Unreleased] for the next PR" {
    write_changelog_with_entry
    commit_all "base"

    run bash "$RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]

    # The heading survives...
    grep -q "^## \[Unreleased\]$" CHANGELOG.md
    # ...and is now empty, so the pre-merge check will demand a new entry
    awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{exit} f&&!/^[[:space:]]*$/&&!/^###/{print}' \
        CHANGELOG.md > entries.txt
    [ ! -s entries.txt ]
}

@test "release keeps the promoted entries under the new version heading" {
    write_changelog_with_entry
    commit_all "base"

    run bash "$RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]

    awk '/^## \[1.2.4\]/{f=1;next} f&&/^## \[/{exit} f' CHANGELOG.md \
        | grep -q "Prune now runs after a fast backup"
}

@test "release updates the comparison links" {
    write_changelog_with_entry
    commit_all "base"

    run bash "$RELEASE_SCRIPT" minor
    [ "$status" -eq 0 ]

    grep -q "^\[Unreleased\]: https://github.com/o/r/compare/v1.3.0\.\.\.HEAD$" CHANGELOG.md
    grep -q "^\[1.3.0\]: https://github.com/o/r/compare/v1.2.3\.\.\.v1.3.0$" CHANGELOG.md
}

@test "release commits the changelog alongside VERSION in the tagged commit" {
    write_changelog_with_entry
    commit_all "base"

    run bash "$RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]

    # Nothing left uncommitted
    [ -z "$(git status --porcelain)" ]

    # The tagged commit contains both files
    git show --stat --name-only v1.2.4 | grep -q "CHANGELOG.md"
    git show --stat --name-only v1.2.4 | grep -q "VERSION"
}

@test "release succeeds when there is no CHANGELOG.md" {
    git add -A && git commit -q -m base

    run bash "$RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No CHANGELOG.md - skipping promotion"
    [ "$(cat VERSION)" = "1.2.4" ]
    git tag | grep -q "v1.2.4"
}

@test "release warns but succeeds when [Unreleased] is missing" {
    cat > CHANGELOG.md << 'EOF'
# Changelog

## [1.2.3] - 2026-01-01

- A thing
EOF
    commit_all "base"

    run bash "$RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "no '## \[Unreleased\]' heading - skipping promotion"
    git tag | grep -q "v1.2.4"
}

@test "release promotes an empty [Unreleased] without corrupting the file" {
    write_empty_changelog
    commit_all "base"

    run bash "$RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]

    TODAY=$(date +%Y-%m-%d)
    grep -q "^## \[1.2.4\] - ${TODAY}$" CHANGELOG.md
    grep -q "^## \[Unreleased\]$" CHANGELOG.md
    # The older section must still be intact
    grep -q "^## \[1.2.3\] - 2026-01-01$" CHANGELOG.md
}
