--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
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
with Od_Dpdk;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;

procedure Od_Receiver with SPARK_Mode => Off is

   In_Sock, Out_Sock : Socket_Type;
   Coll : Relay.Collector;
   Have_Key : Boolean := False;
   Key      : Secure.Key_Bytes := (others => 0);

   --  DPDK kernel-bypass diode input; the subscriber output stays UDP.
   Use_Dpdk : Boolean := False;
   Eal_Args : Unbounded_String := Null_Unbounded_String;
begin
   if Argument_Count < 3 then
      Put_Line (Standard_Error,
        "[usage] od_receiver <diode_port> <out_ip> <out_port>"
        & " [--key HEX64] [--with-dpdk] [--eal ""<args>""]");
      GNAT.OS_Lib.OS_Exit (2);
   end if;

   declare
      A : Natural := 4;
   begin
      while A <= Argument_Count loop
         if Argument (A) = "--key" and then A < Argument_Count then
            A := A + 1;
            Od_Key.Parse_Hex (Argument (A), Key, Have_Key);
            if not Have_Key then
               Put_Line (Standard_Error,
                 "[od_receiver] --key must be 64 hex chars (32 bytes)");
               GNAT.OS_Lib.OS_Exit (2);
            end if;
         elsif Argument (A) = "--with-dpdk" then
            Use_Dpdk := True;
         elsif Argument (A) = "--eal" and then A < Argument_Count then
            A := A + 1; Eal_Args := To_Unbounded_String (Argument (A));
         end if;
         A := A + 1;
      end loop;
   end;

   declare
      Diode_Port : constant Port_Type := Port_Type'Value (Argument (1));
      Out_IP     : constant String    := Argument (2);
      Out_Port   : constant Port_Type := Port_Type'Value (Argument (3));
   begin
      if Use_Dpdk then
         if not Od_Dpdk.Available then
            Put_Line (Standard_Error,
              "[od_receiver] --with-dpdk given, but this binary was built"
              & " without DPDK support.  Rebuild:  WITH_DPDK=yes ./tools/build.sh");
            GNAT.OS_Lib.OS_Exit (2);
         end if;
         declare
            Ok2 : Boolean;
         begin
            Od_Dpdk.Init (To_String (Eal_Args), Ok2);
            if not Ok2 then
               Put_Line (Standard_Error, "[od_receiver] DPDK init failed");
               GNAT.OS_Lib.OS_Exit (2);
            end if;
         end;
      else
         Create_Socket (In_Sock, Family_Inet, Socket_Datagram);
         Set_Socket_Option (In_Sock, Socket_Level, (Reuse_Address, True));
         Set_Socket_Option (In_Sock, Socket_Level, (Receive_Buffer, 4_194_304));
         Bind_Socket (In_Sock,
           (Family => Family_Inet, Addr => Any_Inet_Addr, Port => Diode_Port));
      end if;

      Create_Socket (Out_Sock, Family_Inet, Socket_Datagram);
      Connect_Socket (Out_Sock,
        (Family => Family_Inet, Addr => Inet_Addr (Out_IP), Port => Out_Port));

      Put_Line (Standard_Error,
        "[od_receiver] diode "
        & (if Use_Dpdk then "via DPDK (EtherType 0x88B7)" else Argument (1))
        & " -> out " & Out_IP & ":" & Argument (3));
   end;

   Relay.Init (Coll);

   declare
      Out_Msg  : Relay.Msg_Bytes;
      Out_Len  : Relay.Msg_Byte_Count;
      Produced : Boolean;

      --  Offer one diode packet (Pkt, L) to the relay and, on a completed
      --  message, decrypt-and-verify (dropping a bad tag) and emit to the
      --  subscribers over UDP.  Shared by the UDP and DPDK receive paths.
      procedure Handle (Pkt : Diode_Wire.Packet; L : Natural) is
      begin
         if L not in Diode_Wire.Header_Len .. Diode_Wire.Max_Packet then
            return;
         end if;
         Relay.Offer (Coll, Pkt, L, Produced, Out_Msg, Out_Len);
         if not Produced then
            return;
         end if;
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
                     OB (Stream_Element_Offset (J)) := Stream_Element (Emit (J));
                  end loop;
                  Send_Socket (Out_Sock, OB, OL);
               end;
            end if;
         end;
      end Handle;

      Pkt : Diode_Wire.Packet := (others => 0);
   begin
      if Use_Dpdk then
         --  Kernel-bypass: poll the port in bursts.  Empty poll -> brief sleep
         --  so an idle receiver does not peg a core (a real one would busy-poll
         --  a dedicated lcore).
         declare
            Bufs : Od_Dpdk.Packet_Array;
            Lens : Od_Dpdk.Length_Array;
            Cnt  : Natural;
         begin
            loop
               Od_Dpdk.Rx_Burst (Bufs, Lens, Cnt);
               if Cnt = 0 then
                  delay 0.001;
               else
                  for I in 1 .. Cnt loop
                     Handle (Bufs (I), Lens (I));
                  end loop;
               end if;
            end loop;
         end;
      else
         declare
            In_Buf : Stream_Element_Array
              (1 .. Stream_Element_Offset (Diode_Wire.Max_Packet));
            Last : Stream_Element_Offset;
            From : Sock_Addr_Type;
         begin
            loop
               Receive_Socket (In_Sock, In_Buf, Last, From);
               exit when Last < In_Buf'First;
               declare
                  L : constant Natural := Natural (Last - In_Buf'First + 1);
               begin
                  for I in 1 .. L loop
                     Pkt (I - 1) :=
                       U8 (In_Buf (In_Buf'First + Stream_Element_Offset (I - 1)));
                  end loop;
                  Handle (Pkt, L);
               end;
            end loop;
         end;
      end if;
   end;
end Od_Receiver;
