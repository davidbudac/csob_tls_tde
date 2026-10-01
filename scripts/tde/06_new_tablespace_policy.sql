--------------------------------------------------------------------------------
-- 06_new_tablespace_policy.sql
--------------------------------------------------------------------------------
-- Purpose : Set the "born encrypted" policy so every tablespace created from now
--           on is encrypted (03-tde-guide.md section 8), and provide the
--           detective query that proves new tablespaces use AES256.
--           NOT READ-ONLY: it changes init parameters with SCOPE=BOTH.
--
-- STANDARD (19c):
--   * DDL must ALWAYS say:  ENCRYPTION USING 'AES256' ENCRYPT
--   * ENCRYPT_NEW_TABLESPACES='ALWAYS' is the SAFETY NET: it guarantees that a
--     CREATE TABLESPACE without an ENCRYPTION clause is still encrypted.
--     On 19c that fallback uses AES128 (the default algorithm).
--   * The DETECTIVE query (step 5) catches any tablespace that ended up AES128
--     (or unencrypted). Run it in monitoring.
--
-- Parameter reality on 19c:
--   TABLESPACE_ENCRYPTION_DEFAULT_ALGORITHM is NOT a documented parameter on 19c
--   (documented from 21c; confirmed absent from V$PARAMETER on 19.27). Only a
--   hidden _tablespace_encryption_default_algorithm exists, which must NOT be
--   set without an Oracle Support SR. Step 3 therefore sets the documented
--   parameter only if V$PARAMETER lists it (future RU/version), and otherwise
--   says so and changes nothing.
--
-- Runs on  : PRIMARY, as SYSDBA.
--            * CDB: run in CDB$ROOT. ENCRYPT_NEW_TABLESPACES is PDB-modifiable
--              and the root value is inherited by PDBs without their own value.
--              Step 4 shows per-container values (look for PDB overrides).
--            * Data Guard: the standby has its OWN spfile; ALTER SYSTEM on the
--              primary is not shipped to it. ALSO set it on the STANDBY so a
--              switchover keeps the policy:
--                  ALTER SYSTEM SET ENCRYPT_NEW_TABLESPACES='ALWAYS' SCOPE=SPFILE;
--              (or via broker / re-apply after a role change). Re-verify with
--              step 4 on the standby and after the first switchover test.
--
-- Pre-reqs : * Scripts 01 + 02 done; keystore OPEN with an active MEK.
--            * The KEYSTORE MUST BE OPEN before any tablespace is created
--              afterwards: with ENCRYPT_NEW_TABLESPACES=ALWAYS, CREATE
--              TABLESPACE fails with an ORA-283xx wallet-not-open error when the
--              keystore is closed. Use the AUTOLOGIN keystore (script 02).
--            * Existing tablespaces are NOT touched -- use 03 for conversion.
--
-- Usage    : sqlplus / as sysdba @06_new_tablespace_policy.sql
--------------------------------------------------------------------------------

WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET ECHO ON
SET FEEDBACK ON
SET LINESIZE 200
SET PAGESIZE 100
SET VERIFY OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

COLUMN name           FORMAT A45
COLUMN value          FORMAT A20
COLUMN con_id         FORMAT 999
COLUMN status         FORMAT A18
COLUMN wallet_type    FORMAT A14
COLUMN tablespace_name FORMAT A30
COLUMN encryptionalg  FORMAT A14

PROMPT
PROMPT === 1) CURRENT values (before change)
SELECT name, value
  FROM v$parameter
 WHERE name IN ('encrypt_new_tablespaces','tablespace_encryption')
 ORDER BY name;
PROMPT (tablespace_encryption: no row = not present on this RU; not changed here)

PROMPT
PROMPT === 2) Keystore must be OPEN before new tablespaces are created
SELECT con_id, wrl_type, status, wallet_type
  FROM v$encryption_wallet
 ORDER BY con_id;

DECLARE
  n_open NUMBER;
BEGIN
  SELECT COUNT(*) INTO n_open FROM v$encryption_wallet
   WHERE status IN ('OPEN','OPEN_NO_MASTER_KEY')
     AND con_id = SYS_CONTEXT('USERENV','CON_ID');
  IF n_open = 0 THEN
    RAISE_APPLICATION_ERROR(-20602,
      'Keystore is not OPEN in this container. Nothing changed. Open it first (script 02).');
  END IF;
END;
/

PROMPT
PROMPT === 3) Default algorithm parameter (only if documented parameter exists)
DECLARE
  n_param NUMBER;
