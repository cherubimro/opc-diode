--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Opc_Server -- STUB body (WITH_OPCUA=none): no server stack.

package body Opc_Server with SPARK_Mode => Off is

   function Available return Boolean is (False);

   procedure Start
     (Server_Cfg     : String;
      Addr_Space_Cfg : String;
      Ok             : out Boolean)
   is
      pragma Unreferenced (Server_Cfg, Addr_Space_Cfg);
   begin
      Ok := False;
   end Start;

   procedure Add_Node (Node_Id : String; Ok : out Boolean) is
      pragma Unreferenced (Node_Id);
   begin
      Ok := False;
   end Add_Node;

   procedure Write
     (Node_Id   : String;
      Value     : Val_Bytes;
      Value_Len : Natural;
      Ok        : out Boolean)
   is
      pragma Unreferenced (Node_Id, Value, Value_Len);
   begin
      Ok := False;
   end Write;

   procedure Stop is
   begin
      null;
   end Stop;

end Opc_Server;
