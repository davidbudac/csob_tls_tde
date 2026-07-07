--------------------------------------------------------------------------------
-- 02_create_keystore_and_mek.sql
--------------------------------------------------------------------------------
-- Purpose : Create the software (password) keystore, open it, set the first
--           Master Encryption Key (MEK), and create a NON-LOCAL auto-login
--           keystore (portable to the DG standby host).
--
-- Pre-reqs: Script 01 completed. WALLET_ROOT set + DB restarted;
--           TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=FILE'. Keystore files land
--           in $WALLET_ROOT/tde  (Oracle appends /tde automatically).
--
-- DIRECTORY NOTE (do this at the OS layer BEFORE running, as oracle:oinstall):
--     mkdir -p /oracle/admin/<ORACLE_SID>/wallet/tde
--     chmod 700 /oracle/admin/<ORACLE_SID>/wallet/tde
--   Oracle 19c will create $WALLET_ROOT/tde on CREATE KEYSTORE if the parent
--   exists, but pre-creating with tight perms is the bank standard.
--
-- Runs on  : PRIMARY only, as SYSKM (or SYSDBA). ADMINISTER KEY MANAGEMENT is a
--            PRIMARY-only operation. The STANDBY receives the keystore files via
--            scripts/dg/sync_wallet_to_standby.sh AFTER this script.
--
-- DG ORDER : 1) Run this on PRIMARY.
--            2) Immediately run sync_wallet_to_standby.sh (copies ewallet.p12 +
--               cwallet.sso to the standby's $WALLET_ROOT/tde).
--            3) Verify V$ENCRYPTION_WALLET on the standby.
--            Do NOT create any tablespace/DB key or start encryption before the
--            standby has the keystore files.
--
-- KEY TYPE : We create a NON-LOCAL auto-login keystore (CREATE AUTO_LOGIN, not
--            CREATE LOCAL AUTO_LOGIN). LOCAL binds the SSO to the host it was
--            created on and will NOT open on the standby host -> avoid for DG.
--------------------------------------------------------------------------------

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO ON
SET FEEDBACK ON
SET LINESIZE 200
SET PAGESIZE 100
SET VERIFY OFF

--------------------------------------------------------------------------------
-- DEFINE VARIABLES -- EDIT THESE BEFORE RUNNING
--------------------------------------------------------------------------------
-- Keystore password. In production, do NOT keep this in the file: prompt for it,
-- store it in the bank password vault, and hand it to the operator at run time.
DEFINE ks_pwd = 'REPLACE_STRONG_KEYSTORE_PASSWORD'

-- MEK tag convention: <sid>_<YYYYMMDD>  (e.g. FINP1_20260707). Human-readable,
-- sortable, identifies the key on rotation.
DEFINE mek_tag = 'REPLACE_SID_YYYYMMDD'

COLUMN wrl_parameter FORMAT A50
COLUMN status        FORMAT A16
COLUMN wallet_type   FORMAT A16
COLUMN key_id        FORMAT A55
COLUMN tag           FORMAT A25

PROMPT
PROMPT ============================================================
PROMPT STEP 0 - Pre-flight: confirm config + no existing keystore
PROMPT ============================================================
SELECT name, value FROM v$parameter
 WHERE name IN ('wallet_root','tde_configuration') ORDER BY name;

SELECT wrl_type, status, wallet_type, con_id
  FROM v$encryption_wallet ORDER BY con_id;
PROMPT (Expect STATUS=NOT_AVAILABLE / WALLET_TYPE=UNKNOWN before creation.)

--##############################################################################
--#  NON-CDB VARIANT
--#  (Comment this whole block out when running against a CDB; use the CDB block.)
--##############################################################################
PROMPT
PROMPT ============================================================
PROMPT NON-CDB VARIANT
PROMPT ============================================================

-- 1) Create the password (software) keystore under WALLET_ROOT/tde
PROMPT -- Creating password keystore in WALLET_ROOT/tde ...
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "&ks_pwd";

-- 2) Open the keystore
PROMPT -- Opening keystore ...
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "&ks_pwd";

