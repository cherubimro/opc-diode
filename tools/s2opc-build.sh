#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Clone + build Systerel S2OPC (client/server, no tests/TLS server) and install
# it under deps/s2opc, so `WITH_OPCUA=s2opc ./tools/build.sh` can link it.
# Needs: cmake, a C compiler, mbedtls-devel, libexpat-devel.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$here/.."
SRC="${S2OPC_SRC:-/tmp/S2OPC}"
[ -d "$SRC/.git" ] || git clone --depth 1 https://gitlab.com/systerel/S2OPC.git "$SRC"
export CC="${CC:-cc}"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DWITH_NANO_EXTENDED=ON -DS2OPC_CLIENTSERVER_ONLY=ON -DENABLE_TESTING=OFF \
  -DWITH_PYS2OPC=OFF -DCMAKE_INSTALL_PREFIX="$PWD/deps/s2opc"
cmake --build "$SRC/build" -j"$(nproc)" --target s2opc_clientserver
cmake --install "$SRC/build" || true
echo "S2OPC installed to $PWD/deps/s2opc"
