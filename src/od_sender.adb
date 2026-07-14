--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  od_sender -- the high-security side of the OPC UA PubSub data diode.
--
--  Receive UADP NetworkMessages the publisher sends on a UDP port, protect each
--  with Reed-Solomon (parity sized by --parity), and blast the resulting diode
--  packets one-way to the receiver.  There is no return path.
--
--  This is the TRUSTED shell (SPARK_Mode => Off): it owns the sockets.  All the
--  algorithmic work -- header parse, fragmentation, erasure coding, framing --
--  is done by the proven core (Uadp, Relay, Diode_Wire).
--
--  Usage:
--    od_sender <in_port> <diode_ip> <diode_port> [--parity M] [--pace-us N]
--  The publisher must send NetworkMessages to <in_port> on this host.

pragma Ada_2022;
with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Streams;              use Ada.Streams;
with GNAT.Sockets;             use GNAT.Sockets;
with GNAT.OS_Lib;
with Wire_Types;               use Wire_Types;
with Uadp;
with Rs;
with Relay;
with Od_Stream;

procedure Od_Sender with SPARK_Mode => Off is

   In_Sock, Out_Sock : Socket_Type;
   Parity  : Natural := 2;
   Pace_Us : Natural := 0;

   --  Per-stream monotonic message counters (small fixed table).
   Max_Streams : constant := 64;
   type Stream_Slot is record
      Id   : U64 := 0;
      Seq  : U32 := 0;
      Used : Boolean := False;
   end record;
   Streams : array (1 .. Max_Streams) of Stream_Slot;

   function Next_Seq (Id : U64) return U32 is
      Free : Natural := 0;
   begin
      for I in Streams'Range loop
         if Streams (I).Used and then Streams (I).Id = Id then
            Streams (I).Seq := Streams (I).Seq + 1;
            return Streams (I).Seq;
         end if;
         if not Streams (I).Used and then Free = 0 then
            Free := I;
         end if;
      end loop;
      if Free = 0 then Free := 1; end if;         --  evict slot 1 if full
      Streams (Free) := (Id => Id, Seq => 1, Used => True);
      return 1;
   end Next_Seq;

   Argi : Natural := 1;
begin
   --  ---- CLI ----
   if Argument_Count < 3 then
      Put_Line (Standard_Error,
        "[usage] od_sender <in_port> <diode_ip> <diode_port>"
        & " [--parity M] [--pace-us N]");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   declare
      In_Port    : constant Port_Type := Port_Type'Value (Argument (1));
      Diode_IP   : constant String    := Argument (2);
      Diode_Port : constant Port_Type := Port_Type'Value (Argument (3));
   begin
      Argi := 4;
      while Argi <= Argument_Count loop
         if Argument (Argi) = "--parity" and then Argi < Argument_Count then
            Argi := Argi + 1; Parity := Natural'Value (Argument (Argi));
         elsif Argument (Argi) = "--pace-us" and then Argi < Argument_Count then
            Argi := Argi + 1; Pace_Us := Natural'Value (Argument (Argi));
         end if;
         Argi := Argi + 1;
      end loop;
      if Parity < 1 then Parity := 1; end if;
      if Parity > Rs.Max_M then Parity := Rs.Max_M; end if;

      Create_Socket (In_Sock, Family_Inet, Socket_Datagram);
      Set_Socket_Option (In_Sock, Socket_Level, (Reuse_Address, True));
      Bind_Socket (In_Sock,
        (Family => Family_Inet, Addr => Any_Inet_Addr, Port => In_Port));

      Create_Socket (Out_Sock, Family_Inet, Socket_Datagram);
      Connect_Socket (Out_Sock,
        (Family => Family_Inet, Addr => Inet_Addr (Diode_IP), Port => Diode_Port));

      Put_Line (Standard_Error,
        "[od_sender] in=" & Argument (1) & " -> diode " & Diode_IP & ":"
        & Argument (3) & "  parity=" & Parity'Image);
   end;

   --  ---- main loop ----
   declare
      In_Buf  : Stream_Element_Array (1 .. Stream_Element_Offset (Uadp.Max_Msg));
      Last    : Stream_Element_Offset;
      From    : Sock_Addr_Type;
      Info    : Uadp.Header_Info;
      Msg     : Relay.Msg_Bytes;
      Pkts    : Relay.Packet_Array;
      Lens    : Relay.Length_Array;
      N_Out   : Relay.Out_Count;
      Ok      : Boolean;
      UMsg    : Uadp.Message := (others => 0);
   begin
      loop
         Receive_Socket (In_Sock, In_Buf, Last, From);
         exit when Last < In_Buf'First;             --  socket closed

         declare
            L : constant Natural := Natural (Last - In_Buf'First + 1);
         begin
            if L > 0 and then L <= Relay.Max_Msg_Len then
               --  Copy datagram into both the UADP view and the relay input.
               for I in 1 .. L loop
                  UMsg (I - 1) := U8 (In_Buf (In_Buf'First + Stream_Element_Offset (I - 1)));
                  Msg (I)      := U8 (In_Buf (In_Buf'First + Stream_Element_Offset (I - 1)));
               end loop;

               Uadp.Parse (UMsg, L, Info);
               declare
                  SID : constant U64 :=
                    (if Info.Valid then Od_Stream.Stream_Of (Info) else 0);
                  Seq : constant U32 := Next_Seq (SID);
               begin
                  Relay.Protect (Msg, L, SID, Seq, Parity,
                                 Pkts, Lens, N_Out, Ok);
                  if Ok then
                     for S in 1 .. N_Out loop
                        declare
                           OB : Stream_Element_Array
                             (1 .. Stream_Element_Offset (Lens (S)));
                           OL : Stream_Element_Offset;
                        begin
                           for J in 1 .. Lens (S) loop
                              OB (Stream_Element_Offset (J)) :=
                                Stream_Element (Pkts (S) (J - 1));
                           end loop;
                           Send_Socket (Out_Sock, OB, OL);
                        end;
                        if Pace_Us > 0 then
                           delay Duration (Pace_Us) / 1_000_000.0;
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;
   end;
end Od_Sender;
