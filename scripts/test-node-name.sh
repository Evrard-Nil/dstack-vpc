#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/functions.sh"

assert_equals() {
    local expected=$1
    local actual=$2
    local description=$3

    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $description: got '$actual', want '$expected'" >&2
        exit 1
    fi
}

first=$(node_name_for_instance "postgres-staging" "E4A69B577791AF04AAC3B2BFF92308BFBDC6E020")
second=$(node_name_for_instance "postgres-staging" "0404DBBB914152AEA3CF7D4FD27F589A86D59D7B")

assert_equals "postgres-staging-e4a69b577791" "$first" "name includes a stable instance suffix"
assert_equals "postgres-staging-0404dbbb9141" "$second" "different instances get different names"
assert_equals "$first" "$(node_name_for_instance "postgres-staging" "E4A69B577791AF04AAC3B2BFF92308BFBDC6E020")" "same instance keeps the same name"
assert_equals "my-db-replica-e4a69b577791" "$(node_name_for_instance "My DB_Replica" "E4A69B577791AF04")" "name is DNS-label safe"
assert_equals "node-e4a69b577791" "$(node_name_for_instance "---" "E4A69B577791AF04")" "empty normalized base uses the node fallback"

long_name=$(node_name_for_instance "this-is-an-intentionally-long-postgres-staging-replica-name-that-must-be-truncated" "E4A69B577791AF04")
if [ "${#long_name}" -ne 63 ]; then
    echo "FAIL: long name has ${#long_name} characters, want exactly 63" >&2
    exit 1
fi
case "$long_name" in
    *-e4a69b577791) ;;
    *)
        echo "FAIL: long name lost its stable instance suffix: '$long_name'" >&2
        exit 1
        ;;
esac

if node_name_for_instance "postgres-staging" "" >/dev/null 2>&1; then
    echo "FAIL: empty instance ID unexpectedly produced a node name" >&2
    exit 1
fi

echo "PASS: deterministic per-instance node names"
