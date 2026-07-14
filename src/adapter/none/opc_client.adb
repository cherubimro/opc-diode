--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Opc_Client -- STUB body (WITH_OPCUA=none, the default).  No OPC UA stack is
--  compiled or linked; od_adapter sees Available = False and exits cleanly.

package body Opc_Client with SPARK_Mode => Off is

   function Available return Boolean is (False);

   procedure Init (Endpoint : String; Ok : out Boolean) is
      pragma Unreferenced (Endpoint);
   begin
      Ok := False;
   end Init;

   procedure Subscribe
     (Node_Id     : String;
      Writer_Id   : U16;
      Interval_Ms : Natural;
      Ok          : out Boolean)
   is
      pragma Unreferenced (Node_Id, Writer_Id, Interval_Ms);
   begin
      Ok := False;
   end Subscribe;

   procedure Poll
     (Writer_Id : out U16;
      Ds        : out Ds_Bytes;
      Ds_Len    : out Natural;
      Got       : out Boolean)
   is
   begin
      Writer_Id := 0;
      Ds        := (others => 0);
      Ds_Len    := 0;
      Got       := False;
   end Poll;

   procedure Fini is
   begin
      null;
   end Fini;

end Opc_Client;
