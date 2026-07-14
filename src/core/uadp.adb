--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  UADP header parser body.  A bounded cursor walks the buffer; every read is
--  guarded by "cursor + size <= Len" and refuses (setting Ok => False) rather
--  than run past the end.  All scalars are little-endian (Part 6 5.2.2), and
--  every value type is modular, so the byte-assembly arithmetic cannot overflow
--  -- there is simply no run-time check for it to fail.  The whole proof
--  obligation here is therefore just array-index safety, and it follows from
--  the guards.

package body Uadp with SPARK_Mode => On is

   use type Wire_Types.U8, Wire_Types.U16, Wire_Types.U32, Wire_Types.U64;

   --  ---- bounded readers -------------------------------------------------
   --  Each advances Cur by the field size, but only if the field fits; if it
   --  does not, Ok becomes False and Cur is left <= Len.  Once Ok is False it
   --  stays False, so a single end check at the end of Parse is enough.

   procedure Get8
     (Buf : Message; Len : Msg_Length;
      Cur : in out Msg_Length; Ok : in out Boolean; V : out U8)
     with Pre  => Cur <= Len,
          Post => Cur <= Len
   is
   begin
      if Ok and then Cur < Len then
         V   := Buf (Cur);
         Cur := Cur + 1;
      else
         V  := 0;
         Ok := False;
      end if;
   end Get8;

   procedure Get16
     (Buf : Message; Len : Msg_Length;
      Cur : in out Msg_Length; Ok : in out Boolean; V : out U16)
     with Pre  => Cur <= Len,
          Post => Cur <= Len
   is
      B0, B1 : U8;
   begin
      Get8 (Buf, Len, Cur, Ok, B0);
      Get8 (Buf, Len, Cur, Ok, B1);
      V := U16 (B0) + U16 (B1) * 256;
   end Get16;

   procedure Get32
     (Buf : Message; Len : Msg_Length;
      Cur : in out Msg_Length; Ok : in out Boolean; V : out U32)
     with Pre  => Cur <= Len,
          Post => Cur <= Len
   is
      B0, B1, B2, B3 : U8;
   begin
      Get8 (Buf, Len, Cur, Ok, B0);
      Get8 (Buf, Len, Cur, Ok, B1);
      Get8 (Buf, Len, Cur, Ok, B2);
      Get8 (Buf, Len, Cur, Ok, B3);
      V := U32 (B0)
         + U32 (B1) * 2 ** 8
         + U32 (B2) * 2 ** 16
         + U32 (B3) * 2 ** 24;
   end Get32;

   procedure Get64
     (Buf : Message; Len : Msg_Length;
      Cur : in out Msg_Length; Ok : in out Boolean; V : out U64)
     with Pre  => Cur <= Len,
          Post => Cur <= Len
   is
      Lo, Hi : U32;
   begin
      Get32 (Buf, Len, Cur, Ok, Lo);
      Get32 (Buf, Len, Cur, Ok, Hi);
      V := U64 (Lo) + U64 (Hi) * 2 ** 32;
   end Get64;

   procedure Skip
     (Len : Msg_Length; N : Natural;
      Cur : in out Msg_Length; Ok : in out Boolean)
     with Pre  => Cur <= Len,
          Post => Cur <= Len
   is
   begin
      --  N <= Len - Cur is the same as Cur + N <= Len, but written so the
      --  subtraction is on naturals with Cur <= Len already known.
      if Ok and then N <= Len - Cur then
         Cur := Cur + N;
      else
         Ok := False;
      end if;
   end Skip;

   -----------
   -- Parse --
   -----------

   procedure Parse (Buf : Message; Len : Msg_Length; Info : out Header_Info) is
      Cur : Msg_Length := 0;
      Ok  : Boolean    := True;

      Flags : U8;
      GF    : U8;

      --  EF1/EF2 are read (bit tests) under the same Has_EF* guard that also
      --  assigns them, but SPARK's flow analysis does not correlate the two
      --  branches; a defined default makes the read provably initialised.
      EF1   : U8 := 0;
      EF2   : U8 := 0;

      Has_EF1, Has_EF2 : Boolean;
   begin
      Info := (Valid => False, Is_Data => False, Version => 0,
               Pub => Pub_None, Pub_Numeric => 0,
               Pub_Str_Off => 0, Pub_Str_Len => 0,
               Has_Group_Id => False, Writer_Group_Id => 0,
               Has_Seq => False, Sequence_Number => 0,
               N_Writers => 0, Writers => (others => 0),
               Consumed => 0);

      --  UADPFlags: bits 0-3 version, 4 PublisherId, 5 GroupHeader,
      --             6 PayloadHeader, 7 ExtendedFlags1.
      Get8 (Buf, Len, Cur, Ok, Flags);
      Info.Version := Flags and 16#0F#;

      Has_EF1 := (Flags and 16#80#) /= 0;
      if Has_EF1 then
         Get8 (Buf, Len, Cur, Ok, EF1);
      end if;

      --  ExtendedFlags1 bit 7 -> ExtendedFlags2 present.
      Has_EF2 := Has_EF1 and then (EF1 and 16#80#) /= 0;
      if Has_EF2 then
         Get8 (Buf, Len, Cur, Ok, EF2);
      end if;

      --  PublisherId (UADPFlags bit 4).  Type is ExtendedFlags1 bits 0-2, or
      --  Byte if ExtendedFlags1 is absent.
      if (Flags and 16#10#) /= 0 then
         declare
            PType : constant U8 := (if Has_EF1 then EF1 and 16#07# else 0);
         begin
            case PType is
               when 0 =>
                  declare V : U8; begin
                     Get8 (Buf, Len, Cur, Ok, V);
                     Info.Pub := Pub_Byte; Info.Pub_Numeric := U64 (V);
                  end;
               when 1 =>
                  declare V : U16; begin
                     Get16 (Buf, Len, Cur, Ok, V);
                     Info.Pub := Pub_U16; Info.Pub_Numeric := U64 (V);
                  end;
               when 2 =>
                  declare V : U32; begin
                     Get32 (Buf, Len, Cur, Ok, V);
                     Info.Pub := Pub_U32; Info.Pub_Numeric := U64 (V);
                  end;
               when 3 =>
                  declare V : U64; begin
                     Get64 (Buf, Len, Cur, Ok, V);
                     Info.Pub := Pub_U64; Info.Pub_Numeric := V;
                  end;
               when 4 =>
                  --  String: Int32 length prefix + UTF-8 bytes; -1 == null.
                  declare
                     Raw : U32;
                  begin
                     Get32 (Buf, Len, Cur, Ok, Raw);
                     Info.Pub := Pub_String;
                     if Raw = 16#FFFF_FFFF# then
                        Info.Pub_Str_Off := Cur;    --  null: zero-length
                        Info.Pub_Str_Len := 0;
                     elsif Raw <= U32 (Max_Msg) then
                        Info.Pub_Str_Off := Cur;
                        Info.Pub_Str_Len := Natural (Raw);
                        Skip (Len, Natural (Raw), Cur, Ok);
                     else
                        Ok := False;                --  absurd length
                     end if;
                  end;
               when others =>
                  Ok := False;                      --  reserved PublisherId type
            end case;
         end;
      end if;

      --  DataSetClassId (ExtendedFlags1 bit 3): a 16-byte GUID.
      if Has_EF1 and then (EF1 and 16#08#) /= 0 then
         Skip (Len, 16, Cur, Ok);
      end if;

      --  GroupHeader (UADPFlags bit 5).
      if (Flags and 16#20#) /= 0 then
         Get8 (Buf, Len, Cur, Ok, GF);
         if (GF and 16#01#) /= 0 then               --  WriterGroupId : U16
            declare V : U16; begin
               Get16 (Buf, Len, Cur, Ok, V);
               Info.Has_Group_Id := True; Info.Writer_Group_Id := V;
            end;
         end if;
         if (GF and 16#02#) /= 0 then               --  GroupVersion : 4 bytes
            Skip (Len, 4, Cur, Ok);
         end if;
         if (GF and 16#04#) /= 0 then               --  NetworkMessageNumber : U16
            Skip (Len, 2, Cur, Ok);
         end if;
         if (GF and 16#08#) /= 0 then               --  SequenceNumber : U16
            declare V : U16; begin
               Get16 (Buf, Len, Cur, Ok, V);
               Info.Has_Seq := True; Info.Sequence_Number := V;
            end;
         end if;
      end if;

      --  PayloadHeader (UADPFlags bit 6).  We handle the DataSetMessage type
      --  (ExtendedFlags2 bits 2-4 = 0), which is the process-data case; other
      --  types (discovery) have a different payload header we do not route on.
      if (Flags and 16#40#) /= 0 then
         declare
            NM_Type : constant U8 :=
              (if Has_EF2 then (EF2 / 4) and 16#07# else 0);
         begin
            if NM_Type = 0 then
               Info.Is_Data := True;
               declare
                  Count : U8;
               begin
                  Get8 (Buf, Len, Cur, Ok, Count);
                  --  DataSetWriterIds : U16[Count].  Count is a Byte, so it
                  --  cannot exceed Max_Writers -- no truncation possible.
                  if Ok then
                     Info.N_Writers := Natural (Count);
                     for I in 1 .. Natural (Count) loop
                        pragma Loop_Invariant (Cur <= Len);
                        pragma Loop_Invariant (I <= Max_Writers);
                        declare V : U16; begin
                           Get16 (Buf, Len, Cur, Ok, V);
                           Info.Writers (I) := V;
                        end;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end if;

      Info.Consumed := Cur;
      Info.Valid    := Ok;
   end Parse;

end Uadp;
