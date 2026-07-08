# 04 — Fleet Rollout Plan (TLS & TDE)

**Purpose.** This document is the execution plan for rolling TLS (TCPS) and TDE across the Oracle 19c fleet. It defines the wave model with entry/exit criteria, pilot selection and mandatory performance measurements on AIX/POWER, application-team coordination, per-database cutover runbooks (TLS and TDE, as ordered checklists), rollback approach, monitoring/verification queries, and the operational acceptance criteria that declare a database "done". Environment assumptions are per [00-overview.md](00-overview.md); key-management conventions are per [01-key-management-decision.md](01-key-management-decision.md). TLS and TDE are executed as **independent parallel tracks** — a database progresses through each track separately.

## Table of contents
1. [Wave model & entry/exit criteria](#1-wave-model--entryexit-criteria)
2. [Pilot selection & mandatory measurements](#2-pilot-selection--mandatory-measurements)
3. [Application-team coordination (TLS)](#3-application-team-coordination-tls)
4. [Runbook A — TLS enablement (per DB)](#4-runbook-a--tls-enablement-per-db)
5. [Runbook B — TDE enablement (per DB)](#5-runbook-b--tde-enablement-per-db)
6. [Rollback](#6-rollback)
7. [Monitoring & verification](#7-monitoring--verification)
8. [Operational acceptance criteria](#8-operational-acceptance-criteria)

---

## 1. Wave model & entry/exit criteria

```
Pilot ──▶ DEV ──▶ TEST ──▶ PREPROD ──▶ PROD
```

Each environment wave is batched (e.g. 10–20 databases per batch) to keep change volume and on-call load manageable. **A wave may not start until the previous wave's exit criteria are met.** TLS and TDE each move through these waves on their own schedule.

| Wave | Entry criteria | Exit criteria |
|------|----------------|---------------|
| **Pilot** | Runbooks A & B drafted; key-management conventions ([01](01-key-management-decision.md)) fixed; internal CA can issue; monitoring queries ready; rollback tested in a lab | Pilot DBs fully TLS+TDE done; **performance baselines captured (§2)** and accepted; runbooks corrected from real experience; rollback executed at least once successfully |
| **DEV** | Pilot exit met; scripts in `scripts/tls`, `scripts/tde`, `scripts/dg` version-controlled | All in-scope DEV DBs done per §8; no unresolved Sev-1/2 issues |
| **TEST** | DEV exit met; app teams have working truststore process | All TEST DBs done; app connectivity over TCPS validated by QA |
| **PREPROD** | TEST exit met; change-management approval; app migration playbook signed off by app owners | All PREPROD DBs done; performance within agreed tolerance vs baseline; DR (switchover) tested with TDE+TLS active |
| **PROD** | PREPROD exit met; per-DB change windows scheduled; rollback rehearsed; on-call briefed | All PROD DBs done per §8; TCP closed only after zero-cleartext verification (§3, §7) |

**Cross-cutting gates for every wave:** Data Guard health green before and after each change; keystore backup verified after every TDE key operation; certificate expiry monitoring active before any TCPS endpoint goes live.

## 2. Pilot selection & mandatory measurements

### 2.1 Pilot selection criteria

Pick **2–3 low-risk but representative** databases that together cover the fleet's variety:

- One **CDB with ≥1 PDB** and one **non-CDB** (keystore mode differs — see [01 §8](01-key-management-decision.md#8-mixed-cdb--non-cdb-keystore-mode)).
- At least one **with a Data Guard physical standby** (to prove wallet sync, encrypted redo apply, and switchover).
- Representative **workload mix**: at least one with a meaningful **batch** window and one with an OLTP/app profile.
- Low business risk (not tier-1 critical) but **on the same AIX 7.2/POWER hardware class** as production, so measurements transfer.

### 2.2 Mandatory measurements (before committing the fleet)

TDE tablespace encryption adds AES work to every physical block read/write that misses the buffer cache and to redo. **On AIX/POWER the crypto acceleration path differs from x86 AES-NI**, so we must measure on our actual hardware rather than assume x86 benchmarks. Capture **before and after** encryption:

| Measurement | How | Why |
|-------------|-----|-----|
| **Batch job elapsed times** | Time representative batch jobs pre- and post-encryption | Batch is the most crypto-sensitive (large sequential I/O); primary sizing input |
| **Redo apply rate on standby** | `V$RECOVERY_PROGRESS` / Data Guard apply lag under load | Encrypted redo + apply on POWER standby must keep up |
| **RMAN backup duration** | Time full/incremental backups pre/post | Encrypted blocks change backup CPU/throughput profile |
| **CPU utilisation delta** | Host + DB CPU during batch and backup | Confirm headroom on POWER cores |
| **OLTP response time** | AWR / app SLA metrics | Confirm interactive impact acceptable |

Record results and the accept/adjust decision in the pilot exit report. If impact exceeds tolerance, options include phasing which tablespaces are encrypted, adding CPU headroom, or scheduling encryption/backup windows — decide **before** DEV.

## 3. Application-team coordination (TLS)

TLS is only "done" when applications actually connect over TCPS and the cleartext TCP endpoint is closed. Application migration is the **long pole** — start it early, in parallel with DBA enablement, using the **dual-port coexistence** window ([00 §4](00-overview.md#4-delivery-strategy-two-independent-tracks)).

### 3.1 What each application type must change

| App type | Change required |
|----------|-----------------|
| **Java / JDBC thin** | Import the **internal CA root** into the app's truststore (`cacerts` / a dedicated JKS via `keytool -importcert`, or an Oracle wallet referenced by the driver). Change connect string to TCPS (see below). No client binary change. |
| **Legacy OCI (thick) clients** | Configure `sqlnet.ora` on the client: `WALLET_LOCATION` pointing to a client wallet containing the CA root; set `SSL_SERVER_DN_MATCH=TRUE`; use a TCPS TNS entry. |
| **ORDS / APEX** | Update the ORDS connection pool to the TCPS URL and ensure the ORDS JVM truststore trusts the internal CA root; bounce ORDS. |

### 3.2 Connect-string changes

```properties
# JDBC thin — easy connect plus (19c), TCPS on 1527:
jdbc:oracle:thin:@tcps://db-host.bank.internal:1527/PDBSERVICE?ssl_server_dn_match=true

# TNS (tnsnames.ora) equivalent:
MYDB_TCPS =
 (DESCRIPTION=
   (ADDRESS=(PROTOCOL=TCPS)(HOST=db-host.bank.internal)(PORT=1527))
   (CONNECT_DATA=(SERVICE_NAME=PDBSERVICE))
   (SECURITY=(SSL_SERVER_CERT_DN="CN=db-host.bank.internal")))
```

```sh
# Java: import internal CA root into a truststore (do NOT import the server leaf cert)
keytool -importcert -trustcacerts -alias bank-internal-root \
  -file /path/internal-ca-root.cer \
  -keystore /app/config/truststore.jks -storepass "<pw>"
```

### 3.3 Communication checklist / template (per DB)

- [ ] Notify app owners: DB name, TCPS host/port (1527), service name, expected DN, coexistence window dates, TCP close date.
- [ ] Provide the internal CA root certificate + import instructions per app type.
- [ ] App teams import truststore, add TCPS connect string in **non-prod first**, validate.
- [ ] App teams confirm production cutover to TCPS.
- [ ] DBA confirms **zero cleartext sessions** on the DB (§7) for an agreed soak period.
- [ ] Schedule and execute **TCP close** (Runbook A step 6).

## 4. Runbook A — TLS enablement (per DB)

Ordered checklist. Non-disruptive up to step 6 (dual-port coexistence keeps TCP alive).

1. **Create the TLS server wallet** (separate from any TDE keystore — see [01 §6.2](01-key-management-decision.md#62-standard-directory-layout)):
   ```sh
   orapki wallet create -wallet /oracle/admin/$ORACLE_SID/wallet_tls -pwd "<pw>" -auto_login
   ```
2. **Generate a CSR (Certificate Signing Request), get it signed by the internal CA, import the chain:**
   ```sh
   orapki wallet add -wallet /oracle/admin/$ORACLE_SID/wallet_tls -pwd "<pw>" \
     -dn "CN=$(hostname -f)" -keysize 2048 -sign_alg sha256WithRSAEncryption
   orapki wallet export -wallet /oracle/admin/$ORACLE_SID/wallet_tls -pwd "<pw>" \
     -dn "CN=$(hostname -f)" -request /tmp/$ORACLE_SID.csr
   # -- submit CSR to internal CA, receive signed cert + CA chain --
   orapki wallet add -wallet /oracle/admin/$ORACLE_SID/wallet_tls -pwd "<pw>" \
     -trusted_cert -cert /tmp/internal-ca-root.cer            # CA root (and any intermediate)
   orapki wallet add -wallet /oracle/admin/$ORACLE_SID/wallet_tls -pwd "<pw>" \
     -user_cert -cert /tmp/$ORACLE_SID.signed.cer             # server leaf
   orapki wallet display -wallet /oracle/admin/$ORACLE_SID/wallet_tls   # verify chain + [available] key
   ```
3. **Point SQL*Net at the TLS wallet and set matching:**
   ```ini
   # sqlnet.ora  (REQUIRED here, not just listener.ora — the DB server process needs the
   # wallet after listener handoff, else clients get ORA-28865; see 02-tls-guide.md §4.2.
   # Check first for an existing WALLET_LOCATION / SEPS (Secure External Password Store)
   # WALLET_OVERRIDE — merge, don't append.)
   WALLET_LOCATION = (SOURCE=(METHOD=FILE)(METHOD_DATA=(DIRECTORY=/oracle/admin/<ORACLE_SID>/wallet_tls)))
   SSL_SERVER_DN_MATCH = TRUE
   SSL_VERSION = 1.2                    # enforce TLS 1.2+ (1.3 where client stack supports it)
   # optional: SSL_CIPHER_SUITES=(...) to restrict to approved suites
   ```
4. **Add a TCPS endpoint to the listener — keep TCP for coexistence (dual-port):**
   ```ini
   # listener.ora — BOTH endpoints listed = dual-port coexistence
   LISTENER =
    (DESCRIPTION_LIST=
      (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db-host.bank.internal)(PORT=1526)))
      (DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=db-host.bank.internal)(PORT=1527))))
   WALLET_LOCATION =
      (SOURCE=(METHOD=FILE)(METHOD_DATA=(DIRECTORY=/oracle/admin/<ORACLE_SID>/wallet_tls)))
   SSL_CLIENT_AUTHENTICATION = FALSE    # server-auth TLS only; no client certs
   ```
   ```sh
   lsnrctl stop; lsnrctl start   # adding a NEW listening ADDRESS requires stop/start (reload is not enough)
   lsnrctl status                # expect TCP:1526 AND TCPS:1527 handlers
   ```
5. **Coexistence & client migration** — app teams migrate per §3; both ports serve traffic. Monitor for remaining cleartext sessions (§7).
6. **Close TCP** — only after zero cleartext sessions for the agreed soak period: remove the TCP `ADDRESS` from `listener.ora`, `lsnrctl reload`, and confirm only TCPS:1527 remains. Keep 1526 removable/re-addable for fast rollback (§6).

## 5. Runbook B — TDE enablement (per DB)

Ordered checklist. Uses the conventions from [01](01-key-management-decision.md). Steps 1–2 require an instance restart (`WALLET_ROOT` is static).

1. **Configure `WALLET_ROOT` (static — needs restart) and `TDE_CONFIGURATION` (dynamic):**
   ```sql
   ALTER SYSTEM SET WALLET_ROOT='/oracle/admin/&ORACLE_SID./wallet' SCOPE=SPFILE;
   -- >>> bounce the instance now <<<
   ALTER SYSTEM SET TDE_CONFIGURATION="KEYSTORE_CONFIGURATION=FILE" SCOPE=BOTH;
   ```
2. **Create keystore, open it, set the first MEK (master encryption key), create auto-login** (CDB: `CONTAINER=ALL` in root):
   ```sql
   ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "<ks_pw>";
   ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "<ks_pw>" CONTAINER=ALL;
   ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY IDENTIFIED BY "<ks_pw>"
     WITH BACKUP USING 'initial_mek' CONTAINER=ALL;
   -- non-LOCAL auto-login so the same cwallet.sso works on the standby host (see 01 §7.1):
   ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE
     FROM KEYSTORE IDENTIFIED BY "<ks_pw>";
   ```
3. **Sync the keystore to the standby host(s)** — copy `ewallet.p12` (and the non-LOCAL `cwallet.sso`) to the standby's `$WALLET_ROOT/tde`; if using LOCAL auto-login, regenerate `cwallet.sso` on the standby instead. Configure `WALLET_ROOT`/`TDE_CONFIGURATION` identically on the standby. See `scripts/dg/`.
   ```sql
   -- on standby, verify the wallet opens:
   SELECT con_id, status, wallet_type FROM v$encryption_wallet;   -- expect OPEN
   ```
4. **Encrypt tablespaces (online) on the primary** — redo carries the change to the standby; no manual standby encryption needed:
   ```sql
   ALTER TABLESPACE users ENCRYPTION ONLINE USING 'AES256' ENCRYPT;
   -- omit FILE_NAME_CONVERT (works on OMF and non-OMF alike; =NONE fails on OMF with ORA-28437)
   -- repeat per application tablespace; schedule large ones in low-I/O windows (see §2 baselines)
   ```
   > New tablespaces going forward should be created encrypted by policy (enforce with `ENCRYPT_NEW_TABLESPACES=ALWAYS`). Encrypting existing `SYSTEM`/`SYSAUX`/`UNDO`/`TEMP` is a separate, planned exercise — sequence per [03-tde-guide.md §10](03-tde-guide.md#10-encrypting-system--sysaux--undo--temp).
5. **Verify** (§7): `V$ENCRYPTED_TABLESPACES` shows the tablespaces encrypted; `V$ENCRYPTION_WALLET` OPEN on primary **and** standby; standby apply lag nominal.
6. **Back up the keystore** — after the MEK operation and before/after any rotation, to storage separate from DB backups; keep full key history forever ([01 §7.3](01-key-management-decision.md#73-backup-policy)).

## 6. Rollback

| Track | Rollback approach |
|-------|-------------------|
| **TLS** | Fully reversible. During coexistence, TCP is still open — apps simply keep using it. To back out an enablement: `lsnrctl reload` after reverting `listener.ora`/`sqlnet.ora`. Even after TCP close, rollback = re-add the TCP `ADDRESS` and `lsnrctl reload` (why we keep step 6 trivially reversible). No data impact. |
| **TDE** | **Plan as forward-only.** Online decryption exists (`ALTER TABLESPACE users ENCRYPTION ONLINE DECRYPT ...`) and can undo a specific tablespace if needed, but it is a heavy re-write, not a config revert. **Do not** treat TDE as freely reversible. |

**TDE restore implication (critical):** any RMAN backup or archived redo produced **after** encryption requires the **MEK to restore** — permanently. Never discard old master keys; retain the **full keystore history / all MEKs** ([01 §7.3](01-key-management-decision.md#73-backup-policy)). A "rollback" that deletes keystores would render post-encryption backups unrecoverable. Rollback of TDE, if ever required, is: decrypt online (forward operation) while keeping every historical key.

## 7. Monitoring & verification

### 7.1 TDE state

```sql
-- Which tablespaces are encrypted, with algorithm:
SELECT ts.name AS tablespace, e.encryptionalg, e.status
FROM   v$encrypted_tablespaces e JOIN v$tablespace ts ON ts.ts# = e.ts#;

-- Keystore status (run on primary AND each standby; in a CDB check all CON_IDs):
SELECT con_id, wrl_type, status, wallet_type, keystore_mode
FROM   v$encryption_wallet;        -- want STATUS=OPEN, WALLET_TYPE=AUTOLOGIN

-- Master keys present (history must be retained):
SELECT con_id, key_id, creation_time, activation_time FROM v$encryption_keys;
```

### 7.2 TLS / session protocol

```sql
-- Per-session transport protocol (spot-check for remaining cleartext):
SELECT s.sid, s.username, s.program,
       SYS_CONTEXT('USERENV','NETWORK_PROTOCOL') AS proto   -- run in the target session
FROM   v$session s WHERE s.type='USER';

-- Fleet-wide, prefer the listener log: count TCP vs TCPS PROTOCOL= handoffs.
-- A session's protocol is authoritatively visible via the listener log (PROTOCOL=tcp|tcps)
-- and NETWORK_SERVICE_BANNER; use these to prove "zero cleartext" before TCP close.
```

```sql
-- Confirm TLS is actually in effect for the current session:
SELECT network_service_banner
FROM   v$session_connect_info
WHERE  sid = SYS_CONTEXT('USERENV','SID');   -- look for TCP/IP with SSL/TLS banners
```

### 7.3 Certificate expiry monitoring

```sh
# cron: alert if the server cert is within N days of expiry (parse orapki output)
orapki wallet display -wallet /oracle/admin/$ORACLE_SID/wallet_tls | \
  grep -i 'Subject\|Not After\|valid'          # feed expiry into OEM / alerting
```
Register certificate expiry in the enterprise monitoring/OEM so renewal is driven **before** expiry (an expired server cert breaks all TCPS connections). Track renewal against the internal CA's validity period.

### 7.4 Wallet backup verification

- After every key operation, confirm a keystore backup landed in the designated (separate) location and is restorable — periodically test-restore a keystore in a lab and open it.
- Alert if a TDE-enabled DB's keystore has no backup newer than its most recent key operation.

## 8. Operational acceptance criteria

A database is declared **done** only when all of the following hold:

**TLS track**
- [ ] TCPS:1527 endpoint live; server cert issued by internal CA, chain valid, `orapki` display clean.
- [ ] Certificate expiry monitored in OEM/alerting.
- [ ] All application connections migrated to TCPS; **zero cleartext TCP sessions** over the agreed soak period.
- [ ] TCP:1526 endpoint closed (and documented as fast-re-addable for rollback).
- [ ] `SSL_VERSION`/cipher policy enforced; `SSL_SERVER_DN_MATCH=TRUE` on clients.

**TDE track**
- [ ] `WALLET_ROOT` + `TDE_CONFIGURATION=FILE` configured; deprecated `ENCRYPTION_WALLET_LOCATION` absent.
- [ ] Password keystore + auto-login present; `V$ENCRYPTION_WALLET` OPEN on primary **and** standby.
- [ ] Keystore password vaulted (CyberArk-style); custody separated from DBA ([01 §7.4](01-key-management-decision.md#74-custody-and-separation-of-duties)).
- [ ] All in-scope application tablespaces show encrypted in `V$ENCRYPTED_TABLESPACES` (AES256).
- [ ] Keystore backed up to separate storage after the latest key operation; full key history retained.
- [ ] Data Guard: standby applies encrypted redo with nominal lag; switchover tested (at pilot/preprod).
- [ ] Performance within the tolerance agreed from the §2 baselines.

**Both**
- [ ] Runbook executed steps recorded in the change ticket; monitoring green; rollback path confirmed available.

---
*Cross-references:* [00-overview.md](00-overview.md) (strategy, waves, ANO interim), [01-key-management-decision.md](01-key-management-decision.md) (keystore conventions, custody, CDB/non-CDB, OKV target). Scripts: `scripts/tls/`, `scripts/tde/`, `scripts/dg/`.
