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
--    od_sender <in_port> <diode_ip> <diode_port>
--             [--parity M] [--pace-us N] [--key HEX64]
--  The publisher must send NetworkMessages to <in_port> on this host.  With
--  --key (32 bytes as 64 hex chars), each NetworkMessage is authenticated-
--  encrypted (ChaCha20-Poly1305) before it is fragmented; the receiver must
--  carry the SAME key.  Without --key, payloads cross in the clear.

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
with Secure;
with Od_Key;
with Diode_Wire;
with Od_Dpdk;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;

procedure Od_Sender with SPARK_Mode => Off is

   In_Sock, Out_Sock : Socket_Type;
   Parity  : Natural := 2;
   Pace_Us : Natural := 0;

   --  DPDK kernel-bypass output (docs/ASSURANCE.md).  The publisher input stays
   --  UDP; only the diode-side output changes.
   Use_Dpdk : Boolean := False;
   Eal_Args : Unbounded_String := Null_Unbounded_String;
   Dst_Mac  : Unbounded_String := Null_Unbounded_String;

   Max_Interleave : constant := 16;
   Interleave     : Natural  := 1;   --  1 = no interleaving (send each at once)

   Have_Key : Boolean := False;
   Key      : Secure.Key_Bytes := (others => 0);
   Epoch    : U32 := 0;         --  per-run nonce prefix (unique across restarts)

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
        & " [--parity M] [--pace-us N] [--interleave D]");
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
         elsif Argument (Argi) = "--interleave" and then Argi < Argument_Count then
            Argi := Argi + 1; Interleave := Natural'Value (Argument (Argi));
         elsif Argument (Argi) = "--with-dpdk" then
            Use_Dpdk := True;
         elsif Argument (Argi) = "--eal" and then Argi < Argument_Count then
            Argi := Argi + 1; Eal_Args := To_Unbounded_String (Argument (Argi));
         elsif Argument (Argi) = "--dst" and then Argi < Argument_Count then
            Argi := Argi + 1; Dst_Mac := To_Unbounded_String (Argument (Argi));
         elsif Argument (Argi) = "--key" and then Argi < Argument_Count then
            Argi := Argi + 1;
            Od_Key.Parse_Hex (Argument (Argi), Key, Have_Key);
            if not Have_Key then
               Put_Line (Standard_Error,
                 "[od_sender] --key must be 64 hex chars (32 bytes)");
               GNAT.OS_Lib.OS_Exit (2);
            end if;
         end if;
         Argi := Argi + 1;
      end loop;
      if Parity < 1 then Parity := 1; end if;
      if Parity > Rs.Max_M then Parity := Rs.Max_M; end if;
      if Interleave < 1 then Interleave := 1; end if;
      if Interleave > Max_Interleave then Interleave := Max_Interleave; end if;
      if Have_Key then Epoch := Od_Key.Run_Epoch; end if;

      Create_Socket (In_Sock, Family_Inet, Socket_Datagram);
      Set_Socket_Option (In_Sock, Socket_Level, (Reuse_Address, True));
      Bind_Socket (In_Sock,
        (Family => Family_Inet, Addr => Any_Inet_Addr, Port => In_Port));

      if Use_Dpdk then
         if not Od_Dpdk.Available then
            Put_Line (Standard_Error,
              "[od_sender] --with-dpdk given, but this binary was built without"
              & " DPDK support.  Rebuild:  WITH_DPDK=yes ./tools/build.sh");
            GNAT.OS_Lib.OS_Exit (2);
         end if;
         declare
            Ok2 : Boolean;
         begin
            Od_Dpdk.Init (To_String (Eal_Args), Ok2);
            if not Ok2 then
               Put_Line (Standard_Error, "[od_sender] DPDK init failed");
               GNAT.OS_Lib.OS_Exit (2);
            end if;
            if Dst_Mac /= Null_Unbounded_String then
               Od_Dpdk.Set_Dst (To_String (Dst_Mac), Ok2);
            end if;
            Od_Dpdk.Wait_Link (5_000, Ok2);   --  best-effort; TX drops if down
         end;
      else
         Create_Socket (Out_Sock, Family_Inet, Socket_Datagram);
         Connect_Socket (Out_Sock,
           (Family => Family_Inet, Addr => Inet_Addr (Diode_IP),
            Port => Diode_Port));
      end if;

      Put_Line (Standard_Error,
        "[od_sender] in=" & Argument (1)
        & (if Use_Dpdk then " -> diode via DPDK (EtherType 0x88B7)"
           else " -> diode " & Diode_IP & ":" & Argument (3))
        & "  parity=" & Parity'Image & "  interleave=" & Interleave'Image
        & (if Have_Key then "  encrypted" else "  cleartext"));
   end;

   --  ---- interleaving buffer ----
   --  Cross-message interleaving spreads a burst loss across several messages:
   --  we buffer up to Interleave protected messages, then emit them round-robin
   --  (packet 1 of each, then packet 2 of each, ...).  A short burst then hits
   --  one "round" -- roughly one packet per message -- instead of consecutive
   --  packets of a single message.  A receive timeout flushes a partial buffer
   --  so latency stays bounded.  Interleave = 1 reproduces the old behaviour.
   declare
   type Job is record
      Pkts : Relay.Packet_Array;
      Lens : Relay.Length_Array;
      N    : Relay.Out_Count := 0;
   end record;
   Jobs  : array (1 .. Max_Interleave) of Job;   --  static storage, not stack
   NJobs : Natural := 0;

   procedure Emit (P : Diode_Wire.Packet; L : Natural) is
   begin
      if Use_Dpdk then
         Od_Dpdk.Tx (P, L);
      else
         declare
            OB : Stream_Element_Array (1 .. Stream_Element_Offset (L));
            OL : Stream_Element_Offset;
         begin
            for J in 1 .. L loop
               OB (Stream_Element_Offset (J)) := Stream_Element (P (J - 1));
            end loop;
            Send_Socket (Out_Sock, OB, OL);
         end;
      end if;
      if Pace_Us > 0 then
         delay Duration (Pace_Us) / 1_000_000.0;
      end if;
   end Emit;

   procedure Flush is
      Max_N : Relay.Out_Count := 0;
   begin
      for J in 1 .. NJobs loop
         if Jobs (J).N > Max_N then Max_N := Jobs (J).N; end if;
      end loop;
      for Round in 1 .. Max_N loop            --  round-robin across the jobs
         for J in 1 .. NJobs loop
            if Round <= Jobs (J).N then
               Emit (Jobs (J).Pkts (Round), Jobs (J).Lens (Round));
            end if;
         end loop;
      end loop;
      NJobs := 0;
   end Flush;

   --  Build one protected (optionally encrypted) message from L datagram bytes
   --  into the next job slot.
   procedure Make_Job (In_Buf : Stream_Element_Array; L : Natural) is
      Info  : Uadp.Header_Info;
      Msg   : Relay.Msg_Bytes;
      UMsg  : Uadp.Message := (others => 0);
      R_Len : Natural := L;
   begin
      for I in 1 .. L loop
         UMsg (I - 1) := U8 (In_Buf (In_Buf'First + Stream_Element_Offset (I - 1)));
         Msg (I)      := U8 (In_Buf (In_Buf'First + Stream_Element_Offset (I - 1)));
      end loop;
      Uadp.Parse (UMsg, L, Info);

      declare
         SID : constant U64 :=
           (if Info.Valid then Od_Stream.Stream_Of (Info) else 0);
         Seq : constant U32 := Next_Seq (SID);
         Ok  : Boolean;
      begin
         if Have_Key and then L <= Relay.Max_Msg_Len - Secure.Overhead then
            declare
               Plain : Secure.Plain_Buffer := (others => 0);
               Blob  : Secure.Blob_Buffer;
               BLen  : Secure.Blob_Len_T;
               Nonce : Secure.Nonce_Bytes := (others => 0);
            begin
               for I in 1 .. L loop Plain (I) := Msg (I); end loop;
               Nonce (1) := U8 (Epoch and 16#FF#);
               Nonce (2) := U8 ((Epoch / 2 ** 8) and 16#FF#);
               Nonce (3) := U8 ((Epoch / 2 ** 16) and 16#FF#);
               Nonce (4) := U8 ((Epoch / 2 ** 24) and 16#FF#);
               Nonce (5) := U8 (SID and 16#FF#);
               Nonce (6) := U8 ((SID / 2 ** 8) and 16#FF#);
               Nonce (7) := U8 ((SID / 2 ** 16) and 16#FF#);
               Nonce (8) := U8 ((SID / 2 ** 24) and 16#FF#);
               Nonce (9)  := U8 (Seq and 16#FF#);
               Nonce (10) := U8 ((Seq / 2 ** 8) and 16#FF#);
               Nonce (11) := U8 ((Seq / 2 ** 16) and 16#FF#);
               Nonce (12) := U8 ((Seq / 2 ** 24) and 16#FF#);
               Secure.Seal (Plain, L, Key, Nonce, Blob, BLen);
               for I in 1 .. BLen loop Msg (I) := Blob (I); end loop;
               R_Len := BLen;
            end;
         end if;

         NJobs := NJobs + 1;
         Relay.Protect (Msg, R_Len, SID, Seq, Parity,
                        Jobs (NJobs).Pkts, Jobs (NJobs).Lens,
                        Jobs (NJobs).N, Ok);
         if not Ok then NJobs := NJobs - 1; end if;   --  drop unprotectable msg
      end;
   end Make_Job;

   --  ---- main loop ----
   In_Buf : Stream_Element_Array (1 .. Stream_Element_Offset (Uadp.Max_Msg));
   Last   : Stream_Element_Offset;
   From   : Sock_Addr_Type;
begin
   --  A short receive timeout lets a partially-filled interleave buffer flush.
   if Interleave > 1 then
      Set_Socket_Option (In_Sock, Socket_Level, (Receive_Timeout, Timeout => 0.05));
   end if;

   loop
      declare
         Timed_Out : Boolean := False;
      begin
         begin
            Receive_Socket (In_Sock, In_Buf, Last, From);
         exception
            when Socket_Error => Timed_Out := True;   --  receive timeout
         end;

         if Timed_Out then
            if NJobs > 0 then Flush; end if;          --  flush partial buffer
         else
            exit when Last < In_Buf'First;            --  socket closed
            declare
               L : constant Natural := Natural (Last - In_Buf'First + 1);
            begin
               if L > 0 and then L <= Relay.Max_Msg_Len - Secure.Overhead then
                  Make_Job (In_Buf, L);
                  if NJobs >= Interleave then Flush; end if;
               end if;
            end;
         end if;
      end;
   end loop;
   end;
end Od_Sender;
