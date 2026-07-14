--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton

with Ada.Calendar; use Ada.Calendar;

package body Od_Key with SPARK_Mode => Off is

   function Nibble (C : Character; Ok : in out Boolean) return U8 is
   begin
      case C is
         when '0' .. '9' => return U8 (Character'Pos (C) - Character'Pos ('0'));
         when 'a' .. 'f' => return U8 (Character'Pos (C) - Character'Pos ('a') + 10);
         when 'A' .. 'F' => return U8 (Character'Pos (C) - Character'Pos ('A') + 10);
         when others     => Ok := False; return 0;
      end case;
   end Nibble;

   procedure Parse_Hex (S : String; Key : out Secure.Key_Bytes; Ok : out Boolean)
   is
      P : Natural := S'First;
   begin
      Key := (others => 0);
      Ok  := (S'Length = 2 * Secure.Key_Len);
      if not Ok then
         return;
      end if;
      for I in Key'Range loop
         declare
            Hi : constant U8 := Nibble (S (P), Ok);
            Lo : constant U8 := Nibble (S (P + 1), Ok);
         begin
            Key (I) := Hi * 16 + Lo;
         end;
         P := P + 2;
      end loop;
   end Parse_Hex;

   function Run_Epoch return U32 is
      --  Seconds-of-day at startup, mixed, gives a distinct value each run.
      Now : constant Duration := Seconds (Clock);
      S   : constant U64 := U64 (Long_Long_Integer (Now * 1000.0));
      Z   : U64 := S * 16#2545F4914F6CDD1D# + 16#9E3779B97F4A7C15#;
   begin
      Z := (Z xor (Z / 2 ** 32));
      return U32 (Z mod 2 ** 32);
   end Run_Epoch;

end Od_Key;
