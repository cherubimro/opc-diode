--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  od_probe -- loopback test harness for the OPC diode shell.
--
--    od_probe send <dst_ip> <dst_port> <count> <seed> <maxlen>
--        emit `count` synthetic UADP NetworkMessages (deterministic from seed)
--        to dst, printing each message's length + a checksum to stdout.
--    od_probe recv <bind_port> <count> <seed> <maxlen>
--        receive `count` NetworkMessages, regenerate the expected ones from the
--        same seed, and verify each arrival is byte-identical.  Exit 0 if all
--        matched, 1 otherwise.
--
--  The two are wired by tools/loopback-test.sh through od_sender / od_receiver.

pragma Ada_2022;
with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Streams;              use Ada.Streams;
with GNAT.Sockets;             use GNAT.Sockets;
with GNAT.OS_Lib;
with Interfaces;               use Interfaces;

procedure Od_Probe is

   --  Deterministic SplitMix64 stream, so send and recv agree with no channel.
   type Gen is record
      S : Unsigned_64;
   end record;

   procedure Seed (G : out Gen; V : Unsigned_64) is
   begin
      G.S := V;
   end Seed;

   function Next (G : in out Gen) return Unsigned_64 is
      Z : Unsigned_64;
   begin
      G.S := G.S + 16#9E3779B97F4A7C15#;
      Z := G.S;
      Z := (Z xor Shift_Right (Z, 30)) * 16#BF58476D1CE4E5B9#;
      Z := (Z xor Shift_Right (Z, 27)) * 16#94D049BB133111EB#;
      return Z xor Shift_Right (Z, 31);
   end Next;

   --  Build message number I (deterministic) into Buf; return its length.  It
   --  is a syntactically real UADP NetworkMessage: Byte publisher + group with
   --  SequenceNumber + one DataSetWriterId + a pseudo-random opaque payload.
   procedure Make
     (Seed_V : Unsigned_64; I : Positive; Max_Len : Positive;
      Buf : out Stream_Element_Array; Len : out Stream_Element_Offset)
   is
      G  : Gen;
      P  : Stream_Element_Offset := Buf'First;
      procedure B (X : Unsigned_64) is
      begin
         Buf (P) := Stream_Element (X mod 256); P := P + 1;
      end B;
   begin
      Seed (G, Seed_V + Unsigned_64 (I));
      declare
         Body_Len : constant Positive :=
           1 + Integer (Next (G) mod Unsigned_64 (Max_Len));
      begin
         B (16#71#);                       --  Flags: v1 + Pub + Group + Payload
         B (Next (G));                     --  PublisherId (Byte)
         B (16#08#);                       --  GroupFlags: SequenceNumber
         B (Unsigned_64 (I) mod 256); B (Unsigned_64 (I) / 256 mod 256);  --  seq
         B (1);                            --  PayloadHeader Count = 1
         B (16#E8#); B (16#03#);           --  DataSetWriterId = 1000
         for K in 1 .. Body_Len loop
            B (Next (G));                  --  opaque payload
         end loop;
      end;
      Len := P - Buf'First;
   end Make;

begin
   if Argument_Count < 1 then
      Put_Line (Standard_Error, "usage: od_probe send|recv ..."); return;
   end if;

   if Argument (1) = "send" then
      declare
         Dst   : constant String   := Argument (2);
         Port  : constant Port_Type := Port_Type'Value (Argument (3));
         Count : constant Positive := Positive'Value (Argument (4));
         SeedV : constant Unsigned_64 := Unsigned_64'Value (Argument (5));
         MaxL  : constant Positive := Positive'Value (Argument (6));
         Sock  : Socket_Type;
         Buf   : Stream_Element_Array (1 .. 40000);
         Len   : Stream_Element_Offset;
         Last  : Stream_Element_Offset;
      begin
         Create_Socket (Sock, Family_Inet, Socket_Datagram);
         Connect_Socket (Sock,
           (Family => Family_Inet, Addr => Inet_Addr (Dst), Port => Port));
         for I in 1 .. Count loop
            Make (SeedV, I, MaxL, Buf, Len);
            Send_Socket (Sock, Buf (1 .. Len), Last);
            delay 0.003;                   --  let the pipeline breathe
         end loop;
      end;

   elsif Argument (1) = "recv" then
      declare
         Port  : constant Port_Type := Port_Type'Value (Argument (2));
         Count : constant Positive := Positive'Value (Argument (3));
         SeedV : constant Unsigned_64 := Unsigned_64'Value (Argument (4));
         MaxL  : constant Positive := Positive'Value (Argument (5));
         Sock  : Socket_Type;
         RBuf  : Stream_Element_Array (1 .. 40000);
         Last  : Stream_Element_Offset;
         From  : Sock_Addr_Type;
         Exp   : Stream_Element_Array (1 .. 40000);
         ELen  : Stream_Element_Offset;
         Seen  : array (1 .. Count) of Boolean := (others => False);
         Got   : Natural := 0;
         Bad   : Natural := 0;
      begin
         Create_Socket (Sock, Family_Inet, Socket_Datagram);
         Set_Socket_Option (Sock, Socket_Level, (Reuse_Address, True));
         Set_Socket_Option
           (Sock, Socket_Level, (Receive_Timeout, Timeout => 10.0));
         Bind_Socket (Sock,
           (Family => Family_Inet, Addr => Any_Inet_Addr, Port => Port));

         loop
            begin
               Receive_Socket (Sock, RBuf, Last, From);
            exception
               when Socket_Error => exit;   --  timeout: no more coming
            end;
            exit when Last < RBuf'First;

            --  Identify which message this is by matching against regenerated
            --  candidates (small Count, linear scan is fine for a test).
            declare
               Matched : Boolean := False;
            begin
               for I in 1 .. Count loop
                  if not Seen (I) then
                     Make (SeedV, I, MaxL, Exp, ELen);
                     if ELen = Last - RBuf'First + 1
                       and then RBuf (RBuf'First .. Last) = Exp (1 .. ELen)
                     then
                        Seen (I) := True; Matched := True; Got := Got + 1;
                        exit;
                     end if;
                  end if;
               end loop;
               if not Matched then Bad := Bad + 1; end if;
            end;
            exit when Got = Count;
         end loop;

         Put_Line ("recovered" & Got'Image & " /" & Count'Image
                   & "   mismatched:" & Bad'Image);
         if Got = Count and then Bad = 0 then
            Put_Line (">>> LOOPBACK OK");
         else
            Put_Line (">>> LOOPBACK FAILED");
            GNAT.OS_Lib.OS_Exit (1);
         end if;
      end;
   end if;
end Od_Probe;
