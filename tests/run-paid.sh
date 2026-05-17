#!/usr/bin/env bash
# Run every tests/test-paid-*.sh — tests that DO hit paid cloud LLM endpoints
# and incur real spend per run. Human-only. Never wired into CI or the
# autonomous agent runner.
#
# Pass --yes-i-will-pay to skip the confirm prompt (e.g., for one-off scripted
# runs you've authorized yourself).
#
# Sibling runner: tests/run-all.sh runs only the free suite and is the default
# for CI + agents.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes-i-will-pay) ASSUME_YES=1; shift ;;
        *) echo "unknown arg: $1  (valid: --yes-i-will-pay)" >&2; exit 2 ;;
    esac
done

tests=()
for t in "$SCRIPT_DIR"/test-paid-*.sh; do
    [[ -e "$t" ]] && tests+=("$t")
done

if [[ ${#tests[@]} -eq 0 ]]; then
    echo "No tests/test-paid-*.sh files exist. Nothing to do."
    exit 0
fi

echo "About to run ${#tests[@]} test(s) that call paid cloud LLM endpoints:"
for t in "${tests[@]}"; do echo "  - $(basename "$t")"; done
echo
echo "Each run will incur real spend on your configured OpenRouter / Anthropic /"
echo "Gemini accounts via LiteLLM. The free suite (tests/run-all.sh) does NOT."
echo

if [[ "$ASSUME_YES" -ne 1 ]]; then
    printf "Type 'yes' to continue: "
    read -r reply
    if [[ "$reply" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

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

printf '\nResults: %d passed, %d failed\n' "$_pass" "$_fail"
if [[ $_fail -gt 0 ]]; then
    printf 'Failed: %s\n' "${_failed[*]}"
    exit 1
fi
