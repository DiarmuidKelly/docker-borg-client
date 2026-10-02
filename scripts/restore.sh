#!/bin/sh
set -e

ACTION="${1:-list}"
ARCHIVE="${2:-}"
RESTORE_PATH="${3:-.}"

echo "========================================="
echo "Borg Restore Tool"
echo "========================================="
echo "Repository: $BORG_REPO"
echo ""

# Resolve the special name "latest" to a real archive name so every action can
# be driven without first looking up a timestamp. Borg 1.x has no ::latest
# pseudo-archive, so this is done client-side via --last 1.
resolve_archive() {
    case "$1" in
        latest)
            resolved=$(borg list --last 1 --format '{archive}{NL}' "$BORG_REPO" | head -1)
            if [ -z "$resolved" ]; then
                echo "ERROR: repository has no archives to resolve 'latest'" >&2
                exit 1
            fi
            printf '%s\n' "$resolved"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# Fail-safe: never let a restore write over the live data it was taken from.
# The path checks live in lib-paths.sh because the restore drill needs the same
# guard before it deletes its target directory. Sourced relative to this script
# so it resolves both at /scripts in the image and from a git checkout.
# shellcheck source=scripts/lib-paths.sh
. "$(dirname "$0")/lib-paths.sh"

check_destination() {
    assert_safe_destination "$1" "extract" || exit 1

    if [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; then
        echo "WARNING: destination '$1' is not empty - existing files may be overwritten"
        echo ""
    fi
}

# borg mount needs FUSE bindings in the image plus /dev/fuse and SYS_ADMIN from
# the container runtime. Check up front: a clear message beats borg's
# "no FUSE support" runtime error part-way through a recovery.
assert_fuse_available() {
    # Escape hatch for runtimes where the probe is wrong but mounting works
    if [ "${RESTORE_SKIP_FUSE_CHECK:-false}" = "true" ]; then
        return 0
    fi

    if ! python3 -c 'import pyfuse3' 2>/dev/null && ! python3 -c 'import llfuse' 2>/dev/null; then
        echo "ERROR: this image has no FUSE bindings - 'borg mount' is unavailable" >&2
        echo "       Rebuild with the borgbackup-fuse package installed." >&2
        exit 1
    fi

    if [ ! -e /dev/fuse ]; then
        echo "ERROR: /dev/fuse is not present in this container" >&2
        echo "       Mounting needs the device and capability passed in:" >&2
        echo "         docker run --device /dev/fuse --cap-add SYS_ADMIN \\" >&2
        echo "                    --security-opt apparmor=unconfined ..." >&2
        echo "       In compose:" >&2
        echo "         devices: [\"/dev/fuse\"]" >&2
        echo "         cap_add: [\"SYS_ADMIN\"]" >&2
        echo "         security_opt: [\"apparmor=unconfined\"]" >&2
        echo "       Or use 'extract' instead, which needs no special privileges." >&2
        exit 1
    fi
}

case "$ACTION" in
    list)
        echo "Listing all archives:"
        echo ""
        borg list "$BORG_REPO"
        ;;

    latest)
        # Machine-readable: prints just the newest archive name for scripting
        resolve_archive latest
        ;;

    info)
        if [ -z "$ARCHIVE" ]; then
            echo "ERROR: Archive name required for info action"
            echo "Usage: $0 info <archive-name>"
            exit 1
        fi
        ARCHIVE=$(resolve_archive "$ARCHIVE")
        echo "Archive information:"
        echo ""
        borg info "${BORG_REPO}::${ARCHIVE}"
        ;;

    files)
        if [ -z "$ARCHIVE" ]; then
            echo "ERROR: Archive name required for files action"
            echo "Usage: $0 files <archive-name> [pattern]"
            exit 1
        fi
        ARCHIVE=$(resolve_archive "$ARCHIVE")
        PATTERN="${3:-}"
        echo "Files in archive: $ARCHIVE"
        if [ -n "$PATTERN" ]; then
            echo "Filtering on: $PATTERN"
        fi
        echo ""
        if [ -n "$PATTERN" ]; then
            # grep exits 1 when nothing matches. Under set -e that would make
            # "this file is not in the archive" - a useful, correct answer -
            # indistinguishable from a repository failure mid-recovery.
            MATCHES=$(borg list --format '{path}{NL}' "${BORG_REPO}::${ARCHIVE}" | grep -- "$PATTERN" || true)
            if [ -z "$MATCHES" ]; then
                echo "No paths in $ARCHIVE match '$PATTERN'."
                echo "Archive paths have no leading slash: a source of /data/docs"
                echo "appears as data/docs. Run without a pattern to list everything."
            else
                printf '%s\n' "$MATCHES"
            fi
        else
            borg list --format '{path}{NL}' "${BORG_REPO}::${ARCHIVE}"
        fi
        ;;

    extract)
        if [ -z "$ARCHIVE" ]; then
            echo "ERROR: Archive name required for extract action"
            echo "Usage: $0 extract <archive-name> [restore-path] [inner-path...]"
            exit 1
        fi
        ARCHIVE=$(resolve_archive "$ARCHIVE")
        check_destination "$RESTORE_PATH"
        # Anything after the destination narrows the restore to those paths.
        # Guard the shift: `shift N` with N > $# is fatal in dash.
        if [ $# -gt 3 ]; then shift 3; else set --; fi
        echo "Extracting archive: $ARCHIVE"
        echo "Destination: $RESTORE_PATH"
        if [ $# -gt 0 ]; then
            echo "Paths: $*"
        fi
        echo ""
        mkdir -p "$RESTORE_PATH"
        cd "$RESTORE_PATH"
        borg extract --list "${BORG_REPO}::${ARCHIVE}" "$@"
        echo ""
        echo "✅ Extraction completed!"
        ;;

    dry-run)
        if [ -z "$ARCHIVE" ]; then
            echo "ERROR: Archive name required for dry-run action"
            echo "Usage: $0 dry-run <archive-name> [inner-path...]"
            exit 1
        fi
        ARCHIVE=$(resolve_archive "$ARCHIVE")
        # Reads and decrypts every chunk without writing files: proves the
        # archive is recoverable without needing restore disk space.
        if [ $# -gt 2 ]; then shift 2; else set --; fi
        echo "Dry-run extract of archive: $ARCHIVE"
        echo "No files will be written."
        if [ $# -gt 0 ]; then
            echo "Paths: $*"
        fi
        echo ""
        borg extract --dry-run --list "${BORG_REPO}::${ARCHIVE}" "$@"
        echo ""
        echo "✅ Dry-run completed - archive is readable!"
        ;;

    mount)
        assert_fuse_available
        if [ -z "$ARCHIVE" ]; then
            echo "Mounting entire repository at: $RESTORE_PATH"
            borg mount "$BORG_REPO" "$RESTORE_PATH"
        else
            ARCHIVE=$(resolve_archive "$ARCHIVE")
            echo "Mounting archive: $ARCHIVE at: $RESTORE_PATH"
            borg mount "${BORG_REPO}::${ARCHIVE}" "$RESTORE_PATH"
        fi
        echo ""
        echo "✅ Mounted! Access files at: $RESTORE_PATH"
        echo "To unmount: borg umount $RESTORE_PATH"
        ;;

    umount)
        MOUNT_PATH="${2:-}"
        if [ -z "$MOUNT_PATH" ]; then
            echo "ERROR: Mount path required for umount action"
            echo "Usage: $0 umount <mount-path>"
            exit 1
        fi
        echo "Unmounting: $MOUNT_PATH"
        borg umount "$MOUNT_PATH"
        echo ""
        echo "✅ Unmounted!"
        ;;

    check)
        echo "Checking repository integrity..."
        echo ""
        borg check --progress "$BORG_REPO"
        echo ""
        echo "✅ Repository check completed!"
        ;;

    drill)
        # Automated restore drill - proves recoverability end to end
        exec /scripts/restore-drill.sh
        ;;

    key-export)
        KEY_FILE="${2:-/borg/config/repo-key.txt}"
        echo "Exporting repository key to: $KEY_FILE"
        echo ""
        borg key export "$BORG_REPO" "$KEY_FILE"
        echo ""
        echo "✅ Key exported!"
        echo "⚠️  Store this with your passphrase, OFF this machine."
        echo "   Without the passphrase the key alone cannot decrypt anything."
        ;;

    *)
        echo "Usage: $0 <action> [options]"
        echo ""
        echo "Actions:"
        echo "  list                          List all archives"
        echo "  latest                        Print the newest archive name"
        echo "  info <archive>                Show archive information"
        echo "  files <archive> [pattern]     List files in an archive"
        echo "  extract <archive> [path] [inner-path...]"
        echo "                                Extract archive (optionally only given paths)"
        echo "  dry-run <archive> [inner-path...]"
        echo "                                Verify an archive is readable, writing nothing"
        echo "  mount [archive] [path]        Mount repository or archive (needs /dev/fuse)"
        echo "  umount <path>                 Unmount a mounted archive"
        echo "  check                         Check repository integrity"
        echo "  drill                         Run an automated restore drill"
        echo "  key-export [file]             Export the repository key for disaster recovery"
        echo ""
        echo "Any <archive> may be given as 'latest' to use the newest archive."
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 info backup-2026-01-18_12-00-00"
        echo "  $0 files latest important.txt"
        echo "  $0 extract backup-2026-01-18_12-00-00 /restore"
        echo "  $0 extract latest /restore data/photos/holiday.jpg"
        echo "  $0 dry-run latest"
        echo "  $0 mount backup-2026-01-18_12-00-00 /mnt/backup"
        echo "  $0 check"
        exit 1
        ;;
esac

echo "========================================="
