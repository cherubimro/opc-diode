--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  od_shadow -- low-side output adapter: expose the diode's UADP stream to
--  client/server subscribers via a shadow OPC UA server.
--
--  Receives the recovered NetworkMessages od_receiver re-emits (UDP), parses
--  the UADP header with the proven Uadp.Parse to find the DataSetWriterId, maps
--  it to a NodeId, and writes the DataSetMessage payload into that node of the
--  shadow server (Opc_Server).  Subscribers connect to the shadow server; their
--  sessions stay on the low side -- only one-way UADP crossed the diode.
--
--  Usage:
--    od_shadow <in_port> <server_xml> <addrspace_xml>
--              --node <node_id> <writer_id> [--node ...]

pragma Ada_2022;
with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Streams;       use Ada.Streams;
with GNAT.Sockets;      use GNAT.Sockets;
with GNAT.OS_Lib;
with Wire_Types;        use Wire_Types;
with Uadp;
with Opc_Server;

procedure Od_Shadow with SPARK_Mode => Off is

   use type Uadp.U16;

   --  writer_id -> NodeId map (fixed table from --node args).
   Max_Map : constant := 128;
   type Map_Entry is record
      Wid  : U16 := 0;
      Node : String (1 .. 128) := (others => ' ');
      NLen : Natural := 0;
      Used : Boolean := False;
   end record;
   Map : array (1 .. Max_Map) of Map_Entry;
   N_Map : Natural := 0;

   function Node_Of (Wid : U16) return String is
   begin
      for I in 1 .. N_Map loop
         if Map (I).Used and then Map (I).Wid = Wid then
            return Map (I).Node (1 .. Map (I).NLen);
         end if;
      end loop;
      return "";
   end Node_Of;

   In_Sock : Socket_Type;
begin
   if Argument_Count < 3 then
      Put_Line (Standard_Error,
        "[usage] od_shadow <in_port> <server_xml> <addrspace_xml>"
        & " --node <node_id> <writer_id> [--node ...]");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   if not Opc_Server.Available then
      Put_Line (Standard_Error,
        "[od_shadow] no OPC UA server stack in this build.  Rebuild with"
        & "  WITH_OPCUA=s2opc ./tools/build.sh   (or =open62541)");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   declare
      In_Port : constant Port_Type := Port_Type'Value (Argument (1));
      Ok      : Boolean;
   begin
      Opc_Server.Start (Argument (2), Argument (3), Ok);
      if not Ok then
         Put_Line (Standard_Error, "[od_shadow] server start failed");
         GNAT.OS_Lib.OS_Exit (1);
      end if;

      --  Parse --node <id> <writer> pairs.
      declare
         A : Natural := 4;
      begin
         while A <= Argument_Count loop
            if Argument (A) = "--node" and then A + 1 < Argument_Count
              and then N_Map < Max_Map
            then
               declare
                  Nd : constant String := Argument (A + 1);
                  Wd : constant U16 := U16 (Natural'Value (Argument (A + 2)));
                  L  : constant Natural := Natural'Min (Nd'Length, 128);
               begin
                  N_Map := N_Map + 1;
                  Map (N_Map).Wid  := Wd;
                  Map (N_Map).Node (1 .. L) := Nd (Nd'First .. Nd'First + L - 1);
                  Map (N_Map).NLen := L;
                  Map (N_Map).Used := True;
                  declare Ao : Boolean; begin
                     Opc_Server.Add_Node (Nd, Ao);
                  end;
                  A := A + 2;
               end;
            end if;
            A := A + 1;
         end loop;
      end;

      Create_Socket (In_Sock, Family_Inet, Socket_Datagram);
      Set_Socket_Option (In_Sock, Socket_Level, (Reuse_Address, True));
      Bind_Socket (In_Sock,
        (Family => Family_Inet, Addr => Any_Inet_Addr, Port => In_Port));
      Put_Line (Standard_Error,
        "[od_shadow] UADP on " & Argument (1) & " -> shadow OPC UA server");
   end;

   --  Main loop: receive NetworkMessage, parse, write the payload to its node.
   declare
      In_Buf : Stream_Element_Array
        (1 .. Stream_Element_Offset (Uadp.Max_Msg));
      Last : Stream_Element_Offset;
      From : Sock_Addr_Type;
      UMsg : Uadp.Message := (others => 0);
      Info : Uadp.Header_Info;
   begin
      loop
         Receive_Socket (In_Sock, In_Buf, Last, From);
         exit when Last < In_Buf'First;
         declare
            L : constant Natural := Natural (Last - In_Buf'First + 1);
         begin
            if L > 0 and then L <= Uadp.Max_Msg then
               for I in 1 .. L loop
                  UMsg (I - 1) :=
                    U8 (In_Buf (In_Buf'First + Stream_Element_Offset (I - 1)));
               end loop;
               Uadp.Parse (UMsg, L, Info);
               if Info.Valid and then Info.Is_Data and then Info.N_Writers >= 1
               then
                  declare
                     Node : constant String := Node_Of (Info.Writers (1));
                     PLen : constant Natural := L - Info.Consumed;
                  begin
                     if Node /= "" and then PLen > 0
                       and then PLen <= Opc_Server.Max_Val
                     then
                        declare
                           V  : Opc_Server.Val_Bytes := (others => 0);
                           Ok : Boolean;
                        begin
                           for I in 1 .. PLen loop
                              V (I) := UMsg (Info.Consumed + I - 1);
                           end loop;
                           Opc_Server.Write (Node, V, PLen, Ok);
                        end;
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
   end;
end Od_Shadow;
