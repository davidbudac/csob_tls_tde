--------------------------------------------------------------------------------
-- 03_encrypt_tablespaces_online.sql
--------------------------------------------------------------------------------
-- Purpose : Online tablespace encryption for 19c. Runs pre-checks, GENERATES the
--           ALTER TABLESPACE ... ENCRYPTION ONLINE ... ENCRYPT statements to a
--           spool file for review, and provides progress-monitoring + resume
--           (FINISH) syntax. It does NOT auto-execute the conversions -- you
--           review the generated script and run it deliberately, one tablespace
--           at a time, to throttle redo/IO and DG transport load.
--
-- Method  : Online encryption is no-downtime but:
--             * needs free space ~= the largest datafile being converted
--               (Oracle converts file-by-file, writing a new encrypted copy),
--             * generates redo ~= full tablespace size -> heavy DG transport /
--               apply + archive volume. PLAN archive space and network.
--           Do ONE tablespace at a time in a maintenance window; watch standby.
--
-- Excludes: SYSTEM, SYSAUX, UNDO*, TEMP* and already-encrypted tablespaces.
--           (SYSTEM/SYSAUX/UNDO use OFFLINE conversion; TEMP is recreated --
--            see 03-tde-guide.md. This script targets application tablespaces.)
--
-- Runs on  : PRIMARY, as SYSDBA. Keystore must be OPEN. For a CDB, run inside the
--            target PDB (ALTER SESSION SET CONTAINER=<PDB>) -- see CDB note.
--
-- Pre-reqs: Scripts 01 + 02 done; standby has the keystore (sync + verified).
--------------------------------------------------------------------------------

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO OFF
SET FEEDBACK OFF
SET LINESIZE 200
SET PAGESIZE 200
SET VERIFY OFF
SET TRIMSPOOL ON

--------------------------------------------------------------------------------
-- DEFINE VARIABLES
--------------------------------------------------------------------------------
DEFINE enc_algo   = 'AES256'
DEFINE gen_script = '/tmp/tde_encrypt_generated.sql'

COLUMN tablespace_name FORMAT A30
COLUMN status          FORMAT A12
COLUMN encrypted       FORMAT A10
COLUMN ok_free         FORMAT A8

--------------------------------------------------------------------------------
-- CDB NOTE:
--   Encryption is per-PDB. Connect into the target PDB first:
--       ALTER SESSION SET CONTAINER = <PDB_NAME>;
--   Then run this script. The DBA_* views below then reflect that PDB. Repeat
--   per PDB. (CDB$ROOT app tablespaces, if any, are handled the same way in root.)
--------------------------------------------------------------------------------

PROMPT
PROMPT ============================================================
PROMPT STEP 1 - Keystore must be OPEN before encrypting
PROMPT ============================================================
SET FEEDBACK ON
SELECT status, wallet_type, con_id
  FROM v$encryption_wallet
 WHERE con_id IN (0, SYS_CONTEXT('USERENV','CON_ID'));
-- Abort manually if STATUS is not OPEN.

