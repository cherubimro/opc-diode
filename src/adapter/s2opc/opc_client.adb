--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Opc_Client -- REAL body (WITH_OPCUA=s2opc): thin bindings to
--  opc_client_shim.c, which fronts the Systerel S2OPC client stack.

with Interfaces.C;         use Interfaces.C;
with System;

package body Opc_Client with SPARK_Mode => Off is

   use type Interfaces.C.int;

   function C_Init (Endpoint : char_array) return Interfaces.C.int
     with Import, Convention => C, External_Name => "od_s2opc_init";

   function C_Subscribe (Node : char_array; Wid : Interfaces.C.unsigned_short)
     return Interfaces.C.int
     with Import, Convention => C, External_Name => "od_s2opc_subscribe";

   function C_Poll (Wid : System.Address; Out_Buf : System.Address;
                    Maxlen : Interfaces.C.int) return Interfaces.C.int
     with Import, Convention => C, External_Name => "od_s2opc_poll";

   procedure C_Fini
     with Import, Convention => C, External_Name => "od_s2opc_fini";

   function Available return Boolean is (True);

   procedure Init (Endpoint : String; Ok : out Boolean) is
   begin
      Ok := C_Init (To_C (Endpoint)) = 0;
   end Init;

   procedure Subscribe
     (Node_Id     : String;
      Writer_Id   : U16;
      Interval_Ms : Natural;
      Ok          : out Boolean)
   is
      pragma Unreferenced (Interval_Ms);  --  publish period is set on the sub
   begin
      Ok := C_Subscribe (To_C (Node_Id),
                         Interfaces.C.unsigned_short (Writer_Id)) = 0;
   end Subscribe;

   procedure Poll
     (Writer_Id : out U16;
      Ds        : out Ds_Bytes;
      Ds_Len    : out Natural;
      Got       : out Boolean)
   is
      W : aliased Interfaces.C.unsigned_short := 0;
      R : Interfaces.C.int;
   begin
      Ds := (others => 0);
      R := C_Poll (W'Address, Ds (Ds'First)'Address, Interfaces.C.int (Max_Ds));
      if R > 0 then
         Writer_Id := U16 (W);
         Ds_Len    := Natural (R);
         Got       := True;
      else
         Writer_Id := 0;
         Ds_Len    := 0;
         Got       := False;
      end if;
   end Poll;

   procedure Fini is
   begin
      C_Fini;
   end Fini;

end Opc_Client;
