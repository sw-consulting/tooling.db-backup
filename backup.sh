#!/bin/bash
# Copyright (C) 2025-2026 Maxim [maxirmx] Samsonov (www.sw.consulting)
# All rights reserved.
# This file is a part of sw.consulting toolset 
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Disable job control to avoid setpgid issues
set +m
set -e

if (( $# > 1 )) || { (( $# == 1 )) && [[ $1 != --check-config ]]; }; then
    echo "Usage: $0 [--check-config]" >&2
    exit 1
fi

# Validate configuration before creating files or connecting to the database.
: "${DB_NAME:?DB_NAME must be set and non-empty}"
BACKUP_PROJECT_NAME=${BACKUP_PROJECT_NAME:-$DB_NAME}
if [[ ! "$BACKUP_PROJECT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "BACKUP_PROJECT_NAME must contain only letters, digits, dots, underscores, and hyphens" >&2
    exit 1
fi

DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-5432}
DB_USER=${DB_USER:-postgres}
DB_PASSWORD=${DB_PASSWORD:-postgres}
BACKUP_DIR=${BACKUP_DIR:-/backups}
RETENTION_DAYS=${RETENTION_DAYS:-7}

if [[ ! "$DB_PORT" =~ ^0*([1-9][0-9]{0,4})$ ]] || (( 10#${BASH_REMATCH[1]} > 65535 )); then
    echo "DB_PORT must be an integer between 1 and 65535" >&2
    exit 1
fi
# Bound the decimal value before arithmetic or passing it to find.
if [[ ! "$RETENTION_DAYS" =~ ^0*([0-9]{1,10})$ ]] || (( 10#${BASH_REMATCH[1]} > 2147483647 )); then
    echo "RETENTION_DAYS must be an integer between 0 and 2147483647" >&2
    exit 1
fi
RETENTION_DAYS=$((10#${BASH_REMATCH[1]}))

# Walk components in filesystem order, resolving existing symlinks before '..'.
# Missing components are only simulated; validation never creates directories.
directory=$(pwd -P)
[[ $BACKUP_DIR != /* ]] || directory=/
remaining=$BACKUP_DIR
while [[ -n $remaining ]]; do
    component=${remaining%%/*}
    if [[ $remaining == */* ]]; then remaining=${remaining#*/}; else remaining=; fi
    case $component in
        ''|.) continue ;;
        ..) directory=${directory%/*}; directory=${directory:-/}; continue ;;
    esac
    candidate=${directory%/}/$component
    if [[ -e $candidate || -L $candidate ]]; then
        if [[ ! -d $candidate || ! -x $candidate ]] || ! directory=$(cd -- "$candidate" && pwd -P); then
            echo "BACKUP_DIR contains an inaccessible directory, non-directory, or dangling symbolic link" >&2
            exit 1
        fi
    else
        if [[ -d $directory && ( ! -w $directory || ! -x $directory ) ]]; then
            echo "BACKUP_DIR ancestor does not permit directory creation" >&2
            exit 1
        fi
        directory=$candidate
    fi
done
if [[ -d $directory && ( ! -w $directory || ! -x $directory ) ]]; then
    echo "BACKUP_DIR must be a writable, searchable directory" >&2
    exit 1
fi

if [[ ${1:-} == --check-config ]]; then
    exit 0
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Generate timestamp for backup filename
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${BACKUP_PROJECT_NAME}_backup_$TIMESTAMP.sql"

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
    echo "Backups selected for deletion:"
    find "$BACKUP_DIR" -name "${BACKUP_PROJECT_NAME}_backup_*.sql.gz" -type f -mtime "+$RETENTION_DAYS" -print -delete
    echo "Backup cleanup completed"
    
    echo "Backup process completed at $(date)"
else
    echo "Backup failed!"
    exit 1
fi
