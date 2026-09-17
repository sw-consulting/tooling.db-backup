#!/bin/bash
: "${DB_NAME:?DB_NAME must be set and non-empty}"
BACKUP_PROJECT_NAME=${BACKUP_PROJECT_NAME:-$DB_NAME}
BACKUP_DIR=${BACKUP_DIR:-/backups}
if [[ ! "$BACKUP_PROJECT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "BACKUP_PROJECT_NAME must contain only letters, digits, dots, underscores, and hyphens" >&2
    exit 1
fi

# Check if a backup file was created in the last 24 hours.
find "$BACKUP_DIR" -name "${BACKUP_PROJECT_NAME}_backup_*.sql.gz" -type f -mtime -1 | grep -q . && echo "healthy" || exit 1
