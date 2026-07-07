# 02 — TCPS configuration fragments (server + client)

Annotated `listener.ora`, `sqlnet.ora`, `tnsnames.ora` fragments and JDBC URL examples
for the dual-port (TCP 1521 + TCPS 2484) coexistence rollout. Replace the placeholder
values (`db01.prod.csob.cz`, `APPSVC.prod.csob.cz`, DN, wallet paths) with real values.

Conventions used below:
- Host: `db01.prod.csob.cz` (FQDN — must equal cert CN/SAN)
- TCPS port: `2484`, TCP port: `1521`
- Wallet: `/oracle/admin/db01/wallet_tls` (TLS wallet, **separate from TDE keystore**)
- Server DN: `CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ`

---

## 1. Server `listener.ora`

```
#------------------------------------------------------------------------------
# listener.ora  --  dual endpoint: keep TCP 1521, add TCPS 2484
#------------------------------------------------------------------------------
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = db01.prod.csob.cz)(PORT = 1521)))
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCPS)(HOST = db01.prod.csob.cz)(PORT = 2484)))
  )

# Wallet the LISTENER presents for TCPS handshakes. May live here or in
# sqlnet.ora; if both exist, listener.ora wins for the listener process.
WALLET_LOCATION =
  (SOURCE =
    (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /oracle/admin/db01/wallet_tls)))

# Server authentication only -- do NOT demand a client certificate.
SSL_CLIENT_AUTHENTICATION = FALSE

# Optional but recommended: static registration so the standby / a MOUNTED
# instance is reachable over TCPS during role transitions (Data Guard).
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = db01_DGMGRL.prod.csob.cz)
      (ORACLE_HOME = /oracle/product/19c/dbhome_1)
      (SID_NAME = db01)))

# NOTE: Adding the TCPS ADDRESS above requires a FULL restart:
#         lsnrctl stop  <listener>
#         lsnrctl start <listener>
#       'lsnrctl reload' does NOT add a new listening endpoint. Reload IS
#       sufficient for later certificate renewals into the same wallet.
```

---

## 2. Server `sqlnet.ora`

```
#------------------------------------------------------------------------------
# sqlnet.ora (server)  --  governs the LISTENER's TLS AND the DB acting as a
# TLS CLIENT (DB links / Data Guard redo transport outbound).
#
# WALLET_LOCATION here is MANDATORY for inbound TCPS too: after the listener
# hands the connection off, the DB SERVER PROCESS re-reads sqlnet.ora and needs
# the wallet -- without it clients fail with ORA-28865 AFTER a successful
# listener handshake (verified on 19c).
#
# BEFORE EDITING: check for an existing WALLET_LOCATION (e.g. a SEPS credential
# wallet with SQLNET.WALLET_OVERRIDE=TRUE). sqlnet.ora supports only ONE
# WALLET_LOCATION -- merge the wallets or isolate via TNS_ADMIN, never append
# a second entry. See 02-tls-guide.md section 4.2.
#------------------------------------------------------------------------------
WALLET_LOCATION =
  (SOURCE =
    (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /oracle/admin/db01/wallet_tls)))

SSL_CLIENT_AUTHENTICATION = FALSE

# Pin TLS 1.2. Only use "1.2 or 1.3" after verifying the RU supports TLS 1.3
# (roughly 19.23+); on lower RUs "1.3" can fail the handshake.
SSL_VERSION = 1.2

# Forward-secret AEAD suites only (ECDHE + AES-GCM). Widen only if a legacy
# OCI client cannot negotiate ECDHE, then plan to remove weak suites.
SSL_CIPHER_SUITES = (TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256)

# When THIS DB is a TLS client (DB link / redo transport), match the peer DN.
SSL_SERVER_DN_MATCH = TRUE

#------------------------------------------------------------------------------
# Native encryption (ANO) interaction -- see guide section 5.
# TLS and native encryption do NOT stack usefully; over TCPS, forcing native
# = double encryption. During coexistence, if you rely on native to protect
# the surviving 1521 port, REQUIRED is acceptable but wasteful on TCPS.
# Target (TCPS-only) state: ACCEPTED or REJECTED.
#------------------------------------------------------------------------------
SQLNET.ENCRYPTION_SERVER = ACCEPTED
SQLNET.ENCRYPTION_CLIENT = ACCEPTED

# Optional temporary tracing for handshake debugging:
# TRACE_LEVEL_SERVER    = 16
# TRACE_DIRECTORY_SERVER = /oracle/admin/db01/trace
```

Then advertise the TCPS endpoint for dynamic registration (SQL, not a file):

