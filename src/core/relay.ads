--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  Relay -- the proven core of the data-diode relay.
--
--  Sender side (Protect): take one OPC UA NetworkMessage, split it into K data
--  fragments, add M Reed-Solomon parity fragments, and frame all K+M as diode
--  packets.  Any K that arrive reconstruct the message.  A single-packet
--  message uses K=1, so M parity fragments are just robust copies -- repetition
--  falls out of the same code with no special case.
--
--  Receiver side (Collector + Offer): collect fragments per (stream, msg_seq),
--  erasure-decode once K have arrived, reassemble the NetworkMessage, and hand
--  it back exactly once.  A bounded dedup ring drops the late duplicate
--  fragments the redundancy inevitably produces, and drops a message already
--  delivered.  Fixed-capacity throughout -- no allocation, bounded memory.
--
--  What is NOT here: the UDP sockets and the scheduler that interleaves packets
--  in time.  Those are the trusted shell (src/, SPARK_Mode => Off).

with Wire_Types; use Wire_Types;
with Gf256;      use Gf256;
with Rs;
with Diode_Wire;

package Relay with SPARK_Mode => On is

   --  Data bytes carried per fragment.  K = ceil(Msg_Len / Frag_Payload), so a
   --  message up to Frag_Payload * Rs.Max_K bytes fits in one RS block -- with
   --  Max_K = 72 that is 72 KB, which covers a full UADP NetworkMessage (spec-
   --  capped at 64 KB) plus the 28-byte encryption overhead.
   Frag_Payload : constant := 1024;
   Max_Msg_Len  : constant := Frag_Payload * Rs.Max_K;   --  73728

   subtype Msg_Byte_Count is Natural range 0 .. Max_Msg_Len;
   type Msg_Bytes is array (1 .. Max_Msg_Len) of Byte;

   --  Output of Protect: up to Rs.Max_N framed packets.
   subtype Out_Count is Natural range 0 .. Rs.Max_N;
   type Packet_Array is array (1 .. Rs.Max_N) of Diode_Wire.Packet;
   type Length_Array is array (1 .. Rs.Max_N) of Diode_Wire.Pkt_Length;

   -------------
   -- Protect --
   -------------

   --  Frame one NetworkMessage (first Msg_Len bytes of Msg) into N_Out diode
   --  packets, M of them parity.  Ok is False only if Msg_Len is 0 or exceeds
   --  Max_Msg_Len -- which no UADP NetworkMessage can, so on this transport it
   --  always succeeds.
   procedure Protect
     (Msg       : Msg_Bytes;
      Msg_Len   : Msg_Byte_Count;
      Stream_Id : U64;
      Msg_Seq   : U32;
      M_Parity  : Natural;
      Pkts      : out Packet_Array;
      Lens      : out Length_Array;
      N_Out     : out Out_Count;
      Ok        : out Boolean)
     with Pre => M_Parity in 0 .. Rs.Max_M;

   ---------------
   -- Collector --
   ---------------

   Max_Inflight : constant := 16;    --  messages assembled concurrently
   Dedup_Depth  : constant := 64;    --  recently delivered (stream, seq) kept

   type Collector is private;

   procedure Init (C : out Collector);

   --  Offer one received diode packet (its first Len bytes).  If it completes a
   --  message, Produced is True and the reconstructed NetworkMessage is the
   --  first Out_Len bytes of Out_Msg.  Otherwise Produced is False (fragment
   --  stored, duplicate dropped, or packet malformed).  Total and safe on any
   --  input -- a hostile packet cannot break it.
   procedure Offer
     (C        : in out Collector;
      Buf      : Diode_Wire.Packet;
      Len      : Diode_Wire.Pkt_Length;
      Produced : out Boolean;
      Out_Msg  : out Msg_Bytes;
      Out_Len  : out Msg_Byte_Count);

private

   --  Constrained fields carry their bounds through storage, so when Offer
   --  reads them back the prover still knows K <= Max_K, the RS indices are in
   --  range, and Count + 1 cannot overflow -- no re-validation needed.
   type Assembly is record
      Used      : Boolean := False;
      Stream_Id : U64 := 0;
      Msg_Seq   : U32 := 0;
      K         : Natural range 0 .. Rs.Max_K   := 0;
      M         : Natural range 0 .. Rs.Max_M   := 0;
      Frag_Len  : Natural range 0 .. Rs.Max_Len := 0;
      Msg_Len   : Msg_Byte_Count := 0;
      Count     : Natural range 0 .. Rs.Max_N := 0;   --  distinct fragments held
      Age       : U64 := 0;                --  for LRU eviction
      Present   : Rs.Present_Array := (others => False);
      Frags     : Rs.Frag_Array;
   end record;

   type Entry_Array is array (1 .. Max_Inflight) of Assembly;

   type Dedup_Key is record
      Stream_Id : U64 := 0;
      Msg_Seq   : U32 := 0;
      Set       : Boolean := False;
   end record;
   type Dedup_Ring is array (1 .. Dedup_Depth) of Dedup_Key;

   type Collector is record
      Entries   : Entry_Array;
      Ded       : Dedup_Ring;
      Ded_Head  : Positive range 1 .. Dedup_Depth := 1;
      Clock     : U64 := 0;                --  monotonic tick for Age
   end record;

end Relay;
