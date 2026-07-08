--=============================================================================
-- 03_verify_tls.sql
--
-- Purpose : Confirm the CURRENT session arrived over TLS (TCPS) and show the
--           negotiated network protocol / encryption for that session.
--           Run this AFTER connecting through a TCPS alias, e.g.:
--               sqlplus app_user@APPSVC_TLS @03_verify_tls.sql
--           (Oracle 19c EE. Works for non-CDB and CDB/PDB.)
--
-- Assumptions:
--   * You connected over the TCPS endpoint (port 1527). If you connected over
--     TCP 1526, NETWORK_PROTOCOL will show 'tcp' and this proves the negative.
--   * No SYSDBA required; any session with SELECT on the V$ views below works.
--     (V$SESSION_CONNECT_INFO / V$SESSION_CONNECT_INFO need SELECT_CATALOG_ROLE
--      or explicit grants for non-privileged users.)
--=============================================================================

SET LINESIZE 160
SET PAGESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF
COLUMN item        FORMAT A34
COLUMN value       FORMAT A118
COLUMN network_service_banner FORMAT A118 WORD_WRAPPED

PROMPT
PROMPT ============================================================
PROMPT  TLS / SQL*Net session verification
PROMPT ============================================================
PROMPT

-- 1) Transport protocol + identity of THIS session --------------------------
--    NETWORK_PROTOCOL = 'tcps' proves the session is on the TLS endpoint.
SELECT 'DB / container'                         AS item,
       SYS_CONTEXT('USERENV','DB_NAME')
       || ' / ' || SYS_CONTEXT('USERENV','CON_NAME') AS value
FROM   dual
UNION ALL
SELECT 'Session user',        SYS_CONTEXT('USERENV','SESSION_USER')      FROM dual
UNION ALL
SELECT 'Network protocol',    SYS_CONTEXT('USERENV','NETWORK_PROTOCOL')  FROM dual
UNION ALL
SELECT 'Client host / IP',
       NVL(SYS_CONTEXT('USERENV','HOST'),'?')
       || ' / ' || NVL(SYS_CONTEXT('USERENV','IP_ADDRESS'),'?')          FROM dual
UNION ALL
SELECT 'Server host',         SYS_CONTEXT('USERENV','SERVER_HOST')       FROM dual;

PROMPT
PROMPT --- Interpretation 
PROMPT  Network protocol = tcps  ->  session IS on the TLS endpoint.
PROMPT  Network protocol = tcp   ->  session is CLEARTEXT (port 1526).
PROMPT ===========================================================
PROMPT

-- 2) Network service banners for THIS session -------------------------------
--    On a TLS session the AUTHENTICATION/ENCRYPTION service banners reflect
--    the TLS/crypto adapter in use for the current session.
PROMPT Network service banners for the current session:
PROMPT
SELECT network_service_banner
FROM   v$session_connect_info
WHERE  sid = SYS_CONTEXT('USERENV','SID')
ORDER  BY network_service_banner;

PROMPT
-- 3) Compact encryption/auth summary for THIS session -----------------------
PROMPT Encryption / authentication adapters detected for this session:
PROMPT
SELECT CASE
         WHEN UPPER(network_service_banner) LIKE '%ENCRYPTION%' THEN 'ENCRYPTION'
         WHEN UPPER(network_service_banner) LIKE '%CRYPTO%'     THEN 'ENCRYPTION'
         WHEN UPPER(network_service_banner) LIKE '%AUTHENTICATION%' THEN 'AUTHENTICATION'
         WHEN UPPER(network_service_banner) LIKE '%DATA INTEGRITY%' THEN 'INTEGRITY'
         ELSE 'OTHER'
       END                              AS item,
       network_service_banner           AS value
FROM   v$session_connect_info
WHERE  sid = SYS_CONTEXT('USERENV','SID')
AND    (UPPER(network_service_banner) LIKE '%ENCRYPT%'
        OR UPPER(network_service_banner) LIKE '%CRYPTO%'
        OR UPPER(network_service_banner) LIKE '%AUTHENTICATION%'
        OR UPPER(network_service_banner) LIKE '%INTEGRITY%')
ORDER  BY 1;

PROMPT
PROMPT ============================================================
PROMPT  If 'Network protocol' above is 'tcps', this session is TLS.
PROMPT  Cross-check the negotiated TLS version/cipher on the wire
PROMPT  with:  03_verify_tls.sh  (openssl s_client probe).
PROMPT ============================================================

SET FEEDBACK ON
