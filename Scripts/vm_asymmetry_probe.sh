#!/bin/bash
# Compares Memory->VFO vs VFO->Memory reliability under live app traffic, and
# tries a few candidate "priming" steps before VM000 to see if any of them
# make the exit stick (mirroring the already-known MC0-before-VM011
# precondition for entry). Run with the Mac app left RUNNING.
set -e
HOST="${1:-ftx1pi}"
PORT=4532

send() {
    echo "-> $1"
    printf 'W %s; ;\n' "$1" | nc -w 2 "$HOST" "$PORT"
    echo
}

check() {
    echo "--- state check ---"
    send "VM0"
    send "FA"
}

enter_memory() {
    echo "=== Entering Memory (MC0 reassert + VM011, mirrors the app) ==="
    send "MC000001"
    send "VM011"
    sleep 1
    check
}

echo "############ TRIAL 1: bare VM000 ############"
enter_memory
echo "=== Exiting Memory (bare VM000) ==="
send "VM000"
sleep 1
check

echo
echo "############ TRIAL 2: VM000 preceded by a fresh FA read ############"
enter_memory
echo "=== Exiting Memory (FA read, then VM000) ==="
send "FA"
send "VM000"
sleep 1
check

echo
echo "############ TRIAL 3: VM000 preceded by MC0 reassert (mirrors entry's own precondition) ############"
enter_memory
echo "=== Exiting Memory (MC000001 reassert, then VM000) ==="
send "MC000001"
send "VM000"
sleep 1
check

echo
echo "############ TRIAL 4: VM000 sent twice ############"
enter_memory
echo "=== Exiting Memory (VM000 sent twice) ==="
send "VM000"
send "VM000"
sleep 1
check

echo
echo "############ TRIAL 5: re-confirm VFO->Memory still reliable ############"
enter_memory
