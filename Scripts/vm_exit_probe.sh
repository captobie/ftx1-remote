#!/bin/bash
# Probes whether a bare "VM000;" (exit Memory mode) actually restores VFO A's
# frequency, or whether the front panel's V/M button does something more.
# Bypasses the app entirely -- talks straight to rigctld's raw-CAT passthrough.
set -e
HOST="${1:-ftx1pi}"
PORT=4532

send() {
    echo "-> $1"
    printf 'W %s; ;\n' "$1" | nc -w 2 "$HOST" "$PORT"
}

echo "=== Confirm currently in Memory mode ==="
send "VM0"
send "FA"

echo
echo "=== Exit Memory mode (bare VM000, same as the app sends) ==="
send "VM000"
sleep 1
echo "--- immediately after ---"
send "VM0"
send "FA"

echo
echo "--- 5 seconds later (rule out a longer settle time) ---"
sleep 5
send "VM0"
send "FA"
