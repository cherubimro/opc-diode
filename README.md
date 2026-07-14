# opc-diode

*Made 🄯 libre (free as in freedom) with ❤️ at Politehnica University of Timișoara — quite possibly the first formally-verified (machine-checked proof of no run-time errors) **OPC UA data-diode relay** for one-way mirroring of **OPC UA / OPC UA PubSub** process data across an air gap. Built specifically for industrial control and SCADA — power grids, water treatment plants, oil & gas pipelines, railways, and telecommunications networks — **not** a general-purpose file mover.*

*Because we care — and because critical-infrastructure protection should not depend on proprietary / closed-source systems, and should be made FREE.*

**A high-assurance Ada/SPARK OPC UA PubSub data-diode relay** — a clean-slate rewrite of the ideas in
[opcua-data-diode](https://github.com/cherubimro/opcua-data-diode), aimed at *formal proof* of the
reconstruction path rather than parity with the Python original.

> Status: **Complete and hardened.** GF(2^8), Reed-Solomon (K up to 72, covering the full 64 KB UADP
> range), UADP header parse, diode framing, protect + erasure-recover + dedup, a per-stream anti-replay
> window, and ChaCha20-Poly1305 AEAD are all proved AoRTE by `gnatprove`: **387 checks, 0 unproved, 0
> justified** (SPARKNaCl provides the crypto, separately proven). The trusted UDP shell moves real
> NetworkMessages end-to-end byte-identical -- cleartext or authenticated-encrypted, with a
> cross-message interleaving scheduler for burst-loss resilience; a wrong key or tampering is dropped.
> An **optional DPDK kernel-bypass transport** is available behind `WITH_DPDK` / `--with-dpdk`. The full
> assurance case is [`docs/ASSURANCE.md`](docs/ASSURANCE.md).

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
| **2 … 72 fragments** (medium / large) | **Reed-Solomon over GF(2⁸)** — this module | MDS: *any* K of K+M fragments reconstruct exactly. Optimal across the whole OPC range |
| **>32 KB** (up to the 64 KB UADP ceiling) | **Reed-Solomon, K up to 72** | still MDS-optimal, and it covers the *entire* range a UADP NetworkMessage can occupy |

Reed-Solomon owns the whole range. There is no LT/fountain rung: a UADP NetworkMessage is spec-capped
at 64 KB, which is exactly where RS is optimal and a fountain code (tuned for thousands of fragments)
would only add overhead. So "large message" here means K up to 72, not a separate transport.

The full assurance case — what is proven, what is trusted, the proof's assumptions, and how the
trusted shell and the integrity/confidentiality gate are justified — is in
[`docs/ASSURANCE.md`](docs/ASSURANCE.md).

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
| `secure` | Authenticated encryption wrapper over SPARKNaCl's ChaCha20-Poly1305 AEAD: `Seal` a NetworkMessage into `[nonce\|tag\|ciphertext]`, `Open` verifies the 16-byte tag and rejects a wrong key or any tampering. Sits above the relay, so the erasure code protects the ciphertext |

## Build, test, prove

Toolchain: **GNAT 14.2.0 + gprbuild + gnatprove** (SPARK). `tools/env.sh` puts them on `PATH`.

```sh
./tools/build.sh          # -> bin/{test_core, od_sender, od_receiver, od_probe}
./tools/prove.sh          # gnatprove over the core (387 checks, 0 unproved)
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

Add `--key <64 hex chars>` to BOTH ends for authenticated encryption (ChaCha20-Poly1305). The key is
pre-shared out of band; the sender encrypts each NetworkMessage before fragmenting, the receiver
verifies the tag and drops anything that fails. Without `--key`, payloads cross in the clear.
`--interleave D` on the sender spreads a burst loss across D messages (packet 1 of each, then packet 2
of each, …), so a short burst becomes a recoverable one-per-message trickle.

The publisher points its PubSub output at the sender's `9701`; subscribers listen on the receiver's
`9703`. One-way throughout: nothing flows back.

### Transports: UDP (default) or DPDK kernel-bypass (opt-in)

The proven core takes a fixed packet buffer and never names a socket, so the transport lives wholly in
the trusted shell — **swapping it re-discharges none of the 387 proof obligations.** The default is
`GNAT.Sockets` UDP. An optional DPDK poll-mode backend moves diode packets as raw Ethernet frames
(EtherType `0x88B7`):

```sh
DPDK_PREFIX=/path/to/dpdk-install WITH_DPDK=yes ./tools/build.sh   # or apt install libdpdk-dev
./tools/dpdk-test.sh                                               # memif end-to-end, no root/NIC

# then --with-dpdk --eal "<EAL args>" on BOTH the sender (diode output) and receiver (diode input)
sudo ./bin/od_receiver 0 127.0.0.1 9703 --with-dpdk --eal "-l 0 -a 0000:03:00.0"
sudo ./bin/od_sender 9701 0 0 --with-dpdk --eal "-l 1 -a 0000:03:00.0" --parity 3
```

A default build is DPDK-free (`nm` finds zero `rte_*` symbols); `--with-dpdk` on it exits with *"built
without DPDK support"*. **The trade:** DPDK moves its EAL, mempool and NIC PMD — a large third-party C
body — plus a small mandatory C shim onto the data path *inside the TCB*, and real bypass (`vfio-pci`)
also needs root, an IOMMU and a spare NIC. Safety and integrity are unaffected; what grows is what you
**trust**. Full ledger: [`docs/ASSURANCE.md` §5.1](docs/ASSURANCE.md).

## Roadmap

- **Phase 0+1 — proven core** ✅ GF(2⁸) + Reed-Solomon, AoRTE-proved, round-trip tested.
- **Phase 2 — UADP header parse** ✅ proven parse of the NetworkMessage/GroupHeader/PayloadHeader;
  `SequenceNumber` + routing-id extraction; opaque-payload passthrough; safe on truncated/hostile input.
- **Phase 3 — the relay** ✅ proven core (`diode_wire` + `relay`) **plus** the trusted UDP shell
  (`od_sender` / `od_receiver` / `od_stream`); works end-to-end byte-identical.
- **Phase 4 — encryption** ✅ ChaCha20-Poly1305 AEAD ([SPARKNaCl](https://github.com/rod-chapman/SPARKNaCl),
  vendored under `deps/`, BSD) wrapped by the proven `secure` module; wired into the shell via
  `--key`. Encrypt-then-fragment, so RS protects the ciphertext; a bad tag is dropped, never emitted.
- **Phase 5 — assurance argument** ✅ [`docs/ASSURANCE.md`](docs/ASSURANCE.md): the claim, the
  proven/trusted boundary, what the 387-check proof does and does not establish, the TCB (incl. the
  SPARKNaCl reliance), how the trusted shell is justified, the integrity/confidentiality gate, and
  the residual risks.
- **Hardening** ✅ RS extended to K=72 (the full 64 KB UADP range, LT unneeded); a per-stream
  anti-replay window; a cross-message interleaving scheduler; and an optional DPDK kernel-bypass
  transport (`WITH_DPDK` / `--with-dpdk`).

## Licence

opc-diode is **AGPL-3.0-or-later** ([`LICENSE`](LICENSE); every source file carries the SPDX header).
Copyright © 2026 **Alin-Adrian Anton** (alin.anton@upt.ro), Politehnica University of Timișoara.
See [`AUTHORS`](AUTHORS).

### Third-party components

Own licences apply to the optional, separately-built dependencies. Each is used only when its build
flag is set; a default build links none of them.

| Component | Licence | Used by | Vendored |
|---|---|---|---|
| [SPARKNaCl](https://github.com/rod-chapman/SPARKNaCl) | BSD (© Protean Code Ltd) | ChaCha20-Poly1305 AEAD (always) | `deps/sparknacl/` (`LICENCE.md` kept) |
| [S2OPC](https://gitlab.com/systerel/S2OPC) | Apache-2.0 (© Systerel) | `WITH_OPCUA=s2opc` | built into `deps/s2opc/` (gitignored) |
| [open62541](https://github.com/open62541/open62541) | MPL-2.0 | `WITH_OPCUA=open62541` | built into `deps/open62541/` (gitignored) |

SPARKNaCl (BSD) and S2OPC / open62541 (Apache-2.0 / MPL-2.0, file-level copyleft) are all
AGPL-compatible; their notices are retained in their vendored trees, and `tools/*-build.sh` reproduce
them from source. The S2OPC and open62541 trees are gitignored — this repository distributes no
third-party binaries.
