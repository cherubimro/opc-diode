--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  Relay core body.  Everything is bounded and allocation-free.  Fragment
--  geometry is chosen so its bounds are structural, not arithmetic: the chunk
--  length is either the whole (small) message or exactly Frag_Payload, so
--  Frag_Len <= Frag_Payload holds by a case split rather than a division-bound
--  the prover would have to reason about nonlinearly.

with Diode_Wire; use Diode_Wire;

package body Relay with SPARK_Mode => On is

   use type Wire_Types.U32, Wire_Types.U64;

   -------------
   -- Protect --
   -------------

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
   is
      K, Frag_Len : Natural;
      Frags       : Rs.Frag_Array := (others => (others => 0));
   begin
      Pkts  := (others => (others => 0));
      Lens  := (others => 0);
      N_Out := 0;
      Ok    := False;

      if Msg_Len = 0 or else Msg_Len > Max_Msg_Len then
         return;                       --  empty, or bulk -> LT path (later)
      end if;

      --  Geometry: one chunk if it fits, else full 1024-byte chunks.  Both
      --  branches give Frag_Len <= Frag_Payload and K * Frag_Len >= Msg_Len.
      if Msg_Len <= Frag_Payload then
         K        := 1;
         Frag_Len := Msg_Len;
      else
         Frag_Len := Frag_Payload;
         K        := (Msg_Len + Frag_Payload - 1) / Frag_Payload;
      end if;

      pragma Assert (K in 1 .. Rs.Max_K);
      pragma Assert (Frag_Len in 1 .. Frag_Payload);
      pragma Assert (K * Frag_Len >= Msg_Len);

      --  Stripe the message across the K data fragments, zero-padding the tail.
      for J in 1 .. K loop
         pragma Loop_Invariant (K in 1 .. Rs.Max_K);
         pragma Loop_Invariant (Frag_Len in 1 .. Frag_Payload);
         for B in 1 .. Frag_Len loop
            declare
               Src : constant Natural := (J - 1) * Frag_Len + B;
            begin
               if Src <= Msg_Len then
                  Frags (J) (B) := Msg (Src);
               end if;
            end;
         end loop;
      end loop;

      --  Reed-Solomon parity into slots K+1 .. K+M.
      Rs.Encode (K, (if M_Parity = 0 then 1 else M_Parity), Frag_Len, Frags);

      declare
         M : constant Natural := (if M_Parity = 0 then 1 else M_Parity);
      begin
         for Slot in 1 .. K + M loop
            pragma Loop_Invariant (K in 1 .. Rs.Max_K);
            pragma Loop_Invariant (M in 1 .. Rs.Max_M);
            pragma Loop_Invariant (Slot in 1 .. K + M);
            Diode_Wire.Serialize
              (Scheme    => Scheme_RS,
               Stream_Id => Stream_Id,
               Msg_Seq   => Msg_Seq,
               Msg_Len   => U32 (Msg_Len),
               Frag_Len  => Frag_Len,
               K         => K,
               M         => M,
               Frag_Idx  => Slot,
               Payload   => Frags (Slot),
               Buf       => Pkts (Slot),
               Total     => Lens (Slot));
         end loop;
         N_Out := K + M;
      end;
      Ok := True;
   end Protect;

   ----------
   -- Init --
   ----------

   procedure Init (C : out Collector) is
   begin
      C := (Entries  => (others =>
                          (Used => False, Stream_Id => 0, Msg_Seq => 0,
                           K => 0, M => 0, Frag_Len => 0, Msg_Len => 0,
                           Count => 0, Age => 0,
                           Present => (others => False),
                           Frags => (others => (others => 0)))),
            Ded      => (others => (Stream_Id => 0, Msg_Seq => 0, Set => False)),
            Ded_Head => 1,
            Clock    => 0);
   end Init;

   --  Membership test against the dedup ring.
   function Seen (C : Collector; S : U64; Q : U32) return Boolean is
   begin
      for I in 1 .. Dedup_Depth loop
         if C.Ded (I).Set and then C.Ded (I).Stream_Id = S
           and then C.Ded (I).Msg_Seq = Q
         then
            return True;
         end if;
      end loop;
      return False;
   end Seen;

   procedure Remember (C : in out Collector; S : U64; Q : U32) is
   begin
      C.Ded (C.Ded_Head) := (Stream_Id => S, Msg_Seq => Q, Set => True);
      C.Ded_Head := (if C.Ded_Head >= Dedup_Depth then 1 else C.Ded_Head + 1);
   end Remember;

   subtype Slot_Range is Positive range 1 .. Max_Inflight;

   --  Find the entry for (S,Q), or a free one, or the oldest to evict.  Always
   --  returns a valid index in 1 .. Max_Inflight.
   function Pick (C : Collector; S : U64; Q : U32) return Slot_Range is
      Free    : Natural := 0;
      Oldest  : Slot_Range := 1;
   begin
      for I in 1 .. Max_Inflight loop
         if C.Entries (I).Used
           and then C.Entries (I).Stream_Id = S
           and then C.Entries (I).Msg_Seq = Q
         then
            return I;                       --  existing assembly
         end if;
         if not C.Entries (I).Used and then Free = 0 then
            Free := I;
         end if;
         if C.Entries (I).Age < C.Entries (Oldest).Age then
            Oldest := I;
         end if;
      end loop;
      return (if Free /= 0 then Free else Oldest);
   end Pick;

   -----------
   -- Offer --
   -----------

   procedure Offer
     (C        : in out Collector;
      Buf      : Diode_Wire.Packet;
      Len      : Diode_Wire.Pkt_Length;
      Produced : out Boolean;
      Out_Msg  : out Msg_Bytes;
      Out_Len  : out Msg_Byte_Count)
   is
      H : Diode_Wire.Header;
   begin
      Produced := False;
      Out_Msg  := (others => 0);
      Out_Len  := 0;

      Diode_Wire.Parse (Buf, Len, H);
      if not H.Valid or else H.Scheme /= Scheme_RS then
         return;
      end if;
      --  Compare in U32: Natural(H.Msg_Len) could itself overflow Natural.
      if H.Msg_Len = 0 or else H.Msg_Len > U32 (Max_Msg_Len) then
         return;                          --  outside the RS regime
      end if;
      if Seen (C, H.Stream_Id, H.Msg_Seq) then
         return;                          --  already delivered: drop late copy
      end if;

      declare
         E : constant Slot_Range := Pick (C, H.Stream_Id, H.Msg_Seq);
      begin
         --  (Re)initialise the slot if it is not already this message.
         if not C.Entries (E).Used
           or else C.Entries (E).Stream_Id /= H.Stream_Id
           or else C.Entries (E).Msg_Seq /= H.Msg_Seq
           or else C.Entries (E).K /= H.K
           or else C.Entries (E).Frag_Len /= H.Frag_Len
         then
            C.Entries (E).Used      := True;
            C.Entries (E).Stream_Id := H.Stream_Id;
            C.Entries (E).Msg_Seq   := H.Msg_Seq;
            C.Entries (E).K         := H.K;
            C.Entries (E).M         := H.M;
            C.Entries (E).Frag_Len  := H.Frag_Len;
            C.Entries (E).Msg_Len   := Natural (H.Msg_Len);
            C.Entries (E).Count     := 0;
            C.Entries (E).Present   := (others => False);
         end if;

         --  Store this fragment if new.
         if not C.Entries (E).Present (H.Frag_Idx) then
            for B in 1 .. H.Frag_Len loop
               pragma Loop_Invariant (H.Frag_Len <= Diode_Wire.Max_Payload);
               C.Entries (E).Frags (H.Frag_Idx) (B) := Buf (Header_Len + B - 1);
            end loop;
            --  Zero the padding tail so a short final fragment is well-defined.
            for B in H.Frag_Len + 1 .. Rs.Max_Len loop
               C.Entries (E).Frags (H.Frag_Idx) (B) := 0;
            end loop;
            C.Entries (E).Present (H.Frag_Idx) := True;
            --  At most K+M <= Max_N distinct fragments can ever be stored, so
            --  the guard never actually blocks -- it just makes +1 provably safe.
            if C.Entries (E).Count < Rs.Max_N then
               C.Entries (E).Count := C.Entries (E).Count + 1;
            end if;
         end if;

         C.Entries (E).Age := C.Clock;
         C.Clock := C.Clock + 1;

         --  Enough fragments? erasure-decode and reassemble.  The K/M in 1..
         --  guards satisfy Rs.Decode's preconditions (our own packets always
         --  carry K,M >= 1; a hostile packet claiming M=0 simply never
         --  completes, which is the safe outcome).
         if C.Entries (E).Count >= C.Entries (E).K
           and then C.Entries (E).K in 1 .. Rs.Max_K
           and then C.Entries (E).M in 1 .. Rs.Max_M
         then
            declare
               Dec_Ok : Boolean;
               EK  : constant Rs.K_Range := C.Entries (E).K;
               EM  : constant Rs.M_Range := C.Entries (E).M;
               EFL : constant Natural    := C.Entries (E).Frag_Len;
               ELn : constant Msg_Byte_Count := C.Entries (E).Msg_Len;
            begin
               Rs.Decode (EK, EM, EFL, C.Entries (E).Present,
                          C.Entries (E).Frags, Dec_Ok);
               if Dec_Ok then
                  for J in 1 .. EK loop
                     pragma Loop_Invariant (EK <= Rs.Max_K);
                     pragma Loop_Invariant (EFL <= Rs.Max_Len);
                     for B in 1 .. EFL loop
                        declare
                           Dst : constant Natural := (J - 1) * EFL + B;
                        begin
                           if Dst <= ELn and then Dst <= Max_Msg_Len then
                              Out_Msg (Dst) := C.Entries (E).Frags (J) (B);
                           end if;
                        end;
                     end loop;
                  end loop;
                  Out_Len  := (if ELn <= Max_Msg_Len then ELn else 0);
                  Produced := Out_Len > 0;
                  Remember (C, H.Stream_Id, H.Msg_Seq);
                  C.Entries (E).Used := False;    --  slot freed
               end if;
            end;
         end if;
      end;
   end Offer;

end Relay;
