--  opc-diode -- a high-assurance Ada/SPARK OPC UA PubSub data-diode relay.
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--  SPDX-License-Identifier: AGPL-3.0-or-later
--
--  Od_Dpdk -- optional DPDK poll-mode transport (kernel bypass).
--
--  TRUSTED shell (SPARK_Mode => Off).  Selecting it moves DPDK (EAL + mempool +
--  the NIC PMD) and a small C shim onto the data path, inside the TCB; the
--  kernel/UDP path remains the default.  The body is chosen at BUILD time by the
--  WITH_DPDK external:
--
--    WITH_DPDK=no  (default) -> src/net/stub : Available = False, no DPDK linked.
--    WITH_DPDK=yes           -> src/net/dpdk : real bindings to the C shim.
--
--  So a default build neither links nor mentions DPDK; `--with-dpdk` at run time
--  then fails cleanly with "not built with DPDK support".  The proven core is
--  untouched either way: both paths carry the same Diode_Wire.Packet bytes.

with Diode_Wire;

package Od_Dpdk with SPARK_Mode => Off is

   Batch : constant := 64;    --  RX burst size (mirrors OD_BURST in the shim)

   type Packet_Array is array (1 .. Batch) of aliased Diode_Wire.Packet;
   type Length_Array is array (1 .. Batch) of Integer;

   function Available return Boolean;
   --  True iff this build has the DPDK backend compiled in.

   procedure Init (Eal_Args : String; Ok : out Boolean);
   --  EAL init + bring-up of the first available ethdev port.  Eal_Args is a
   --  whitespace-separated EAL command line (argv[0] supplied internally).

   procedure Set_Dst (Mac : String; Ok : out Boolean);
   --  Destination MAC "aa:bb:cc:dd:ee:ff".  Default broadcast -- a diode sender
   --  need not know the receiver.

   procedure Wait_Link (Timeout_Ms : Natural; Up : out Boolean);
   --  Bounded wait for the link (SENDERS ONLY; a receiver has no peer to wait
   --  for and would just stall).  A down link is not fatal: TX drops, which on
   --  a one-way link is indistinguishable from loss.

   procedure Rx_Burst
     (Bufs  : in out Packet_Array;
      Lens  : out Length_Array;
      Count : out Natural);
   --  Poll the port.  Copies out up to Batch diode packets; Lens (I) is the
   --  byte length of Bufs (I) for I in 1 .. Count.  Non-diode frames are
   --  dropped in the shim.

   procedure Tx (Buf : Diode_Wire.Packet; Len : Natural);
   --  Transmit one diode packet of Len bytes as a raw Ethernet frame.  A drop
   --  is silent (a one-way link has no retransmission).

   procedure Fini;

end Od_Dpdk;
