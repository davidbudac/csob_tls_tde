--------------------------------------------------------------------------------
-- 01_db_inventory.sql
--------------------------------------------------------------------------------
-- Purpose : Per-database READINESS REPORT used to place each DB in a rollout
--           wave and to pick a TDE conversion method (online / standby-first /
--           offline / rebuild -- see 03-tde-guide.md section 5). READ-ONLY:
--           SELECTs only, nothing is changed. Safe to run anytime.
--
-- Covers  : version/RU, CDB + PDB open modes, role / protection mode / DG
--           standby destinations, log mode, force logging, TLS/TDE related init
--           parameters, wallet status, OMF, tablespace sizes + encryption flag,
--           total size, daily redo volume (last 7 days), FRA / archive space,
--           database links (TCPS or not), and a per-container "TDE method hint".
--
-- Runs on  : PRIMARY (preferred) or STANDBY, as SYSDBA, non-CDB or CDB.
--            On a CDB run from CDB$ROOT -- CDB_* views then cover all PDBs.
--            (In 19c the CDB_* views also exist on a non-CDB; con_id = 0 there.)
--            Run it ON EACH DATABASE and keep the spool output with the wave plan.
--
-- Usage   : sqlplus -s / as sysdba @01_db_inventory.sql
--           (spool is optional: SPOOL db_inventory_<sid>.txt before @)
--
-- Notes   : * WHENEVER SQLERROR CONTINUE -- a parameter or view that does not
--             exist on a given RU just gives an error/no rows for that section.
--           * Redo volume comes from V$ARCHIVED_LOG (dest_id=1), which is
--             instance-wide; it is NOT per PDB. Run in CDB$ROOT / non-CDB.
--           * Temp files are not included in the size figures (CDB_DATA_FILES).
--           * The TDE method hint is ADVISORY only -- see the rule text below.
--------------------------------------------------------------------------------

WHENEVER SQLERROR CONTINUE
SET ECHO OFF
SET FEEDBACK OFF
SET LINESIZE 220
SET PAGESIZE 200
SET VERIFY OFF
SET TRIMSPOOL ON

COLUMN name             FORMAT A45
COLUMN value            FORMAT A100 TRUNCATED
COLUMN version_full     FORMAT A16
COLUMN host_name        FORMAT A30
COLUMN instance_name    FORMAT A14
COLUMN db_name          FORMAT A12
COLUMN db_unique_name   FORMAT A20
COLUMN is_cdb           FORMAT A6
COLUMN con_name         FORMAT A20
COLUMN pdb_name         FORMAT A20
COLUMN open_mode        FORMAT A12
COLUMN database_role    FORMAT A18
COLUMN protection_mode  FORMAT A22
COLUMN dest_name        FORMAT A20
COLUMN destination      FORMAT A40
COLUMN wrl_parameter    FORMAT A55
COLUMN status           FORMAT A12
COLUMN wallet_type      FORMAT A14
COLUMN tablespace_name  FORMAT A28
COLUMN encrypted        FORMAT A9
COLUMN owner            FORMAT A20
COLUMN db_link          FORMAT A32
COLUMN host             FORMAT A70
COLUMN tcps_link        FORMAT A9
COLUMN hint             FORMAT A75

PROMPT
PROMPT ============================================================
PROMPT  DB READINESS INVENTORY  --  &_CONNECT_IDENTIFIER
PROMPT ============================================================

PROMPT
PROMPT --- 1) Version / instance
SELECT version_full, instance_name, host_name, status, logins
  FROM v$instance;

PROMPT
PROMPT --- 2) CDB?  (YES = multitenant; list of containers follows)
SELECT name AS db_name, db_unique_name, cdb AS is_cdb, database_role, open_mode
  FROM v$database;

PROMPT PDBs (no rows = non-CDB, or run from inside a PDB):
SELECT con_id, name AS pdb_name, open_mode, restricted
  FROM v$pdbs
 ORDER BY con_id;

PROMPT
PROMPT --- 3) Role / protection mode / Data Guard standby destinations
SELECT database_role, protection_mode, protection_level, switchover_status
  FROM v$database;

PROMPT Standby destinations (target=STANDBY, status=VALID). No rows = no live standby:
SELECT dest_id, dest_name, db_unique_name, destination, status, transmit_mode
  FROM v$archive_dest
 WHERE target = 'STANDBY'
   AND status = 'VALID'
 ORDER BY dest_id;

PROMPT
PROMPT --- 4) Log mode / force logging
SELECT log_mode, force_logging, flashback_on FROM v$database;

PROMPT
PROMPT --- 5) TLS / TDE related parameters (missing row = parameter absent on this RU)
SELECT name, value
  FROM v$parameter
 WHERE name IN ('wallet_root','tde_configuration','encrypt_new_tablespaces',
                'tablespace_encryption_default_algorithm',
                'tablespace_encryption','local_listener','remote_listener',
                'db_create_file_dest','db_recovery_file_dest',
                'db_recovery_file_dest_size')
 ORDER BY name;

PROMPT
PROMPT --- 6) Keystore / wallet status (per container)
SELECT con_id, wrl_type, wrl_parameter, status, wallet_type
  FROM v$encryption_wallet
 ORDER BY con_id;

PROMPT
PROMPT --- 7) OMF in use?  (db_create_file_dest set = Oracle Managed Files)
SELECT CASE WHEN value IS NULL THEN 'NO  (db_create_file_dest not set)'
            ELSE 'YES (' || value || ')' END AS omf_in_use
  FROM v$parameter
 WHERE name = 'db_create_file_dest';

