#!/bin/bash
set -e

# Verify a pull request adds at least one entry to the [Unreleased] section of
# CHANGELOG.md.
#
# A changelog is only worth having if it is actually written, and the usual
# failure mode is silent rot: entries stop being added, releases ship empty
# sections, and nobody notices until someone needs to know what changed.
#
# Checks the content of the [Unreleased] section specifically, not merely that
# CHANGELOG.md was touched - editing an older section or a link reference does
# not count.
#
# Usage: check-changelog.sh [base-ref] [changelog-path]

BASE_REF="${1:-origin/main}"
CHANGELOG="${2:-CHANGELOG.md}"

# Print the substantive lines of the [Unreleased] section from stdin, ignoring
# blank lines and "### Added"-style subheadings so an empty scaffold does not
# count as an entry.
unreleased_entries() {
    awk '
        /^## \[Unreleased\]/ { in_section = 1; next }
        in_section && /^## \[/ { exit }
        in_section {
            if ($0 ~ /^[[:space:]]*$/) next
            if ($0 ~ /^###/) next
            print
        }
    '
}

if [ ! -f "$CHANGELOG" ]; then
    echo "❌ $CHANGELOG not found"
    exit 1
fi

if ! grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
    echo "❌ $CHANGELOG has no '## [Unreleased]' heading"
    echo "   The release workflow promotes that heading to the new version, so"
    echo "   it must exist."
    exit 1
fi

HEAD_ENTRIES=$(mktemp)
BASE_ENTRIES=$(mktemp)
trap 'rm -f "$HEAD_ENTRIES" "$BASE_ENTRIES"' EXIT

unreleased_entries < "$CHANGELOG" > "$HEAD_ENTRIES"

# The changelog may not exist on the base branch yet (as when it is first added)
if git cat-file -e "${BASE_REF}:${CHANGELOG}" 2>/dev/null; then
    git show "${BASE_REF}:${CHANGELOG}" | unreleased_entries > "$BASE_ENTRIES"
else
    : > "$BASE_ENTRIES"
fi

# Lines present now but not on the base branch. Compared by content rather than
# by counting, so a PR that rewords one entry and adds another still passes.
#
# The empty-base case is handled separately on purpose: with an empty pattern
# file, GNU grep -v prints every line while busybox grep prints none. Relying on
# the GNU behaviour would make this pass in CI and fail under `make test-alpine`.
if [ -s "$BASE_ENTRIES" ]; then
    ADDED=$(grep -Fxv -f "$BASE_ENTRIES" "$HEAD_ENTRIES" || true)
else
    ADDED=$(cat "$HEAD_ENTRIES")
fi

if [ -z "$ADDED" ]; then
    echo "❌ No new entries in the [Unreleased] section of $CHANGELOG"
    echo ""
    echo "Add a line describing the user-visible effect of this change, under the"
    echo "appropriate heading (Added / Changed / Fixed / Removed / Documentation):"
    echo ""
    echo "    ## [Unreleased]"
    echo ""
    echo "    ### Changed"
    echo ""
    echo "    - Prune now runs after a fast backup, so retention is enforced on"
    echo "      small repositories where it previously was not. (#56)"
    echo ""
    echo "Behavioural changes matter most: this is backup software, and someone"
    echo "pinning an image tag needs to know when an upgrade changes what happens"
    echo "to their archives."
    echo ""
    echo "If this change genuinely has no user-visible effect, either title the PR"
    echo "'docs:' / 'chore:' / '[SKIP] ...' (which skips the release entirely), or"
    echo "apply the 'no-changelog' label."
    exit 1
fi

COUNT=$(printf '%s\n' "$ADDED" | wc -l | tr -d ' ')
echo "✅ $COUNT new [Unreleased] entry line(s) in $CHANGELOG:"
printf '%s\n' "$ADDED" | sed 's/^/   /'
