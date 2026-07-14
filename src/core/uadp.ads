--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  Uadp -- proven parser for the OPC UA PubSub UADP NetworkMessage HEADER.
--
--  We are a relay, not an OPC UA endpoint, so this deliberately parses only as
--  far as it must:
--     * SequenceNumber   (GroupHeader)  -- the deduplication key
--     * PublisherId, WriterGroupId, DataSetWriterIds -- the routing key
--  Everything after the PayloadHeader (Timestamp, Security, the DataSetMessages
--  themselves) is left untouched and relayed BYTE-IDENTICAL.  Because we never
--  interpret a payload, we cannot corrupt one.
--
--  Field layout is OPC UA Part 14 v1.05 section 7.2.4; scalar encoding is Part 6
--  section 5.2.2 (all integers little-endian).  The parser is a bounded cursor
--  over a fixed buffer + a length: every read is gated by "cursor + size <= Len",
--  so a malformed or truncated NetworkMessage sets Valid = False and can never
--  read out of bounds.  That property is what gnatprove establishes here.

package Uadp with SPARK_Mode => On is

   type U8  is mod 2 ** 8;
   type U16 is mod 2 ** 16;
   type U32 is mod 2 ** 32;
   type U64 is mod 2 ** 64;

   --  A NetworkMessage carried in one UDP datagram.  The spec caps a payload at
   --  65535 bytes (larger is split across NetworkMessages), so this bound holds.
   Max_Msg : constant := 65535;

   subtype Msg_Index  is Natural range 0 .. Max_Msg - 1;
   subtype Msg_Length is Natural range 0 .. Max_Msg;
   type Message is array (Msg_Index) of U8;

   --  PublisherId is one of five wire types (Part 14 Table, ExtendedFlags1
   --  bits 0-2).  Pub_None means the field was absent.
   type Pub_Kind is (Pub_None, Pub_Byte, Pub_U16, Pub_U32, Pub_U64, Pub_String);

   --  A NetworkMessage may carry up to 255 DataSetMessages (Count is one byte).
   Max_Writers : constant := 255;
   subtype Writer_Count is Natural range 0 .. Max_Writers;
   type Writer_Array is array (1 .. Max_Writers) of U16;

   --  The relay-relevant result of parsing a header.
   type Header_Info is record
      Valid           : Boolean := False;   --  header parsed without overrun
      Is_Data         : Boolean := False;   --  NetworkMessage type = DataSet
      Version         : U8      := 0;

      --  Routing: who published this.
      Pub             : Pub_Kind := Pub_None;
      Pub_Numeric     : U64      := 0;       --  set for Pub_Byte/U16/U32/U64
      Pub_Str_Off     : Msg_Length := 0;     --  Pub_String: bytes at Off..Off+Len
      Pub_Str_Len     : Msg_Length := 0;

      Has_Group_Id    : Boolean := False;
      Writer_Group_Id : U16     := 0;

      --  Dedup: which message in the stream.
      Has_Seq         : Boolean := False;
      Sequence_Number : U16     := 0;

      --  Routing: which writers' DataSets are inside.
      N_Writers       : Writer_Count := 0;
      Writers         : Writer_Array := (others => 0);

      --  Bytes consumed up to and including the PayloadHeader.  The opaque
      --  remainder the relay forwards verbatim begins here.
      Consumed        : Msg_Length := 0;
   end record;

   --  Parse the header of the first Len bytes of Buf.  Total, and safe on any
   --  input: a truncated or malformed message yields Valid => False, never an
   --  out-of-bounds read.
   procedure Parse (Buf : Message; Len : Msg_Length; Info : out Header_Info);

end Uadp;
