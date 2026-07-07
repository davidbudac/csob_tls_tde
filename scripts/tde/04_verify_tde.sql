--------------------------------------------------------------------------------
-- 04_verify_tde.sql
--------------------------------------------------------------------------------
-- Purpose : Full TDE status report for audit / handover. Read-only. Safe to run
--           anytime on PRIMARY or STANDBY, non-CDB or CDB.
--
-- Covers  : wallet status/type/location, encrypted vs unencrypted tablespaces,
--           encrypted datafile count, MEK metadata (creation time/tag/activation),
--           relevant init parameters, and a per-PDB rollup for CDBs.
--
-- Runs on  : as SYSDBA (or a monitoring user with SELECT on the V$/DBA views).
--            On a CDB, run from CDB$ROOT for the fleet-wide rollup; the
--            CONTAINER=ALL views (V$ENCRYPTION_WALLET etc.) report all open PDBs.
--------------------------------------------------------------------------------

WHENEVER SQLERROR CONTINUE
SET ECHO OFF
SET FEEDBACK OFF
SET LINESIZE 210
SET PAGESIZE 200
SET VERIFY OFF

COLUMN name           FORMAT A22
COLUMN value          FORMAT A60
COLUMN wrl_parameter  FORMAT A55
COLUMN status         FORMAT A14
COLUMN wallet_type    FORMAT A14
COLUMN con_name       FORMAT A16
COLUMN creator_pdbname FORMAT A16
COLUMN tablespace_name FORMAT A28
COLUMN encryptionalg  FORMAT A14
COLUMN key_id         FORMAT A55
COLUMN tag            FORMAT A22

PROMPT
PROMPT ============================================================
PROMPT  TDE STATUS REPORT  --  &_CONNECT_IDENTIFIER  --  generated now
PROMPT ============================================================

PROMPT
PROMPT --- 1) Relevant init parameters 
SELECT name, value FROM v$parameter
 WHERE name IN ('wallet_root','tde_configuration',
                'encrypt_new_tablespaces','tablespace_encryption')
 ORDER BY name;
PROMPT (tablespace_encryption exists only on 19.16+ RUs; a "no rows" for it just
PROMPT  means an older RU -- use encrypt_new_tablespaces there.)

PROMPT
PROMPT --- 2) Keystore / wallet status (per container) 
SELECT wrl_type, wrl_parameter, status, wallet_type,
       keystore_mode, con_id
  FROM v$encryption_wallet
 ORDER BY con_id;
PROMPT Expect on a healthy primary/standby: WALLET_TYPE=AUTOLOGIN, STATUS=OPEN.
PROMPT WALLET_TYPE=LOCAL_AUTOLOGIN would be a red flag on a DG fleet (not portable).

PROMPT
PROMPT --- 3) Master Encryption Keys (MEK metadata) 
SELECT key_id,
       tag,
       creator_pdbname,
       TO_CHAR(creation_time,   'YYYY-MM-DD HH24:MI:SS') AS created,
       TO_CHAR(activation_time, 'YYYY-MM-DD HH24:MI:SS') AS activated,
       con_id
  FROM v$encryption_keys
 ORDER BY con_id, creation_time;
PROMPT (Multiple rows per container after rotations -- newest activation is live.
PROMPT  NEVER delete old keys: older backups still need them.)

PROMPT
PROMPT --- 4) Encrypted vs unencrypted tablespaces 
SELECT t.con_id,
       t.tablespace_name,
       t.contents,
       t.encrypted,
       et.encryptionalg
  FROM cdb_tablespaces t
  LEFT JOIN v$tablespace vt
         ON vt.name = t.tablespace_name AND vt.con_id = t.con_id
  LEFT JOIN v$encrypted_tablespaces et
         ON et.ts# = vt.ts# AND et.con_id = t.con_id
 ORDER BY t.con_id, t.encrypted, t.tablespace_name;
PROMPT (On a non-CDB, CDB_TABLESPACES == the single container. If CDB_* is not
PROMPT  available in your context, swap to DBA_TABLESPACES / DBA-level views.)

PROMPT
PROMPT --- 5) Encryption coverage summary 
SELECT encrypted,
       COUNT(*) AS tablespace_count
  FROM cdb_tablespaces
 WHERE contents = 'PERMANENT'
 GROUP BY encrypted
 ORDER BY encrypted;

PROMPT
PROMPT --- 6) Encrypted DATAFILE count 
SELECT et.con_id, COUNT(*) AS encrypted_datafiles
  FROM v$encrypted_tablespaces et
  JOIN v$tablespace vt ON vt.ts# = et.ts# AND vt.con_id = et.con_id
  JOIN cdb_data_files df ON df.tablespace_name = vt.name AND df.con_id = et.con_id
 GROUP BY et.con_id
 ORDER BY et.con_id;

PROMPT
PROMPT --- 7) Per-PDB rollup (CDB only) 
SELECT c.con_id,
       c.name AS con_name,
       c.open_mode,
       w.status       AS wallet_status,
       w.wallet_type,
       (SELECT COUNT(*) FROM v$encryption_keys k WHERE k.con_id = c.con_id)
                        AS mek_count
  FROM v$containers c
  LEFT JOIN v$encryption_wallet w ON w.con_id = c.con_id
 ORDER BY c.con_id;
PROMPT (On a non-CDB this returns the single CON_ID=0/1 row -- harmless.)

PROMPT
PROMPT ============================================================
PROMPT 04_verify_tde.sql COMPLETE.
PROMPT ============================================================
