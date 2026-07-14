#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# End-to-end loopback for the OPC diode shell, all on localhost:
#
#   od_probe send --> [P_IN] od_sender --UDP diode--> [P_DIODE] od_receiver --> [P_OUT] od_probe recv
#
# Three passes:
#   1. cleartext           -- messages arrive byte-identical
#   2. encrypted           -- same, with ChaCha20-Poly1305 on the wire
#   3. encrypted, wrong key -- receiver must recover NOTHING (tag rejects all)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

gprbuild -q -P opc_diode.gpr >/dev/null

COUNT=${COUNT:-40}; SEED=${SEED:-777}; MAXLEN=${MAXLEN:-6000}
KEY_A=$(printf '%064x' 305419896)      # 0x...12345678
KEY_B=$(printf '%064x' 2596069104)     # different key
FAILS=0

PORT_BASE=9740
run_pass () {   # $1=label $2=snd_key_args $3=rcv_key_args $4=expect $5=extra_snd_args
    local label="$1" sk="$2" rk="$3" expect="$4" extra="${5:-}"
    local pin=$PORT_BASE pd=$((PORT_BASE+1)) po=$((PORT_BASE+2))
    PORT_BASE=$((PORT_BASE+10))
    local tmp; tmp="$(mktemp -d)"
    ./bin/od_receiver "$pd" 127.0.0.1 "$po" $rk 2>"$tmp/rx.log" & local rx=$!
    ./bin/od_sender   "$pin" 127.0.0.1 "$pd" --parity 3 --pace-us 200 $extra $sk \
        2>"$tmp/snd.log" & local snd=$!
    sleep 0.5
    ./bin/od_probe recv "$po" "$COUNT" "$SEED" "$MAXLEN" >"$tmp/sink.out" 2>&1 & local sink=$!
    sleep 0.3
    ./bin/od_probe send 127.0.0.1 "$pin" "$COUNT" "$SEED" "$MAXLEN"
    wait "$sink" 2>/dev/null; local rc=$?
    kill "$rx" "$snd" 2>/dev/null; wait "$rx" "$snd" 2>/dev/null

    local got; got="$(grep -oE 'recovered [0-9]+' "$tmp/sink.out" | awk '{print $2}')"
    got="${got:-0}"
    if [ "$expect" = all ]; then
        if [ "$rc" = 0 ] && [ "$got" = "$COUNT" ]; then
            echo "  PASS  $label: $got/$COUNT byte-identical"
        else echo "  FAIL  $label: $got/$COUNT (rc=$rc)"; FAILS=$((FAILS+1)); fi
    else
        if [ "$got" = 0 ]; then
            echo "  PASS  $label: recovered nothing (tag rejected all)"
        else echo "  FAIL  $label: leaked $got messages"; FAILS=$((FAILS+1)); fi
    fi
    rm -rf "$tmp"
}

echo "== OPC diode loopback =="
run_pass "cleartext"            ""              ""              all
run_pass "encrypted"           "--key $KEY_A"  "--key $KEY_A"  all
run_pass "encrypted wrong key" "--key $KEY_A"  "--key $KEY_B"  none
run_pass "encrypted+interleave" "--key $KEY_A" "--key $KEY_A"  all  "--interleave 4"

echo
if [ "$FAILS" = 0 ]; then echo ">>> LOOPBACK OK"; else echo ">>> $FAILS PASS(ES) FAILED"; exit 1; fi
