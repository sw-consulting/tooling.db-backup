# PostgreSQL database backups

Creates compressed SQL backups daily at 02:00 in the container's timezone.

## Configuration

Pass configuration as environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DB_NAME` | Required | Database to back up or restore; also required for health checks. |
| `BACKUP_PROJECT_NAME` | `DB_NAME` | Backup filename prefix; unset or empty values use `DB_NAME`. |
| `DB_HOST` | `db` | PostgreSQL host. |
| `DB_PORT` | `5432` | PostgreSQL port. |
| `DB_USER` | `postgres` | PostgreSQL user. |
| `DB_PASSWORD` | `postgres` | PostgreSQL password. |
| `BACKUP_DIR` | `/backups` | Backup output and health-check directory. |
| `RETENTION_DAYS` | `7` | Non-negative retention value passed to `find -mtime +N`. |

The project prefix accepts only ASCII letters, digits, dots, underscores, and
hyphens. For database names containing other characters, set an explicit safe
`BACKUP_PROJECT_NAME`. Invalid prefixes fail before backup filesystem operations.

Files are named `<project>_backup_YYYYMMDD_HHMMSS.sql.gz`. Cleanup only removes
matching files older than the retention threshold, using `find`'s rounded-down
24-hour age calculation. Health checks require a matching regular file less
than 24 hours old and use the configured backup directory.

## Docker example

Build the image with `docker build -t db-backup .`. The following Compose service
assumes a PostgreSQL service named `db` is available on the same network:

```yaml
services:
  backup:
    image: db-backup
    environment:
      DB_HOST: db
      DB_NAME: accounting_db
      BACKUP_PROJECT_NAME: accounting
      DB_USER: postgres
      DB_PASSWORD: ${DB_PASSWORD:?Set DB_PASSWORD}
      BACKUP_DIR: /backups
      RETENTION_DAYS: "7"
    volumes:
      - ./backups:/backups
    healthcheck:
      test: ["CMD", "/usr/local/bin/healthcheck.sh"]
      interval: 1h
      timeout: 10s
      retries: 3
```

Backups run on the daily schedule; before the first successful backup, the
health check fails. To run a backup immediately, use
`docker compose exec backup /usr/local/bin/backup.sh`.

## Restore

Run the repository's `restore.sh` in a Bash environment with `psql` and `gunzip`
installed, supplying connection variables and an explicit compressed SQL file:

```bash
DB_NAME=accounting_db DB_HOST=localhost bash restore.sh /backups/accounting_backup_20260917_020000.sql.gz
```

Restore accepts any supplied filename, regardless of `BACKUP_PROJECT_NAME`.
The Docker image currently includes only backup and health-check scripts.

## Upgrading existing installations

`DB_NAME` no longer defaults to `logibooks`; missing or empty values fail clearly.
Set `DB_NAME=logibooks` and leave `BACKUP_PROJECT_NAME` unset to preserve existing
filenames, cleanup, and health checks. Changing the project prefix leaves older
backups untouched: cleanup and health checks consider only the selected prefix.

See [support documentation](support/README.md) for downloading remote backups
to Windows.
