# 02 — TLS / SQL*Net Network Encryption Guide (Oracle 19c EE)

**Purpose.** This runbook describes how to introduce TLS (TCPS) network encryption for
Oracle 19c Enterprise Edition on AIX 7.2, non-RAC hosts, using a dual-port coexistence
strategy: keep the cleartext `TCP` endpoint on port **1521**, add a `TCPS` endpoint on
port **2484**, migrate every client/link/redo-transport channel, then retire 1521.
It covers server-side wallet and listener configuration, client configuration (JDBC
thin, legacy OCI, APEX/ORDS), DB links, Data Guard redo transport, certificate
rotation, and a troubleshooting reference. The TLS wallet is **strictly separate** from
the TDE keystore (see the TDE track) and lives in its own directory
(`/oracle/admin/$ORACLE_SID/wallet_tls`); the two must never share a wallet.

> Scope note: This is *server authentication only* (one-way TLS). Clients verify the
> server certificate against the internal enterprise CA; the server does **not** require
> client certificates (`SSL_CLIENT_AUTHENTICATION = FALSE`). Mutual-TLS (cert-based DB
> authentication) is explicitly out of scope.

---

## Table of Contents

1. [Concepts & decisions](#1-concepts--decisions)
2. [Wallet strategy](#2-wallet-strategy)
3. [CSR workflow with the internal CA](#3-csr-workflow-with-the-internal-ca)
4. [Server: listener.ora / sqlnet.ora](#4-server-listenerora--sqlnetora)
5. [TLS vs native encryption (ANO) interaction](#5-tls-vs-native-encryption-ano-interaction)
6. [Dynamic registration & firewall](#6-dynamic-registration--firewall)
7. [Client: JDBC thin](#7-client-jdbc-thin)
8. [Client: legacy OCI](#8-client-legacy-oci)
9. [Client: APEX / ORDS](#9-client-apex--ords)
10. [DB links over TCPS](#10-db-links-over-tcps)
11. [Data Guard redo transport over TCPS](#11-data-guard-redo-transport-over-tcps)
12. [Certificate rotation & monitoring](#12-certificate-rotation--monitoring)
13. [Pitfalls & troubleshooting](#13-pitfalls--troubleshooting)
14. [Cutover checklist](#14-cutover-checklist)

---

## 1. Concepts & decisions

| Item | Decision for CSOB |
|------|-------------------|
| TLS mode | One-way (server auth only). `SSL_CLIENT_AUTHENTICATION=FALSE`. |
| Ports | `TCP` 1521 (existing, keep during coexistence), `TCPS` 2484 (new). |
| Wallet type | Auto-login (`cwallet.sso`) so the listener/DB starts unattended. |
| Wallet location | `/oracle/admin/$ORACLE_SID/wallet_tls` — separate from TDE keystore. |
| TLS version | Pin **TLS 1.2** (`SSL_VERSION=1.2`) unless the RU level is confirmed to support 1.3 (see §4). |
| Cipher suites | ECDHE + AES-GCM only (see §4). |
| Cert key size | 2048-bit minimum; prefer **3072-bit** RSA for new certs (bank crypto policy). |
| Cert subject | `CN` = server **FQDN**; request SANs for every name clients use. |
| CA | Internal enterprise CA, CSR workflow. Import **root + intermediate** as trusted certs, then the user (server) cert. |

**Why dual-port coexistence?** A single listener can serve both `TCP` and `TCPS`
endpoints simultaneously. Existing 1521 clients keep working while you migrate clients
to 2484 one application at a time. Only when monitoring confirms zero 1521 traffic from
production apps do you remove the 1521 endpoint. This avoids a big-bang cutover.

---

## 2. Wallet strategy

### Per-host vs per-DB

You have two viable layouts. **Recommended: one TLS wallet per host** when certificates
are host-scoped (CN = host FQDN) and multiple listeners/instances on the host share the
same server identity.

| Approach | Pros | Cons | Use when |
|----------|------|------|----------|
| **Per-host** wallet (e.g. `/oracle/admin/tls/wallet_tls`) | One cert per host to renew; one `WALLET_LOCATION`; simplest ops | All local DBs share one identity | Cert CN=host FQDN; single listener or shared listener for all instances |
| **Per-DB** wallet (`/oracle/admin/$ORACLE_SID/wallet_tls`) | Per-DB isolation; per-DB rotation; matches TDE per-DB layout | More certs to renew; more `WALLET_LOCATION` entries | Each DB has its own listener/port; separate cert identities required |

Because the listener runs as the `oracle` OS user and the server cert is keyed to the
**host FQDN** (not the service), a per-host wallet is usually the least-effort, correct
choice. The scripts in this track default to a **per-`ORACLE_SID`** path
(`/oracle/admin/$ORACLE_SID/wallet_tls`) to match the TDE track's directory convention
and to keep each DB independently rotatable; set `WALLET_DIR` to a shared per-host path
if you standardise on per-host.

> Whichever you choose, keep it **out of** the TDE keystore directory. Sharing a wallet
> between TLS and TDE couples two unrelated rotation lifecycles and risks exposing the
> TDE master key material handling to network-cert operations.

### Auto-login

Create the wallet with `-auto_login` (produces `cwallet.sso` alongside `ewallet.p12`).
The listener and the DB (for outbound DB-link/redo-transport TLS) read the SSO wallet
without a password prompt at startup. Keep the PKCS#12 password in the bank password
vault for maintenance (add/import cert operations).

> Do **not** use `-auto_login_local` for the TLS wallet on hosts where the wallet may be
> read after a hostname/IP change (e.g. some DR failover scenarios), because
> `-auto_login_local` binds the SSO file to the host+user and will refuse to open
> elsewhere. Plain `-auto_login` is the safe default for network-cert wallets.

### Permissions

```
Directory  /oracle/admin/$ORACLE_SID/wallet_tls   drwx------  (700)  oracle:oinstall
ewallet.p12                                        -rw-------  (600)  oracle:oinstall
cwallet.sso                                        -rw-------  (600)  oracle:oinstall
```

The listener process is `oracle`; it must be able to read `cwallet.sso`. World/group read
on the SSO file would expose the private key material — enforce `600`/`700`.

---

## 3. CSR workflow with the internal CA

19c ships `orapki` in `$ORACLE_HOME/bin`. The full flow:

### 3.1 Create the wallet (auto-login)

```ksh
orapki wallet create \
  -wallet /oracle/admin/$ORACLE_SID/wallet_tls \
  -auto_login -pwd "$WALLET_PWD"
```

### 3.2 Generate the key pair + CSR

```ksh
orapki wallet add \
  -wallet /oracle/admin/$ORACLE_SID/wallet_tls \
  -dn "CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ" \
  -keysize 3072 \
  -pwd "$WALLET_PWD"

orapki wallet export \
  -wallet /oracle/admin/$ORACLE_SID/wallet_tls \
  -dn "CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ" \
  -request /tmp/db01.prod.csob.cz.csr \
  -pwd "$WALLET_PWD"
```

Submit `/tmp/db01.prod.csob.cz.csr` to the internal CA through the standard CSR request
workflow. Request the CA to issue with:

- **Subject CN = the server FQDN** clients will use in the connect string.
- **subjectAltName (SAN) DNS** entries for every alias clients may use (FQDN, short
  name if used, any VIP/alias, and — for Data Guard — both primary and standby names if
  a shared cert is desired; otherwise use per-host certs).
- `extendedKeyUsage = serverAuth` (and `clientAuth` too if this DB will also be a TLS
  *client* for DB links / redo transport — see §10/§11).

### 3.3 SAN caveat (important)

`orapki` in 19c has **limited/no SAN support when generating the CSR** — the CSR it
produces generally carries only the DN, not SANs. Options:

1. **Preferred:** have the **CA template** add the SANs from the request metadata (most
   enterprise CAs let the template inject `DNS:` SANs based on the CN / request form),
   so the issued cert has proper SANs even though the `orapki` CSR did not carry them.
2. Generate the CSR with `openssl` (which supports SAN via a config `[ req_ext ]`
   section) into a temporary key, then import the issued cert + private key into the
   wallet with `orapki wallet import_pkcs12` / a PKCS#12 bundle. This gives full SAN
   control at the cost of handling the private key outside `orapki`.
3. Accept **CN-only** matching: clients then match on CN=FQDN. This works with
   `ssl_server_dn_match=true` *as long as* the connect-string host equals the CN. Modern
   drivers (21c+) also do hostname-vs-SAN matching; without SANs they fall back to CN.
   See §7 for driver-specific DN-match behaviour.

Recommendation: go with option (1) — a CA template that stamps `CN=FQDN` + matching
`DNS` SANs — so both legacy CN-matching and modern SAN-matching clients are satisfied.

### 3.4 Import the CA chain, then the server cert — **order matters**

Import **root first, then intermediate(s)** as *trusted* certs, then the *user* cert
(the server cert). The user cert import will fail with a chain error if the issuing
intermediate is not already present as a trusted cert.

```ksh
# 1) Root CA (trusted)
orapki wallet add -wallet /oracle/admin/$ORACLE_SID/wallet_tls \
  -trusted_cert -cert /tmp/csob-root-ca.cer -pwd "$WALLET_PWD"

# 2) Intermediate/issuing CA (trusted)
orapki wallet add -wallet /oracle/admin/$ORACLE_SID/wallet_tls \
  -trusted_cert -cert /tmp/csob-issuing-ca.cer -pwd "$WALLET_PWD"

# 3) Server (user) cert — matches the CSR's key pair
orapki wallet add -wallet /oracle/admin/$ORACLE_SID/wallet_tls \
  -user_cert -cert /tmp/db01.prod.csob.cz.cer -pwd "$WALLET_PWD"
```

Verify:

```ksh
orapki wallet display -wallet /oracle/admin/$ORACLE_SID/wallet_tls
```

You should see the user cert with a **Subject** = your DN and a **complete chain** up to
the root under "Trusted Certificates". If the user cert shows as a "Requested
Certificate" still, the chain import did not complete — re-check step order.

---

## 4. Server: listener.ora / sqlnet.ora

Full annotated fragments live in
[`scripts/tls/02_listener_tcps_fragments.md`](../scripts/tls/02_listener_tcps_fragments.md).
Key points:

### 4.1 listener.ora — add the TCPS endpoint

```
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = db01.prod.csob.cz)(PORT = 1521)))
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCPS)(HOST = db01.prod.csob.cz)(PORT = 2484)))
  )

# Wallet the listener presents for TCPS. Can live here or in sqlnet.ora.
WALLET_LOCATION =
  (SOURCE = (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /oracle/admin/db01/wallet_tls)))

SSL_CLIENT_AUTHENTICATION = FALSE
```

- **HOST** should be the **FQDN** that matches the cert CN/SAN (helps DN match and avoids
  the endpoint binding to a wrong interface).
- **Restart vs reload:** `lsnrctl reload` re-reads most parameters, **but adding a new
  listening ADDRESS/endpoint (the TCPS 2484 line) requires a full `lsnrctl stop` /
  `lsnrctl start`.** Wallet/SSL parameter changes that don't add endpoints can be picked
  up with `reload`. Certificate-content changes (renewal into the same wallet) are picked
  up by `lsnrctl reload` — the listener re-reads the wallet — so rotation is
  zero-downtime for the *listener* (see §12).

### 4.2 sqlnet.ora — server side

```
WALLET_LOCATION =
  (SOURCE = (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /oracle/admin/db01/wallet_tls)))

SSL_CLIENT_AUTHENTICATION = FALSE
SSL_VERSION = 1.2
SSL_CIPHER_SUITES = (TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256)
```

- **`SSL_VERSION = 1.2`** — pin TLS 1.2. Native TLS 1.3 support in the Oracle DB stack
  arrived only in later 19c RUs (roughly **19.23+**) and in 23ai; on lower RUs setting
  `1.3` can fail the handshake. **Verify your RU** (`SELECT version_full FROM
  v$instance;` on 19.18+, or check the RU with `opatch lspatches`). Unless every host is
  confirmed at an RU that supports TLS 1.3 *and* your client drivers negotiate it, pin
  `1.2`. You may specify `SSL_VERSION = 1.2 or 1.3` only after that verification.
- **`SSL_CIPHER_SUITES`** — restrict to ECDHE key exchange with AES-GCM AEAD suites for
  forward secrecy. Omit CBC and RSA-key-exchange suites. If any legacy OCI client can't
  negotiate ECDHE, widen temporarily but plan to remove weak suites. (Cipher-suite *names*
  above are the SQL*Net-style names; TLS 1.3 suites, if enabled, are named differently —
  `TLS_AES_256_GCM_SHA384` etc.)
- **`WALLET_LOCATION` in the server sqlnet.ora is MANDATORY, not optional.** The
  listener only brokers the initial TCPS handshake; on dedicated-server handoff the
  spawned **database server process re-reads sqlnet.ora** and needs the wallet to keep
  the TLS session up. With the wallet only in listener.ora, clients fail with
  **ORA-28865: SSL connection has closed** *after* a successful listener handshake
  (verified live on 19c). Set `WALLET_LOCATION` in **both** files (or in sqlnet.ora
  only, which the listener also reads). It also governs the DB's behaviour as a TLS
  **client** (DB links, redo transport). Simplest is one wallet, referenced in both.
- **SEPS conflict — check before editing sqlnet.ora.** sqlnet.ora supports only **one**
  `WALLET_LOCATION`. If the host already uses a Secure External Password Store
  (`SQLNET.WALLET_OVERRIDE = TRUE` with a credentials wallet — common for Data Guard
  broker/observer scripts and RMAN jobs), appending a second `WALLET_LOCATION` for TLS
  will silently break one of the two. Merge instead: add the CA trust chain (and server
  cert) into the existing SEPS wallet, or move the SEPS credentials into the TLS wallet
  (`mkstore -wrl ... -createCredential`), or isolate the conflicting tool with its own
  `TNS_ADMIN` directory. Audit `grep -c WALLET_LOCATION sqlnet.ora` fleet-wide as a
  pre-flight step.

---

## 5. TLS vs native encryption (ANO) interaction

Oracle Advanced Networking (native/ANO encryption, `SQLNET.ENCRYPTION_SERVER` etc.) and
TLS are **two independent encryption mechanisms**. They do **not** "stack" usefully:

- Over a **TCPS** connection the transport is already encrypted by TLS. If native
  encryption is also negotiated (`REQUIRED` on both ends) the payload gets
  **double-encrypted** — wasted CPU, no added security.
- Over a **TCP** connection TLS does not apply; native encryption is what protects the
  wire.

19c behaviour and recommendation for the coexistence period:

| `SQLNET.ENCRYPTION_SERVER` | Effect on TCP 1521 | Effect on TCPS 2484 |
|----------------------------|--------------------|---------------------|
| `REJECTED` | No native encryption; cleartext | TLS only (clean) |
| `ACCEPTED` (default) | Native only if client requests it | TLS only; native not forced |
| `REQUESTED` | Native if client supports | TLS; native may also negotiate → double encryption |
| `REQUIRED` | Native forced (good for 1521) | **Double encryption** on TCPS |

**Recommendation:**

- If you rely on **native encryption to protect the surviving 1521 port** during
  coexistence, set `SQLNET.ENCRYPTION_SERVER = REQUIRED` — but be aware TCPS sessions
  will then double-encrypt. Acceptable but wasteful.
- The cleaner target state (after 1521 is closed) is `SQLNET.ENCRYPTION_SERVER =
  ACCEPTED` or `REJECTED` and rely solely on TLS. Set
  `SQLNET.ENCRYPTION_CLIENT`/`SERVER` to `ACCEPTED`/`REJECTED` on the TCPS-only end state
  so TLS is the single mechanism.
- Do **not** set both native `REQUIRED` and treat TCPS as the norm long-term.

There is no automatic "TLS already encrypts, so skip native" negotiation in 19c — the two
stacks are unaware of each other. You control it via the `SQLNET.ENCRYPTION_*` params and
which port the client uses.

---

## 6. Dynamic registration & firewall

### 6.1 LOCAL_LISTENER must advertise the TCPS endpoint

PMON dynamically registers the instance with the listener. By default it registers via
the TCP endpoint on the default host:1521. For the instance to be reachable (and for
`lsnrctl status` to show services on the TCPS endpoint), point `LOCAL_LISTENER` at an
address list including the TCPS address, or use static registration.

**Option A — LOCAL_LISTENER with both protocols (recommended):**

```sql
ALTER SYSTEM SET LOCAL_LISTENER=
 '(DESCRIPTION_LIST=
    (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db01.prod.csob.cz)(PORT=1521)))
    (DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=db01.prod.csob.cz)(PORT=2484))))'
 SCOPE=BOTH;
```

For CDBs set this at the CDB root (it propagates); PDBs register their services through
the same local listener.

**Option B — static registration** in listener.ora (`SID_LIST_LISTENER` with
`GLOBAL_DBNAME`/`SID_NAME`/`ORACLE_HOME`). Useful for Data Guard so the standby is
reachable while `MOUNTED` (PMON in a mounted standby may not dynamically register).
Include the static entry for reliable TCPS reachability during role transitions.

After setting `LOCAL_LISTENER`, `ALTER SYSTEM REGISTER;` and confirm with
`lsnrctl status` that the service lists a `TCPS` handler on 2484.

### 6.2 Firewall

- Open **2484/tcp** between every client subnet (app servers, ORDS hosts, DBA
  jump-hosts) and the DB host, and between **primary ↔ standby** for redo transport.
- Keep 1521 open during coexistence; **close it** only after §14 confirms no legitimate
  traffic remains.
- TLS handshakes are larger than the cleartext connect packet; ensure firewalls / load
  balancers don't clip MTU or impose aggressive idle timeouts that kill the handshake
  (see Pitfalls, MTU/timeout row).

---

## 7. Client: JDBC thin

Ranked options (prefer #1 for a bank-standard, wallet-free client):

### Option 1 — System truststore (JKS/PKCS12) with the internal CA root (recommended)

The thin driver validates the server cert against a standard Java truststore that
contains the CSOB **root (and intermediate) CA** — no Oracle wallet, no extra jars.

```
-Djavax.net.ssl.trustStore=/etc/pki/csob-truststore.jks
-Djavax.net.ssl.trustStoreType=JKS
-Djavax.net.ssl.trustStorePassword=changeit
```

Build the truststore once:

```ksh
keytool -importcert -alias csob-root -file csob-root-ca.cer \
  -keystore /etc/pki/csob-truststore.jks -storetype JKS -noprompt
keytool -importcert -alias csob-issuing -file csob-issuing-ca.cer \
  -keystore /etc/pki/csob-truststore.jks -storetype JKS -noprompt
```

### Option 2 — `oracle.net.ssl_*` connection properties

Set per-datasource instead of JVM-wide:

```
oracle.net.ssl_server_dn_match = true
javax.net.ssl.trustStore       = /etc/pki/csob-truststore.jks
javax.net.ssl.trustStoreType   = JKS
oracle.net.ssl_version         = 1.2
```

### Option 3 — Oracle wallet (`cwallet.sso`) with `oraclepki`/`osdt` jars

Only if the app must reuse an Oracle auto-login wallet. Requires `oraclepki.jar`,
`osdt_core.jar`, `osdt_cert.jar` on the classpath **in addition to** `ojdbc8.jar`, and
`oracle.net.wallet_location`. Heaviest option; avoid unless mandated.

### Connect strings — Easy Connect Plus

```
jdbc:oracle:thin:@tcps://db01.prod.csob.cz:2484/APPSVC.prod.csob.cz?ssl_server_dn_match=true
```

Or a TNS descriptor with `(PROTOCOL=TCPS)` and
`(SECURITY=(SSL_SERVER_DN_MATCH=TRUE)(SSL_SERVER_CERT_DN="CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ"))`.

### DN-match behaviour by driver version (critical)

| Driver | `ssl_server_dn_match` default | Matching behaviour |
|--------|-------------------------------|--------------------|
| 12.2 / 18c thin | **false** | No DN check unless you set true. Set `true` explicitly. |
| 19c thin | **false** (historically); some later 19.x align toward stricter | Set `true` explicitly; matches `SSL_SERVER_CERT_DN` (full DN) if provided, else host vs CN/SAN. |
| 21c+ thin | **true** | Performs **hostname** matching against cert CN **and SANs**; falls back to CN if no SAN. |

**Recommendation (all versions):**
1. Set `ssl_server_dn_match=true` **explicitly** — never rely on the default.
2. Ensure the **connect-string host = the cert CN and appears as a DNS SAN**. If you
   connect by FQDN, the cert CN/SAN must be that FQDN. Short-name connect strings fail DN
   match unless the short name is also a SAN.
3. If you must pin the exact DN, add `SSL_SERVER_CERT_DN` with the full subject DN — then
   the driver matches the whole DN, not just the host. Keep it in sync on cert renewal if
   the DN changes.

---

## 8. Client: legacy OCI

Legacy OCI (thick) clients use a client-side `sqlnet.ora` + `tnsnames.ora`.

### Truststore-only auto-login wallet (no key)

Create a wallet on the OCI client host that contains **only the CA chain** (trusted
certs), auto-login, no user cert/private key:

```ksh
orapki wallet create -wallet /oracle/client/wallet_tls -auto_login -pwd "$PW"
orapki wallet add -wallet /oracle/client/wallet_tls -trusted_cert -cert csob-root-ca.cer -pwd "$PW"
orapki wallet add -wallet /oracle/client/wallet_tls -trusted_cert -cert csob-issuing-ca.cer -pwd "$PW"
```

Client `sqlnet.ora`:

```
WALLET_LOCATION =
  (SOURCE = (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /oracle/client/wallet_tls)))
SSL_SERVER_DN_MATCH = TRUE
SSL_VERSION = 1.2
```

Client `tnsnames.ora`:

```
APPSVC_TLS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCPS)(HOST = db01.prod.csob.cz)(PORT = 2484))
    (CONNECT_DATA = (SERVICE_NAME = APPSVC.prod.csob.cz))
    (SECURITY = (SSL_SERVER_CERT_DN = "CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ")))
```

Because auth is server-only, the client wallet needs **no private key** — trust anchors
are sufficient to validate the server chain.

---

## 9. Client: APEX / ORDS

ORDS is a Java app; it is a JDBC thin client to the DB. Two things to configure:

1. **ORDS pool connection over TCPS.** In the pool config (`default/pool.xml` or
   `ords_conf`/`conf/apex.xml` depending on ORDS version), either:
   - set `db.connectionType=customurl` and `db.customURL` to a TCPS JDBC URL:
     ```
     db.customURL=jdbc:oracle:thin:@tcps://db01.prod.csob.cz:2484/APEXSVC.prod.csob.cz?ssl_server_dn_match=true
     ```
   - or, on newer ORDS, set `db.hostname`, `db.port=2484`, `db.servicename`, and
     `db.protocol=tcps`.
2. **ORDS JVM truststore.** ORDS must trust the CSOB CA. Pass the truststore to the ORDS
   JVM (in the ORDS/Tomcat/standalone startup):
   ```
   -Djavax.net.ssl.trustStore=/etc/pki/csob-truststore.jks
   -Djavax.net.ssl.trustStoreType=JKS
   -Djavax.net.ssl.trustStorePassword=changeit
   ```
   If ORDS runs in standalone mode, add these to the `JAVA_OPTIONS`/`ords.jvm` args; in
   Tomcat/WebLogic add to that container's JVM options. Restart ORDS after the change.

APEX itself (PL/SQL) is unaffected; only the ORDS→DB channel changes.

---

## 10. DB links over TCPS

When DB **A** has a database link to DB **B** over TCPS, **A is the TLS client** and must
trust B's cert:

- On A's server `sqlnet.ora`, `WALLET_LOCATION` must point to a wallet containing B's CA
  chain (the CSOB CA — usually already present in A's own TLS wallet, since the same
  internal CA issues both certs). So **A's existing auto-login TLS wallet already trusts
  B** if both certs come from the CSOB CA. No extra wallet needed.
- The DB link's connect descriptor must use `PROTOCOL=TCPS` and port 2484, and should
  include `SSL_SERVER_CERT_DN` / rely on `SSL_SERVER_DN_MATCH=TRUE`.

```sql
CREATE DATABASE LINK b_link
  CONNECT TO app_user IDENTIFIED BY "..."
  USING '(DESCRIPTION=
           (ADDRESS=(PROTOCOL=TCPS)(HOST=db02.prod.csob.cz)(PORT=2484))
           (CONNECT_DATA=(SERVICE_NAME=BSVC.prod.csob.cz))
           (SECURITY=(SSL_SERVER_CERT_DN="CN=db02.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ")))';
```

Since `SSL_CLIENT_AUTHENTICATION=FALSE` on B, A does **not** present a client cert — A's
wallet only needs the CA trust anchors. A password (or proxy) still authenticates the DB
link at the Oracle level; TLS only encrypts the transport.

---

## 11. Data Guard redo transport over TCPS

Redo transport is just another SQL*Net connection from primary → standby (and standby →
primary on role change). To run it over TLS:

1. **Wallet on both primary and standby hosts** (each host presents its own server cert;
   each host trusts the CSOB CA to validate the peer). The existing per-host/per-SID TLS
   wallet already covers both directions because auth is server-only and both certs chain
   to the same CA.
2. **Use a TCPS TNS alias** for transport:
   - Non-broker: `LOG_ARCHIVE_DEST_2='SERVICE=stdby_tls ... '` where `stdby_tls` is a
     `tnsnames.ora` alias with `PROTOCOL=TCPS`, port 2484.
   - Broker: set the member's `DGConnectIdentifier` (and `StaticConnectIdentifier` for
     startup/role changes) to a TCPS descriptor/alias.
3. **`SSL_CLIENT_AUTHENTICATION=FALSE` is fine.** Redo transport authenticates via the
   **redo transport user** using the **password file** (`REDO_TRANSPORT_USER`, SYS by
   default) — the passwords must match between primary and standby (they do, since the
   password file is copied). **Mutual cert auth is NOT required**; server-auth TLS +
   password-file auth is the supported, standard combination.
4. **Static registration** for the standby is recommended (see §6.1 Option B) so the
   TCPS endpoint is reachable while the standby is only `MOUNTED` and during role
   transitions when PMON may not dynamically register.

Broker property changes example:

```
EDIT DATABASE 'stdby' SET PROPERTY DGConnectIdentifier='stdby_tls';
EDIT DATABASE 'stdby' SET PROPERTY StaticConnectIdentifier=
  '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=stdby01.dr.csob.cz)(PORT=2484))
     (CONNECT_DATA=(SERVICE_NAME=stdby_DGMGRL.dr.csob.cz)(INSTANCE_NAME=stdby)(SERVER=DEDICATED)))';
```

Do the symmetric change for the primary member so switchover works both ways. Validate
with `DGMGRL> VALIDATE DATABASE 'stdby';` and check `V$ARCHIVE_DEST_STATUS` /
`V$DATAGUARD_STATS` show transport healthy over the TCPS alias.

---

## 12. Certificate rotation & monitoring

### Renewal (zero-downtime for the listener)

1. Well before expiry (bank policy: begin at **T-60 days**), generate a **new CSR** from
   the **same wallet** (`orapki wallet add` a fresh key + `export -request`) — or reuse
   the key if policy allows (prefer fresh key).
2. Get the renewed cert from the CA. Ensure the CA chain (root/intermediate) is still
   present in the wallet; import any changed intermediate first.
3. `orapki wallet add -user_cert -cert <renewed>.cer` into the wallet.
4. `lsnrctl reload <listener>` — the listener re-reads the wallet and presents the new
   cert on new handshakes. **Existing sessions are unaffected**; new connections use the
   new cert. No endpoint change, so no full restart needed.
5. For the **DB-as-client** side (DB links, redo transport), the DB re-reads the wallet
   for new outbound connections; long-lived redo transport connections re-handshake on
   reconnect. Plan a low-traffic window if you want to force redo transport to pick up a
   new cert immediately (bounce the transport, e.g. defer/enable `LOG_ARCHIVE_DEST_2`).

If the CA rotates its **root/intermediate**, you must also update every **client
truststore** (JKS) and client wallet — coordinate that as a fleet change *before* the
server cert switches to the new chain.

### Expiry monitoring

- Enumerate wallets and check `notAfter`:
  ```ksh
  orapki wallet display -wallet /oracle/admin/$ORACLE_SID/wallet_tls | grep -i "Subject:"
  # For dates, export the user cert and read with openssl:
  openssl x509 -in /tmp/server.cer -noout -enddate -subject
  # Or probe the live endpoint:
  echo | openssl s_client -connect db01.prod.csob.cz:2484 2>/dev/null | openssl x509 -noout -enddate -subject
  ```
- Add a monitoring check (OEM metric extension or a cron+`openssl s_client` probe) that
  alerts at **T-45 / T-30 / T-14** days before `notAfter`.
- Track **intermediate** and **root** expiry too — chain expiry breaks handshakes even
  if the leaf is valid.

---

## 13. Pitfalls & troubleshooting

### Common pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| **DN / hostname mismatch** | Client refuses cert; DN-match failure | Connect by the FQDN that equals cert CN/SAN; set `ssl_server_dn_match=true`; add SANs. |
| **Missing intermediate CA in wallet** | Handshake fails; chain incomplete | Import root **and** intermediate as trusted certs *before* the user cert; re-check `orapki wallet display`. |
| **Wallet permissions** | Listener can't open wallet; TCPS handler absent | `oracle:oinstall`, dir `700`, files `600`; listener runs as oracle. |
| **MTU / handshake timeout via firewall** | Connect hangs then fails; works locally | Check MTU/fragmentation and idle timeouts on firewall/LB; allow larger TLS handshake packets. |
| **FQDN vs shortname** | DN match fails only from some clients | Ensure every connect-string name is a SAN (or CN); mixed-case service names are irrelevant, but the **host** must match. |
| **ojdbc jars** | `ClassNotFound oracle.security.pki...` | You only need `oraclepki/osdt_*` jars when using an **Oracle wallet**; JKS truststore needs none. |
| **Native + TLS double-encrypt** | High CPU on TCPS; slow throughput | Don't force `ENCRYPTION_SERVER=REQUIRED` for TCPS-only paths (see §5). |
| **Adding endpoint via reload** | New 2484 port never appears | Adding an ADDRESS needs full listener stop/start, not reload. |
| **`-auto_login_local` after host move** | Wallet won't open on DR host | Use plain `-auto_login` for network-cert wallets. |

### Error → cause reference

| Error | Meaning | Where to look |
|-------|---------|---------------|
| **ORA-28759: failure to open file** | Wallet not found or not readable | `WALLET_LOCATION` path correct? `cwallet.sso` present? Perms `600` oracle-readable? Listener/DB env points at right wallet. |
| **ORA-28864: SSL connection closed gracefully** | TLS handshake aborted (often cipher/version/DN mismatch or peer closed) | Check `SSL_VERSION` both ends, cipher-suite overlap, DN match, and firewall interference. `openssl s_client` to isolate. |
| **ORA-28865: SSL connection has closed** | Listener handshake OK, but the **DB server process** has no wallet — `WALLET_LOCATION` missing from the server **sqlnet.ora** (listener.ora alone is not enough) | Add `WALLET_LOCATION` to the DB's sqlnet.ora (watch the SEPS conflict, §4.2) and retry. Verified cause on 19c. |
| **ORA-29024: Certificate validation failure** | Client can't validate server chain | Client truststore/wallet missing the CA (root/intermediate); server presenting incomplete chain. |
| **ORA-28860: Fatal SSL error** | Generic handshake failure | Combine with sqlnet trace; often version/cipher mismatch or wallet issues. |
| **ORA-12560 / TNS-12560** | Protocol adapter error | Endpoint not listening (2484 not up), or LOCAL_LISTENER not registering TCPS. `lsnrctl status`. |
| **ORA-12170: TNS connect timeout** | No answer on port | Firewall closed 2484, or MTU/handshake stall. |

### Diagnostic commands

```ksh
# Is the TCPS endpoint up and serving services?
lsnrctl status

# Probe the TLS endpoint, show chain + negotiated version/cipher
echo | openssl s_client -connect db01.prod.csob.cz:2484 -showcerts

# Server-side SQL*Net trace (temporary) in sqlnet.ora:
#   TRACE_LEVEL_SERVER = 16
#   TRACE_DIRECTORY_SERVER = /oracle/admin/db01/trace
# Client-side: TRACE_LEVEL_CLIENT = 16
```

---

## 14. Cutover checklist

Per DB/host:

- [ ] TLS wallet created (auto-login), perms `600`/`700`, **separate from TDE keystore**.
- [ ] CSR issued with CN=FQDN + SANs; root+intermediate+user cert imported (correct order).
- [ ] `orapki wallet display` shows a complete chain.
- [ ] listener.ora: TCPS 2484 endpoint added; `WALLET_LOCATION` set; `SSL_CLIENT_AUTHENTICATION=FALSE`.
- [ ] sqlnet.ora audited for a pre-existing `WALLET_LOCATION` / SEPS `WALLET_OVERRIDE` (merge, don't append — §4.2).
- [ ] sqlnet.ora: `WALLET_LOCATION` (required for the server process, §4.2), `SSL_VERSION=1.2`, cipher suites, ANO params decided (§5).
- [ ] `LOCAL_LISTENER` (or static reg) advertises TCPS; `ALTER SYSTEM REGISTER;`.
- [ ] Full `lsnrctl stop/start`; `lsnrctl status` shows TCPS handler on 2484.
- [ ] Firewall: 2484 open (clients, and primary↔standby).
- [ ] `openssl s_client` and `03_verify_tls.sql` confirm TLS session.
- [ ] Clients migrated: JDBC truststore + tcps URL; OCI wallet+tns; ORDS pool+truststore.
- [ ] DB links repointed to TCPS; Data Guard transport moved to TCPS alias; broker validated.
- [ ] Cert expiry monitoring in place (T-45/30/14 alerts).
- [ ] Monitoring confirms **zero** legitimate 1521 traffic → remove 1521 endpoint, restart listener.

---

*See `scripts/tls/` for the wallet-creation, listener/tns fragment, and verification
templates referenced throughout this guide.*
