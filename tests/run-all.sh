#!/usr/bin/env bash
# Run every test-*.sh in this directory. Exit 0 only when all pass.
#
# --retry N   Re-run the suite up to N times (max 3) with 30s backoff between
#             attempts. Use this when Argo sync timing could cause false failures.
#             Example: tests/run-all.sh --retry 3

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAX_RETRIES=0
RETRY_WAIT=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --retry)
            r="${2:-1}"
            MAX_RETRIES=$(( r > 3 ? 3 : r ))
            shift 2
            ;;
        *)
            echo "unknown arg: $1  (valid: --retry N)" >&2
            exit 2
            ;;
    esac
done

tests=("$SCRIPT_DIR"/test-*.sh)

_pass=0
_fail=0
_failed=()

run_suite() {
    _pass=0
    _fail=0
    _failed=()
    for t in "${tests[@]}"; do
        name=$(basename "$t" .sh)
        if bash "$t"; then
            _pass=$(( _pass + 1 ))
        else
            _fail=$(( _fail + 1 ))
            _failed+=("$name")
        fi
    done
}

run_suite

attempt=1
while [[ $_fail -gt 0 && $attempt -le $MAX_RETRIES ]]; do
    printf '\n--- retry %d/%d (waiting %ds for cluster sync) ---\n' \
        "$attempt" "$MAX_RETRIES" "$RETRY_WAIT"
    sleep "$RETRY_WAIT"
    run_suite
    attempt=$(( attempt + 1 ))
done

printf '\nResults: %d passed, %d failed\n' "$_pass" "$_fail"
if [[ $_fail -gt 0 ]]; then
    printf 'Failed: %s\n' "${_failed[*]}"
    exit 1
fi
