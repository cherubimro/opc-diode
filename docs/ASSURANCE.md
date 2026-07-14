# Trusted-boundary assurance argument

This is the assurance case for **opc-diode**: what is formally proven, what is
trusted, exactly where the line between them is drawn and why, what the proof
rests on, and how the trusted side is justified. It is written to be read
alongside the code — every claim points at a unit, a contract, or a piece of
evidence you can re-run.

## 1. Claim

> On the path that carries an OPC UA PubSub NetworkMessage from the
> high-security network to the low-security network, the codec **cannot commit
> a language-defined run-time error** (no integer or float overflow, no
> out-of-bounds array access, no division by zero, no range violation), every
> loop **terminates**, and every functional contract holds —
> **machine-checked, with no assumptions injected into the proof**.
>
> Corrupt or forged output is **never emitted**: when a key is set, the
> whole-message Poly1305 tag is checked by the proven core, so a mis-decode
> (from loss or a hostile packet) or a tampered/forged payload is **dropped**,
> not re-published.

The claim is deliberately scoped. It is a **safety + integrity** claim about
the proven data path plus the authentication gate, together with
**confidentiality** from the encryption — *not* a proof of full functional
correctness (see §3.2), *not* the correctness of the cryptographic primitives
themselves (that is SPARKNaCl's, §4), and *not* an availability guarantee
(see §7).

What makes this stronger than a typical diode port: because the source
publishes **PubSub natively**, there is **no OPC UA stack anywhere** — no
client, no server, no third-party protocol library in the process. The entire
data path from wire to wire is the proven core. We are a relay that parses only
the UADP header (to dedup and route) and treats each DataSetMessage as an
opaque, verbatim payload, so we cannot corrupt a payload's meaning: we never
interpret one.

## 2. The boundary

The system is two layers with a single, narrow interface between them.

| Layer | Files | `SPARK_Mode` | Status |
|---|---|---|---|
| **Proven core** | `src/core/*` (`wire_types`, `gf256`, `rs_matrix`, `rs`, `uadp`, `diode_wire`, `relay`, `secure`) and `src/od_stream` | `On` | proved by `gnatprove` |
| **Trusted I/O shell** | `src/{od_sender,od_receiver,od_key}` | `Off` | reviewed |
| **Proven dependency** | `deps/sparknacl/*` | `On` (upstream) | proved upstream; relied upon (§4) |

The core is **self-contained and allocation-free**: it operates on
caller-supplied buffers with fixed-capacity working storage, has no global
mutable state, and never calls out to the shell. Data crosses the boundary only
*into* the core, through a handful of subprograms with explicit contracts:

```
Uadp.Parse        (Buf, Len, Info)              -- header parse, total & safe
Secure.Seal       (Plain, Len, Key, Nonce, ...) -- authenticated-encrypt
Secure.Open       (Blob, Len, Key, ...)         -- verify + decrypt
Relay.Protect     (Msg, Len, Stream, Seq, M, ...)-- fragment + erasure-code
Relay.Offer       (Collector, Pkt, Len, ...)    -- regroup + decode + dedup
Diode_Wire.Serialize / Parse (...)              -- our on-wire framing
Rs.Encode / Decode (...)                        -- the erasure code
```

That is the entire interface. Roughly **1815 lines** of proven core sit behind
it; the trusted shell is **~430 lines** of socket plumbing.

## 3. What the proof establishes

`gnatprove` (level 2) over the core discharges **351 verification conditions,
0 unproved, 0 justified**:

- **Run-time checks** (173) — no overflow, no array index or range violation,
  no division by zero, anywhere in the core, on any input including a hostile
  UDP datagram.
- **Assertions & functional contracts** (104) — the pre/postconditions,
  including `Diode_Wire.Parse`'s postcondition that hands validated field bounds
  to the relay, and the length relations in `Secure`.
- **Loop termination** (15) — every loop, including the Gauss-Jordan erasure
  decode and the UADP cursor.
- **Initialization & non-aliasing** (59) — no read of an uninitialized value.

Reproduce with `./tools/prove.sh` (or `./tools/check.sh`, which fails the build
if any obligation is unproved).

### 3.1 Why this is the right target for a diode

On a one-way link there is **no retransmission** — a crash or a silently wrong
computation on the receive path is unrecoverable, and a malformed packet from
the untrusted low side must never be able to fault the daemon. AoRTE removes the
entire class of language-level faults: the erasure decoder inverts a matrix over
GF(2⁸) in tight loops, the UADP parser walks a variable-length header with a
cursor, and a single off-by-one in either would be a `Constraint_Error`
mid-transfer. Proving it *once* is worth more than any amount of testing of that
specific class.

### 3.2 What the proof does **not** establish

- **Not** "the erasure code recovers the message when K fragments arrive," nor
  "the UADP parse extracts the right SequenceNumber." Those are functional
  properties; they are validated empirically (`test_core`: byte-exact erasure
  round-trips, header-parse cases including truncation and lying counts) and
  *contained* by the authentication gate (§6), not proved.
- **Not** the correctness of ChaCha20 or Poly1305 — that is SPARKNaCl's proof
  (§4). Our `secure` module is proved AoRTE and proved to satisfy SPARKNaCl's
  preconditions; the cryptographic strength is inherited, not re-established.
- **Not** anything about the trusted shell (§5).

## 4. The proof's trusted computing base (assumptions)

The proof is only as strong as what it rests on. These are the assumptions —
kept explicit and minimal:

1. **Toolchain soundness.** GNAT 14.2.0 correctly implements Ada semantics, and
   `gnatprove` with its provers (CVC5, Z3) is sound. The standard SPARK
   assumption.
2. **No injected assumptions.** There is **no `pragma Assume` and no
   justification** anywhere in the core — the "Justified" column of the proof
   summary is empty. The proof relies on **no human-asserted lemma**; nothing is
   taken on faith inside the analysis.
3. **SPARKNaCl's published proof.** We use SPARKNaCl's AEAD (ChaCha20-Poly1305,
   RFC 8439) and rely on its separate, published proof of type-safety.
   `tools/prove.sh` runs `--no-subprojects`, so `gnatprove` uses SPARKNaCl's
   **contracts** without re-verifying its bodies. SPARKNaCl (Protean Code
   Limited, BSD, vendored under `deps/`) is thus a trusted-but-proven
   dependency: its *strength* is inherited, its *soundness* assumed exactly as
   the toolchain's is.
4. **The precondition obligations are met at the boundary.** Each core
   subprogram is proved safe *given its precondition*. The non-trivial ones are
   satisfied by construction: `Relay.Protect`'s `M_Parity` bound and
   `Diode_Wire.Serialize`'s index bounds are checked by the callers, and
   SPARKNaCl's AEAD preconditions (0-based, equal lengths, size < 2³¹) are
   discharged inside `secure` by the marshalling (proved).
5. **Analyzed instance and representation.** The relay is proved with its
   concrete capacities (`Max_K = Max_M = 32`, `Max_Inflight = 16`,
   `Dedup_Depth = 64`); over-capacity input is dropped, never overflows. The GF
   tables and Cauchy matrix are frozen constants, generated and self-checked
   offline (`tools/gen-tables.py`) and pasted into the Ada, not built at
   elaboration — so there is no initialization loop to reason about, and a human
   can diff the constants against the generator.
6. **Determinism.** Sender and receiver agree because the RS geometry and the
   Cauchy matrix are fixed constants and the framing is a fixed layout — bit
   identical on every host.

## 5. The trusted shell — surface and how it is assured

Everything the *operating system* touches is trusted, because SPARK cannot model
sockets or the clock. The surface is small and enumerable:

| Trusted concern | Where | How it is assured |
|---|---|---|
| UDP receive/send (`GNAT.Sockets`) | `od_sender`, `od_receiver` | small reviewed plumbing; every received datagram is copied into a fixed buffer and handed to the proven `Uadp.Parse` / `Relay.Offer`, which are total and safe on any bytes |
| Key parsing, nonce epoch | `od_key` | 64-hex → 32 bytes; a per-run clock-based nonce prefix |
| Per-stream sequence counters | `od_sender` | a fixed table; assigns the `msg_seq` the receiver dedups on |
| Stream-id derivation | `od_stream` | **proven** (`SPARK_Mode => On`) — a pure total function of the header |

The trusted side is justified by three means:

1. **Small, reviewed surface.** The table above is the whole of it (~430 lines).
   The proven core carries every algorithmic step — parse, encrypt, fragment,
   erasure-code, reassemble, decrypt, dedup; the shell only moves bytes between
   a socket and the core.
2. **Correct use of the proven interface.** The shell's obligations are the core
   preconditions, met by construction (§4.4). `od_stream`, though it lives with
   the shell, is itself proven.
3. **Exercised end-to-end.** `tools/loopback-test.sh` runs the whole pipeline
   over real UDP in three passes — cleartext, encrypted, and encrypted with a
   *wrong* key — and asserts byte-identical delivery for the first two and
   **zero** delivery for the third (every forged-key blob rejected by the tag).

## 6. Integrity and confidentiality — safe degradation

The strongest part of the argument is that a fault in the *trusted* shell, or a
hostile packet from the low side, cannot silently publish wrong data.

- **Encrypt-then-fragment.** `secure.Seal` authenticates *and* encrypts the
  whole NetworkMessage before `Relay.Protect` fragments the ciphertext. So the
  16-byte Poly1305 tag covers the entire message; the erasure code only ever
  sees ciphertext, and loss is just erasure.
- **The gate.** `secure.Open` (proven) recomputes and checks the tag. Only on a
  match is the plaintext handed back to the shell for emission; on any mismatch
  it returns `Ok => False` and **no plaintext**, and `od_receiver` drops it.
- **Opaque passthrough.** A recovered message is re-emitted byte-identical; we
  never re-encode a payload, so we cannot corrupt one.

So even under the strongest adversary on the low side — replaying, forging, or
flipping bytes — the outcome is a **dropped** packet, never a `.published`
message with wrong bytes. A `stream_id` collision merges two fragment pools; the
erasure decode or the tag then rejects the blend, so a collision costs a dropped
message, never a corrupt one. Integrity degrades safely; it does not fail open.
(Without `--key`, there is no authentication: integrity then rests only on the
erasure decode succeeding, and the link is assumed physically one-way.)

## 7. Residual risks and limitations

- **Functional correctness is tested, not proved** (§3.2). Mitigation: the
  authentication gate turns any residual mis-decode into a dropped packet.
- **The trusted shell is not proved.** Mitigation: small surface, review, and
  the end-to-end loopback — assurance by argument and evidence, not proof.
- **Availability, not safety.** If more than `M` fragments of a message are
  lost, that message is not recovered; there is no retransmission. This affects
  *whether* a message arrives, not *whether* an arrived message is correct.
  Mitigation: parity sized by `--parity`, sender pacing. **Not yet done**: a
  cross-message interleaving scheduler (today the sender only paces), and the LT
  transport for messages larger than 32 KB (currently such a message is
  dropped by `Relay.Protect`, reported honestly by `Ok => False`).
- **Replay.** The dedup ring is bounded (`Dedup_Depth = 64`). An attacker on the
  low side who records diode packets and replays them *after* their
  `(stream, msg_seq)` has aged out of the ring could cause a stale-but-authentic
  NetworkMessage to be re-published. The AEAD tag passes because the ciphertext
  is genuine. Mitigation path (not yet implemented): a per-stream monotonic
  high-water `msg_seq`, rejecting any non-advancing sequence.
- **Nonce uniqueness is an assumption, not a proof.** Confidentiality of
  ChaCha20-Poly1305 requires the `(epoch, stream_id, msg_seq)` nonce never to
  repeat under one key. `epoch` is clock-derived per run; two sender processes
  started within the same clock tick, on the same stream, could in principle
  collide. Mitigation path: a higher-entropy epoch (e.g. from the OS RNG).
- **Key management is out of band.** The pre-shared key is supplied on the
  command line; distributing and protecting it is the operator's responsibility.

## 8. Reproducing the evidence

```sh
./tools/prove.sh          # gnatprove: 351 checks, 0 unproved, 0 justified
./tools/check.sh          # build + proof + core sanity + end-to-end loopback
./tools/loopback-test.sh  # cleartext + encrypted + wrong-key over real UDP
```

The assurance case is the composition of all three: **a proof that the whole
data path cannot fault, an authentication gate that never publishes corrupt or
forged output, and a small trusted shell that is reviewed and exercised
end-to-end** — with the cryptography itself carried by a separately-proven
library.
