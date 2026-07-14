#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Clone open62541 and produce the single-file amalgamation into deps/open62541,
# so `WITH_OPCUA=open62541 ./tools/build.sh` can compile+link it.  Needs cmake+python.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$here/.."
SRC="${OPEN62541_SRC:-/tmp/open62541}"
[ -d "$SRC/.git" ] || git clone --depth 1 https://github.com/open62541/open62541.git "$SRC"
git -C "$SRC" submodule update --init --recursive
cmake -S "$SRC" -B "$SRC/build" -DUA_ENABLE_AMALGAMATION=ON \
  -DUA_ENABLE_SUBSCRIPTIONS=ON -DUA_BUILD_EXAMPLES=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build" -j"$(nproc)" --target open62541-amalgamation
mkdir -p deps/open62541
cp "$SRC/build/open62541.h" "$SRC/build/open62541.c" deps/open62541/
echo "open62541 amalgamation -> deps/open62541/"
