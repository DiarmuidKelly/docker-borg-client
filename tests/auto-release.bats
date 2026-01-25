#!/usr/bin/env bats

# Test auto-release.sh version bumping logic

setup() {
    # Path to the script under test
    AUTO_RELEASE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/auto-release.sh"

    # Create temporary test directory
    TEST_DIR="/tmp/test-auto-release-$$"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"

    # Initialize git repo for testing
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial VERSION file
    echo "1.2.3" > VERSION
    git add VERSION
    git commit -m "Initial commit" --quiet
}

teardown() {
    # Clean up
    cd /
    rm -rf "$TEST_DIR"
}

# Test: Patch version bump (default)
@test "bumps patch version by default" {
    run bash "$AUTO_RELEASE_SCRIPT"
    [ "$status" -eq 0 ]

    # Check VERSION file was updated
    [ "$(cat VERSION)" = "1.2.4" ]

    # Check git tag was created
    git tag | grep -q "v1.2.4"

    # Check commit message
    git log -1 --pretty=%B | grep -q "chore: bump version to 1.2.4"
}

# Test: Explicit patch bump
@test "bumps patch version when specified" {
    run bash "$AUTO_RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]

    [ "$(cat VERSION)" = "1.2.4" ]
    git tag | grep -q "v1.2.4"
}

# Test: Minor version bump
@test "bumps minor version and resets patch" {
    run bash "$AUTO_RELEASE_SCRIPT" minor
    [ "$status" -eq 0 ]

    [ "$(cat VERSION)" = "1.3.0" ]
    git tag | grep -q "v1.3.0"
    git log -1 --pretty=%B | grep -q "chore: bump version to 1.3.0"
}

# Test: Major version bump
@test "bumps major version and resets minor and patch" {
    run bash "$AUTO_RELEASE_SCRIPT" major
    [ "$status" -eq 0 ]

    [ "$(cat VERSION)" = "2.0.0" ]
    git tag | grep -q "v2.0.0"
    git log -1 --pretty=%B | grep -q "chore: bump version to 2.0.0"
}

# Test: Invalid bump type
@test "fails with invalid bump type" {
    run bash "$AUTO_RELEASE_SCRIPT" invalid
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Invalid bump type: invalid"

    # VERSION should remain unchanged
    [ "$(cat VERSION)" = "1.2.3" ]
}

# Test: Handles version with double digits
@test "handles multi-digit version numbers" {
    echo "10.99.999" > VERSION
    git add VERSION
    git commit -m "Set high version" --quiet

    run bash "$AUTO_RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "10.99.1000" ]

    # Test minor bump
    echo "10.99.999" > VERSION
    run bash "$AUTO_RELEASE_SCRIPT" minor
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "10.100.0" ]

    # Test major bump
    echo "99.99.99" > VERSION
    run bash "$AUTO_RELEASE_SCRIPT" major
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "100.0.0" ]
}

# Test: Output messages
@test "displays correct output messages" {
    run bash "$AUTO_RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "Current version: 1.2.3"
    echo "$output" | grep -q "Bump type: patch"
    echo "$output" | grep -q "New version: 1.2.4"
    echo "$output" | grep -q "✅ Version bumped to 1.2.4"
    echo "$output" | grep -q "✅ Tag v1.2.4 created"
}

# Test: Version starting at 0.0.0
@test "handles version starting from 0.0.0" {
    echo "0.0.0" > VERSION
    git add VERSION
    git commit -m "Zero version" --quiet

    run bash "$AUTO_RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "0.0.1" ]

    echo "0.0.0" > VERSION
    run bash "$AUTO_RELEASE_SCRIPT" minor
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "0.1.0" ]

    echo "0.0.0" > VERSION
    run bash "$AUTO_RELEASE_SCRIPT" major
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "1.0.0" ]
}

# Test: Script creates proper git history
@test "creates proper git history" {
    run bash "$AUTO_RELEASE_SCRIPT" patch
    [ "$status" -eq 0 ]

    # Check that VERSION file is committed
    git diff --quiet HEAD -- VERSION

    # Check that tag points to latest commit
    TAG_COMMIT=$(git rev-list -n 1 v1.2.4)
    HEAD_COMMIT=$(git rev-parse HEAD)
    [ "$TAG_COMMIT" = "$HEAD_COMMIT" ]
}

# Test: Missing VERSION file
@test "fails when VERSION file is missing" {
    rm VERSION
    run bash "$AUTO_RELEASE_SCRIPT" patch
    [ "$status" -ne 0 ]
}

# Test: Malformed VERSION file
@test "fails with malformed VERSION file" {
    echo "not-a-version" > VERSION
    git add VERSION
    git commit -m "Bad version" --quiet

    run bash "$AUTO_RELEASE_SCRIPT" patch
    [ "$status" -ne 0 ]
}