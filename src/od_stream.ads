--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026  Alin-Adrian Anton <alin.anton@upt.ro>
--
--  Od_Stream -- derive a 64-bit stream id from a parsed UADP header.
--
--  The receiver groups and deduplicates fragments per stream, so the sender
--  must map each (PublisherId, WriterGroupId) to a stable id.  This is proven
--  SPARK: a pure, total function over the header, no I/O.

with Wire_Types; use Wire_Types;
with Uadp;

package Od_Stream with SPARK_Mode => On is

   --  A collision only merges two publishers' fragment pools; the erasure
   --  decode or the msg_seq mismatch then rejects the blend, so a collision
   --  costs a dropped message, never a corrupt one.  With 64 bits it will not
   --  happen in practice.
   function Stream_Of (H : Uadp.Header_Info) return U64
     with Post => True;

end Od_Stream;
