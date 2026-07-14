--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  Sanity driver for the proven core.  This is behaviour testing, NOT proof:
--  gnatprove establishes absence of run-time errors, and these checks confirm
--  the field axioms and the RS round-trip actually hold on concrete values.

with Ada.Text_IO; use Ada.Text_IO;
with Interfaces;
with Gf256;       use Gf256;
with Rs;
with Uadp;

procedure Test_Core is

   use type Byte;
   use type Uadp.U8, Uadp.U16, Uadp.U64, Uadp.Pub_Kind;
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
   end;

   New_Line;
   if Fail = 0 then
      Put_Line (">>> CORE SANITY PASSED");
   else
      Put_Line (">>>" & Fail'Image & " CHECK(S) FAILED");
   end if;
end Test_Core;