-- 3) Set (activate) the first MEK, backing up the keystore in the same op
PROMPT -- Setting first MEK (WITH BACKUP) tag=&mek_tag ...
ADMINISTER KEY MANAGEMENT SET KEY
   USING TAG '&mek_tag'
   IDENTIFIED BY "&ks_pwd"
   WITH BACKUP USING '&mek_tag._setkey';

-- 4) Create NON-LOCAL auto-login keystore (portable to standby host)
PROMPT -- Creating NON-LOCAL auto-login keystore (cwallet.sso) ...
ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE
   FROM KEYSTORE IDENTIFIED BY "&ks_pwd";

PROMPT -- NON-CDB verification:
SELECT wrl_type, wrl_parameter, status, wallet_type, con_id
  FROM v$encryption_wallet;
-- Expect: WALLET_TYPE = AUTOLOGIN, STATUS = OPEN.

SELECT key_id, tag, creation_time, activation_time
  FROM v$encryption_keys
 ORDER BY creation_time;

--##############################################################################
--#  CDB / PDB VARIANT (UNITED mode: one keystore in CDB$ROOT, per-PDB MEKs)
--#  Run connected to CDB$ROOT as SYSKM/SYSDBA.
--#  (Comment this whole block out when running against a non-CDB.)
--##############################################################################
PROMPT
PROMPT ============================================================
PROMPT CDB VARIANT (UNITED keystore, CONTAINER=ALL)
PROMPT ============================================================

-- 1) Create keystore (single keystore serves the whole CDB in united mode)
-- ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "&ks_pwd";

-- 2) Open across ALL containers (CDB$ROOT + all PDBs)
-- ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN
--    IDENTIFIED BY "&ks_pwd" CONTAINER=ALL;

-- 3a) Set MEK in CDB$ROOT
-- ADMINISTER KEY MANAGEMENT SET KEY
--    USING TAG '&mek_tag._ROOT'
--    IDENTIFIED BY "&ks_pwd"
--    WITH BACKUP USING '&mek_tag._root_setkey';
--
-- 3b) Set a SEPARATE MEK in EACH PDB (per-PDB keys are the recommendation).
--     NOTE: SET KEY with CONTAINER=ALL sets keys for root + all *open* PDBs in
--     one call; per-PDB tags are clearer, so we loop the PDBs explicitly.
--     For each application PDB:
--         ALTER SESSION SET CONTAINER = <PDB_NAME>;
--         ADMINISTER KEY MANAGEMENT SET KEY
--            USING TAG '<PDB_NAME>_<YYYYMMDD>'
--            IDENTIFIED BY "&ks_pwd"
--            WITH BACKUP USING '<PDB_NAME>_setkey';
--         ALTER SESSION SET CONTAINER = CDB$ROOT;
--
--     (One-shot alternative for all open PDBs at once:)
--         ADMINISTER KEY MANAGEMENT SET KEY
--            IDENTIFIED BY "&ks_pwd" WITH BACKUP CONTAINER=ALL;

-- 4) Create NON-LOCAL auto-login (root-level; covers the CDB)
-- ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE
--    FROM KEYSTORE IDENTIFIED BY "&ks_pwd";

PROMPT -- CDB verification (per-container rollup):
-- SELECT wrl_type, status, wallet_type, con_id
--   FROM v$encryption_wallet ORDER BY con_id;
-- Expect one row per container; WALLET_TYPE=AUTOLOGIN, STATUS=OPEN in each.

-- SELECT k.con_id, c.name AS con_name, k.key_id, k.tag, k.creation_time
--   FROM v$encryption_keys k
--   LEFT JOIN v$containers c ON c.con_id = k.con_id
--  ORDER BY k.con_id, k.creation_time;

PROMPT
PROMPT ============================================================
PROMPT POST-RUN (Data Guard) -- do NOT skip:
PROMPT   Run scripts/dg/sync_wallet_to_standby.sh NOW to copy
PROMPT   ewallet.p12 + cwallet.sso to the standby's WALLET_ROOT/tde,
PROMPT   then verify V$ENCRYPTION_WALLET on the standby shows STATUS=OPEN.
PROMPT   Only after that proceed to script 03 (encryption).
PROMPT ============================================================
PROMPT 02_create_keystore_and_mek.sql COMPLETE.
