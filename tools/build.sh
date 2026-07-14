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
STAMP="obj/.dpdk-config"
WANT="$WITH_DPDK|${DPDK_PREFIX:-}|${DPDK_LIBS:-}"
if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
    [ -e "$STAMP" ] && echo "build.sh: DPDK config changed -> full rebuild"
    gprclean -q -P opc_diode.gpr -XWITH_DPDK="$WITH_DPDK" 2>/dev/null || true
    mkdir -p obj && printf '%s' "$WANT" > "$STAMP"
fi

gprbuild -P opc_diode.gpr -XWITH_DPDK="$WITH_DPDK" "$@"
