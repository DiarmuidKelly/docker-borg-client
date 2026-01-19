#!/bin/sh
# Check if current time is within backup window
# Exit 0 if inside window, 1 if outside window

# If no window configured, always allow backup
if [ -z "$BACKUP_WINDOW_START" ] || [ -z "$BACKUP_WINDOW_END" ]; then
    exit 0
fi

# Convert HH:MM to HHMM for integer comparison (e.g., "01:00" -> 100, "22:00" -> 2200)
current=$(date +%H%M | sed 's/^0*//')
current=${current:-0}
start=$(echo "$BACKUP_WINDOW_START" | tr -d : | sed 's/^0*//')
start=${start:-0}
end=$(echo "$BACKUP_WINDOW_END" | tr -d : | sed 's/^0*//')
end=${end:-0}

# Normal window (e.g., 01:00-07:00)
if [ "$start" -lt "$end" ]; then
    if [ "$current" -ge "$start" ] && [ "$current" -lt "$end" ]; then
        exit 0  # Inside window
    else
        exit 1  # Outside window
    fi
else
    # Overnight window (e.g., 22:00-06:00)
    if [ "$current" -ge "$start" ] || [ "$current" -lt "$end" ]; then
        exit 0  # Inside window
    else
        exit 1  # Outside window
    fi
fi
