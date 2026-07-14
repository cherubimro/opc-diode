# opc-diode

**A high-assurance Ada/SPARK OPC UA PubSub data-diode relay** — a clean-slate rewrite of the ideas in
[opcua-data-diode](https://github.com/cherubimro/opcua-data-diode), aimed at *formal proof* of the
reconstruction path rather than parity with the Python original.

> Status: **Phase 3 proven core complete.** GF(2⁸), Reed-Solomon, the UADP header parser, the diode
> framing, and the **relay logic** (protect + erasure-recover + dedup) are all proved free of run-time
> errors by `gnatprove`: **316 checks, 0 unproved, 0 justified**, with an end-to-end round-trip test
> (NetworkMessage → protect → drop up to M packets → recover byte-identical, plus dedup). The remaining
> piece is the trusted UDP shell (sockets + scheduler).

## Why this design, and how it differs from the Python original

The source high-security network **publishes OPC UA PubSub natively** (UADP encoding over UDP). That
one fact removes the hardest part: PubSub is connectionless and one-way by construction, so **there
is no OPC UA stack anywhere in this project** — no client, no shadow server, no `asyncua`/`open62541`
in the trusted computing base. We are a *relay*, not a translator:

- parse only the **UADP header** — enough to read the `SequenceNumber` (dedup) and the publisher /
  writer ids (routing);
- treat each `DataSetMessage` as an **opaque, verbatim payload** and re-emit it byte-identical.

Because we never interpret payloads, we cannot corrupt their meaning. The whole data path can live in
the proven SPARK core.

Two deliberate departures from the Python version, both about *not corrupting a one-way stream*:

- **No JSON, no decompression on the receive path.** The Python receiver does
  `decrypt → decompress(zlib/lz4) → json.loads` on untrusted bytes — a large dynamic attack surface
  (decompression bombs, a JSON parser). We replace it with a fixed binary framing, parsed by proven
  code (the `lt_wire` discipline from gnat-lt-pro).
- **Forward error correction, which the Python version lacks entirely.** It sends JSON in UDP
  datagrams up to 60 000 bytes, so a single lost IP fragment destroys a whole 60 KB update — with no
  retransmission on a diode. Loss is handled here, sized to the message (see below).

## The FEC ladder — protection sized to the payload

| Payload | Scheme | Why |
|---|---|---|
| **1 packet** (typical DataSetMessage) | interleaved **repetition** ×R, dedup on `SequenceNumber` | cheapest; interleaving spreads copies in time so a burst can't take all of them |
| **2 … 32 packets** (medium messages) | **Reed-Solomon over GF(2⁸)** — this module | MDS: *any* K of K+M fragments reconstruct exactly. Optimal at small K, where a fountain code wastes overhead |
| **bulk** (structure dumps) | **LT fountain** (reuse gnat-lt-pro) | efficient only at large K |

Reed-Solomon owns the middle rung and is what Phase 0+1 delivers.

## The proven core (`src/core/`)

| Unit | Purpose |
|---|---|
| `gf256` | GF(2⁸) arithmetic, primitive polynomial `0x11D`. Frozen log/antilog tables; the doubled antilog makes `Mul`'s index provably in-range with no check |
| `rs_matrix` | The frozen Cauchy generator matrix — every square submatrix invertible, which is *why* the code is MDS |
| `rs` | Systematic RS: `Encode` (Cauchy matrix-vector) and `Decode` (Gauss-Jordan inversion over GF(2⁸)). `Decode` fails only if fewer than K fragments survive |
| `uadp` | Proven parser of the UADP NetworkMessage header (Part 14 §7.2.4, Part 6 little-endian). A bounded cursor extracts the `SequenceNumber` (dedup) and PublisherId / WriterGroupId / DataSetWriterIds (routing); a truncated or malformed message yields `Valid => False`, never an out-of-bounds read. Payloads are left opaque |
| `wire_types` | The one shared byte/scalar type (`U8`..`U64`), so a datagram is field elements or protocol bytes with no conversion |
| `diode_wire` | Our own fixed 25-byte framing across the diode: proven `Serialize`/`Parse`, every field validated before it is trusted |
| `relay` | `Protect` (NetworkMessage → K data + M parity diode packets) and `Collector`/`Offer` (regroup by stream, erasure-decode, reassemble, dedup). Fixed-capacity, allocation-free; a single-packet message is K=1 so repetition needs no special case |

## Build, test, prove

Toolchain: **GNAT 14.2.0 + gprbuild + gnatprove** (SPARK). `tools/env.sh` puts them on `PATH`.

```sh
./tools/build.sh     # -> bin/test_core
./tools/prove.sh     # gnatprove over the core (112 checks, 0 unproved)
./tools/check.sh     # build + proof + field axioms + RS erasure round-trip
```

## Roadmap

- **Phase 0+1 — proven core** ✅ GF(2⁸) + Reed-Solomon, AoRTE-proved, round-trip tested.
- **Phase 2 — UADP header parse** ✅ proven parse of the NetworkMessage/GroupHeader/PayloadHeader;
  `SequenceNumber` + routing-id extraction; opaque-payload passthrough; safe on truncated/hostile input.
- **Phase 3 — the relay** ✅ *proven core*: `diode_wire` framing + `relay` (protect + erasure-recover +
  dedup), round-trip tested. **Remaining**: the trusted UDP shell (sockets, main loop, interleaving
  scheduler); optionally the DPDK bypass + LT transport from gnat-lt-pro.
- **Phase 4 — encryption** AEAD from [SPARKNaCl](https://github.com/rod-chapman/SPARKNaCl) in the
  proven core.
- **Phase 5 — assurance argument** the proven/trusted boundary, as in gnat-lt-pro's `ASSURANCE.md`.