```sql
ALTER SYSTEM SET LOCAL_LISTENER=
 '(DESCRIPTION_LIST=
    (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db01.prod.csob.cz)(PORT=1521)))
    (DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=db01.prod.csob.cz)(PORT=2484))))'
 SCOPE=BOTH;
ALTER SYSTEM REGISTER;
```

---

## 3. Server-side `tnsnames.ora` (for DB links / Data Guard aliases)

```
#------------------------------------------------------------------------------
# TCPS alias used by DB links from this DB and by redo transport.
#------------------------------------------------------------------------------
DB02_TLS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCPS)(HOST = db02.prod.csob.cz)(PORT = 2484))
    (CONNECT_DATA = (SERVICE_NAME = BSVC.prod.csob.cz))
    (SECURITY = (SSL_SERVER_DN_MATCH = TRUE)
                (SSL_SERVER_CERT_DN = "CN=db02.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ")))

# Data Guard standby transport alias (broker DGConnectIdentifier / LAD_2).
STDBY_TLS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCPS)(HOST = stdby01.dr.csob.cz)(PORT = 2484))
    (CONNECT_DATA = (SERVICE_NAME = stdby.dr.csob.cz))
    (SECURITY = (SSL_SERVER_DN_MATCH = TRUE)
                (SSL_SERVER_CERT_DN = "CN=stdby01.dr.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ")))
```

---

## 4. Client `sqlnet.ora` (legacy OCI / thick client)

```
#------------------------------------------------------------------------------
# Client sqlnet.ora  --  points at a TRUSTSTORE-ONLY auto-login wallet
# (CA chain only, NO private key), because auth is server-only.
#------------------------------------------------------------------------------
WALLET_LOCATION =
  (SOURCE =
    (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /oracle/client/wallet_tls)))

SSL_SERVER_DN_MATCH = TRUE
SSL_VERSION = 1.2
```

Build the client truststore wallet (CA chain only):

```ksh
orapki wallet create -wallet /oracle/client/wallet_tls -auto_login -pwd "$PW"
orapki wallet add -wallet /oracle/client/wallet_tls -trusted_cert -cert csob-root-ca.cer   -pwd "$PW"
orapki wallet add -wallet /oracle/client/wallet_tls -trusted_cert -cert csob-issuing-ca.cer -pwd "$PW"
```

## 5. Client `tnsnames.ora` (legacy OCI)

```
APPSVC_TLS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCPS)(HOST = db01.prod.csob.cz)(PORT = 2484))
    (CONNECT_DATA = (SERVICE_NAME = APPSVC.prod.csob.cz))
    (SECURITY = (SSL_SERVER_DN_MATCH = TRUE)
                (SSL_SERVER_CERT_DN = "CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ")))
```

Connect and verify:

```
sqlplus app_user@APPSVC_TLS
```

---

## 6. JDBC thin URL examples

### Easy Connect Plus (preferred, JKS truststore holds the CA)

```
jdbc:oracle:thin:@tcps://db01.prod.csob.cz:2484/APPSVC.prod.csob.cz?ssl_server_dn_match=true
```

JVM / datasource properties (system truststore approach — no Oracle wallet, no
`oraclepki`/`osdt` jars needed):

```
-Djavax.net.ssl.trustStore=/etc/pki/csob-truststore.jks
-Djavax.net.ssl.trustStoreType=JKS
-Djavax.net.ssl.trustStorePassword=changeit
```

### TNS-descriptor form (explicit DN pin)

```
jdbc:oracle:thin:@(DESCRIPTION=
  (ADDRESS=(PROTOCOL=TCPS)(HOST=db01.prod.csob.cz)(PORT=2484))
  (CONNECT_DATA=(SERVICE_NAME=APPSVC.prod.csob.cz))
  (SECURITY=(SSL_SERVER_DN_MATCH=TRUE)
            (SSL_SERVER_CERT_DN="CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ")))
```

> DN-match default varies by driver: pre-21c thin defaults to FALSE, 21c+ defaults to
> TRUE (with hostname vs CN/SAN matching). **Always set `ssl_server_dn_match=true`
> explicitly** and ensure the connect-string host equals the cert CN/SAN.

### ORDS pool (APEX) — custom URL form

```
db.connectionType=customurl
db.customURL=jdbc:oracle:thin:@tcps://db01.prod.csob.cz:2484/APEXSVC.prod.csob.cz?ssl_server_dn_match=true
```

ORDS JVM must trust the CA (add to the ORDS/Tomcat/WebLogic JVM options):

```
-Djavax.net.ssl.trustStore=/etc/pki/csob-truststore.jks
-Djavax.net.ssl.trustStoreType=JKS
-Djavax.net.ssl.trustStorePassword=changeit
```
