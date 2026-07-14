#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# End-to-end test of the DPDK code path, with NO root, NO hugepages and NO NIC.
#
#   od_probe send --UDP--> od_sender --with-dpdk --memif--> od_receiver --with-dpdk --UDP--> od_probe recv
#
# The two DPDK ends are joined by DPDK's memif PMD: a shared-memory pipe on ONE
# machine.  It is a real ethdev port, so this genuinely drives EAL bring-up, the
# C shim, rte_eth_rx_burst/tx_burst and the raw-Ethernet framing -- but memif is
# NOT kernel bypass and does not cross a wire.  It needs no root precisely
# because it bypasses nothing.  Real bypass (vfio-pci) needs a spare NIC + IOMMU.
#
# Build first:  DPDK_PREFIX=... WITH_DPDK=yes ./tools/build.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

HAVE="$(nm bin/od_receiver 2>/dev/null | grep -c ' T rte_eal_init' || true)"
if [ "$HAVE" = "0" ]; then
    echo "od_receiver has no DPDK linked in."
    echo "  build it:  DPDK_PREFIX=... WITH_DPDK=yes ./tools/build.sh"
    exit 1
fi

SOCK=/tmp/opc-diode-memif.sock
TMP="$(mktemp -d)"; RX=""; SND=""; SINK=""
cleanup () { kill $RX $SND $SINK 2>/dev/null; rm -rf "$TMP" "$SOCK"; }
trap cleanup EXIT
rm -f "$SOCK"

P_IN=9781; P_OUT=9782
COUNT=${COUNT:-30}; SEED=${SEED:-909}; MAXLEN=${MAXLEN:-6000}

# receiver = memif server (creates the socket); sender = memif client (waits).
EAL_RX="--no-huge --file-prefix=odrx -l 0 --vdev=net_memif0,role=server,socket=$SOCK,socket-abstract=no"
EAL_TX="--no-huge --file-prefix=odtx -l 1 --vdev=net_memif0,role=client,socket=$SOCK,socket-abstract=no"

echo "== 1. receiver up on a DPDK port (memif server) =="
./bin/od_receiver 0 127.0.0.1 "$P_OUT" --with-dpdk --eal "$EAL_RX" >"$TMP/rx.log" 2>&1 & RX=$!
for _ in $(seq 1 60); do grep -q 'via DPDK' "$TMP/rx.log" 2>/dev/null && break; sleep 0.25; done
if [ -S "$SOCK" ] && kill -0 "$RX" 2>/dev/null; then
    echo "  PASS  receiver up, memif socket listening"
else
    echo "  FAIL  receiver did not come up"; sed -n '1,20p' "$TMP/rx.log"; exit 1
fi

echo "== 2. sender up (memif client), then transfer over the bypass path =="
./bin/od_sender "$P_IN" 0 0 --with-dpdk --eal "$EAL_TX" --pace-us 200 >"$TMP/snd.log" 2>&1 & SND=$!
sleep 1.5     # let memif link establish

./bin/od_probe recv "$P_OUT" "$COUNT" "$SEED" "$MAXLEN" >"$TMP/sink.out" 2>&1 & SINK=$!
sleep 0.3
./bin/od_probe send 127.0.0.1 "$P_IN" "$COUNT" "$SEED" "$MAXLEN"

wait $SINK 2>/dev/null; RC=$?
GOT="$(grep -oE 'recovered [0-9]+' "$TMP/sink.out" | awk '{print $2}')"; GOT="${GOT:-0}"
if [ "$RC" = 0 ] && [ "$GOT" = "$COUNT" ]; then
    echo "  PASS  $GOT/$COUNT NetworkMessages byte-identical over the DPDK path"
else
    echo "  FAIL  $GOT/$COUNT (rc=$RC)"; sed -n '1,20p' "$TMP/rx.log"; sed -n '1,10p' "$TMP/snd.log"
    exit 1
fi

echo
echo ">>> DPDK CODE PATH TEST PASSED"
echo "    (over memif: shared memory, one machine.  NOT kernel bypass -- see the"
echo "     header of this script and docs/ASSURANCE.md before quoting it as one.)"