BEGIN
  SELECT COUNT(*) INTO n_param FROM v$parameter
   WHERE name = 'tablespace_encryption_default_algorithm';
  IF n_param = 1 THEN
    EXECUTE IMMEDIATE
      'ALTER SYSTEM SET TABLESPACE_ENCRYPTION_DEFAULT_ALGORITHM = ''AES256'' SCOPE=BOTH';
    DBMS_OUTPUT.PUT_LINE('SET: TABLESPACE_ENCRYPTION_DEFAULT_ALGORITHM = AES256');
  ELSE
    DBMS_OUTPUT.PUT_LINE('NOTE: TABLESPACE_ENCRYPTION_DEFAULT_ALGORITHM does not exist on this version (19c).');
    DBMS_OUTPUT.PUT_LINE('NOTE: ENCRYPT_NEW_TABLESPACES=ALWAYS will encrypt new tablespaces with AES128');
    DBMS_OUTPUT.PUT_LINE('NOTE: unless the DDL says ENCRYPTION USING ''AES256'' ENCRYPT. Use that in all DDL');
    DBMS_OUTPUT.PUT_LINE('NOTE: and run the detective query (step 5) in monitoring.');
  END IF;
END;
/
-- DO NOT enable the hidden parameter below unless Oracle Support (SR) approves it:
-- ALTER SYSTEM SET "_tablespace_encryption_default_algorithm" = 'AES256' SCOPE=BOTH;

PROMPT
PROMPT === 3b) APPLY the safety net (SCOPE=BOTH)
ALTER SYSTEM SET ENCRYPT_NEW_TABLESPACES = 'ALWAYS' SCOPE=BOTH;

PROMPT
PROMPT === 4) VERIFY (per container; ISDEFAULT=FALSE rows on a PDB override the root)
SELECT con_id, name, value, isdefault
  FROM v$system_parameter
 WHERE name IN ('encrypt_new_tablespaces','tablespace_encryption_default_algorithm')
 ORDER BY con_id, name;
PROMPT Expect ENCRYPT_NEW_TABLESPACES = ALWAYS.
PROMPT REMINDER: repeat on the Data Guard STANDBY spfile (see header) -- not done here.

PROMPT
PROMPT === 5) DETECTIVE CONTROL: encrypted tablespaces NOT using AES256 (expect no rows)
SELECT t.con_id, t.name AS tablespace_name, e.encryptionalg
  FROM v$tablespace t
  JOIN v$encrypted_tablespaces e
    ON e.ts# = t.ts# AND e.con_id = t.con_id
 WHERE e.encryptionalg <> 'AES256'
 ORDER BY t.con_id, t.name;

PROMPT
PROMPT === 5b) Application tablespaces NOT encrypted at all (expect none after conversion)
SELECT con_id, tablespace_name
  FROM cdb_tablespaces
 WHERE encrypted = 'NO'
   AND contents = 'PERMANENT'
   AND tablespace_name NOT IN ('SYSTEM','SYSAUX')
 ORDER BY con_id, tablespace_name;

--------------------------------------------------------------------------------
-- OPTIONAL SELF-TEST (commented out). Creates and DROPS a tiny tablespace; run in
-- a PDB or non-CDB on the PRIMARY only. With OMF no DATAFILE name is needed;
-- otherwise give a path under the datafile mount.
--------------------------------------------------------------------------------
-- CREATE TABLESPACE tde_policy_selftest DATAFILE SIZE 10M
--   ENCRYPTION USING 'AES256' DEFAULT STORAGE (ENCRYPT);
--
-- SELECT tablespace_name, encrypted
--   FROM dba_tablespaces WHERE tablespace_name = 'TDE_POLICY_SELFTEST';
--
-- SELECT t.name, e.encryptionalg
--   FROM v$tablespace t
--   JOIN v$encrypted_tablespaces e ON e.ts# = t.ts# AND e.con_id = t.con_id
--  WHERE t.name = 'TDE_POLICY_SELFTEST';
-- -- Expect ENCRYPTED=YES and ENCRYPTIONALG=AES256.
--
-- -- Safety-net test: no ENCRYPTION clause, expect ENCRYPTIONALG=AES128 on 19c.
-- -- CREATE TABLESPACE tde_policy_selftest2 DATAFILE SIZE 10M;
--
-- DROP TABLESPACE tde_policy_selftest INCLUDING CONTENTS AND DATAFILES;
-- -- DROP TABLESPACE tde_policy_selftest2 INCLUDING CONTENTS AND DATAFILES;
