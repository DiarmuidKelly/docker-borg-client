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

case "$ACTION" in
    list)
        echo "Listing all archives:"
        echo ""
        borg list "$BORG_REPO"
        ;;

    info)
        if [ -z "$ARCHIVE" ]; then
            echo "ERROR: Archive name required for info action"
            echo "Usage: $0 info <archive-name>"
            exit 1
        fi
        echo "Archive information:"
        echo ""
        borg info "${BORG_REPO}::${ARCHIVE}"
        ;;

    extract)
        if [ -z "$ARCHIVE" ]; then
            echo "ERROR: Archive name required for extract action"
            echo "Usage: $0 extract <archive-name> [restore-path]"
            exit 1
        fi
        echo "Extracting archive: $ARCHIVE"
        echo "Destination: $RESTORE_PATH"
        echo ""
        borg extract --list "${BORG_REPO}::${ARCHIVE}" --target "$RESTORE_PATH"
        echo ""
        echo "✅ Extraction completed!"
        ;;

    mount)
        if [ -z "$ARCHIVE" ]; then
            echo "Mounting entire repository at: $RESTORE_PATH"
            borg mount "$BORG_REPO" "$RESTORE_PATH"
        else
            echo "Mounting archive: $ARCHIVE at: $RESTORE_PATH"
            borg mount "${BORG_REPO}::${ARCHIVE}" "$RESTORE_PATH"
        fi
        echo ""
        echo "✅ Mounted! Access files at: $RESTORE_PATH"
        echo "To unmount: borg umount $RESTORE_PATH"
        ;;

    check)
        echo "Checking repository integrity..."
        echo ""
        borg check --progress "$BORG_REPO"
        echo ""
        echo "✅ Repository check completed!"
        ;;

    *)
        echo "Usage: $0 <action> [options]"
        echo ""
        echo "Actions:"
        echo "  list                          List all archives"
        echo "  info <archive>                Show archive information"
        echo "  extract <archive> [path]      Extract archive to path (default: current dir)"
        echo "  mount [archive] [path]        Mount repository or archive"
        echo "  check                         Check repository integrity"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 info backup-2026-01-18_12-00-00"
        echo "  $0 extract backup-2026-01-18_12-00-00 /restore"
        echo "  $0 mount backup-2026-01-18_12-00-00 /mnt/backup"
        echo "  $0 check"
        exit 1
        ;;
esac

echo "========================================="
