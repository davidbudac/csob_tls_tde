--------------------------------------------------------------------------------
-- 01_configure_wallet_root.sql
--------------------------------------------------------------------------------
-- Purpose : Configure WALLET_ROOT (spfile, static) and TDE_CONFIGURATION
--           (dynamic) for Oracle 19c software keystore TDE, standardized on the
--           WALLET_ROOT layout so a later migration to OKV is clean.
--
-- Standard : WALLET_ROOT      = /oracle/admin/<ORACLE_SID>/wallet
--            (Oracle auto-appends /tde -> keystore lives in .../wallet/tde)
--            TDE_CONFIGURATION = 'KEYSTORE_CONFIGURATION=FILE'
--
-- IMPORTANT: Do NOT use sqlnet.ora ENCRYPTION_WALLET_LOCATION (deprecated in 19c).
--
-- Runs on  : PRIMARY as SYSDBA (SYSKM privilege is enough for KM ops, but this
--            step alters spfile parameters so a SYSDBA login is expected).
--            For CDB run from CDB$ROOT. WALLET_ROOT / TDE_CONFIGURATION are set
--            at the CDB level and inherited by PDBs (united mode).
--
-- Order    : Run this FIRST. Requires ONE database restart between the WALLET_ROOT
--            change (static) and the TDE_CONFIGURATION change (dynamic).
--
-- Env      : Oracle 19c EE, non-RAC, AIX 7.2. Data Guard physical standby present.
--            RUN ON PRIMARY. Repeat the WALLET_ROOT/spfile step on the STANDBY
--            (its spfile also needs WALLET_ROOT so the standby can open the copied
--            keystore) -- see NOTE at the bottom.
--------------------------------------------------------------------------------

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO ON
SET FEEDBACK ON
SET LINESIZE 200
SET PAGESIZE 100
SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- DEFINE VARIABLES -- EDIT THESE BEFORE RUNNING
--------------------------------------------------------------------------------
-- The literal path. Convention: /oracle/admin/<ORACLE_SID>/wallet
-- (Oracle appends /tde automatically; do NOT include /tde here.)
DEFINE wallet_root_path = '/oracle/admin/REPLACE_SID/wallet'

COLUMN name  FORMAT A30
COLUMN value FORMAT A80
COLUMN con   FORMAT A10

PROMPT
PROMPT ============================================================
PROMPT STEP 0 - Show current configuration BEFORE any change
PROMPT ============================================================
SELECT name, value
  FROM v$parameter
 WHERE name IN ('wallet_root','tde_configuration')
 ORDER BY name;

PROMPT
PROMPT Current WALLET keystore view (expect empty / NOT_AVAILABLE before setup):
SELECT wrl_type, wrl_parameter, status, wallet_type, con_id
  FROM v$encryption_wallet
 ORDER BY con_id;

--------------------------------------------------------------------------------
-- STEP 1 - Set WALLET_ROOT (STATIC -> scope=spfile -> requires RESTART)
--          Same statement for non-CDB and CDB (set once at CDB root level).
--------------------------------------------------------------------------------
PROMPT
PROMPT ============================================================
PROMPT STEP 1 - Set WALLET_ROOT (spfile only; RESTART required afterwards)
PROMPT ============================================================
PROMPT About to set WALLET_ROOT = &wallet_root_path
ALTER SYSTEM SET WALLET_ROOT = '&wallet_root_path' SCOPE=SPFILE;

PROMPT
PROMPT Verify the pending spfile value (V$SPPARAMETER shows the spfile,
PROMPT not the runtime value -- the runtime value stays empty until restart):
COLUMN value FORMAT A80
SELECT name, value
  FROM v$spparameter
 WHERE name = 'wallet_root';

PROMPT
PROMPT ****************************************************************
PROMPT * ACTION REQUIRED: RESTART THE DATABASE NOW.                   *
PROMPT *   non-CDB / CDB:  SHUTDOWN IMMEDIATE;  STARTUP;              *
PROMPT *   (Data Guard: bounce the PRIMARY per your maintenance SOP;  *
PROMPT *    apply the SAME WALLET_ROOT spfile change on the STANDBY   *
PROMPT *    and bounce it too -- see NOTE at bottom.)                 *
PROMPT *                                                              *
PROMPT * Then re-connect and run STEP 2 below (it is dynamic).        *
PROMPT ****************************************************************
PROMPT
PROMPT Stopping here so the restart is not skipped. Re-run from STEP 2
PROMPT after the bounce (comment out STEP 1 or just proceed past it).
PROMPT
-- Intentional hard stop so an operator cannot blow past the restart.
-- The EXIT below is ACTIVE by default (first pass). On the SECOND pass
-- (after the restart), comment out the EXIT line -- or simply re-run only
-- STEP 2 and STEP 3 -- to continue.
PROMPT First pass complete. EXITing before STEP 2 -- restart the DB now.
EXIT

--------------------------------------------------------------------------------
-- STEP 2 - Set TDE_CONFIGURATION (DYNAMIC). Run AFTER the restart.
--          FILE = local software keystore under WALLET_ROOT/tde.
--------------------------------------------------------------------------------
PROMPT
PROMPT ============================================================
PROMPT STEP 2 - Set TDE_CONFIGURATION (dynamic, both instances)
PROMPT ============================================================
PROMPT Confirm WALLET_ROOT is now populated at runtime (must be non-null):
SELECT name, value FROM v$parameter WHERE name = 'wallet_root';

-- ---- non-CDB variant --------------------------------------------------------
-- Single container. SCOPE=BOTH persists it.
ALTER SYSTEM SET TDE_CONFIGURATION = 'KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;

-- ---- CDB variant ------------------------------------------------------------
-- In UNITED mode the CDB$ROOT setting is inherited by all PDBs; you normally
-- set it ONCE at the root (statement above). If you later choose ISOLATED mode
-- for a specific PDB (19c: supported but see guide caveat re: RU level), you
-- would connect into that PDB and run:
--     ALTER SESSION SET CONTAINER = <PDB_NAME>;
--     ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;
-- For this fleet we recommend UNITED mode -> do NOT set it per PDB.

--------------------------------------------------------------------------------
-- STEP 3 - Verify
--------------------------------------------------------------------------------
PROMPT
PROMPT ============================================================
PROMPT STEP 3 - Verify final configuration
PROMPT ============================================================
SELECT name, value
  FROM v$parameter
 WHERE name IN ('wallet_root','tde_configuration')
 ORDER BY name;

PROMPT
PROMPT Keystore view (expect WALLET_TYPE=UNKNOWN / STATUS=NOT_AVAILABLE until the
PROMPT keystore is actually created in script 02):
SELECT wrl_type, wrl_parameter, status, wallet_type, con_id
  FROM v$encryption_wallet
 ORDER BY con_id;

PROMPT
PROMPT ============================================================
PROMPT NOTE (Data Guard):
PROMPT   The STANDBY spfile ALSO needs WALLET_ROOT (STEP 1) and
PROMPT   TDE_CONFIGURATION (STEP 2). Set them on the standby and bounce it.
PROMPT   The standby does NOT run CREATE KEYSTORE / SET KEY -- it only needs
PROMPT   the parameters plus the copied keystore files (script 02 + sync).
PROMPT ============================================================
PROMPT 01_configure_wallet_root.sql COMPLETE.
