# opc-diode

**A high-assurance Ada/SPARK OPC UA PubSub data-diode relay** — a clean-slate rewrite of the ideas in
[opcua-data-diode](https://github.com/cherubimro/opcua-data-diode), aimed at *formal proof* of the
reconstruction path rather than parity with the Python original.

> Status: **Phase 3 complete — a working, proven relay.** The proven core (GF(2⁸), Reed-Solomon, UADP
> header parse, diode framing, protect + erasure-recover + dedup) is AoRTE-clean: **318 checks, 0
> unproved, 0 justified**. On top sits a small trusted UDP shell (`od_sender` / `od_receiver`), and the
> two move real NetworkMessages end-to-end over UDP byte-identical (`tools/loopback-test.sh`: 40/40).

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
./tools/build.sh          # -> bin/{test_core, od_sender, od_receiver, od_probe}
./tools/prove.sh          # gnatprove over the core (318 checks, 0 unproved)
./tools/check.sh          # build + proof + core sanity + end-to-end loopback
./tools/loopback-test.sh  # od_sender <-UDP-> od_receiver, byte-identical
```

## Running the relay

```sh
# low side: recover diode packets on 9702, re-emit NetworkMessages to subscribers on 127.0.0.1:9703
./bin/od_receiver 9702 127.0.0.1 9703

# high side: take the publisher's NetworkMessages on 9701, protect with 3 parity, blast to the diode
./bin/od_sender 9701 <receiver_ip> 9702 --parity 3 --pace-us 200
```

The publisher points its PubSub output at the sender's `9701`; subscribers listen on the receiver's
`9703`. One-way throughout: nothing flows back.

## Roadmap

- **Phase 0+1 — proven core** ✅ GF(2⁸) + Reed-Solomon, AoRTE-proved, round-trip tested.
- **Phase 2 — UADP header parse** ✅ proven parse of the NetworkMessage/GroupHeader/PayloadHeader;
  `SequenceNumber` + routing-id extraction; opaque-payload passthrough; safe on truncated/hostile input.
- **Phase 3 — the relay** ✅ proven core (`diode_wire` + `relay`) **plus** the trusted UDP shell
  (`od_sender` / `od_receiver` / `od_stream`); works end-to-end byte-identical. *Refinements left*: a
  cross-message interleaving scheduler (today: simple pacing), and optionally the DPDK bypass + LT
  transport from gnat-lt-pro for the bulk rung.
- **Phase 4 — encryption** AEAD from [SPARKNaCl](https://github.com/rod-chapman/SPARKNaCl) in the
  proven core.
- **Phase 5 — assurance argument** the proven/trusted boundary, as in gnat-lt-pro's `ASSURANCE.md`.
