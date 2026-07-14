#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# First END-TO-END test of the OPC UA adapters, all on localhost with open62541:
#
#   opcua_source (server)  <--client--  od_adapter --UADP--> od_sender
#        ns=1;s=x, ++/200ms                                       |
#                                                              diode (UDP)
#                                                                 v
#   opcua_read (client) --> od_shadow (shadow server) <--UADP-- od_receiver
#
# Verifies a live value flows source -> adapter -> diode -> shadow -> subscriber.
# Requires a DPDK-free open62541 build:  WITH_OPCUA=open62541 ./tools/build.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

UA="deps/open62541"
#  grep -c, not -q: under pipefail, grep -q exits early, nm takes SIGPIPE, and
#  the pipeline reports absent exactly when the symbol IS present.
HAVE="$(nm bin/od_adapter 2>/dev/null | grep -c ' UA_Client_connect' || true)"
if [ "$HAVE" = "0" ]; then
    echo "od_adapter has no open62541 linked in."
    echo "  build:  WITH_OPCUA=open62541 ./tools/build.sh"
    exit 1
fi

TMP="$(mktemp -d)"; PIDS=()
cleanup () { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

echo "== compile test source server + reader (open62541) =="
cc -O2 -w tests/opcua_source.c "$UA/open62541.o" -I"$UA" -lpthread -lm -o "$TMP/src"
cc -O2 -w tests/opcua_read.c   "$UA/open62541.o" -I"$UA" -lpthread -lm -o "$TMP/rd"

SRC_PORT=4841; SHADOW_PORT=4842
P_IN=9781; P_DIODE=9782; P_OUT=9783
NODE="ns=1;s=x"; WID=1000

echo "== start source server (ns=1;s=x incrementing) =="
"$TMP/src" $SRC_PORT >"$TMP/src.log" 2>&1 & PIDS+=($!)
sleep 1.5

echo "== start the chain: receiver, shadow, sender, adapter =="
./bin/od_receiver "$P_DIODE" 127.0.0.1 "$P_OUT" 2>"$TMP/rx.log" & PIDS+=($!)
./bin/od_shadow   "$P_OUT" - - --node "$NODE" "$WID" 2>"$TMP/shadow.log" & PIDS+=($!)
sleep 1.0    # let the shadow server bind :4840 and create the node
./bin/od_sender   "$P_IN" 127.0.0.1 "$P_DIODE" --pace-us 100 2>"$TMP/snd.log" & PIDS+=($!)
./bin/od_adapter  "opc.tcp://127.0.0.1:$SRC_PORT" 127.0.0.1 "$P_IN" \
    --node "$NODE" "$WID" --interval 200 2>"$TMP/adapter.log" & PIDS+=($!)

echo "== let a few updates flow, then read the shadow server =="
sleep 4

# od_shadow's open62541 server listens on the default :4840.  Grep the clean
# VALUE= marker out of open62541's chatty stdout logging.
rd_val () {
    timeout 8 "$TMP/rd" "opc.tcp://127.0.0.1:4840" "$NODE" 2>/dev/null \
      | grep -oE 'VALUE=[-0-9.]+' | tail -1 | cut -d= -f2
}
V1="$(rd_val)"; V1="${V1:-none}"
sleep 1.5
V2="$(rd_val)"; V2="${V2:-none}"

echo "  shadow reads: '$V1' then '$V2'"
echo "  --- adapter log ---"; sed -n '1,4p' "$TMP/adapter.log"
echo "  --- shadow log  ---"; sed -n '1,4p' "$TMP/shadow.log"

ok=1
case "$V1" in ''|err|read-fail*|connect-fail|badnode) ok=0;; esac
# a non-zero, advancing value proves the live flow
if [ "$ok" = 1 ] && awk "BEGIN{exit !($V1 > 0)}" 2>/dev/null; then
    if awk "BEGIN{exit !($V2 >= $V1)}" 2>/dev/null; then
        echo; echo ">>> OPC UA END-TO-END PASSED (value $V1 -> $V2 across the diode)"
        exit 0
    fi
fi
echo; echo ">>> OPC UA END-TO-END FAILED"
exit 1
