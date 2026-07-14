--  SPDX-License-Identifier: AGPL-3.0-or-later
--  Copyright (C) 2026 Alin Anton
--
--  Od_Key -- key material handling for the trusted shell (not proven).
--
--  Parses a 32-byte symmetric key from 64 hex characters, and supplies a
--  per-run nonce epoch.  Trusted: it only marshals bytes and reads the clock.

with Wire_Types; use Wire_Types;
with Secure;

package Od_Key with SPARK_Mode => Off is

   --  Parse exactly 64 hex chars into a 32-byte key.  Ok is False on any other
   --  length or a non-hex character.
   procedure Parse_Hex (S : String; Key : out Secure.Key_Bytes; Ok : out Boolean);

   --  A value that differs between runs of the process, used as the high 32
   --  bits of every nonce so a restart cannot reuse a (stream, msg_seq) nonce.
   function Run_Epoch return U32;

end Od_Key;
