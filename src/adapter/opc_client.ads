--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Opc_Client -- the high-side input adapter's OPC UA client interface.
--
--  TRUSTED shell (SPARK_Mode => Off).  It fronts a full client/server OPC UA
--  stack (S2OPC or open62541), which is a large third-party C body -- but it
--  stays ENTIRELY on the high-security side, behind the diode: the bidirectional
--  protocol (TCP, sessions, secure channels) never crosses the wire.  Only the
--  flattened, one-way UADP the adapter builds does.
--
--  The body is chosen at BUILD time by WITH_OPCUA:
--    none      (default) -> src/adapter/none      : Available = False, no stack.
--    s2opc               -> src/adapter/s2opc     : Systerel S2OPC (Apache-2.0).
--    open62541           -> src/adapter/open62541 : open62541 (MPL-2.0).
--
--  Poll-based (no C -> Ada callbacks): the shim buffers data-change updates,
--  each already encoded by the stack as a DataSetMessage; Poll drains one, and
--  od_adapter frames it with the proven Uadp.Encode and sends it to od_sender.

with Wire_Types; use Wire_Types;

package Opc_Client with SPARK_Mode => Off is

   --  Largest DataSetMessage we frame (leaves room for the UADP header inside
   --  one NetworkMessage).
   Max_Ds : constant := 1300;
   type Ds_Bytes is array (1 .. Max_Ds) of U8;

   function Available return Boolean;
   --  True iff a client stack is compiled into this build.

   procedure Init (Endpoint : String; Ok : out Boolean);
   --  Connect to the server at Endpoint (e.g. "opc.tcp://host:4840").

   procedure Subscribe
     (Node_Id     : String;    --  e.g. "ns=2;i=42"
      Writer_Id   : U16;        --  DataSetWriterId to tag this variable's stream
      Interval_Ms : Natural;
      Ok          : out Boolean);
   --  Monitor one variable; its updates surface through Poll.

   procedure Poll
     (Writer_Id : out U16;
      Ds        : out Ds_Bytes;
      Ds_Len    : out Natural;
      Got       : out Boolean);
   --  Drain one buffered update (a DataSetMessage of Ds_Len bytes).  Got is
   --  False when nothing is pending right now.

   procedure Fini;

end Opc_Client;
