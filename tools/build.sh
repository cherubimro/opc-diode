#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build the project and run the core sanity driver.
#
#   ./tools/build.sh                  # default: kernel/UDP transport, no DPDK
#   WITH_DPDK=yes ./tools/build.sh    # + the DPDK poll-mode backend
#
# The DPDK build needs libdpdk via pkg-config.  DPDK_PREFIX points at a local
# install (the gnat-lt-pro vendored one by default); on Debian/Ubuntu just
# `apt install libdpdk-dev` and leave DPDK_PREFIX unset.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

WITH_DPDK="${WITH_DPDK:-no}"
WITH_OPCUA="${WITH_OPCUA:-none}"

if [ "$WITH_OPCUA" = "s2opc" ]; then
    S2="${S2OPC_PREFIX:-$PWD/deps/s2opc}"
    if [ ! -e "$S2/lib/libs2opc_clientserver.a" ]; then
        echo "build.sh: S2OPC not found at $S2 (set S2OPC_PREFIX=...)." >&2
        exit 1
    fi
    OPCUA_CFLAGS="-I$S2/include/s2opc/common -I$S2/include/s2opc/clientserver -I$S2/include/s2opc"
    #  clientserver before common (link order); + mbedtls, expat, pthreads.
    OPCUA_LIBS="$S2/lib/libs2opc_clientserver.a $S2/lib/libs2opc_common.a -lmbedtls -lmbedx509 -lmbedcrypto -lexpat -lpthread -lrt -lm"
    export OPCUA_CFLAGS OPCUA_LIBS
    echo "build.sh: OPC UA adapter ON (S2OPC, $S2)"
elif [ "$WITH_OPCUA" = "open62541" ]; then
    echo "build.sh: WITH_OPCUA=open62541 not yet wired" >&2; exit 1
fi

if [ "$WITH_DPDK" = "yes" ]; then
    DPDK_PREFIX="${DPDK_PREFIX:-$HOME/code/dpdk/deps/dpdk-install-nic}"
    export PKG_CONFIG_PATH="$DPDK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    if ! pkg-config --exists libdpdk; then
        echo "build.sh: libdpdk not found via pkg-config." >&2
        echo "  looked in: $DPDK_PREFIX/lib/pkgconfig" >&2
        echo "  set DPDK_PREFIX=/path/to/dpdk-install, or install libdpdk-dev." >&2
        exit 1
    fi
    #  --static is load-bearing: it emits --whole-archive, without which the
    #  PMD constructors never self-register and the app sees zero ports.
    DPDK_CFLAGS="$(pkg-config --cflags libdpdk)"
    DPDK_LIBS="$(pkg-config --static --libs libdpdk)"
    export DPDK_CFLAGS DPDK_LIBS
    echo "build.sh: DPDK backend ON (libdpdk $(pkg-config --modversion libdpdk), $DPDK_PREFIX)"
fi

#  gprbuild tracks Ada sources, not the value of an external.  Switching
#  WITH_DPDK or DPDK_PREFIX changes only DPDK_LIBS, so gprbuild would keep the
#  old link and silently produce a binary lacking the driver.  Stamp the config
#  and force a clean when it moves.
STAMP="obj/.build-config"
WANT="$WITH_DPDK|$WITH_OPCUA|${DPDK_PREFIX:-}|${DPDK_LIBS:-}|${OPCUA_LIBS:-}"
if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
    [ -e "$STAMP" ] && echo "build.sh: build config changed -> full rebuild"
    gprclean -q -P opc_diode.gpr -XWITH_DPDK="$WITH_DPDK" -XWITH_OPCUA="$WITH_OPCUA" 2>/dev/null || true
    mkdir -p obj && printf '%s' "$WANT" > "$STAMP"
fi

gprbuild -P opc_diode.gpr -XWITH_DPDK="$WITH_DPDK" -XWITH_OPCUA="$WITH_OPCUA" "$@"
