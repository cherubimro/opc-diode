#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# End-to-end loopback for the OPC diode shell, all on localhost:
#
#   od_probe send  --> [P_IN] od_sender --UDP diode--> [P_DIODE] od_receiver --> [P_OUT] od_probe recv
#
# Verifies that synthetic UADP NetworkMessages survive protect + one-way
# transport + erasure-recover + dedup and arrive byte-identical.  No packet loss
# is injected here (that is the RS unit test's job); this proves the wiring.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

gprbuild -q -P opc_diode.gpr >/dev/null

P_IN=9701; P_DIODE=9702; P_OUT=9703
COUNT=${COUNT:-40}; SEED=${SEED:-777}; MAXLEN=${MAXLEN:-6000}
TMP="$(mktemp -d)"; trap 'kill $RX $SND $SINK 2>/dev/null; rm -rf "$TMP"' EXIT

./bin/od_receiver "$P_DIODE" 127.0.0.1 "$P_OUT" 2>"$TMP/rx.log" & RX=$!
./bin/od_sender   "$P_IN" 127.0.0.1 "$P_DIODE" --parity 3 --pace-us 200 \
    2>"$TMP/snd.log" & SND=$!
sleep 0.5

# Start the sink first (it blocks on receive), then inject.
./bin/od_probe recv "$P_OUT" "$COUNT" "$SEED" "$MAXLEN" >"$TMP/sink.out" 2>&1 & SINK=$!
sleep 0.3
./bin/od_probe send 127.0.0.1 "$P_IN" "$COUNT" "$SEED" "$MAXLEN"

wait $SINK; RC=$?
echo "----- sink -----"; cat "$TMP/sink.out"
exit $RC