PROMPT
PROMPT --- 8) Tablespace sizes per container (GB), largest first
PROMPT    ENCRYPTED comes from CDB_TABLESPACES. SYSTEM/SYSAUX/UNDO need OFFLINE
PROMPT    conversion regardless of method (03-tde-guide.md 5.5).
SELECT f.con_id,
       f.tablespace_name,
       ROUND(SUM(f.bytes)/1024/1024/1024, 2)     AS total_gb,
       ROUND(MAX(f.bytes)/1024/1024/1024, 2)     AS largest_datafile_gb,
       COUNT(*)                                  AS files,
       t.encrypted
  FROM cdb_data_files f
  LEFT JOIN cdb_tablespaces t
    ON t.con_id = f.con_id
   AND t.tablespace_name = f.tablespace_name
 GROUP BY f.con_id, f.tablespace_name, t.encrypted
 ORDER BY f.con_id, total_gb DESC;

PROMPT
PROMPT --- 9) Total database size (datafiles only, GB) per container and overall
SELECT con_id,
       ROUND(SUM(bytes)/1024/1024/1024, 2) AS total_gb
  FROM cdb_data_files
 GROUP BY ROLLUP (con_id)
 ORDER BY con_id;
PROMPT (NULL con_id row = grand total)

PROMPT
PROMPT --- 10) Daily redo volume, last 7 full days (V$ARCHIVED_LOG, dest_id=1, GB/day)
SELECT TRUNC(first_time) AS day,
       ROUND(SUM(blocks * block_size)/1024/1024/1024, 2) AS redo_gb
  FROM v$archived_log
 WHERE dest_id = 1
   AND first_time >= TRUNC(SYSDATE) - 7
   AND first_time <  TRUNC(SYSDATE)
 GROUP BY TRUNC(first_time)
 ORDER BY 1;

PROMPT
PROMPT --- 11) FRA / archive destination free space
PROMPT    (online TDE conversion generates redo ~= tablespace size -- see hint below)
SELECT name,
       ROUND(space_limit/1024/1024/1024, 2)                          AS limit_gb,
       ROUND(space_used/1024/1024/1024, 2)                           AS used_gb,
       ROUND(space_reclaimable/1024/1024/1024, 2)                    AS reclaimable_gb,
       ROUND((space_limit - space_used + space_reclaimable)/1024/1024/1024, 2) AS free_gb
  FROM v$recovery_file_dest;
PROMPT (no rows = no FRA; check the LOG_ARCHIVE_DEST_n filesystem with df -g on the host)

PROMPT
PROMPT --- 12) Database links (HOST shows whether the link already uses TCPS)
PROMPT    TCPS_LINK = NO means the link goes cleartext/1526 -> repoint after the
PROMPT    TARGET is on 1527 (02-tls-guide.md section 10).
COLUMN host FORMAT A70 TRUNCATED
SELECT con_id, owner, db_link, host,
       CASE WHEN UPPER(host) LIKE '%PROTOCOL%=%TCPS%' THEN 'YES' ELSE 'NO' END AS tcps_link
  FROM cdb_db_links
 ORDER BY con_id, owner, db_link;

PROMPT
PROMPT --- 13) TDE METHOD HINT per container  (ADVISORY -- confirm with 03-tde-guide.md 5.5)
PROMPT    Rule: compare the LARGEST application tablespace with the average daily
PROMPT    redo (last 7 full days). Online conversion writes ~= the tablespace size
PROMPT    as extra redo through archive + DG transport + apply.
PROMPT      largest TS <= avg daily redo  -> ONLINE (method 1) is a modest load
PROMPT      largest TS >  avg daily redo  -> prefer STANDBY-FIRST (method 3) if a standby
PROMPT                                       exists, else schedule ONLINE off-peak / OFFLINE
PROMPT      total DB < 20 GB              -> small: OFFLINE (2) or REBUILD (4) also viable
PROMPT    SYSTEM/SYSAUX/UNDO are always OFFLINE (method 2).
WITH redo AS (
  SELECT NVL(ROUND(SUM(blocks * block_size)/1024/1024/1024/7, 2), 0) AS avg_daily_redo_gb
    FROM v$archived_log
   WHERE dest_id = 1
     AND first_time >= TRUNC(SYSDATE) - 7
     AND first_time <  TRUNC(SYSDATE)
),
ts AS (
  SELECT con_id, tablespace_name, SUM(bytes)/1024/1024/1024 AS gb
    FROM cdb_data_files
   WHERE tablespace_name NOT IN ('SYSTEM','SYSAUX')
     AND tablespace_name NOT LIKE 'UNDO%'
   GROUP BY con_id, tablespace_name
),
agg AS (
  SELECT con_id,
         ROUND(MAX(gb), 2) AS largest_ts_gb,
         ROUND(SUM(gb), 2) AS app_total_gb
    FROM ts
   GROUP BY con_id
)
SELECT a.con_id,
       a.largest_ts_gb,
       r.avg_daily_redo_gb,
       a.app_total_gb,
       CASE
         WHEN r.avg_daily_redo_gb = 0
           THEN 'NO REDO DATA (standby/PDB-only run?) - decide manually'
         WHEN a.largest_ts_gb <= r.avg_daily_redo_gb
           THEN 'ONLINE (method 1): largest TS <= 1 day of redo'
         ELSE 'STANDBY-FIRST (method 3) if DG exists, else ONLINE off-peak/OFFLINE'
       END ||
       CASE WHEN a.app_total_gb < 20 THEN '; small DB: OFFLINE/REBUILD ok' ELSE '' END AS hint
  FROM agg a
 CROSS JOIN redo r
 ORDER BY a.con_id;

PROMPT
PROMPT ============================================================
PROMPT  END OF INVENTORY
PROMPT ============================================================
