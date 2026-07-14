--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Od_Dpdk -- STUB body, used when WITH_DPDK=no (the default build).
--
--  Pure Ada, no imports: a default build pulls in no DPDK header, compiles no
--  C, links no library.  `--with-dpdk` at run time sees Available = False and
--  exits with a clear message rather than failing obscurely.

package body Od_Dpdk with SPARK_Mode => Off is

   function Available return Boolean is (False);

   procedure Init (Eal_Args : String; Ok : out Boolean) is
      pragma Unreferenced (Eal_Args);
   begin
      Ok := False;
   end Init;

   procedure Set_Dst (Mac : String; Ok : out Boolean) is
      pragma Unreferenced (Mac);
   begin
      Ok := False;
   end Set_Dst;

   procedure Wait_Link (Timeout_Ms : Natural; Up : out Boolean) is
      pragma Unreferenced (Timeout_Ms);
   begin
      Up := False;
   end Wait_Link;

   procedure Rx_Burst
     (Bufs  : in out Packet_Array;
      Lens  : out Length_Array;
      Count : out Natural)
   is
      pragma Unreferenced (Bufs);
   begin
      Lens  := (others => 0);
      Count := 0;
   end Rx_Burst;

   procedure Tx (Buf : Diode_Wire.Packet; Len : Natural) is
      pragma Unreferenced (Buf, Len);
   begin
      null;
   end Tx;

   procedure Fini is
   begin
      null;
   end Fini;

end Od_Dpdk;
