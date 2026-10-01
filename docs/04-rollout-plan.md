# 04 — Fleet Rollout Plan (TLS & TDE)

**Purpose.** This is the execution plan for rolling TLS (TCPS) and TDE across the Oracle 19c fleet: the phases and their gates, who does what, the pilot and its measurements, the per-database runbooks (ordered steps with the script to run at each step), application coordination, rollback, verification, acceptance criteria and the risk register. Environment assumptions are per [00-overview.md](00-overview.md); key-management conventions per [01-key-management-decision.md](01-key-management-decision.md). Technical depth lives in [02-tls-guide.md](02-tls-guide.md) and [03-tde-guide.md](03-tde-guide.md); this document tells you **what to do, in which order, and how you know it worked**.

> TLS and TDE are **independent parallel tracks**. A database moves through each track on its own schedule, under separate change tickets with separate backout. Never bundle a TLS change and a TDE change into one window.

A visual version of this plan is in [rollout-plan.html](rollout-plan.html).

## Table of contents
1. [Plan at a glance](#1-plan-at-a-glance)
2. [Roles & responsibilities](#2-roles--responsibilities)
3. [Phase 0 — Preparation](#3-phase-0--preparation)
4. [Phase 1 — Pilot](#4-phase-1--pilot)
5. [Phases 2–5 — Environment waves & gates](#5-phases-25--environment-waves--gates)
6. [Runbook A — TLS enablement (per DB)](#6-runbook-a--tls-enablement-per-db)
7. [Runbook B — TDE enablement (per DB)](#7-runbook-b--tde-enablement-per-db)
8. [Application-team coordination (TLS)](#8-application-team-coordination-tls)
9. [Rollback](#9-rollback)
10. [Monitoring & verification](#10-monitoring--verification)
11. [Operational acceptance criteria](#11-operational-acceptance-criteria)
12. [Phase 6 — Close-out & steady state](#12-phase-6--close-out--steady-state)
13. [Risk register](#13-risk-register)
14. [Script index](#14-script-index)
15. [Fact-check log (this revision)](#15-fact-check-log-this-revision)

---

## 1. Plan at a glance

```
Phase 0  PREPARE ──▶ Phase 1  PILOT ──▶ Phase 2 DEV ──▶ Phase 3 TEST ──▶ Phase 4 PREPROD ──▶ Phase 5 PROD ──▶ Phase 6 CLOSE-OUT
 inventory, CA,       2–3 DBs, both      batches of 10–20 DBs per wave; each wave gated by        TCP 1526 closed,
 firewall, vault,     tracks, measure    the previous wave's exit criteria (§5)                  BAU rotation/renewal,
 monitoring, comms    on POWER, rollback                                                          OKV migration
```

| Phase | Indicative duration | TLS track outcome | TDE track outcome |
|-------|--------------------|-------------------|-------------------|
| **0 Prepare** | 4–6 weeks | CA template live, 1527 firewall rules requested, app inventory + owners known | Vault + custody in place, keystore backup location ready, pilot DBs chosen |
| **1 Pilot** | 4–6 weeks | TCPS live on pilot DBs incl. DG redo transport; one app migrated end-to-end | Pilot DBs encrypted; **performance baselines on POWER accepted**; switchover + restore proven |
| **2 DEV** | 3–4 weeks | TCPS on all DEV DBs; app teams start non-prod migration | All DEV DBs encrypted |
| **3 TEST** | 4 weeks | QA validates apps over TCPS | All TEST DBs encrypted |
| **4 PREPROD** | 4 weeks | Production-like cutover rehearsed | Encrypted; perf vs baseline within tolerance; DR test passed |
| **5 PROD** | 8–12 weeks (batched) | TCPS live everywhere; apps migrate during coexistence | All PROD DBs encrypted |
| **6 Close-out** | Rolling, app-driven | **1526 closed** per DB once zero cleartext | Rotation/backup BAU; OKV migration when licensed |

Durations are planning placeholders. Firm them up with change management once Phase 0 has produced the inventory. **TLS application migration is the long pole.** Start the app-owner conversation in Phase 0, not after PROD enablement.

**Two kinds of change, two kinds of window:**

| Change | Impact | Window |
|--------|--------|--------|
| TLS: add TCPS endpoint (A5) | Listener `stop`/`start`: **new connections refused for a few seconds** on both ports; existing sessions unaffected | Short standard change, low-traffic period |
| TLS: close TCP 1526 (A10) | Any client still on 1526 breaks | Only after zero-cleartext evidence (§10.2) |
| TDE: `WALLET_ROOT` (B1) | **Instance restart** (static parameter) | Outage window, or switchover-based (B1) for near-zero downtime |
| TDE: keystore + MEK (B2–B4) | None (online) | Standard change |
| TDE: encrypt app tablespaces (B6) | Online method: none, but heavy redo/I/O. Offline/standby-first: per method | Low-I/O window; one tablespace at a time |
| TDE: SYSTEM/SYSAUX/UNDO/TEMP (B7) | Offline conversion / swap | Separate planned change |

---

## 2. Roles & responsibilities

| Role | Responsible for |
|------|-----------------|
| **Programme lead** | Wave plan, gates, reporting, risk register, stakeholder comms |
| **DBA team** | Runbooks A and B, scripts, verification, rollback execution |
| **Key custodian** (security / key-management team, **not** the DBA) | Generates and holds TDE keystore passwords in the vault; enters/releases them for key operations; owns keystore backup copies ([01 §7.4](01-key-management-decision.md#74-custody-and-separation-of-duties)) |
| **PKI / CA team** | CA certificate template (CN = FQDN + DNS SANs, `serverAuth` + `clientAuth`), CSR turnaround SLA, root/intermediate distribution |
| **Network / firewall** | 1527/tcp from all client subnets and primary ↔ standby; later removal of 1526 |
| **Application owners** | Truststore import, connect-string change, non-prod validation, prod cutover sign-off |
| **Monitoring / OEM team** | Certificate-expiry alerts, keystore and TDE status checks, repointing OEM DB targets to TCPS |
| **Backup team** | Keystore backup location (separate from RMAN), backup-window re-sizing, restore tests |
| **Change management / CAB** | Change templates for the per-DB changes, wave approvals |
| **Security / compliance** | Acceptance of the evidence pack per wave (DORA / PCI) |

---

## 3. Phase 0 — Preparation

Nothing in Phase 0 touches a database. All of it has to be finished before the pilot starts.

### 3.1 Decisions to record (sign-off by security + DBA lead)

- [ ] Key management: **local software keystore now, OKV later** ([01 §5](01-key-management-decision.md#5-recommendation)), **united** keystore for CDBs, **non-LOCAL** auto-login.
- [ ] TLS: **server-auth only** (`SSL_CLIENT_AUTHENTICATION=FALSE`), `SSL_VERSION=1.2` initially (1.3 later per client validation), ECDHE + AES-GCM cipher suites.
- [ ] TLS wallet layout: **per-`ORACLE_SID`** `/oracle/admin/$ORACLE_SID/wallet_tls` (script default) or per-host. Choose one and use it everywhere ([02 §2](02-tls-guide.md#2-wallet-strategy)).
- [ ] Interim **native network encryption (ANO)**: use it or skip it ([00 §5](00-overview.md#5-interim-option-native-sqlnet-encryption-ano)). It can cover 1526 while apps migrate.
- [ ] Encryption scope: all application tablespaces **plus** SYSTEM/SYSAUX/UNDO/TEMP ([03 §10](03-tde-guide.md#10-encrypting-system--sysaux--undo--temp)). Algorithm **AES256**.
- [ ] MEK rotation crypto-period (e.g. annual) and certificate validity/renewal lead time (start at T-60 days).
- [ ] Performance tolerance that the pilot must meet (e.g. batch elapsed ≤ +10 %, OLTP p95 ≤ +5 %, standby apply keeps up at peak).

### 3.2 Inventory and readiness (per database / host)

Run on every database and host. Load the results into the wave tracker.

```sh
# per DB (read-only): version/RU, CDB+PDBs, DG role and standby, sizes, largest
# datafile, redo/day, FRA space, DB links, current TDE params
sqlplus -s / as sysdba @scripts/preflight/01_db_inventory.sql > inv_${ORACLE_SID}.txt

# per host (read-only): orapki/openssl, sqlnet.ora WALLET_LOCATION/SEPS conflicts,
# deprecated ENCRYPTION_WALLET_LOCATION, listener endpoints, free space
ORACLE_SID=FINP1 STANDBY_HOST=stdby01.dr.csob.cz DATA_MOUNTS="/oradata" \
  ./scripts/preflight/02_host_preflight.sh
```

Readiness items that change the plan for a DB:

| Finding | Consequence |
|---------|-------------|
| `sqlnet.ora` already has `WALLET_LOCATION` / `SQLNET.WALLET_OVERRIDE=TRUE` (SEPS) | Must **merge** wallets or isolate `TNS_ADMIN` before A4 ([02 §4.2](02-tls-guide.md#42-sqlnetora--server-side)) |
| `ENCRYPTION_WALLET_LOCATION` present | Remove it as part of B1 (deprecated; conflicts with `WALLET_ROOT`) |
| Largest tablespace ≫ daily redo / archive headroom | Online encryption impractical → **standby-first** or offline method ([03 §5.5](03-tde-guide.md#55-recommendation-logic)) |
| Not enough free space for a copy of the largest datafile | Add space, use `FILE_NAME_CONVERT` to another mount (non-OMF only), or offline method |
| DB links, GoldenGate, OEM agents, RMAN catalog, backup tools connect on 1526 | Each one is an internal consumer that must move to TCPS before 1526 closes (A8) |

### 3.3 Enablers (owned outside the DBA team)

- [ ] **CA template** issuing `CN=<host FQDN>` with matching **DNS SANs**, EKU `serverAuth` + `clientAuth`, 4096-bit RSA keys. The template must inject SANs, because 19c `orapki` CSRs do not carry them ([02 §3.3](02-tls-guide.md#33-san-caveat-important)). Agree a CSR turnaround SLA.
- [ ] **Firewall** requests for 1527/tcp: all client subnets → DB hosts, primary ↔ standby (both directions), OEM/backup/jump hosts.
- [ ] **Vault**: a safe/object per database for the TDE keystore password and the TLS wallet password; custodian access model agreed.
- [ ] **Keystore backup location** separate from RMAN backups, with restricted access ([01 §7.3](01-key-management-decision.md#73-backup-policy)).
- [ ] **Monitoring**: certificate-expiry check (T-45/30/14), keystore `OPEN` check on primary and standby, and the cleartext-connection report (§10.2) scheduled.
- [ ] **Truststore package** for app teams: CSOB root + issuing CA certs, a ready-made JKS/PKCS12, a client wallet for OCI, one-page instructions per client type (§8).
- [ ] **Change templates** for A5, A10, B1, B2–B5, B6, B7 approved by CAB as standard changes after the pilot.
- [ ] **Client inventory**: JDBC driver versions (ojdbc8+ needed for `tcps://` Easy Connect Plus; older drivers use the TNS-descriptor URL form), OCI client versions (11.2 clients are a risk for TLS 1.2 + ECDHE-GCM and must be validated or upgraded), ORDS versions.

**Phase 0 exit:** all §3.1 decisions signed; inventory complete for the pilot and DEV; CA template issuing test certs; pilot firewall rules in place; vault and backup location usable; monitoring checks deployed for pilot hosts.

---

## 4. Phase 1 — Pilot

### 4.1 Pilot selection

Pick **2–3 low-risk but representative** databases that together cover:

- One **CDB with ≥1 PDB** and one **non-CDB** (keystore commands differ — [01 §8](01-key-management-decision.md#8-mixed-cdb--non-cdb-keystore-mode)).
- At least one **with a Data Guard physical standby** (wallet sync, encrypted redo apply, TCPS redo transport, switchover).
- One with a meaningful **batch** window and one with an OLTP/app profile.
- At least one Java/JDBC app, and ideally one ORDS/APEX and one OCI client.
- Same **AIX 7.2 / POWER hardware class** as production, so the measurements transfer.

### 4.2 Mandatory measurements (before committing the fleet)

On AIX/POWER, do not assume x86 AES-NI numbers ([03 §7](03-tde-guide.md#7-performance-on-aix--power)). Capture **before and after**:

| Measurement | How | Why |
|-------------|-----|-----|
| Batch job elapsed time | Same batch, same data volume, pre/post encryption | Most crypto-sensitive; main sizing input |
| Standby redo apply rate & lag | `V$DATAGUARD_STATS` (`apply lag`, `transport lag`), `V$RECOVERY_PROGRESS` under peak load | Encrypted redo applied on POWER must keep up |
| Online-encryption throughput | GB/hour per tablespace during B6, redo GB generated | Sizes PROD windows and archive space |
| RMAN backup & **restore** duration, backup size | Level 0 + level 1 pre/post; one full restore test | Encrypted blocks compress poorly; restore needs keystore |
| Host & DB CPU | `nmon`/`lparstat`, AWR | Headroom on POWER cores |
| OLTP response time | AWR top SQL, app SLA metrics | Interactive impact |
| TLS connect cost | Connection-storm test (pool restart) on TCPS vs TCP; CPU during handshake burst | Pools that reconnect aggressively feel TLS most |

### 4.3 Pilot exit report

Record: measurements vs tolerance with an accept/adjust decision, runbook corrections from real execution, rollback executed at least once per track (TLS endpoint removed and restored; one tablespace decrypted online and re-encrypted on a non-critical pilot DB), a switchover and switchback with TDE + TCPS active, and an RMAN restore that included a keystore restore from the separate backup location. Also close the [03 §14](03-tde-guide.md#14-open-validation-items) open validation items: POWER crypto acceleration, the UNDO path, standby-first sequencing, and auto-login open on a copied-to standby. Also confirm that the listener log records TCPS clients as `(ADDRESS=(PROTOCOL=tcps)…)`. The TCP format was checked on 19.27, but the TCPS line has not been seen live yet, and the §10.2 report depends on it.

---

## 5. Phases 2–5 — Environment waves & gates

Each wave is batched (10–20 databases per batch) to keep change volume and on-call load manageable. **A wave starts only when the previous wave's exit criteria are met.** TLS and TDE pass through the gates independently.

| Wave | Entry criteria | Exit criteria |
|------|----------------|---------------|
| **Pilot** | Phase 0 exit met; runbooks + scripts version-controlled; rollback tested in a lab | Pilot report accepted (§4.3); runbooks corrected; both rollbacks executed successfully |
| **DEV** | Pilot exit met; standard-change templates approved | All in-scope DEV DBs done per §11; no open Sev-1/2 |
| **TEST** | DEV exit met; truststore package published to app teams | All TEST DBs done; app connectivity over TCPS validated by QA |
| **PREPROD** | TEST exit met; app migration playbook signed off by app owners | All PREPROD DBs done; performance within tolerance; DR switchover tested with TDE + TCPS |
| **PROD** | PREPROD exit met; per-DB windows scheduled; rollback rehearsed; on-call briefed; custodians rostered | All PROD DBs done per §11 (TCP close tracked separately in Phase 6) |

**Gates that apply to every change in every wave:**

- Data Guard healthy (no gap, apply lag nominal) **before** starting and **after** finishing.
- Keystore backup verified in the separate location **after every key operation**.
- Certificate-expiry monitoring active **before** a TCPS endpoint goes live.
- A full RMAN backup exists from before the TDE change.

**Recommended per-database order inside a wave:** do TLS (A1–A7) first. It is low-risk and fully reversible, and it starts the application migration clock early. TDE (B1–B10) runs in its own window, usually a few days later. Within a Data Guard pair, change the **standby first, then the primary**.

---

## 6. Runbook A — TLS enablement (per DB)

Placeholders: host `db01.prod.csob.cz`, standby `stdby01.dr.csob.cz`, DN `CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ`, wallet `/oracle/admin/$ORACLE_SID/wallet_tls`. Configuration fragments: [`scripts/tls/02_listener_tcps_fragments.md`](../scripts/tls/02_listener_tcps_fragments.md).

| Step | What | Where | Outage? |
|------|------|-------|---------|
| A0 | Pre-flight | both hosts | no |
| A1 | Wallet + key + CSR | each host | no |
| A2 | CA issues cert | PKI | no |
| A3 | Import chain + cert | each host | no |
| A4 | `sqlnet.ora` (merge) | each host | no |
| A5 | TCPS endpoint + registration | each host, standby first | **seconds** (listener restart) |
| A6 | Verify + firewall | each host | no |
| A7 | Repeat A1–A6 on standby | standby host | seconds |
| A8 | Move internal consumers (DG redo, DB links, OEM…) | DB / OEM | no |
| A9 | Application migration (coexistence) | app teams | no |
| A10 | Close TCP 1526 | each host | clients still on 1526 break |

**A0 — Pre-flight.** Run `scripts/preflight/02_host_preflight.sh`. Resolve any `WALLET_LOCATION` / SEPS conflict first. Confirm 1527 firewall rules are in place, and that the TLS wallet password exists in the vault.

**A1 — Create the TLS wallet and CSR** (separate from the TDE keystore. The script refuses TDE-looking paths):

```sh
ORACLE_SID=FINP1 \
CERT_DN="CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ" \
KEYSIZE=4096 \
  ./scripts/tls/01_create_tls_wallet.sh --mode csr        # prompts for the wallet password
# -> /tmp/FINP1_tls.csr ; submit to the internal CA
```

**A2 — CA issues the certificate** with the agreed template (CN = FQDN, DNS SANs for every name clients use, `serverAuth` + `clientAuth`). Collect the root CA, the issuing CA and the server certificate.

**A3 — Import the chain (root → issuing → server) and check it:**

```sh
ROOT_CA_CERT=/tmp/csob-root-ca.cer ISSUING_CA_CERT=/tmp/csob-issuing-ca.cer \
SERVER_CERT=/tmp/db01.prod.csob.cz.cer ORACLE_SID=FINP1 \
  ./scripts/tls/01_create_tls_wallet.sh --mode import
# expect: user cert with Subject = the DN, complete chain under "Trusted Certificates"
```

**A4 — Server `sqlnet.ora`.** Merge into the existing file; never add a second `WALLET_LOCATION`. `WALLET_LOCATION` is **required here**, not only in `listener.ora`. Without it clients get ORA-28865 after the handshake ([02 §4.2](02-tls-guide.md#42-sqlnetora--server-side)).

```ini
WALLET_LOCATION =
  (SOURCE = (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /oracle/admin/FINP1/wallet_tls)))
SSL_CLIENT_AUTHENTICATION = FALSE
SSL_VERSION = 1.2                     # TLS 1.2 only; widen to "1.2 or 1.3" after client validation
SSL_CIPHER_SUITES = (TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256)
SSL_SERVER_DN_MATCH = TRUE            # applies when this DB is a TLS client (DB links, redo transport)
# ANO decision (§3.1): REQUIRED protects 1526 during coexistence but double-encrypts TCPS;
# ACCEPTED is the target once 1526 is closed. See 02-tls-guide.md §5.
SQLNET.ENCRYPTION_SERVER = ACCEPTED
```

**A5 — Add the TCPS endpoint and advertise it** (in a short window, because the listener restart refuses new connections for a few seconds):

```ini
# listener.ora — both endpoints = dual-port coexistence
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP) (HOST = db01.prod.csob.cz)(PORT = 1526)))
    (DESCRIPTION = (ADDRESS = (PROTOCOL = TCPS)(HOST = db01.prod.csob.cz)(PORT = 1527))))
WALLET_LOCATION =
  (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /oracle/admin/FINP1/wallet_tls)))
SSL_CLIENT_AUTHENTICATION = FALSE
# + static SID_LIST_LISTENER entry for DG hosts (see fragments §1)
```

```sql
-- dynamic registration must include the TCPS address (CDB: set in CDB$ROOT)
ALTER SYSTEM SET LOCAL_LISTENER=
 '(DESCRIPTION_LIST=
    (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db01.prod.csob.cz)(PORT=1526)))
    (DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=db01.prod.csob.cz)(PORT=1527))))'
 SCOPE=BOTH;
```

```sh
lsnrctl stop LISTENER; lsnrctl start LISTENER    # adding an ADDRESS needs stop/start; reload is not enough
echo "ALTER SYSTEM REGISTER;" | sqlplus -s / as sysdba   # (no <<< here-strings: AIX ksh88)
lsnrctl status LISTENER                          # expect TCP:1526 and TCPS:1527, services on both
```

**A6 — Verify:**

```sh
TLS_HOST=db01.prod.csob.cz TNS_ALIAS=APPSVC_TLS DB_USER=dba_check \
  ./scripts/tls/03_verify_tls.sh
# expect: TCPS handler on 1527 · TLSv1.2 + ECDHE-GCM · "Verify return code: 0" · NETWORK_PROTOCOL=tcps
```

**A7 — Standby host.** Repeat A1–A6 on the standby with its own certificate. Use the standby's own FQDN in `listener.ora`, `LOCAL_LISTENER` and the static registration. Doing the standby first is preferred.

**A8 — Move internal consumers to TCPS.** These are not application-team work, so the DBA team owns them:

- **Data Guard redo transport**: TCPS aliases in `tnsnames.ora` on both hosts. Then set broker `DGConnectIdentifier` / `StaticConnectIdentifier` for both members (or `LOG_ARCHIVE_DEST_n SERVICE=`), and run `VALIDATE DATABASE` ([02 §11](02-tls-guide.md#11-data-guard-redo-transport-over-tcps)).
- **DB links**: recreate with TCPS descriptors ([02 §10](02-tls-guide.md#10-db-links-over-tcps)). The inventory lists them (`01_db_inventory.sql`).
- **OEM agent monitoring**, RMAN catalog connections, backup tooling, GoldenGate, and DBA jump-host tooling.

**A9 — Application migration during coexistence** (§8). Both ports serve traffic. Run `scripts/tls/04_cleartext_session_report.sh` weekly and send app owners their list of remaining 1526 sources.

**A10 — Close TCP 1526**, only after the zero-cleartext evidence in §10.2 has held for the agreed soak period (e.g. 2 weeks covering a month-end):

1. Remove the TCP `DESCRIPTION` from `listener.ora` **and** from `LOCAL_LISTENER` (`SCOPE=BOTH`), on primary **and** standby.
2. `lsnrctl stop` / `lsnrctl start` (treat every endpoint change as stop/start), then `ALTER SYSTEM REGISTER`.
3. Ask network to remove the 1526 firewall rules.
4. If ANO was set to `REQUIRED` for coexistence, return it to `ACCEPTED` (or `REJECTED`).
5. Keep the previous `listener.ora` next to the live one for a fast rollback (§9).

---

## 7. Runbook B — TDE enablement (per DB)

Conventions per [01 §6](01-key-management-decision.md#6-decided-conventions). `WALLET_ROOT=/oracle/admin/$ORACLE_SID/wallet` → keystore in `$WALLET_ROOT/tde`. Commands below show the **CDB** form. Each script has a non-CDB variant, where `CONTAINER=ALL` is omitted.

| Step | What | Where | Outage? |
|------|------|-------|---------|
| B0 | Pre-flight + method choice | both | no |
| B1 | `WALLET_ROOT` + `TDE_CONFIGURATION` | standby, then primary | **restart** (or switchover) |
| B2 | Keystore + first MEK + auto-login | primary | no |
| B3 | Sync keystore to standby | standby | no |
| B4 | Back up keystore (separate storage) | custodian | no |
| B5 | Born-encrypted policy | primary + standby | no |
| B6 | Encrypt application tablespaces | primary (or standby-first) | method-dependent |
| B7 | SYSTEM/SYSAUX/UNDO/TEMP | separate change | yes (offline/swap) |
| B8 | Verify | both | no |
| B9 | RMAN level 0 + restore test | primary | no |
| B10 | Switchover test (pilot/preprod) | DG pair | role change |

**B0 — Pre-flight and method choice.** Using `01_db_inventory.sql`:

- Pick the conversion method per DB ([03 §5.5](03-tde-guide.md#55-recommendation-logic)): **online** when archive space, network and standby can absorb redo ≈ tablespace size; **standby-first** for large DG databases; **offline** when a window is acceptable.
- Free space ≥ the largest datafile being converted. Archive destination / FRA headroom ≥ the size of the largest tablespace converted in one go, with margin.
- A recent full RMAN backup exists. DG is healthy. The custodian is booked for B2.
- Remove any `ENCRYPTION_WALLET_LOCATION` from `sqlnet.ora` on both hosts.
- `mkdir -p /oracle/admin/$ORACLE_SID/wallet/tde; chmod 700` on **both** hosts.

**B1 — `WALLET_ROOT` (static) and `TDE_CONFIGURATION` (dynamic).** `scripts/tde/01_configure_wallet_root.sql` stops after the `SCOPE=SPFILE` step so the restart cannot be skipped:

```sql
ALTER SYSTEM SET WALLET_ROOT='/oracle/admin/FINP1/wallet' SCOPE=SPFILE;
-- restart, then:
ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;
```

Two ways to absorb the restart on a DG pair:

- **Outage window**: set on the standby and restart it, then set on the primary and restart it.
- **Near-zero downtime**: set on the standby and restart it, **switch over**, set on the old primary (now standby) and restart it, then optionally switch back. The application sees only the switchover.

**B2 — Create the keystore, first MEK and auto-login on the primary** (`scripts/tde/02_create_keystore_and_mek.sql`; the custodian enters the password):

```sql
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "<ks_pw>";
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "<ks_pw>" CONTAINER=ALL;
ADMINISTER KEY MANAGEMENT SET KEY USING TAG 'FINP1_20261015'
  IDENTIFIED BY "<ks_pw>" WITH BACKUP USING 'FINP1_20261015_setkey' CONTAINER=ALL;
ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE           -- NOT "LOCAL": must open on the standby
  FROM KEYSTORE IDENTIFIED BY "<ks_pw>";
```

`V$ENCRYPTION_WALLET` shows `WALLET_TYPE=PASSWORD` until the keystore is next reopened. After a restart it shows `AUTOLOGIN`. For per-PDB tags, use the per-PDB loop in the script: `CONTAINER=ALL` gives untagged PDB keys.

**B3 — Sync the keystore to the standby, then verify** (before any encryption):

```sh
./scripts/dg/sync_wallet_to_standby.sh stdby01.dr.csob.cz /oracle/admin/FINP1/wallet
```

```sql
-- on the standby
SELECT con_id, status, wallet_type FROM v$encryption_wallet;   -- OPEN / AUTOLOGIN
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag','apply lag');
```

**B4 — Back up the keystore** (`ewallet.p12` + `cwallet.sso`) to the separate custody location, and confirm it landed. Repeat after **every** key operation. Never delete old keys.

**B5 — Born-encrypted policy** on the primary **and** the standby spfile, so it survives a role change:

```sh
sqlplus / as sysdba @scripts/tde/06_new_tablespace_policy.sql
# sets ENCRYPT_NEW_TABLESPACES=ALWAYS and runs the AES256 compliance check
```

On 19c, `ALWAYS` encrypts a new tablespace with **AES128** unless the DDL names the algorithm. `TABLESPACE_ENCRYPTION_DEFAULT_ALGORITHM` became a documented parameter only in 21c. It is absent from `V$PARAMETER` on 19.27, and the 19c underscore equivalent needs an Oracle Support SR. So the standard has two parts:
- **Preventive:** all DDL says `ENCRYPTION USING 'AES256' ENCRYPT`. Add this to the build standard and to app-team DDL review.
- **Detective:** the compliance query in script 06 runs in monitoring and flags any tablespace whose `ENCRYPTIONALG` is not AES256. Fix offenders with `ALTER TABLESPACE … ENCRYPTION ONLINE USING 'AES256' REKEY`.

**B6 — Encrypt application tablespaces** using the method chosen in B0:

- **Online**: `scripts/tde/03_encrypt_tablespaces_online.sql` generates the statements. Run them **one tablespace at a time**:
  ```sql
  ALTER TABLESPACE "APP_DATA" ENCRYPTION ONLINE USING 'AES256' ENCRYPT;
  -- no FILE_NAME_CONVERT (=NONE fails with ORA-28437 on OMF); interrupted? → ... FINISH ENCRYPT
  ```
  Between tablespaces, check `V$SESSION_LONGOPS`, archive destination space, and standby transport/apply lag.
- **Standby-first**: follow the current MOS procedure for 19.30 ([03 §5.3](03-tde-guide.md#53-standby-first-conversion-method-3--recommended-for-this-fleet)). Convert offline on the standby with apply stopped, switch over, then convert the former primary.
- **Offline**: `ALTER TABLESPACE ... OFFLINE NORMAL; ALTER TABLESPACE ... ENCRYPTION OFFLINE USING 'AES256' ENCRYPT; ALTER TABLESPACE ... ONLINE;` in a window. On DG, the standby must be converted too (see 03 §5.2–5.3).

**B7 — SYSTEM / SYSAUX / UNDO / TEMP** as a separate, planned change: offline for SYSTEM/SYSAUX, recreate-and-swap for UNDO and TEMP ([03 §10](03-tde-guide.md#10-encrypting-system--sysaux--undo--temp)).

**B8 — Verify** with `scripts/tde/04_verify_tde.sql` on **primary and standby**. Attach both outputs to the change ticket as evidence.

**B9 — RMAN.** Take a fresh **level 0** after conversion: re-encryption rewrites every block, so the next level 1 would be as large as a full. Compare backup duration and size against the pilot baseline. Restore tests must include restoring the keystore from the separate location.

**B10 — Switchover test** (mandatory in pilot and PREPROD; per DR-test cadence in PROD): switch over, confirm the new primary opens its keystore automatically, encrypted tablespaces are readable, and redo flows the other way; then switch back.

---

## 8. Application-team coordination (TLS)

TLS is only "done" when applications connect over TCPS and 1526 is closed. Start this conversation in Phase 0.

### 8.1 What each client type must change

| Client | Change | Notes |
|--------|--------|-------|
| **Java / JDBC thin** | Import the **CA root + issuing CA** into the app truststore (never the server leaf). Switch the URL to TCPS 1527 with DN matching. | `tcps://` Easy Connect Plus needs a 18c+/19c driver; older drivers use the descriptor form. pre-21c drivers default DN-match to **off** → set it explicitly. |
| **Legacy OCI (thick)** | Client `sqlnet.ora` → truststore-only wallet (CA certs, no key), `SSL_SERVER_DN_MATCH=TRUE`, TCPS TNS alias | Validate 11.2 clients early; upgrade to 19c Instant Client where they fail |
| **ORDS / APEX** | ORDS pool URL → TCPS; ORDS JVM truststore trusts the CA; restart ORDS | APEX itself is unaffected |
| **DB links / DG / OEM / tools** | DBA-owned, see A8 | — |

### 8.2 Connect strings

```properties
# JDBC thin — Easy Connect Plus (ojdbc8 19c+):
jdbc:oracle:thin:@tcps://db01.prod.csob.cz:1527/APPSVC.prod.csob.cz?ssl_server_dn_match=true

# JDBC thin — descriptor form (any driver; explicit DN pin):
jdbc:oracle:thin:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=db01.prod.csob.cz)(PORT=1527))
  (CONNECT_DATA=(SERVICE_NAME=APPSVC.prod.csob.cz))
  (SECURITY=(SSL_SERVER_DN_MATCH=TRUE)
    (SSL_SERVER_CERT_DN="CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ")))
```

`SSL_SERVER_CERT_DN` must be the certificate's **full** subject DN. `CN=` alone does not match.

```sh
# Java truststore: import the CA certificates, not the server certificate
keytool -importcert -trustcacerts -alias csob-root-ca    -file csob-root-ca.cer    -keystore truststore.jks
keytool -importcert -trustcacerts -alias csob-issuing-ca -file csob-issuing-ca.cer -keystore truststore.jks
# JVM: -Djavax.net.ssl.trustStore=/path/truststore.jks -Djavax.net.ssl.trustStoreType=JKS
```

### 8.3 Per-database communication checklist

- [ ] Notify app owners: DB, TCPS host/port (1527), service name, full server DN, coexistence start, **planned 1526 close date**.
- [ ] Send the truststore package and the client-type instructions.
- [ ] App teams switch **non-prod first** and validate (QA sign-off in TEST).
- [ ] App teams cut over production and confirm.
- [ ] DBA sends the weekly cleartext report (§10.2) for that DB with remaining sources named.
- [ ] Zero cleartext for the soak period → schedule A10 and announce it one week ahead.

---

## 9. Rollback

| Step | Rollback | Data impact |
|------|----------|-------------|
| **A1–A4** (wallet, sqlnet) | Restore the previous `sqlnet.ora`; the wallet directory can stay | None |
| **A5** (TCPS endpoint) | Restore the previous `listener.ora` and `LOCAL_LISTENER`; `lsnrctl stop/start`; `ALTER SYSTEM REGISTER` | None. TCP 1526 was never removed |
| **A8** (DG / DB links over TCPS) | Point the broker properties / DB links back to the TCP aliases | None |
| **A10** (1526 closed) | Re-add the TCP address to `listener.ora` and `LOCAL_LISTENER`; `lsnrctl stop/start`; re-open 1526 in the firewall (lead time!) | None |
| **B1** (`WALLET_ROOT`) | `ALTER SYSTEM RESET WALLET_ROOT SCOPE=SPFILE` + restart, **only before B2** | None |
| **B2–B5** (keystore, MEK, policy) | Leave the keystore in place (harmless when no data is encrypted); `ENCRYPT_NEW_TABLESPACES` back to `CLOUD_ONLY` | None |
| **B6–B7** (data encrypted) | **Forward-only by design.** If really needed: `ALTER TABLESPACE ... ENCRYPTION ONLINE DECRYPT` per tablespace, a full rewrite like the encryption itself | Keys must still be kept forever |

**Critical TDE rule:** every backup and archived log produced after encryption needs the MEK **forever**. A "rollback" that deletes the keystore makes those backups unrecoverable. Even after a decrypt, keep the keystore and its full key history for the whole backup retention horizon ([01 §7.3](01-key-management-decision.md#73-backup-policy)).

---

## 10. Monitoring & verification

### 10.1 TDE state

`scripts/tde/04_verify_tde.sql` is the full report. Core checks:

```sql
-- keystore on primary AND every standby (CDB: one row per container)
SELECT con_id, wrl_type, status, wallet_type, keystore_mode FROM v$encryption_wallet;
-- want STATUS=OPEN, WALLET_TYPE=AUTOLOGIN (LOCAL_AUTOLOGIN is a red flag on DG)

-- encrypted tablespaces + algorithm (join on con_id too in a CDB)
SELECT ts.con_id, ts.name, e.encryptionalg, e.status
FROM   v$encrypted_tablespaces e
JOIN   v$tablespace ts ON ts.ts# = e.ts# AND ts.con_id = e.con_id;

-- key history (must only grow)
SELECT con_id, key_id, tag, creation_time, activation_time FROM v$encryption_keys ORDER BY con_id, creation_time;
```

### 10.2 Proving "zero cleartext" before closing 1526

A plain `V$SESSION` query cannot show each session's protocol. `SYS_CONTEXT('USERENV','NETWORK_PROTOCOL')` only reports **your own** session. Use the listener log, which records the client's protocol for every connection:

```sh
# weekly per DB host; output = totals tcp vs tcps + top remaining tcp sources
# (client IP, service, program) + a ZERO-CLEARTEXT verdict line
./scripts/tls/04_cleartext_session_report.sh /u01/app/oracle/diag/tnslsnr/db01/listener/trace/listener.log
```

The evidence for A10 is the report showing **zero `tcp` connections** over the soak period, on primary and standby. To spot-check a single session after connecting, run `scripts/tls/03_verify_tls.sql` (`NETWORK_PROTOCOL = tcps`).

### 10.3 Certificate expiry

Alert at **T-45 / T-30 / T-14** days for the server certificate **and** the issuing/root CA certificates. The simplest fleet-wide probe works from any monitoring host:

```sh
echo | openssl s_client -connect db01.prod.csob.cz:1527 2>/dev/null | openssl x509 -noout -enddate -subject
```

Renewal is zero-downtime: new cert into the same wallet, then `lsnrctl reload` ([02 §12](02-tls-guide.md#12-certificate-rotation--monitoring)).

### 10.4 Keystore backups

- After every key operation, confirm that the backup landed in the separate location and that its timestamp is newer than the newest `V$ENCRYPTION_KEYS.CREATION_TIME`.
- Quarterly: restore a keystore backup in a lab and open it.

---

## 11. Operational acceptance criteria

A database is **done** per track only when all items hold. Attach the evidence to the change ticket.

**TLS track**
- [ ] TCPS:1527 live on primary **and** standby; CA-issued certs with complete chain (`orapki wallet display`).
- [ ] `03_verify_tls.sh` clean: TLS 1.2+, ECDHE-GCM, verify code 0, `NETWORK_PROTOCOL=tcps`.
- [ ] Certificate expiry monitored (server + chain).
- [ ] DG redo transport, DB links, OEM and tools on TCPS (A8).
- [ ] Zero cleartext connections over the soak period (§10.2), then 1526 removed from listener, `LOCAL_LISTENER` and firewall (A10). *(Phase 6, tracked separately.)*

**TDE track**
- [ ] `WALLET_ROOT` + `TDE_CONFIGURATION=FILE` on both; no `ENCRYPTION_WALLET_LOCATION` anywhere.
- [ ] Keystore `OPEN` / `AUTOLOGIN` on primary **and** standby.
- [ ] Keystore password in the vault under custodian control, not known to the operating DBA alone.
- [ ] All in-scope tablespaces encrypted **AES256** (app tablespaces + SYSTEM/SYSAUX/UNDO/TEMP once B7 is done).
- [ ] `ENCRYPT_NEW_TABLESPACES=ALWAYS` on both; AES256 compliance check (script 06) clean and scheduled.
- [ ] Keystore backup in the separate location newer than the last key operation; full key history retained.
- [ ] Post-encryption level 0 taken; restore test (incl. keystore) passed at pilot/PREPROD.
- [ ] Standby applies with nominal lag; switchover tested (pilot/PREPROD).
- [ ] Performance within the tolerance from the pilot.

---

## 12. Phase 6 — Close-out & steady state

- **TLS close-out:** A10 per database as each one reaches zero cleartext. Report the fleet-wide percentage of DBs with 1526 closed until it reaches 100 %. Finally, raise the fleet to `SSL_VERSION = 1.2 or 1.3` where clients allow it.
- **Certificate lifecycle:** renewals start at T-60 days ([02 §12](02-tls-guide.md#12-certificate-rotation--monitoring)). A CA root/intermediate change is a fleet change that starts with the client truststores.
- **MEK rotation:** per crypto-period with `scripts/tde/05_rotate_mek.sql`. **Always** re-sync the standby right after, then back up the keystore.
- **New databases:** built with TCPS-only listeners, `WALLET_ROOT`, keystore and the born-encrypted policy from day one. Add this to the DB build standard.
- **OKV migration** once licensed and clustered: [01 §9](01-key-management-decision.md#9-later-migration-to-okv), wave by wave like this plan.
- **Audit evidence pack** per wave: inventory, change tickets, `04_verify_tde.sql` + `03_verify_tls.sh` outputs, cleartext reports, keystore-backup log.

---

## 13. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| R1 | Apps don't migrate off 1526 on time | High | Programme delay | Start in Phase 0; weekly named cleartext report; date-bound 1526 close with escalation; ANO interim for 1526 |
| R2 | Keystore lost or old MEK deleted | Low | **Unrecoverable data loss** | `WITH BACKUP` + separate-location backup after every key op; never delete keys; quarterly restore test |
| R3 | Standby keystore stale after key op | Medium | Redo apply stalls (ORA-28365/28374) | Sync script mandatory after B2/rotation; alert on standby wallet status + apply lag |
| R4 | Online encryption redo floods archive/FRA or the DG link | Medium | Primary hangs on archiver, lag | Size from inventory; one tablespace at a time; standby-first for large DBs |
| R5 | TDE overhead on POWER above tolerance | Medium | Batch/backup windows overrun | Pilot measurements gate the fleet; phase scope; add CPU headroom |
| R6 | SEPS `WALLET_LOCATION` conflict breaks DG broker/RMAN scripts | Medium | Silent failure of scripted jobs | Preflight script flags it; merge wallets or isolate `TNS_ADMIN` |
| R7 | Old OCI / JDBC clients can't negotiate TLS 1.2 + ECDHE-GCM | Medium | App can't move | Client inventory in Phase 0; early test; upgrade path |
| R8 | Certificate expires unnoticed | Low | All TCPS connections fail | T-45/30/14 alerts incl. chain; renewal at T-60 |
| R9 | New tablespaces created without `USING 'AES256'` | Medium | Get AES128 on 19c (policy breach) | DDL standard + scheduled AES256 compliance check (B5); `REKEY` offenders online |
| R10 | Listener restart / instance restart during business hours | Low | Brief connection failures | Windows per §1 table; switchover-based B1 |

---

## 14. Script index

| Step | Script | Read-only? |
|------|--------|------------|
| Phase 0 / A0 / B0 | `scripts/preflight/01_db_inventory.sql` | yes |
| Phase 0 / A0 / B0 | `scripts/preflight/02_host_preflight.sh` | yes |
| A1, A3 | `scripts/tls/01_create_tls_wallet.sh --mode csr\|import\|display` | no |
| A4, A5, A8 | `scripts/tls/02_listener_tcps_fragments.md` (config fragments) | — |
| A6 | `scripts/tls/03_verify_tls.sh` + `03_verify_tls.sql` | yes |
| A9, A10 | `scripts/tls/04_cleartext_session_report.sh` | yes |
| B1 | `scripts/tde/01_configure_wallet_root.sql` | no (restart) |
| B2 | `scripts/tde/02_create_keystore_and_mek.sql` | no |
| B3, rotation | `scripts/dg/sync_wallet_to_standby.sh` | no |
| B5 | `scripts/tde/06_new_tablespace_policy.sql` | no |
| B6 | `scripts/tde/03_encrypt_tablespaces_online.sql` (generator) | yes (generates) |
| B8 | `scripts/tde/04_verify_tde.sql` | yes |
| Phase 6 | `scripts/tde/05_rotate_mek.sql` | no |

---

## 15. Fact-check log (this revision)

Corrections to the previous version of this document:

| Previous text | Problem | Now |
|---------------|---------|-----|
| CSR with `-dn "CN=$(hostname -f)"` | AIX `hostname` has no `-f`; CN-only DN didn't match the DN used everywhere else | Use `01_create_tls_wallet.sh` with the full DN (A1) |
| `-keysize 2048 -sign_alg sha256WithRSAEncryption` | `-sign_alg` accepts `md5\|sha1\|sha256\|sha384\|sha512\|ecdsa…` only (checked against 19c `orapki` help) | Script handles it; no invalid flag |
| Repo-wide 3072-bit key standard (TLS guide, wallet script) | 19c `orapki -keysize` accepts 512/1024/2048/**4096**/… — 3072 is not listed | Standard changed to **4096** in the guide, the script default and here |
| Only the root CA imported | Leaf import fails if the issuing CA is missing | Root → issuing → server (A3) |
| `SSL_VERSION = 1.2  # enforce TLS 1.2+` | `1.2` means 1.2 **only**, not "1.2+" | Comment corrected; 1.3 widening in Phase 6 |
| No `LOCAL_LISTENER` change | Services not registered on the TCPS endpoint | A5 sets it, A10 removes TCP from it |
| "Non-disruptive up to step 6" | Listener `stop/start` refuses new connections briefly | Window guidance in §1 |
| Close TCP / roll back with `lsnrctl reload` | The same doc says endpoint changes need `stop/start` | All endpoint changes use `stop/start` |
| `SSL_SERVER_CERT_DN="CN=db-host…"` | Must be the full subject DN | Full DN; host names unified to the `csob.cz` placeholders used in the scripts |
| `SELECT … SYS_CONTEXT('USERENV','NETWORK_PROTOCOL') FROM v$session` | Returns the **caller's** protocol on every row; proves nothing about other sessions | Listener-log report (§10.2) |
| "Steps 1–2 require an instance restart" | Only `WALLET_ROOT` (step 1) is static | B1 only; switchover option added |
| `CONTAINER=ALL` shown unconditionally | Not valid on a non-CDB | CDB form noted; scripts carry both variants |
| `ENCRYPT_NEW_TABLESPACES=ALWAYS` alone | New tablespaces get **AES128** on 19c; the parameter that changes the default is 21c+ (absent on 19.27, checked live) | DDL standard + AES256 compliance check (B5) |
| Only online encryption in the runbook | 03 recommends standby-first for large DG DBs | Method choice in B0/B6 |
| No WALLET_ROOT/keystore dir on standby before sync, no ENCRYPTION_WALLET_LOCATION removal | Missing prerequisites | B0 |
| Missing: DG redo transport, DB links, OEM, backup over TCPS before closing 1526 | 1526 close would break them | A8 |
| Missing: roles, Phase 0, timeline, risks, post-encryption level 0 | Gaps for a fleet programme | §1–§3, §7 B9, §13 |

---
*Cross-references:* [00-overview.md](00-overview.md) (strategy, ANO interim, licensing), [01-key-management-decision.md](01-key-management-decision.md) (keystore conventions, custody, OKV), [02-tls-guide.md](02-tls-guide.md), [03-tde-guide.md](03-tde-guide.md), [05-faq.md](05-faq.md).
