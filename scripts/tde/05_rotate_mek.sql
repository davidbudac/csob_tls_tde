--------------------------------------------------------------------------------
-- 05_rotate_mek.sql
--------------------------------------------------------------------------------
-- Purpose : Rotate (re-key) the Master Encryption Key (MEK) with WITH BACKUP.
--
-- WHAT ROTATION DOES / DOES NOT DO:
--   * DOES   generate a NEW MEK and re-encrypt the tablespace/table keys
--            (the key hierarchy) with it.
--   * DOES NOT re-encrypt your DATA. Table/tablespace keys are unchanged; only
--            the wrapper (MEK) rotates. So rotation is fast and low-I/O.
--   * The OLD MEK is retained in the keystore -- it is still needed to open OLD
--            backups / archived redo. NEVER delete old keys.
--
-- Policy  : Rotate per the bank crypto-period (e.g. annually) and after any
--           suspected keystore-password exposure or personnel change.
--
-- Runs on  : PRIMARY only, as SYSKM/SYSDBA. Keystore must be OPEN.
--
-- *** DATA GUARD PRE-CHECK (MANDATORY) ***
--   SET KEY changes the keystore FILE (ewallet.p12) and, because we use a
--   non-local auto-login, the cwallet.sso too. The STANDBY still holds the OLD
--   keystore and will FAIL to open redo encrypted under the new MEK if it is not
--   refreshed. THEREFORE:
--     1) Confirm the standby wallet is currently OPEN and current (script 04).
--     2) Rotate here.
--     3) IMMEDIATELY run scripts/dg/sync_wallet_to_standby.sh to push the new
--        ewallet.p12 + cwallet.sso to the standby.
--     4) Verify V$ENCRYPTION_WALLET + MRP on the standby.
--   Skipping step 3 will stall redo apply on the standby.
--------------------------------------------------------------------------------

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO ON
SET FEEDBACK ON
SET LINESIZE 200
SET PAGESIZE 100
SET VERIFY OFF

--------------------------------------------------------------------------------
-- DEFINE VARIABLES -- EDIT BEFORE RUNNING
--------------------------------------------------------------------------------
-- Keystore password (prompt for it / pull from vault in production).
DEFINE ks_pwd  = 'REPLACE_STRONG_KEYSTORE_PASSWORD'
-- New MEK tag convention: <sid>_<YYYYMMDD>_rekey (e.g. FINP1_20260707_rekey)
DEFINE new_tag = 'REPLACE_SID_YYYYMMDD_rekey'

COLUMN key_id FORMAT A55
COLUMN tag    FORMAT A26
COLUMN status FORMAT A14

PROMPT
PROMPT ============================================================
PROMPT STEP 0 - Pre-check: keystore OPEN + current keys (PRIMARY)
PROMPT ============================================================
SELECT status, wallet_type, con_id
  FROM v$encryption_wallet ORDER BY con_id;
-- Abort manually unless STATUS=OPEN.

PROMPT -- Existing keys BEFORE rotation:
SELECT key_id, tag, TO_CHAR(activation_time,'YYYY-MM-DD HH24:MI:SS') AS activated,
       con_id
  FROM v$encryption_keys ORDER BY con_id, creation_time;

PROMPT
PROMPT ****************************************************************
PROMPT * DG REMINDER: verify the STANDBY wallet is OPEN & current NOW *
PROMPT * (run 04_verify_tde.sql on the standby). You MUST re-sync the *
PROMPT * wallet to the standby immediately AFTER this rotation.       *
PROMPT ****************************************************************

--##############################################################################
--#  NON-CDB VARIANT
--##############################################################################
PROMPT
PROMPT ============================================================
PROMPT NON-CDB VARIANT - rotate MEK
PROMPT ============================================================
ADMINISTER KEY MANAGEMENT SET KEY
   USING TAG '&new_tag'
   IDENTIFIED BY "&ks_pwd"
   WITH BACKUP USING '&new_tag';

--##############################################################################
--#  CDB VARIANT (UNITED mode)
--#  Rotate CDB$ROOT + all open PDBs in one call with CONTAINER=ALL, OR loop PDBs
--#  for per-PDB tags. Comment out the non-CDB block above when using this.
--##############################################################################
PROMPT
PROMPT ============================================================
PROMPT CDB VARIANT - rotate MEK (CONTAINER=ALL)
PROMPT ============================================================
-- ADMINISTER KEY MANAGEMENT SET KEY
--    IDENTIFIED BY "&ks_pwd"
--    WITH BACKUP USING '&new_tag'
--    CONTAINER=ALL;
--
-- NOTE (verified on 19.27): CONTAINER=ALL rotation creates the new MEKs with
-- an EMPTY tag in every container ('WITH BACKUP USING' only names the backup
-- file). If you need tagged keys for the audit trail, use the per-PDB loop
-- below, or retag afterwards per container with:
--     ADMINISTER KEY MANAGEMENT SET TAG '<tag>' FOR '<key_id>'
--        IDENTIFIED BY "&ks_pwd" WITH BACKUP;
--
-- Per-PDB tagged alternative (clearer audit trail):
--   For each PDB:
--     ALTER SESSION SET CONTAINER=<PDB_NAME>;
--     ADMINISTER KEY MANAGEMENT SET KEY USING TAG '<PDB>_<YYYYMMDD>_rekey'
--        IDENTIFIED BY "&ks_pwd" WITH BACKUP USING '<PDB>_<YYYYMMDD>_rekey';
--     ALTER SESSION SET CONTAINER=CDB$ROOT;

--------------------------------------------------------------------------------
-- STEP 2 - Post-rotation verify (PRIMARY)
--------------------------------------------------------------------------------
PROMPT
PROMPT ============================================================
PROMPT STEP 2 - Verify new MEK is active
PROMPT ============================================================
SELECT key_id, tag,
       TO_CHAR(creation_time,'YYYY-MM-DD HH24:MI:SS')   AS created,
       TO_CHAR(activation_time,'YYYY-MM-DD HH24:MI:SS') AS activated,
       con_id
  FROM v$encryption_keys
 ORDER BY con_id, creation_time;
PROMPT The row with the newest activation_time and tag '&new_tag' is now live.
PROMPT Old rows remain (required for old backups) -- this is expected.

PROMPT
PROMPT ============================================================
PROMPT STEP 3 - MANDATORY POST-STEP (Data Guard):
PROMPT   Run scripts/dg/sync_wallet_to_standby.sh NOW, then verify the standby
PROMPT   (04_verify_tde.sql on standby + check MRP is applying).
PROMPT ============================================================
PROMPT 05_rotate_mek.sql COMPLETE.
