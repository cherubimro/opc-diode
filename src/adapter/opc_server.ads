--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Opc_Server -- the low-side output adapter's OPC UA server interface.
--
--  Mirror of Opc_Client: it fronts a client/server OPC UA SERVER stack (S2OPC or
--  open62541) so subscribers that do not speak PubSub can still read the mirrored
--  data.  The stack stays ENTIRELY on the low-security side, behind the diode:
--  the subscribers' sessions never cross the wire; only one-way UADP came in.
--
--  Build-time body (same WITH_OPCUA switch as Opc_Client):
--    none -> stub (Available=False) ; s2opc / open62541 -> real.

with Wire_Types; use Wire_Types;

package Opc_Server with SPARK_Mode => Off is

   Max_Val : constant := 1300;   --  = Opc_Client.Max_Ds (a DataSetMessage)
   type Val_Bytes is array (1 .. Max_Val) of U8;

   function Available return Boolean;

   --  Start the shadow server from XML config paths (endpoint + address space).
   procedure Start
     (Server_Cfg     : String;
      Addr_Space_Cfg : String;
      Ok             : out Boolean);

   --  Ensure a writable variable node exists (created programmatically on
   --  open62541; a no-op on S2OPC, whose nodes come from the address-space XML).
   procedure Add_Node (Node_Id : String; Ok : out Boolean);

   --  Write one recovered value to the node Node_Id.  Value (1 .. Value_Len) is
   --  the encoded SOPC_DataValue that arrived as the DataSetMessage payload.
   procedure Write
     (Node_Id   : String;
      Value     : Val_Bytes;
      Value_Len : Natural;
      Ok        : out Boolean);

   procedure Stop;

end Opc_Server;
