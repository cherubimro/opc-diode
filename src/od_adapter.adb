--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  od_adapter -- high-side input adapter: turn a client/server OPC UA source
--  into PubSub for a diode that only carries UADP.
--
--  It is an OPC UA client to the source server, and a UADP producer to
--  od_sender: it subscribes to variables, and for each update frames the
--  DataSetMessage the stack encoded (via the proven Uadp.Encode) into a
--  NetworkMessage and sends it by UDP to od_sender's input port.
--
--  Runs ENTIRELY on the high-security side.  The client stack and its
--  bidirectional session live here, behind the diode; only one-way UADP crosses.
--
--  Usage:
--    od_adapter <endpoint> <sender_ip> <sender_port>
--               --node <node_id> <writer_id> [--node ...] [--interval MS]
--    e.g.  od_adapter opc.tcp://plc:4840 127.0.0.1 9701 \
--            --node "ns=2;i=42" 1001 --node "ns=2;i=43" 1002

pragma Ada_2022;
with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Streams;       use Ada.Streams;
with GNAT.Sockets;      use GNAT.Sockets;
with GNAT.OS_Lib;
with Wire_Types;        use Wire_Types;
with Uadp;
with Opc_Client;

procedure Od_Adapter with SPARK_Mode => Off is

   Pub_Id      : constant U64 := 1;      --  our PublisherId (U16)
   Group_Id    : constant U16 := 1;      --  WriterGroupId
   Interval_Ms : Natural := 200;

   Sock : Socket_Type;
   Seq  : U16 := 0;
begin
   if Argument_Count < 3 then
      Put_Line (Standard_Error,
        "[usage] od_adapter <endpoint> <sender_ip> <sender_port>"
        & " --node <node_id> <writer_id> [--node ...] [--interval MS]");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   if not Opc_Client.Available then
      Put_Line (Standard_Error,
        "[od_adapter] no OPC UA client stack in this build.  Rebuild with"
        & "  WITH_OPCUA=s2opc ./tools/build.sh   (or =open62541)");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   declare
      Endpoint : constant String    := Argument (1);
      Snd_IP   : constant String    := Argument (2);
      Snd_Port : constant Port_Type := Port_Type'Value (Argument (3));
      Ok       : Boolean;
   begin
      Opc_Client.Init (Endpoint, Ok);
      if not Ok then
         Put_Line (Standard_Error, "[od_adapter] cannot connect " & Endpoint);
         GNAT.OS_Lib.OS_Exit (1);
      end if;

      --  Parse --node <id> <writer> pairs and --interval.
      declare
         A : Natural := 4;
      begin
         while A <= Argument_Count loop
            if Argument (A) = "--interval" and then A < Argument_Count then
               A := A + 1; Interval_Ms := Natural'Value (Argument (A));
            elsif Argument (A) = "--node" and then A + 1 < Argument_Count then
               declare
                  Node : constant String := Argument (A + 1);
                  Wid  : constant U16 := U16 (Natural'Value (Argument (A + 2)));
                  So   : Boolean;
               begin
                  Opc_Client.Subscribe (Node, Wid, Interval_Ms, So);
                  if not So then
                     Put_Line (Standard_Error,
                       "[od_adapter] subscribe failed: " & Node);
                  end if;
                  A := A + 2;
               end;
            end if;
            A := A + 1;
         end loop;
      end;

      Create_Socket (Sock, Family_Inet, Socket_Datagram);
      Connect_Socket (Sock,
        (Family => Family_Inet, Addr => Inet_Addr (Snd_IP), Port => Snd_Port));

      Put_Line (Standard_Error,
        "[od_adapter] " & Endpoint & " -> UADP " & Snd_IP & ":" & Argument (3));
   end;

   --  Main loop: poll updates, frame each as a NetworkMessage, send to od_sender.
   loop
      declare
         Wid  : U16;
         Ds   : Opc_Client.Ds_Bytes;
         DLen : Natural;
         Got  : Boolean;
      begin
         Opc_Client.Poll (Wid, Ds, DLen, Got);
         if not Got then
            delay 0.005;
         else
            declare
               Pay : Uadp.Message := (others => 0);
               Enc : Uadp.Message;
               ELn : Uadp.Msg_Length;
               Ok  : Boolean;
            begin
               for I in 1 .. DLen loop Pay (I - 1) := Ds (I); end loop;
               Seq := Seq + 1;
               Uadp.Encode (Uadp.Pub_U16, Pub_Id, Group_Id, Seq, Wid,
                            Pay, DLen, Enc, ELn, Ok);
               if Ok then
                  declare
                     OB : Stream_Element_Array
                       (1 .. Stream_Element_Offset (ELn));
                     Last : Stream_Element_Offset;
                  begin
                     for I in 1 .. ELn loop
                        OB (Stream_Element_Offset (I)) :=
                          Stream_Element (Enc (I - 1));
                     end loop;
                     Send_Socket (Sock, OB, Last);
                  end;
               end if;
            end;
         end if;
      end;
   end loop;
end Od_Adapter;
