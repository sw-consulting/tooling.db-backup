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

set -euo pipefail
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2' ERR

backup=/usr/local/bin/backup.sh
health=/usr/local/bin/healthcheck.sh
work=$(mktemp -d)
chmod 755 "$work"
cron_pid=
cleanup() {
    if [[ -n $cron_pid ]]; then
        kill -CONT "$cron_pid" 2>/dev/null || true
        kill "$cron_pid" 2>/dev/null || true
        wait "$cron_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

expect_failure() {
    local message=$1
    shift
    if "$@" >"$work/error" 2>&1; then
        echo "Expected failure: $*" >&2
        exit 1
    fi
    if ! grep -Fq "$message" "$work/error"; then
        cat "$work/error" >&2
        echo "Expected diagnostic: $message" >&2
        exit 1
    fi
}

dos2unix /tests/*.sh
for script in "$backup" "$health" /tests/*.sh; do bash -n "$script"; done
mkdir "$work/bin"
cat > "$work/bin/pg_dump" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$CALL_LOG"
while (( $# )); do
    if [[ $1 == -f ]]; then printf 'SELECT 1;\n' > "$2"; exit 0; fi
    shift
done
exit 1
STUB
cat > "$work/bin/psql" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$CALL_LOG"
cat > "$RESTORED_SQL"
STUB
chmod +x "$work/bin/pg_dump" "$work/bin/psql"
export PATH="$work/bin:$PATH" CALL_LOG="$work/calls" RESTORED_SQL="$work/restored"
export DB_NAME=test_database BACKUP_DIR="$work/backups"
unset BACKUP_PROJECT_NAME DB_PORT RETENTION_DAYS

"$backup" --check-config
test ! -e "$BACKUP_DIR"
test ! -e "$CALL_LOG"
for port in 1 65535 05432; do DB_PORT=$port "$backup" --check-config; done
BACKUP_PROJECT_NAME=project-1.2_test "$backup" --check-config
BACKUP_PROJECT_NAME= "$backup" --check-config
RETENTION_DAYS=0 "$backup" --check-config
RETENTION_DAYS=2147483647 "$backup" --check-config
RETENTION_DAYS=00000000000000000007 "$backup" --check-config
expect_failure 'Usage:' "$backup" --unknown
expect_failure 'Usage:' "$backup" --check-config extra

# Both validation-only and actual backup reject bad configuration before writes.
for mode in check backup; do
    args=()
    if [[ $mode == check ]]; then args=(--check-config); fi
    expect_failure DB_NAME env -u DB_NAME "$backup" "${args[@]}"
    expect_failure DB_NAME env DB_NAME= "$backup" "${args[@]}"
    for prefix in '../bad' 'bad*' 'bad name' 'bad[abc]' 'bad/name'; do
        expect_failure BACKUP_PROJECT_NAME env BACKUP_PROJECT_NAME="$prefix" "$backup" "${args[@]}"
    done
    for port in 0 65536 -1 1.5 abc 999999999999999999999999; do
        expect_failure DB_PORT env DB_PORT="$port" "$backup" "${args[@]}"
    done
    for days in -1 abc 1.5 2147483648 999999999999999999999999; do
        expect_failure RETENTION_DAYS env RETENTION_DAYS="$days" "$backup" "${args[@]}"
    done
    test ! -e "$BACKUP_DIR"
    test ! -e "$CALL_LOG"
done
DB_NAME='database with spaces' BACKUP_PROJECT_NAME=safe "$backup" --check-config
expect_failure BACKUP_PROJECT_NAME env DB_NAME='database with spaces' "$backup" --check-config

touch "$work/file"
for path in "$work/file" "$work/file/child"; do
    expect_failure BACKUP_DIR env BACKUP_DIR="$path" "$backup" --check-config
done
ln -s "$work/absent" "$work/dangling"
expect_failure BACKUP_DIR env BACKUP_DIR="$work/dangling" "$backup" --check-config

# Real Unix permissions, using the image's unprivileged postgres account.
mkdir "$work/writable" "$work/locked" "$work/no-search"
chmod 777 "$work/writable"
chmod 555 "$work/locked"
chmod 666 "$work/no-search"
for path in "$work/writable" "$work/writable/new/nested"; do
    gosu postgres env BACKUP_DIR="$path" "$backup" --check-config
done
test ! -e "$work/writable/new"
for path in "$work/locked" "$work/locked/child" "$work/no-search"; do
    expect_failure BACKUP_DIR gosu postgres env BACKUP_DIR="$path" "$backup" --check-config
done

# Resolve traversal after missing components and after existing symlinks.
mkdir "$work/writable/locked" "$work/physical"
chmod 555 "$work/writable/locked"
ln -s "$work/writable/locked" "$work/physical/link"
for path in "$work/writable/missing/../locked/child" "$work/physical/link/../locked/child"; do
    expect_failure BACKUP_DIR gosu postgres env BACKUP_DIR="$path" "$backup" --check-config
done
test ! -e "$work/writable/missing"
test ! -e "$work/writable/locked/child"
gosu postgres env BACKUP_DIR="$work/physical/link/../valid" "$backup" --check-config
gosu postgres env BACKUP_DIR="$work/writable/missing/../valid" "$backup" --check-config
test ! -e "$work/writable/valid"

expect_failure 'crond is not running' "$health"
crond -f &
cron_pid=$!
ready=false
for attempt in {1..20}; do
    if "$health" > "$work/health-output" 2>&1; then ready=true; break; fi
    sleep 0.1
done
[[ $ready == true ]]
grep -qx healthy "$work/health-output"
kill -STOP "$cron_pid"
stopped=false
for attempt in {1..20}; do
    if grep -q '^State:.*T' "/proc/$cron_pid/status"; then stopped=true; break; fi
    sleep 0.1
done
[[ $stopped == true ]]
expect_failure 'crond is not running' "$health"
kill -CONT "$cron_pid"
ready=false
for attempt in {1..20}; do
    if "$health" > "$work/health-output" 2>&1; then ready=true; break; fi
    sleep 0.1
done
[[ $ready == true ]]
test ! -e "$BACKUP_DIR"
mkdir "$BACKUP_DIR"
"$health"
touch -t 200001010000 "$BACKUP_DIR/test_database_backup_old.sql.gz"
"$health"
expect_failure DB_NAME env DB_NAME= "$health"
expect_failure RETENTION_DAYS env RETENTION_DAYS=-1 "$health"
test ! -e "$CALL_LOG"

mkdir "$work/scripts"
cp "$health" "$work/scripts/healthcheck.sh"
expect_failure 'readable, executable' "$work/scripts/healthcheck.sh"
cp "$backup" "$work/scripts/backup.sh"
chmod -x "$work/scripts/backup.sh"
expect_failure 'readable, executable' "$work/scripts/healthcheck.sh"
chmod +x "$work/scripts/backup.sh"
printf '\nif then\n' >> "$work/scripts/backup.sh"
expect_failure 'invalid Bash syntax' "$work/scripts/healthcheck.sh"

# A restricted PATH removes each dependency without changing the image.
for missing in mkdir date timeout pg_dump gzip find; do
    isolated="$work/path-$missing"
    mkdir "$isolated"
    for command_name in bash dirname mkdir date timeout pg_dump gzip find; do
        if [[ $command_name != "$missing" ]]; then
            ln -s "$(command -v "$command_name")" "$isolated/$command_name"
        fi
    done
    expect_failure "required command unavailable: $missing" env PATH="$isolated" "$health"
done

kill "$cron_pid"
wait "$cron_pid" || true
cron_pid=
touch "$BACKUP_DIR/test_database_backup_recent.sql.gz"
expect_failure 'crond is not running' "$health"
crond -f &
cron_pid=$!
ready=false
for attempt in {1..20}; do
    if "$health" > "$work/health-output" 2>&1; then ready=true; break; fi
    sleep 0.1
done
[[ $ready == true ]]

export BACKUP_PROJECT_NAME=project RETENTION_DAYS=7
touch -t 200001010000 "$BACKUP_DIR/project_backup_old.sql.gz" "$BACKUP_DIR/other_backup_old.sql.gz"
touch "$BACKUP_DIR/project_backup_recent.sql.gz"
"$backup"
test ! -e "$BACKUP_DIR/project_backup_old.sql.gz"
test -e "$BACKUP_DIR/other_backup_old.sql.gz"
test -e "$BACKUP_DIR/project_backup_recent.sql.gz"
grep -qx test_database "$CALL_LOG"
files=("$BACKUP_DIR"/project_backup_20*.sql.gz)
test "${#files[@]}" = 1
gzip -cd "${files[0]}" | grep -qx 'SELECT 1;'
saved_backup=${files[0]}
RETENTION_DAYS=2147483647 BACKUP_DIR="$work/max-retention" "$backup"
touch -t 200001010000 "$work/max-retention/project_backup_old.sql.gz"
test -z "$(find "$work/max-retention" -type f -mtime +2147483647 -print)"
for prefix in unset empty; do
    export BACKUP_DIR="$work/$prefix"
    if [[ $prefix == unset ]]; then unset BACKUP_PROJECT_NAME; else export BACKUP_PROJECT_NAME=; fi
    "$backup"
    files=("$BACKUP_DIR"/test_database_backup_20*.sql.gz)
    test -f "${files[0]}"
done
DB_NAME=restore_target BACKUP_PROJECT_NAME='ignored*' bash /tests/restore.sh "$saved_backup"
grep -qx restore_target "$CALL_LOG"
grep -qx 'SELECT 1;' "$RESTORED_SQL"
echo 'PASS: configuration, permissions, cron, dependencies, backup and restore'
