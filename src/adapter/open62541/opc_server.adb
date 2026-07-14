--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Opc_Server -- REAL body (WITH_OPCUA=s2opc): bindings to opc_server_shim.c.

with Interfaces.C; use Interfaces.C;
with System;

package body Opc_Server with SPARK_Mode => Off is

   use type Interfaces.C.int;

   function C_Start (Server_Cfg, Addr_Space : char_array)
     return Interfaces.C.int
     with Import, Convention => C, External_Name => "od_ua_srv_start";

   function C_Write (Node : char_array; Val : System.Address;
                     Len : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "od_ua_srv_write";

   function C_Add (Node : char_array) return Interfaces.C.int
     with Import, Convention => C, External_Name => "od_ua_srv_add_node";

   procedure C_Stop
     with Import, Convention => C, External_Name => "od_ua_srv_stop";

   function Available return Boolean is (True);

   procedure Start
     (Server_Cfg     : String;
      Addr_Space_Cfg : String;
      Ok             : out Boolean)
   is
   begin
      Ok := C_Start (To_C (Server_Cfg), To_C (Addr_Space_Cfg)) = 0;
   end Start;

   procedure Add_Node (Node_Id : String; Ok : out Boolean) is
   begin
      Ok := C_Add (To_C (Node_Id)) = 0;
   end Add_Node;

   procedure Write
     (Node_Id   : String;
      Value     : Val_Bytes;
      Value_Len : Natural;
      Ok        : out Boolean)
   is
      Local : aliased Val_Bytes := Value;
   begin
      Ok := C_Write (To_C (Node_Id), Local (Local'First)'Address,
                     Interfaces.C.int (Value_Len)) = 0;
   end Write;

   procedure Stop is
   begin
      C_Stop;
   end Stop;

end Opc_Server;
