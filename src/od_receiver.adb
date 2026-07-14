--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  od_receiver -- the low-security side of the OPC UA PubSub data diode.
--
--  Receive diode packets one-way, hand each to the proven Relay.Collector, and
--  when a NetworkMessage is fully recovered re-emit it BYTE-IDENTICAL to the
--  low-side subscribers.  No return path, ever.
--
--  Trusted shell (SPARK_Mode => Off): it owns the sockets; the collection,
--  erasure decoding, reassembly and dedup are all in the proven core (Relay).
--
--  Usage:
--    od_receiver <diode_port> <out_ip> <out_port> [--key HEX64]
--  Recovered NetworkMessages are sent to <out_ip>:<out_port>.  With --key, each
--  recovered blob is authenticated-decrypted; a blob that fails the tag (wrong
--  key or tampering) is DROPPED, never emitted.  The key must match the sender.

pragma Ada_2022;
with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Streams;              use Ada.Streams;
with GNAT.Sockets;             use GNAT.Sockets;
with GNAT.OS_Lib;
with Wire_Types;               use Wire_Types;
with Relay;
with Diode_Wire;
with Secure;
with Od_Key;

procedure Od_Receiver with SPARK_Mode => Off is

   In_Sock, Out_Sock : Socket_Type;
   Coll : Relay.Collector;
   Have_Key : Boolean := False;
   Key      : Secure.Key_Bytes := (others => 0);
begin
   if Argument_Count < 3 then
      Put_Line (Standard_Error,
        "[usage] od_receiver <diode_port> <out_ip> <out_port> [--key HEX64]");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   for A in 4 .. Argument_Count loop
      if Argument (A) = "--key" and then A < Argument_Count then
         Od_Key.Parse_Hex (Argument (A + 1), Key, Have_Key);
         if not Have_Key then
            Put_Line (Standard_Error,
              "[od_receiver] --key must be 64 hex chars (32 bytes)");
            GNAT.OS_Lib.OS_Exit (2);
         end if;
      end if;
   end loop;

   declare
      Diode_Port : constant Port_Type := Port_Type'Value (Argument (1));
      Out_IP     : constant String    := Argument (2);
      Out_Port   : constant Port_Type := Port_Type'Value (Argument (3));
   begin
      Create_Socket (In_Sock, Family_Inet, Socket_Datagram);
      Set_Socket_Option (In_Sock, Socket_Level, (Reuse_Address, True));
      Set_Socket_Option (In_Sock, Socket_Level, (Receive_Buffer, 4_194_304));
      Bind_Socket (In_Sock,
        (Family => Family_Inet, Addr => Any_Inet_Addr, Port => Diode_Port));

      Create_Socket (Out_Sock, Family_Inet, Socket_Datagram);
      Connect_Socket (Out_Sock,
        (Family => Family_Inet, Addr => Inet_Addr (Out_IP), Port => Out_Port));

      Put_Line (Standard_Error,
        "[od_receiver] diode " & Argument (1) & " -> out " & Out_IP & ":"
        & Argument (3));
   end;

   Relay.Init (Coll);

   declare
      In_Buf : Stream_Element_Array
        (1 .. Stream_Element_Offset (Diode_Wire.Max_Packet));
      Last     : Stream_Element_Offset;
      From     : Sock_Addr_Type;
      Pkt      : Diode_Wire.Packet := (others => 0);
      Produced : Boolean;
      Out_Msg  : Relay.Msg_Bytes;
      Out_Len  : Relay.Msg_Byte_Count;
   begin
      loop
         Receive_Socket (In_Sock, In_Buf, Last, From);
         exit when Last < In_Buf'First;

         declare
            L : constant Natural := Natural (Last - In_Buf'First + 1);
         begin
            if L in Diode_Wire.Header_Len .. Diode_Wire.Max_Packet then
               for I in 1 .. L loop
                  Pkt (I - 1) :=
                    U8 (In_Buf (In_Buf'First + Stream_Element_Offset (I - 1)));
               end loop;

               Relay.Offer (Coll, Pkt, L, Produced, Out_Msg, Out_Len);

               if Produced then
                  --  The recovered bytes are a sealed blob when a key is set;
                  --  decrypt-and-verify, dropping anything that fails the tag.
                  declare
                     Emit_Len : Natural := Out_Len;
                     Emit     : Relay.Msg_Bytes := Out_Msg;
                     Send_It  : Boolean := True;
                  begin
                     if Have_Key then
                        declare
                           Blob  : Secure.Blob_Buffer := (others => 0);
                           Plain : Secure.Plain_Buffer;
                           PLen  : Secure.Plain_Len_T;
                           Ok    : Boolean;
                        begin
                           if Out_Len <= Secure.Max_Blob then
                              for I in 1 .. Out_Len loop Blob (I) := Out_Msg (I); end loop;
                              Secure.Open (Blob, Out_Len, Key, Plain, PLen, Ok);
                              if Ok and then PLen <= Relay.Max_Msg_Len then
                                 for I in 1 .. PLen loop Emit (I) := Plain (I); end loop;
                                 Emit_Len := PLen;
                              else
                                 Send_It := False;   --  bad tag: drop
                              end if;
                           else
                              Send_It := False;
                           end if;
                        end;
                     end if;

                     if Send_It then
                        declare
                           OB : Stream_Element_Array
                             (1 .. Stream_Element_Offset (Emit_Len));
                           OL : Stream_Element_Offset;
                        begin
                           for J in 1 .. Emit_Len loop
                              OB (Stream_Element_Offset (J)) :=
                                Stream_Element (Emit (J));
                           end loop;
                           Send_Socket (Out_Sock, OB, OL);
                        end;
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
   end;
end Od_Receiver;