PROMPT
PROMPT ============================================================
PROMPT STEP 2 - Free-space pre-check
PROMPT   Online conversion needs free space >= the LARGEST datafile of the
PROMPT   tablespace (file-by-file). This checks per-tablespace whether the file
PROMPT   can autoextend or whether headroom exists at the ASM/filesystem level.
PROMPT   NOTE: this checks the tablespace's own max headroom; you MUST also
PROMPT   confirm the underlying diskgroup/filesystem has room for a copy of the
PROMPT   largest datafile. Autoextend ON with enough MAXSIZE covers most cases.
PROMPT ============================================================
SELECT df.tablespace_name,
       ROUND(MAX(df.bytes)/1024/1024)                       AS largest_file_mb,
       ROUND(SUM(df.bytes)/1024/1024)                       AS ts_total_mb,
       ROUND(MAX(CASE WHEN df.autoextensible='YES'
                      THEN df.maxbytes - df.bytes ELSE 0 END)/1024/1024) AS max_autoext_headroom_mb
  FROM dba_data_files df
 WHERE df.tablespace_name NOT IN ('SYSTEM','SYSAUX')
   AND df.tablespace_name NOT LIKE 'UNDO%'
   AND df.tablespace_name NOT IN
       (SELECT tablespace_name FROM dba_tablespaces WHERE contents='TEMPORARY')
   AND df.tablespace_name NOT IN
       (SELECT ts.name FROM v$encrypted_tablespaces et
          JOIN v$tablespace ts ON ts.ts# = et.ts#)
 GROUP BY df.tablespace_name
 ORDER BY df.tablespace_name;

PROMPT
PROMPT ============================================================
PROMPT STEP 3 - Tablespaces that WILL be targeted (candidate list)
PROMPT   = permanent, ONLINE, not already encrypted, excluding SYSTEM/SYSAUX/
PROMPT     UNDO*/TEMP*.
PROMPT ============================================================
SET FEEDBACK ON
SELECT t.tablespace_name, t.status, t.encrypted
  FROM dba_tablespaces t
 WHERE t.contents = 'PERMANENT'
   AND t.status   = 'ONLINE'
   AND t.encrypted = 'NO'
   AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
   AND t.tablespace_name NOT LIKE 'UNDO%'
 ORDER BY t.tablespace_name;

--------------------------------------------------------------------------------
-- STEP 4 - GENERATE the encryption statements to a spool file for REVIEW.
--------------------------------------------------------------------------------
PROMPT
PROMPT ============================================================
PROMPT STEP 4 - Generating ALTER statements to &gen_script
PROMPT          REVIEW the file, then run it MANUALLY, ONE tablespace at a time.
PROMPT ============================================================
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SPOOL &gen_script

SELECT '-- Generated online-encryption statements. Run ONE AT A TIME.' FROM dual;
SELECT '-- Algorithm: &enc_algo   Generated: '
       || TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS') FROM dual;
SELECT '-- Monitor V$SESSION_LONGOPS and the standby between each run.' FROM dual;
SELECT 'ALTER TABLESPACE "' || t.tablespace_name
       || '" ENCRYPTION ONLINE USING ''&enc_algo'' ENCRYPT;'  AS stmt
  FROM dba_tablespaces t
 WHERE t.contents = 'PERMANENT'
   AND t.status   = 'ONLINE'
   AND t.encrypted = 'NO'
   AND t.tablespace_name NOT IN ('SYSTEM','SYSAUX')
   AND t.tablespace_name NOT LIKE 'UNDO%'
 ORDER BY t.tablespace_name;

SPOOL OFF
SET HEADING ON
SET PAGESIZE 200
SET FEEDBACK ON

PROMPT
PROMPT Generated. Review &gen_script before executing anything.
PROMPT
PROMPT NOTES on the generated syntax:
PROMPT  * FILE_NAME_CONVERT is deliberately OMITTED: Oracle then creates the
PROMPT    temporary converted copy itself and keeps datafiles in place. This is
PROMPT    the only form that works on BOTH OMF and non-OMF databases
PROMPT    (FILE_NAME_CONVERT=NONE raises ORA-28437 on OMF -- verified on 19.27).
PROMPT  * On non-OMF you MAY add FILE_NAME_CONVERT=('/old/','/new/') to place
PROMPT    the conversion copy on a different mount if the datafile filesystem
PROMPT    lacks headroom. Adjust the generator if you need that.
PROMPT  * USING '&enc_algo' -> AES256 (bank standard). Other 19c options:
PROMPT    AES128, AES192, AES256, ARIA*, GOST*, SEED* (stick to AES256).
PROMPT  * You can also DECRYPT ( ... ENCRYPTION ONLINE DECRYPT ) or REKEY
PROMPT    ( ... ENCRYPTION ONLINE ... ENCRYPT to re-encrypt with a new TS key ).

--------------------------------------------------------------------------------
-- STEP 5 - RESUME an interrupted online conversion (FINISH clause)
--------------------------------------------------------------------------------
PROMPT
PROMPT ============================================================
PROMPT STEP 5 - If an online conversion was INTERRUPTED (crash / abort / space)
PROMPT ============================================================
PROMPT An interrupted ALTER TABLESPACE ... ENCRYPTION ONLINE leaves a partially
PROMPT converted set of files. Resume it with FINISH (does NOT restart from zero):
PROMPT
PROMPT   -- Encrypt, resuming:
PROMPT   ALTER TABLESPACE "<TS>" ENCRYPTION ONLINE USING '&enc_algo' FINISH ENCRYPT;
PROMPT
PROMPT   -- (If you were DECRYPTing:)
PROMPT   ALTER TABLESPACE "<TS>" ENCRYPTION ONLINE FINISH DECRYPT;
PROMPT
PROMPT Check for a leftover temp/partial file in the datafile directory before
PROMPT resuming; ensure free space is available for the remaining file(s).

--------------------------------------------------------------------------------
-- STEP 6 - PROGRESS MONITORING (run in a SEPARATE session during conversion)
--------------------------------------------------------------------------------
PROMPT
PROMPT ============================================================
PROMPT STEP 6 - Monitoring queries (copy into a second SQL*Plus session)
PROMPT ============================================================
PROMPT
PROMPT -- 6a) Live long-operation progress for the encryption:
PROMPT SELECT sid, serial#, opname, target,
PROMPT        sofar, totalwork,
PROMPT        ROUND(sofar/DECODE(totalwork,0,NULL,totalwork)*100,1) AS pct_done,
PROMPT        time_remaining, elapsed_seconds
PROMPT   FROM v$session_longops
PROMPT  WHERE opname LIKE '%ncrypt%' OR opname LIKE '%onvert%'
PROMPT  ORDER BY start_time DESC;
PROMPT
PROMPT -- 6b) Which tablespaces are now encrypted (status join):
PROMPT SELECT t.tablespace_name, t.encrypted,
PROMPT        et.encryptionalg, et.status AS enc_status
PROMPT   FROM dba_tablespaces t
PROMPT   LEFT JOIN v$tablespace vt ON vt.name = t.tablespace_name
PROMPT   LEFT JOIN v$encrypted_tablespaces et ON et.ts# = vt.ts#
PROMPT  ORDER BY t.tablespace_name;
PROMPT
PROMPT -- 6c) Standby health during conversion (RUN ON THE STANDBY):
PROMPT --   * confirm MRP is applying:
PROMPT --       SELECT process, status, thread#, sequence#
PROMPT --         FROM v$managed_standby WHERE process LIKE 'MRP%';
PROMPT --   * confirm apply is keeping up (transport/apply lag):
PROMPT --       SELECT name, value, unit FROM v$dataguard_stats
PROMPT --        WHERE name IN ('transport lag','apply lag');
PROMPT
PROMPT ============================================================
PROMPT 03_encrypt_tablespaces_online.sql COMPLETE (generation only).
PROMPT Next: review &gen_script and execute per-tablespace in your window.
PROMPT ============================================================
