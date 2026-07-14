--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  Rs -- a systematic Reed-Solomon ERASURE code over GF(2^8).
--
--  Purpose on a diode: protect a message that spans a small number of packets.
--  Split it into K data fragments, add M parity fragments, and send all K + M.
--  ANY K of the K + M that arrive reconstruct the message exactly -- this is
--  the MDS (maximum-distance-separable) property, and it comes for free from
--  the Cauchy generator matrix (Rs_Matrix), every square submatrix of which is
--  invertible.  There are no unlucky loss patterns: only the COUNT matters.
--
--  Why RS here rather than the LT fountain of gnat-lt-pro: at small K (a
--  handful of packets) RS is optimal -- exactly K survivors suffice -- whereas
--  the soliton distribution behaves poorly and wastes overhead.  LT wins only
--  at large K (bulk transfers).  This code owns the small-message regime.
--
--  The code is "systematic": data fragments are sent verbatim (slots 1 .. K),
--  parity follows (slots K+1 .. K+M).  So in the common no-loss case the
--  receiver does no arithmetic at all -- the data fragments ARE the message.

with Gf256; use Gf256;

package Rs with SPARK_Mode => On is

   Max_K   : constant := 32;      --  data fragments per message
   Max_M   : constant := 32;      --  parity fragments per message
   Max_N   : constant := Max_K + Max_M;
   Max_Len : constant := 1400;    --  bytes per fragment (fits one UADP datagram)

   subtype Frag_Len   is Natural  range 0 .. Max_Len;
   subtype K_Range    is Positive range 1 .. Max_K;
   subtype M_Range    is Positive range 1 .. Max_M;
   subtype Slot_Range is Positive range 1 .. Max_N;

   type Fragment     is array (1 .. Max_Len) of Byte;
   type Frag_Array   is array (Slot_Range) of Fragment;
   type Present_Array is array (Slot_Range) of Boolean;

   --  Encode: given K data fragments (slots 1 .. K of Frags, each Len bytes),
   --  fill in the M parity fragments (slots K+1 .. K+M).  Data slots are left
   --  untouched, so the result is systematic.
   procedure Encode
     (K, M : Positive;
      Len  : Frag_Len;
      Frags : in out Frag_Array)
     with Pre => K <= Max_K and then M <= Max_M;

   --  Decode: Present (s) says whether fragment s arrived.  On success every
   --  data slot 1 .. K of Frags holds the original bytes (missing ones are
   --  reconstructed; ones that arrived are unchanged).  Ok is False iff fewer
   --  than K fragments arrived -- the only genuine failure, since any K suffice.
   procedure Decode
     (K, M    : Positive;
      Len     : Frag_Len;
      Present : Present_Array;
      Frags   : in out Frag_Array;
      Ok      : out Boolean)
     with Pre => K <= Max_K and then M <= Max_M;

end Rs;
