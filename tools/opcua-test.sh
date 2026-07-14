#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# END-TO-END test of the OPC UA adapters on localhost, for EITHER backend:
#
#   ./tools/opcua-test.sh [open62541|s2opc]      (default: open62541)
#
#   opcua_source (server)  <--client--  od_adapter --UADP--> od_sender
#        ns=1;s=x, ++/200ms                                       |
#                                                              diode (UDP)
#                                                                 v
#   opcua_read (client) --> od_shadow (shadow server) <--UADP-- od_receiver
#
# Verifies a live value flows source -> adapter -> diode -> shadow -> subscriber.
# The product (od_adapter/od_shadow) uses the chosen stack; the test harness
# (source server + reader) is always open62541, acting as a generic OPC UA peer.
#
# Build the product for the backend under test first:
#   WITH_OPCUA=open62541 ./tools/build.sh     (or  WITH_OPCUA=s2opc ...)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

BACKEND="${1:-open62541}"
UA="deps/open62541"

# --- product build must carry the requested client stack ---
case "$BACKEND" in
  open62541) SYM=' UA_Client_connect' ;;
  s2opc)     SYM=' SOPC_ClientHelper_Connect' ;;
  *) echo "usage: $0 [open62541|s2opc]"; exit 2 ;;
esac
if [ "$(nm bin/od_adapter 2>/dev/null | grep -c "$SYM" || true)" = "0" ]; then
    echo "od_adapter is not built with $BACKEND."
    echo "  build:  WITH_OPCUA=$BACKEND ./tools/build.sh"
    exit 1
fi

# --- the test harness (source + reader) needs the open62541 amalgamation ---
if [ ! -e "$UA/open62541.o" ]; then
    if [ -e "$UA/open62541.c" ]; then
        echo "== compiling open62541 amalgamation for the test harness (once) =="
        cc -O2 -w -c "$UA/open62541.c" -I"$UA" -o "$UA/open62541.o"
    else
        echo "test harness needs open62541 (deps/open62541); run tools/open62541-build.sh"
        exit 1
    fi
fi

TMP="$(mktemp -d)"; PIDS=()
cleanup () { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP" /tmp/od-memif-* 2>/dev/null; }
trap cleanup EXIT

echo "== compile test source server + reader (open62541) =="
cc -O2 -w tests/opcua_source.c "$UA/open62541.o" -I"$UA" -lpthread -lm -o "$TMP/src"
cc -O2 -w tests/opcua_read.c   "$UA/open62541.o" -I"$UA" -lpthread -lm -o "$TMP/rd"

SRC_PORT=4841
P_IN=9781; P_DIODE=9782; P_OUT=9783
SRC_NODE="ns=1;s=x"; WID=1000

# Per-backend shadow config: open62541 creates nodes programmatically (no XML,
# same node id as the source); S2OPC is XML-configured, so we point it at the
# test data and map the writer to an existing writable node in that address space.
if [ "$BACKEND" = "s2opc" ]; then
    D="$PWD/tests/s2opc-data"
    if [ ! -e "$D/server_none.xml" ]; then
        echo "missing $D (the S2OPC server config + address space)"; exit 1
    fi
    SHADOW_ARGS=("$D/server_none.xml" "$D/addrspace.xml")
    SHADOW_NODE="ns=1;i=1003"
else
    SHADOW_ARGS=(- -)
    SHADOW_NODE="$SRC_NODE"
fi

echo "== [$BACKEND] start source server (ns=1;s=x incrementing) =="
"$TMP/src" $SRC_PORT >"$TMP/src.log" 2>&1 & PIDS+=($!)
sleep 1.5

echo "== start the chain: receiver, shadow, sender, adapter =="
./bin/od_receiver "$P_DIODE" 127.0.0.1 "$P_OUT" 2>"$TMP/rx.log" & PIDS+=($!)
./bin/od_shadow   "$P_OUT" "${SHADOW_ARGS[@]}" --node "$SHADOW_NODE" "$WID" \
    2>"$TMP/shadow.log" & PIDS+=($!)
sleep 3.0    # let the shadow server bind :4840 and (S2OPC) load its address space
./bin/od_sender   "$P_IN" 127.0.0.1 "$P_DIODE" --pace-us 100 2>"$TMP/snd.log" & PIDS+=($!)
./bin/od_adapter  "opc.tcp://127.0.0.1:$SRC_PORT" 127.0.0.1 "$P_IN" \
    --node "$SRC_NODE" "$WID" --interval 200 2>"$TMP/adapter.log" & PIDS+=($!)

echo "== let a few updates flow, then read the shadow node $SHADOW_NODE =="
sleep 4

rd_val () {
    timeout 8 "$TMP/rd" "opc.tcp://127.0.0.1:4840" "$SHADOW_NODE" 2>/dev/null \
      | grep -oE 'VALUE=[-0-9.]+' | tail -1 | cut -d= -f2
}
V1="$(rd_val)"; V1="${V1:-none}"
sleep 1.5
V2="$(rd_val)"; V2="${V2:-none}"

echo "  shadow reads: '$V1' then '$V2'"

ok=1
case "$V1" in ''|none|err|read-fail*|connect-fail|badnode|zero) ok=0 ;; esac
if [ "$ok" = 1 ] && awk "BEGIN{exit !($V1 > 0 && $V2 >= $V1)}" 2>/dev/null; then
    echo; echo ">>> OPC UA END-TO-END PASSED [$BACKEND] (value $V1 -> $V2 across the diode)"
    exit 0
fi
echo "  --- adapter log ---"; sed -n '1,4p' "$TMP/adapter.log"
echo "  --- shadow log  ---"; sed -n '1,4p' "$TMP/shadow.log"
echo; echo ">>> OPC UA END-TO-END FAILED [$BACKEND]"
exit 1
