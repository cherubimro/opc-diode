#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Prove the SPARK core (GF(256) + Reed-Solomon) free of run-time errors.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."
gnatprove -P opc_diode.gpr --level=2 --steps=25000 --no-subprojects --report=all "$@"
