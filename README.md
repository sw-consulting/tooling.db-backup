# PostgreSQL database backups

Creates compressed SQL backups daily at 02:00 in the container's timezone.
The image uses `tini` as PID 1 so `crond` can initialize its process group.

## Configuration

Pass configuration as environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DB_NAME` | Required | Database to back up or restore; also required for health checks. |
| `BACKUP_PROJECT_NAME` | `DB_NAME` | Backup filename prefix; unset or empty values use `DB_NAME`. |
| `DB_HOST` | `db` | PostgreSQL host. |
| `DB_PORT` | `5432` | PostgreSQL port, an integer from 1 to 65535. |
| `DB_USER` | `postgres` | PostgreSQL user. |
| `DB_PASSWORD` | `postgres` | PostgreSQL password. |
| `BACKUP_DIR` | `/backups` | Backup output directory; access is checked during validation. |
| `RETENTION_DAYS` | `7` | Integer from 0 to 2147483647, passed to `find -mtime +N`. |

The project prefix accepts only ASCII letters, digits, dots, underscores, and
hyphens. For database names containing other characters, set an explicit safe
`BACKUP_PROJECT_NAME`. Invalid prefixes fail before backup filesystem operations.

Files are named `<project>_backup_YYYYMMDD_HHMMSS.sql.gz`. Cleanup only removes
matching files older than the retention threshold, using `find`'s rounded-down
24-hour age calculation.

## Readiness checks

`backup.sh --check-config` validates configuration and backup-directory access
without creating files or connecting to PostgreSQL. Normal backups perform the
same validation before any side effects. If the directory does not exist,
each necessary ancestor must allow directory creation. Path components are
checked in filesystem order, resolving existing symlinks before `..`.

`healthcheck.sh` checks that the sibling backup script is readable, executable,
and syntactically valid, validates configuration, checks required backup commands,
and verifies that a live, non-suspended `crond` process exists. It prints `healthy`
and exits 0 on success, or reports an error and exits 1 on failure.

Health means local readiness and a running scheduler. It does not check database
connectivity or certify that backups have succeeded. Backup-file existence and
age do not affect health; a container can be healthy before its first backup.

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

Backups run on the daily schedule. To run a backup immediately, use
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
filenames and cleanup. Changing the project prefix leaves older backups
untouched: cleanup considers only the selected prefix.

## Verification

The `ci` GitHub Actions workflow runs on pushes to `main`, pull requests, and
manual dispatch. It builds the image and exercises configuration, directory
permissions, real cron start/stop behavior, and backup/restore with stubbed
PostgreSQL commands. It needs no database credentials and does not publish images.

Run the same checks locally with Bash and a running Linux Docker engine:

```bash
docker build -t db-backup:test .
bash tests/verify.sh db-backup:test
```

The harness removes its test containers on exit and prints container logs on
failure. The publication workflow remains independent of CI.

See [support documentation](support/README.md) for downloading remote backups
to Windows.
