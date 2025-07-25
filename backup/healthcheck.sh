#!/bin/bash
# Check if backup was created in the last 25 hours
find /backups -name "logibooks_backup_*.sql.gz" -mtime -1 | grep -q . && echo "healthy" || exit 1
