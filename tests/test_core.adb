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

procedure Test_Core is

   use type Byte;
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

   New_Line;
   if Fail = 0 then
      Put_Line (">>> CORE SANITY PASSED");
   else
      Put_Line (">>>" & Fail'Image & " CHECK(S) FAILED");
   end if;
end Test_Core;
