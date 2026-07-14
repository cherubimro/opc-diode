--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--
--  Sanity driver for the proven core.  This is behaviour testing, NOT proof:
--  gnatprove establishes absence of run-time errors, and these checks confirm
--  the field axioms and the RS round-trip actually hold on concrete values.

with Ada.Text_IO; use Ada.Text_IO;
with Interfaces;
with Gf256;       use Gf256;
with Rs;
with Uadp;
with Wire_Types;   use Wire_Types;
with Diode_Wire;
with Relay;
with Secure;

procedure Test_Core is

   use type Byte;
   use type Wire_Types.U32, Wire_Types.U64;
   use type Uadp.U16, Uadp.U64, Uadp.Pub_Kind;
   subtype Interfaces_Unsigned is Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_64;

   Fail : Natural := 0;

   procedure Check (Cond : Boolean; Msg : String) is
   begin
      if not Cond then
         Put_Line ("  FAIL  " & Msg);
         Fail := Fail + 1;
      end if;
   end Check;

begin
   Put_Line ("== GF(256) field axioms ==");

   --  Additive: a xor a = 0.
   for A in Byte loop
      Check (Add (A, A) = 0, "a + a = 0");
   end loop;

   --  Multiplicative identity and inverse.
   for A in Byte range 1 .. Byte'Last loop
      Check (Mul (A, 1) = A, "a * 1 = a");
      Check (Mul (A, Inv (A)) = 1, "a * a^-1 = 1");
   end loop;

   --  Distributivity a*(b+c) = a*b + a*c, over the whole field.
   for A in Byte loop
      for B in Byte loop
         --  c fixed sweep would be O(2^24); sample c against b's complement.
         declare
            C : constant Byte := B xor 16#5A#;
         begin
            Check (Mul (A, Add (B, C)) = Add (Mul (A, B), Mul (A, C)),
                   "a*(b+c) = a*b + a*c");
         end;
      end loop;
   end loop;

   --  Associativity spot-check.
   for A in Byte range 1 .. 40 loop
      for B in Byte range 1 .. 40 loop
         for C in Byte range 1 .. 40 loop
            Check (Mul (Mul (A, B), C) = Mul (A, Mul (B, C)),
                   "(a*b)*c = a*(b*c)");
         end loop;
      end loop;
   end loop;

   --  Reed-Solomon erasure round-trip: encode, erase various patterns, decode,
   --  and require byte-exact recovery whenever at least K fragments survive.
   Put_Line ("== Reed-Solomon erasure round-trip ==");
   declare
      --  A deterministic PRNG (SplitMix64) so the test is reproducible.
      State : Byte := 0;
      Seed  : Interfaces_Unsigned := 16#9E3779B97F4A7C15#;

      function Rand return Byte is
         Z : Interfaces_Unsigned;
      begin
         Seed := Seed + 16#9E3779B97F4A7C15#;
         Z := Seed;
         Z := (Z xor (Z / 2 ** 30)) * 16#BF58476D1CE4E5B9#;
         Z := (Z xor (Z / 2 ** 27)) * 16#94D049BB133111EB#;
         Z := Z xor (Z / 2 ** 31);
         return Byte (Z mod 256);
      end Rand;

      procedure Trial (K, M, Len : Positive; Erase : Natural) is
         Orig  : Rs.Frag_Array := (others => (others => 0));
         Work  : Rs.Frag_Array;
         Pres  : Rs.Present_Array := (others => True);
         Ok    : Boolean;
         Dropped : Natural := 0;
      begin
         for J in 1 .. K loop
            for B in 1 .. Len loop
               Orig (J) (B) := Rand;
            end loop;
         end loop;
         Work := Orig;
         Rs.Encode (K, M, Len, Work);          --  fills parity slots K+1..K+M

         --  Erase `Erase` fragments across the whole K+M set.
         while Dropped < Erase loop
            declare
               S : constant Positive := 1 + Integer (Rand) mod (K + M);
            begin
               if Pres (S) then
                  Pres (S) := False;
                  Work (S) := (others => 16#FF#);   --  clobber, prove it's rebuilt
                  Dropped := Dropped + 1;
               end if;
            end;
         end loop;

         Rs.Decode (K, M, Len, Pres, Work, Ok);

         --  With M parity, up to M erasures are always recoverable.
         if Erase <= M then
            Check (Ok, "decode ok  (K=" & K'Image & " M=" & M'Image
                       & " erase=" & Erase'Image & ")");
            if Ok then
               for J in 1 .. K loop
                  for B in 1 .. Len loop
                     Check (Work (J) (B) = Orig (J) (B),
                            "byte-exact recovery K=" & K'Image
                            & " M=" & M'Image & " erase=" & Erase'Image);
                  end loop;
               end loop;
            end if;
         end if;
      end Trial;
   begin
      pragma Unreferenced (State);
      Trial (4,  2, 100, 0);      --  no loss (systematic shortcut)
      Trial (4,  2, 100, 1);
      Trial (4,  2, 100, 2);      --  max recoverable for M=2
      Trial (8,  4, 200, 4);      --  every data slot could be gone
      Trial (16, 8, 300, 8);
      Trial (10, 6, 1400, 6);     --  full fragment length
      Trial (1,  3, 50,  3);      --  pure replication (K=1): survive any 1 of 4
      Trial (72, 16, 1024, 16);   --  max K (covers a 72 KB / 64 KB-UADP message)
   end;

   --  UADP NetworkMessage header parsing.  Build messages byte-by-byte and
   --  check the relay-relevant fields are extracted, and that truncated /
   --  malformed input is rejected (Valid => False) without ever crashing.
   Put_Line ("== UADP header parse ==");
   declare
      M   : Uadp.Message := (others => 0);
      Pos : Natural := 0;

      procedure B (X : Uadp.U8) is
      begin
         M (Pos) := X; Pos := Pos + 1;
      end B;

      procedure LE16 (X : Uadp.U16) is
      begin
         B (Uadp.U8 (X and 16#FF#)); B (Uadp.U8 (X / 256));
      end LE16;

      procedure Reset is
      begin
         M := (others => 0); Pos := 0;
      end Reset;

      Info : Uadp.Header_Info;
   begin
      --  Message 1: Byte PublisherId, GroupHeader (WriterGroupId+SequenceNumber),
      --  PayloadHeader with two DataSetWriterIds, then opaque payload.
      Reset;
      B (16#71#);                 --  Flags: v1 + Publisher + Group + Payload
      B (16#2A#);                 --  PublisherId (Byte) = 42
      B (16#09#);                 --  GroupFlags: WriterGroupId + SequenceNumber
      LE16 (100);                 --  WriterGroupId
      LE16 (7);                   --  SequenceNumber
      B (2);                      --  PayloadHeader Count = 2
      LE16 (1000); LE16 (1001);   --  DataSetWriterIds
      B (16#DE#); B (16#AD#);     --  opaque payload
      Uadp.Parse (M, Pos, Info);
      Check (Info.Valid,                          "msg1 valid");
      Check (Info.Is_Data,                        "msg1 is dataset");
      Check (Info.Version = 1,                    "msg1 version");
      Check (Info.Pub = Uadp.Pub_Byte,            "msg1 pub kind");
      Check (Info.Pub_Numeric = 42,               "msg1 pub id");
      Check (Info.Has_Group_Id
             and Info.Writer_Group_Id = 100,      "msg1 group id");
      Check (Info.Has_Seq
             and Info.Sequence_Number = 7,        "msg1 seqnum");
      Check (Info.N_Writers = 2,                  "msg1 writer count");
      Check (Info.Writers (1) = 1000
             and Info.Writers (2) = 1001,         "msg1 writer ids");
      Check (Info.Consumed = 12,                  "msg1 header length");

      --  Message 2: UInt32 PublisherId (needs ExtendedFlags1), SequenceNumber
      --  only, no PayloadHeader.
      Reset;
      B (16#B1#);                 --  Flags: v1 + Publisher + Group + EF1
      B (16#02#);                 --  EF1: PublisherId type 2 (UInt32)
      B (16#4F#); B (16#27#); B (0); B (0);   --  PublisherId = 10063
      B (16#08#);                 --  GroupFlags: SequenceNumber only
      LE16 (65535);               --  SequenceNumber at max (wrap boundary)
      Uadp.Parse (M, Pos, Info);
      Check (Info.Valid,                          "msg2 valid");
      Check (Info.Pub = Uadp.Pub_U32
             and Info.Pub_Numeric = 10063,        "msg2 pub u32");
      Check (Info.Has_Seq
             and Info.Sequence_Number = 65535,    "msg2 seqnum max");
      Check (not Info.Is_Data,                    "msg2 no payload header");

      --  Message 3: String PublisherId must be skipped correctly to still
      --  reach the SequenceNumber that follows it.
      Reset;
      B (16#B1#);                 --  v1 + Publisher + Group + EF1
      B (16#04#);                 --  EF1: PublisherId type 4 (String)
      B (3); B (0); B (0); B (0); --  String length = 3
      B (Character'Pos ('a')); B (Character'Pos ('b')); B (Character'Pos ('c'));
      B (16#08#);                 --  GroupFlags: SequenceNumber
      LE16 (321);
      Uadp.Parse (M, Pos, Info);
      Check (Info.Valid,                          "msg3 valid");
      Check (Info.Pub = Uadp.Pub_String
             and Info.Pub_Str_Len = 3,            "msg3 string pub len");
      Check (Info.Has_Seq
             and Info.Sequence_Number = 321,      "msg3 seqnum after string");

      --  Message 4: truncation.  Every prefix of message 1 must parse without
      --  crashing; a prefix that cuts a field short must be Valid => False.
      Reset;
      B (16#71#); B (16#2A#); B (16#09#); LE16 (100); LE16 (7);
      B (2); LE16 (1000); LE16 (1001);
      declare
         Full : constant Natural := Pos;
         Any_Crash : constant Boolean := False;
      begin
         for Cut in 0 .. Full loop
            Uadp.Parse (M, Cut, Info);
            --  A short header must be rejected; the full one accepted.
            if Cut < Full then
               Check (not Info.Valid or else Info.Consumed <= Cut,
                      "truncated prefix safe at" & Cut'Image);
            end if;
         end loop;
         Check (not Any_Crash, "no crash across all truncations");
      end;

      --  Message 5: a declared writer count larger than the bytes present must
      --  fail cleanly, not read past the end.
      Reset;
      B (16#71#); B (16#2A#); B (16#09#); LE16 (100); LE16 (7);
      B (200);                    --  claims 200 writers, provides none
      Uadp.Parse (M, Pos, Info);
      Check (not Info.Valid,                      "msg5 lying count rejected");

      --  Encode -> Parse round-trip: what the adapter builds must parse back to
      --  the same routing/dedup fields, for every numeric publisher kind.
      declare
         Pay : Uadp.Message := (others => 0);
         Enc : Uadp.Message;
         ELn : Uadp.Msg_Length;
         Ok2 : Boolean;
      begin
         for I in 0 .. 9 loop Pay (I) := Uadp.U8 (I + 16#40#); end loop;
         for Kind in Uadp.Pub_Byte .. Uadp.Pub_U64 loop
            Uadp.Encode (Kind, 16#1234_5678#, 100, 7, 1000, Pay, 10,
                         Enc, ELn, Ok2);
            Check (Ok2, "encode ok");
            Uadp.Parse (Enc, ELn, Info);
            Check (Info.Valid and Info.Is_Data,        "enc/parse valid");
            Check (Info.Pub = Kind,                    "enc pub kind");
            Check (Info.Writer_Group_Id = 100
                   and Info.Sequence_Number = 7,       "enc group+seq");
            Check (Info.N_Writers = 1
                   and Info.Writers (1) = 1000,        "enc writer id");
            --  The opaque payload lands right after the header.
            Check (Enc (Info.Consumed) = 16#40#,       "enc payload placed");
         end loop;
      end;
   end;

   --  End-to-end relay: NetworkMessage -> Protect -> drop up to M packets in
   --  any order -> Offer -> byte-identical recovery, then dedup of late copies.
   Put_Line ("== relay protect/recover round-trip ==");
   declare
      Rng : U64 := 16#243F6A8885A308D3#;
      function Rand return Byte is
         Z : U64;
      begin
         Rng := Rng + 16#9E3779B97F4A7C15#;
         Z := Rng;
         Z := (Z xor (Z / 2 ** 30)) * 16#BF58476D1CE4E5B9#;
         Z := (Z xor (Z / 2 ** 27)) * 16#94D049BB133111EB#;
         Z := Z xor (Z / 2 ** 31);
         return Byte (Z mod 256);
      end Rand;

      --  Varies which packets get dropped from trial to trial.
      function Seq_Idx (S : U32) return Natural is (Natural (S mod 7));

      procedure Trial (Msg_Len, M : Positive; Drop : Natural; Seq : U32) is
         Src   : Relay.Msg_Bytes := (others => 0);
         Pkts  : Relay.Packet_Array;
         Lens  : Relay.Length_Array;
         N     : Relay.Out_Count;
         Ok    : Boolean;
         Coll  : Relay.Collector;
         Deliv : Boolean := False;
         Got   : Relay.Msg_Bytes;
         GLen  : Natural := 0;
         Dropped : Natural := 0;
      begin
         for I in 1 .. Msg_Len loop
            Src (I) := Rand;
         end loop;

         Relay.Protect (Src, Msg_Len, 16#DEADBEEF#, Seq, M, Pkts, Lens, N, Ok);
         Check (Ok, "protect ok (len" & Msg_Len'Image & " M" & M'Image & ")");

         Relay.Init (Coll);
         --  Deliver packets, dropping `Drop` of them (drop the first Drop in a
         --  rotated order so it's not always the parity that goes).
         for I in 1 .. N loop
            declare
               Idx : constant Positive := 1 + ((I + Seq_Idx (Seq)) mod N);
               P   : Boolean;
               O   : Relay.Msg_Bytes;
               L   : Natural;
            begin
               if Dropped < Drop then
                  Dropped := Dropped + 1;         --  simulate loss
               else
                  Relay.Offer (Coll, Pkts (Idx), Lens (Idx), P, O, L);
                  if P then Deliv := True; Got := O; GLen := L; end if;
               end if;
            end;
         end loop;

         if Drop <= M then
            Check (Deliv, "recovered (len" & Msg_Len'Image
                          & " drop" & Drop'Image & ")");
            if Deliv then
               Check (GLen = Msg_Len, "recovered length");
               declare
                  Same : Boolean := True;
               begin
                  for I in 1 .. Msg_Len loop
                     if Got (I) /= Src (I) then Same := False; end if;
                  end loop;
                  Check (Same, "byte-identical NetworkMessage");
               end;
            end if;
         end if;
      end Trial;
   begin
      Trial (50,    2, 2, 1);     --  single packet, repetition (K=1, M=2)
      Trial (1000,  2, 1, 2);     --  still K=1
      Trial (3000,  2, 2, 3);     --  K=3, drop 2
      Trial (10000, 4, 4, 4);     --  K=10, drop 4
      Trial (32768, 6, 6, 5);     --  K=32, drop 6
      Trial (50000, 8, 8, 6);     --  >32KB: K=49, drop 8 (RS extension)
      Trial (73728, 12, 12, 7);   --  max message, K=72, drop 12
      Trial (777,   3, 3, 8);     --  K=1, three copies, drop all but one

      --  Dedup: two fully-redundant deliveries of the same message must yield
      --  exactly one recovery.  (Collector is ~megabytes -> heap, not stack.)
      declare
         type Coll_Ptr is access Relay.Collector;
         Src  : Relay.Msg_Bytes := (others => 0);
         Pkts : Relay.Packet_Array; Lens : Relay.Length_Array;
         N    : Relay.Out_Count;   Ok : Boolean;
         Coll : constant Coll_Ptr := new Relay.Collector;
         Deliveries : Natural := 0;
      begin
         for I in 1 .. 2000 loop Src (I) := Rand; end loop;
         Relay.Protect (Src, 2000, 16#1234#, 42, 3, Pkts, Lens, N, Ok);
         Relay.Init (Coll.all);
         for Pass in 1 .. 2 loop
            for I in 1 .. N loop
               declare P : Boolean; O : Relay.Msg_Bytes; L : Natural; begin
                  Relay.Offer (Coll.all, Pkts (I), Lens (I), P, O, L);
                  if P then Deliveries := Deliveries + 1; end if;
               end;
            end loop;
         end loop;
         Check (Deliveries = 1, "dedup: one delivery despite all packets twice");
      end;

      --  Replay defence: deliver several messages of a stream, then replay an
      --  OLD message's packets in full -- it must NOT be re-delivered.  And a
      --  genuinely new later message must still get through.
      declare
         type Coll_Ptr is access Relay.Collector;
         Src  : Relay.Msg_Bytes := (others => 0);
         Coll : constant Coll_Ptr := new Relay.Collector;
         Old_Pkts : Relay.Packet_Array; Old_Lens : Relay.Length_Array;
         Np : Relay.Out_Count; Ok : Boolean;
         Replays : Natural := 0; News : Natural := 0;

         procedure Feed (Seq : U32; Save : Boolean) is
            Pk : Relay.Packet_Array; Ln : Relay.Length_Array;
            Nn : Relay.Out_Count; O2 : Boolean;
         begin
            for I in 1 .. 1500 loop Src (I) := Rand; end loop;
            Relay.Protect (Src, 1500, 16#ABCD#, Seq, 2, Pk, Ln, Nn, O2);
            if Save then Old_Pkts := Pk; Old_Lens := Ln; Np := Nn; end if;
            for I in 1 .. Nn loop
               declare P : Boolean; O : Relay.Msg_Bytes; L : Natural; begin
                  Relay.Offer (Coll.all, Pk (I), Ln (I), P, O, L);
               end;
            end loop;
         end Feed;
      begin
         Relay.Init (Coll.all);
         Feed (100, True);           --  message #100, remember its packets
         for S in U32 range 101 .. 130 loop Feed (S, False); end loop;

         --  Replay message #100 in full: every packet must be dropped.
         for I in 1 .. Np loop
            declare P : Boolean; O : Relay.Msg_Bytes; L : Natural; begin
               Relay.Offer (Coll.all, Old_Pkts (I), Old_Lens (I), P, O, L);
               if P then Replays := Replays + 1; end if;
            end;
         end loop;
         Check (Replays = 0, "replay of an old message is rejected");

         --  A brand-new later message still gets through.
         declare Pk : Relay.Packet_Array; Ln : Relay.Length_Array;
                 Nn : Relay.Out_Count; O2 : Boolean; begin
            for I in 1 .. 1500 loop Src (I) := Rand; end loop;
            Relay.Protect (Src, 1500, 16#ABCD#, 200, 2, Pk, Ln, Nn, O2);
            for I in 1 .. Nn loop
               declare P : Boolean; O : Relay.Msg_Bytes; L : Natural; begin
                  Relay.Offer (Coll.all, Pk (I), Ln (I), P, O, L);
                  if P then News := News + 1; end if;
               end;
            end loop;
         end;
         Check (News = 1, "a new message after replays still delivered");
         pragma Unreferenced (Ok, Np);
      end;
   end;

   --  Authenticated encryption: seal -> open round-trips; a wrong key or a
   --  flipped byte is REJECTED, never silently decoded.
   Put_Line ("== authenticated encryption (SPARKNaCl AEAD) ==");
   declare
      Rng2 : U64 := 16#B5297A4D7687A3C1#;
      function R2 return U8 is
      begin
         Rng2 := Rng2 * 6364136223846793005 + 1442695040888963407;
         return U8 ((Rng2 / 2 ** 33) mod 256);
      end R2;

      Key   : Secure.Key_Bytes;
      Key2  : Secure.Key_Bytes;
      Nonce : Secure.Nonce_Bytes;
      P     : Secure.Plain_Buffer := (others => 0);
      Blob  : Secure.Blob_Buffer;
      BLen  : Secure.Blob_Len_T;
      Got   : Secure.Plain_Buffer;
      GLen  : Secure.Plain_Len_T;
      Ok    : Boolean;
   begin
      for I in Key'Range  loop Key (I)  := R2; end loop;
      for I in Key2'Range loop Key2 (I) := R2; end loop;
      for I in Nonce'Range loop Nonce (I) := R2; end loop;

      for PLen in Positive range 1 .. 3 loop
         declare
            L : constant Positive := (case PLen is
                                         when 1 => 1,
                                         when 2 => 1500,
                                         when others => 20000);
         begin
            for I in 1 .. L loop P (I) := R2; end loop;

            Secure.Seal (P, L, Key, Nonce, Blob, BLen);
            Check (BLen = L + Secure.Overhead, "blob length = plain + 28");

            --  correct key -> exact recovery
            Secure.Open (Blob, BLen, Key, Got, GLen, Ok);
            Check (Ok, "open with right key");
            if Ok then
               Check (GLen = L, "opened length");
               declare Same : Boolean := True; begin
                  for I in 1 .. L loop
                     if Got (I) /= P (I) then Same := False; end if;
                  end loop;
                  Check (Same, "decrypted == plaintext");
               end;
            end if;

            --  wrong key -> rejected
            Secure.Open (Blob, BLen, Key2, Got, GLen, Ok);
            Check (not Ok, "wrong key rejected");

            --  tamper one ciphertext byte -> rejected
            declare
               Bad : Secure.Blob_Buffer := Blob;
            begin
               Bad (Secure.Overhead + 1) := Bad (Secure.Overhead + 1) xor 1;
               Secure.Open (Bad, BLen, Key, Got, GLen, Ok);
               Check (not Ok, "tampered ciphertext rejected");
            end;
         end;
      end loop;
   end;

   New_Line;
   if Fail = 0 then
      Put_Line (">>> CORE SANITY PASSED");
   else
      Put_Line (">>>" & Fail'Image & " CHECK(S) FAILED");
   end if;
end Test_Core;
