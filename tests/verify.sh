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

image=${1:-db-backup:test}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${OSTYPE:-} == msys* ]]; then
    root=$(cygpath -m "$root")
    export MSYS_NO_PATHCONV=1
fi
containers=()
cleanup() {
    result=$?
    trap - EXIT
    for container in "${containers[@]}"; do
        if (( result != 0 )); then docker logs "$container" >&2 || true; fi
        docker rm -f "$container" >/dev/null || true
    done
    exit "$result"
}
trap cleanup EXIT

# Exercise the image's real entrypoint and default CMD with an empty directory.
normal=$(docker create -e DB_NAME=test_database "$image")
containers+=("$normal")
docker start "$normal" >/dev/null
ready=false
for attempt in {1..20}; do
    if docker exec "$normal" /usr/local/bin/healthcheck.sh; then
        ready=true
        break
    fi
    sleep 0.5
done
[[ $ready == true ]]
docker stop "$normal" >/dev/null

# Bash stays alive as PID 1 while the suite starts and stops a real crond child.
suite=$(docker create --entrypoint /bin/bash "$image" /tests/container.sh)
containers+=("$suite")
docker cp "$root/tests" "$suite:/tests"
docker cp "$root/restore.sh" "$suite:/tests/restore.sh"
docker start -a "$suite"
test "$(docker inspect --format '{{.State.ExitCode}}' "$suite")" = 0
echo 'PASS: all container checks'
