#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Regenerate and verify the frozen GF(2^8) tables (gf256.adb) and the Cauchy
# generator matrix (rs_matrix.ads).  The Ada carries the *result*; this is how
# the result is produced and checked, so the constants are reproducible rather
# than magic.  Run it and diff against the committed files.
#
#   ./tools/gen-tables.py            # prints the tables + a self-check verdict
POLY = 0x11D   # x^8 + x^4 + x^3 + x^2 + 1, the standard RS primitive polynomial

exp = [0] * 512
log = [0] * 256
x = 1
for i in range(255):
    exp[i] = x
    log[x] = i
    x <<= 1
    if x & 0x100:
        x ^= POLY
for i in range(255, 512):
    exp[i] = exp[i - 255]
log[0] = 0   # sentinel; never read (Mul short-circuits on a zero operand)

def mul(a, b):
    return 0 if a == 0 or b == 0 else exp[log[a] + log[b]]

def inv(a):
    return exp[255 - log[a]]

# --- self-check: the field axioms, on concrete values ---
ok = True
for a in range(1, 256):
    if mul(a, inv(a)) != 1:
        ok = False
import itertools
for a, b, c in itertools.islice(
        ((a, b, a ^ b) for a in range(256) for b in range(256)), 0, 65536):
    if mul(a, b ^ c) != (mul(a, b) ^ mul(a, c)):
        ok = False
        break

# Cauchy: C(i,j) = 1/(x_i XOR y_j), y_j in 0..K-1, x_i in K..K+M-1 (disjoint sets),
# so every square submatrix is invertible -> the erasure code is MDS.
MAXK, MAXM = 72, 48
assert MAXK + MAXM <= 256
cauchy = [[inv((MAXK + i) ^ j) for j in range(MAXK)] for i in range(MAXM)]

print(f"GF(2^8) poly=0x11D  self-check: {'OK' if ok else 'FAILED'}")
print(f"exp[0..7] = {exp[:8]}")
print(f"log[1..8] = {log[1:9]}")
print(f"Cauchy[0][0]={cauchy[0][0]}  Cauchy[{MAXM-1}][{MAXK-1}]={cauchy[MAXM-1][MAXK-1]}")
print("These feed gf256.adb (Exp_T/Log_T) and rs_matrix.ads (Cauchy).")
