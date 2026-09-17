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

set -e

fail() {
    echo "Unhealthy: $*" >&2
    exit 1
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backup_script="$script_dir/backup.sh"
[[ -f $backup_script && -r $backup_script && -x $backup_script ]] ||
    fail "backup.sh must be a readable, executable file"
bash -n "$backup_script" || fail "backup.sh has invalid Bash syntax"
bash "$backup_script" --check-config || fail "invalid backup configuration"

for command_name in mkdir date timeout pg_dump gzip find; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command unavailable: $command_name"
done

# Inspect process names, not command lines; cron need not be PID 1.
for status_file in /proc/[0-9]*/status; do
    process_name= process_state=
    # A process can exit while /proc is being inspected.
    if ! {
        while IFS=$'\t' read -r key value; do
            case $key in
                Name:) process_name=$value ;;
                State:) process_state=${value:0:1} ;;
            esac
        done < "$status_file"
    } 2>/dev/null; then
        continue
    fi
    if [[ $process_name == crond && -n $process_state && $process_state != Z && $process_state != X && $process_state != x && $process_state != T && $process_state != t ]]; then
        echo healthy
        exit 0
    fi
done
fail "crond is not running"
