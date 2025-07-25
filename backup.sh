#!/bin/bash

# Disable job control to avoid setpgid issues
set +m
set -e

# Rest of your backup script...
DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-logibooks}
DB_USER=${DB_USER:-postgres}
DB_PASSWORD=${DB_PASSWORD:-postgres}
BACKUP_DIR=${BACKUP_DIR:-/backups}
RETENTION_DAYS=${RETENTION_DAYS:-7}

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Generate timestamp for backup filename
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/logibooks_backup_$TIMESTAMP.sql"

echo "Starting database backup at $(date)"
echo "Backup file: $BACKUP_FILE"

# Set password for pg_dump
export PGPASSWORD="$DB_PASSWORD"

# Create backup with explicit options to avoid process group issues
if timeout 3600 pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$BACKUP_FILE" --verbose --no-password; then
    echo "Backup completed successfully: $BACKUP_FILE"
    
    # Compress the backup
    gzip "$BACKUP_FILE"
    echo "Backup compressed: $BACKUP_FILE.gz"
    
    # Clean up old backups
    echo "Cleaning up backups older than $RETENTION_DAYS days..."
    find "$BACKUP_DIR" -name "logibooks_backup_*.sql.gz" -type f -mtime +$RETENTION_DAYS -delete
    
    echo "Backup process completed at $(date)"
else
    echo "Backup failed!"
    exit 1
fi

