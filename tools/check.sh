#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# build + proof + in-memory core sanity + end-to-end loopback, and -- when the
# optional OPC UA backends are present -- the full adapter chain for each.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

echo "=== build (default: no DPDK, no OPC UA) ==="; gprbuild -q -P opc_diode.gpr; echo ok

echo "=== SPARK proof (expect 0 unproved) ==="
gnatprove -q -P opc_diode.gpr --level=2 --steps=25000 --no-subprojects --report=all >/dev/null
if grep -qE '(medium|high|low):' obj/gnatprove/gnatprove.out 2>/dev/null; then
  echo "UNPROVED checks remain:"; grep -E '(medium|high|low):' obj/gnatprove/gnatprove.out; exit 1
fi
echo "ok: all checks proved"

echo "=== core sanity ==="; ./bin/test_core

echo "=== end-to-end loopback (shell over UDP) ==="
./tools/loopback-test.sh >/dev/null 2>&1 && echo ok || { echo FAIL; exit 1; }

# --- optional: OPC UA adapter chains, one per available backend ---------------
# The adapters need a client/server stack built into deps/ (tools/{s2opc,
# open62541}-build.sh); if none is present we skip, leaving the proof gate above
# as the mandatory part.  The test harness itself always needs open62541.
run_opcua () {   # $1 = backend
    echo "=== OPC UA end-to-end [$1] ==="
    WITH_OPCUA="$1" ./tools/build.sh >/dev/null 2>&1
    if ./tools/opcua-test.sh "$1" >/dev/null 2>&1; then
        echo "ok"
    else
        echo "FAIL"; RC=1
    fi
}

RC=0
if [ -e deps/open62541/open62541.c ]; then
    run_opcua open62541
    [ -e deps/s2opc/lib/libs2opc_clientserver.a ] && run_opcua s2opc
else
    echo "=== OPC UA adapters: skipped (no stack in deps/; see tools/*-build.sh) ==="
fi

# restore the default (no-OPC-UA) build so the tree is left clean
gprbuild -q -P opc_diode.gpr >/dev/null 2>&1 || ./tools/build.sh >/dev/null 2>&1 || true

exit $RC
