--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton

package body Od_Stream with SPARK_Mode => On is

   use type Wire_Types.U64, Uadp.Pub_Kind;

   function Stream_Of (H : Uadp.Header_Info) return U64 is
      --  Mix publisher kind, publisher numeric id, and writer-group id.  For a
      --  string publisher we have only the length here (the bytes stay in the
      --  datagram); length + group + kind still separates streams well enough,
      --  and any residual collision degrades safely (see the spec comment).
      K : constant U64 := U64 (Uadp.Pub_Kind'Pos (H.Pub));
      P : constant U64 := (if H.Pub = Uadp.Pub_String
                           then U64 (H.Pub_Str_Len)
                           else H.Pub_Numeric);
      G : constant U64 := U64 (H.Writer_Group_Id);
   begin
      --  A cheap, well-mixed combine (SplitMix64 finaliser on the parts).
      return (P xor (G * 2 ** 40) xor (K * 2 ** 56));
   end Stream_Of;

end Od_Stream;
