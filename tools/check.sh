#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# build + proof + in-memory core sanity (field axioms + RS erasure round-trip).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."
echo "=== build ==="; gprbuild -q -P opc_diode.gpr; echo ok
echo "=== SPARK proof (expect 0 unproved) ==="
gnatprove -q -P opc_diode.gpr --level=2 --report=all >/dev/null
if grep -qE '(medium|high|low):' obj/gnatprove/gnatprove.out 2>/dev/null; then
  echo "UNPROVED checks remain:"; grep -E '(medium|high|low):' obj/gnatprove/gnatprove.out; exit 1
fi
echo "ok: all checks proved"
echo "=== core sanity ==="; ./bin/test_core
