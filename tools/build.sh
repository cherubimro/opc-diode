#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build the project and run the core sanity driver.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."
gprbuild -P opc_diode.gpr "$@"
