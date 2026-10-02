#!/bin/sh
# shellcheck shell=ash
# Shared path helpers for restore operations.
#
# Sourced by restore.sh and restore-drill.sh. Both need the same question
# answered - "is it safe to write to (or delete) this path?" - and getting it
# wrong means destroying the data a restore is meant to recover.

# Resolve a path to an absolute, normalised form without touching the
# filesystem. The destination may not exist yet, and the path may be relative,
# so `realpath` is not an option (and busybox lacks `realpath -m`).
#
# Collapses "", ".", ".." segments and duplicate slashes:
#   .            (cwd /)   -> /
#   /data/../etc           -> /etc
#   /data//photos/         -> /data/photos
normalise_path() {
    _np_input="$1"

    case "$_np_input" in
        /*) _np_abs="$_np_input" ;;
        *)  _np_abs="$(pwd)/$_np_input" ;;
    esac

    printf '%s' "$_np_abs" | awk -F/ '
        {
            n = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "" || $i == ".") continue
                if ($i == "..") { if (n > 0) n--; continue }
                parts[++n] = $i
            }
            out = ""
            for (i = 1; i <= n; i++) out = out "/" parts[i]
            print (out == "" ? "/" : out)
        }'
}

# Fail if writing to (or deleting) this path could clobber the live source data.
#
# Borg stores archive paths without a leading slash, so extracting at / recreates
# the original absolute tree over the top of the source. Refuse that, and refuse
# anything inside a configured backup path.
#
# Usage: assert_safe_destination <path> <operation-description>
assert_safe_destination() {
    _asd_raw="$1"
    _asd_what="${2:-extract}"

    if [ -z "$_asd_raw" ]; then
        echo "ERROR: no destination given for $_asd_what" >&2
        return 1
    fi

    _asd_dest=$(normalise_path "$_asd_raw")

    if [ "$_asd_dest" = "/" ]; then
        echo "ERROR: refusing to $_asd_what at '/' - this would overwrite live data" >&2
        if [ "$_asd_raw" != "/" ]; then
            echo "       ('$_asd_raw' resolves to '/' from $(pwd))" >&2
        fi
        echo "       Pass an empty restore directory instead, e.g. /restore" >&2
        return 1
    fi

    for _asd_src in $(printf '%s' "${BACKUP_PATHS:-}" | tr ':' '\n'); do
        [ -n "$_asd_src" ] || continue
        _asd_src=$(normalise_path "$_asd_src")

        # A backup source of / makes every destination unsafe
        if [ "$_asd_src" = "/" ]; then
            echo "ERROR: refusing to $_asd_what to '$_asd_dest'" >&2
            echo "       BACKUP_PATHS includes '/', so any destination is inside" >&2
            echo "       the backup source. Restore to a path that is excluded" >&2
            echo "       from the backup, or mount a separate volume." >&2
            return 1
        fi

        if [ "$_asd_dest" = "$_asd_src" ] || \
           case "$_asd_dest/" in "$_asd_src"/*) true ;; *) false ;; esac; then
            echo "ERROR: refusing to $_asd_what to '$_asd_dest'" >&2
            echo "       It is inside backup source '$_asd_src' - restoring there" >&2
            echo "       would overwrite the data you are trying to recover." >&2
            return 1
        fi
    done

    return 0
}
