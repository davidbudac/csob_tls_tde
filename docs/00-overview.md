# 00 — TLS & TDE Programme Overview

**Purpose.** This document is the entry point for the fleet-wide programme to introduce SQL*Net transport encryption (TLS/TCPS) and Transparent Data Encryption (TDE) across our Oracle 19c estate. It states the drivers, scope, current-vs-target state, the phased delivery strategy, and licensing considerations, and it points to the detailed decision and runbook documents. It is written for both the sponsoring stakeholders (regulatory/security, application owners) and the DBA/engineering teams executing the work.

## Table of contents
1. [Goals and drivers](#1-goals-and-drivers)
2. [Scope and environment assumptions](#2-scope-and-environment-assumptions)
3. [Current state → target state](#3-current-state--target-state)
4. [Delivery strategy: two independent tracks](#4-delivery-strategy-two-independent-tracks)
5. [Interim option: native SQL*Net encryption (ANO)](#5-interim-option-native-sqlnet-encryption-ano)
6. [Licensing summary](#6-licensing-summary)
7. [Wave and timeline model](#7-wave-and-timeline-model)
8. [Reading map](#8-reading-map)

---

## 1. Goals and drivers

The programme delivers two distinct security controls:

- **Data-in-transit encryption** — encrypt all Oracle Net (SQL*Net) traffic between clients and databases using TLS (TCPS), with server authentication via our internal enterprise CA.
- **Data-at-rest encryption** — encrypt sensitive tablespaces (and by policy, effectively all application tablespaces) using TDE tablespace encryption, so that database files, backups, and Data Guard redo are protected on disk and in transit at the storage layer.

**Drivers:**

| Driver | Relevance |
|--------|-----------|
| **DORA** (Digital Operational Resilience Act) | ICT risk management requires encryption of data at rest and in transit, plus demonstrable key management and operational resilience of those controls. |
| **PCI-DSS-style requirements** | Cardholder / sensitive data must be encrypted in transit over open/internal networks and rendered unreadable at rest; documented key-management lifecycle (generation, rotation, custody, retirement). |
| **Internal bank security policy** | Mandates encryption of confidential data at rest and in transit, separation of duties for key custody, and auditable cryptographic operations. |
| **Audit / regulator findings** | Unencrypted SQL*Net and unencrypted datafiles are recurring findings; this programme closes them fleet-wide with a consistent, evidenced standard. |

**Non-goals for this programme:** application-level (column-level cell) encryption redesign, TLS for non-Oracle protocols, and network segmentation changes. Those are tracked separately.

## 2. Scope and environment assumptions

The following environment assumptions hold across the estate and are restated in the detailed documents where they drive a decision:

- **Oracle 19c Enterprise Edition**, all instances **non-RAC** (single-instance).
- Hosts are **AIX 7.2 on IBM POWER**. This matters for TDE performance (POWER crypto acceleration differs from x86 AES-NI — see [04-rollout-plan.md](04-rollout-plan.md)) and for key-management endpoint support ([01-key-management-decision.md](01-key-management-decision.md)).
- **Mixed architecture:** some **non-CDB**, some **CDB with one or more PDBs**. Keystore and MEK handling differs between the two — see [01-key-management-decision.md](01-key-management-decision.md).
- **Most/all databases have a physical standby** (Data Guard). Redo apply, wallet synchronisation, and switchover/failover behaviour must be preserved.
- **No TLS and no TDE anywhere today.** This is a greenfield rollout of both controls.
- **Application stack:** predominantly Java applications using the **JDBC thin driver**; some **legacy OCI (thick) clients**; **APEX served via ORDS**.
- An **internal enterprise CA** exists and can issue server certificates for database hosts.
- **Advanced Security Option (ASO) is licensed fleet-wide** (covers TDE). **Oracle Key Vault (OKV)** would be a **separate** licence/purchase.

## 3. Current state → target state

| Dimension | Current state | Target state |
|-----------|---------------|--------------|
| SQL*Net transport | Cleartext TCP (port 1521) only | TLS/TCPS with server-cert authentication; TCP closed after coexistence |
| Server identity | None (no certificates) | Per-host server certificate from internal CA, monitored for expiry |
| Data at rest | Unencrypted datafiles, backups, redo | TDE tablespace encryption on all application tablespaces; encrypted RMAN backups |
| Master key storage | N/A | Standardised TDE keystore (local software keystore now → **OKV/HSM** target); `WALLET_ROOT`-based config |
| Key lifecycle | N/A | Documented generation, rotation, backup, custody with separation of duties |
| Data Guard | Unencrypted redo transport | TDE-protected redo; keystore kept in sync on standby |

## 4. Delivery strategy: two independent tracks

**TDE and TLS are independent controls and MUST be run as separate, parallel workstreams.** They share almost nothing operationally: TLS touches the listener, certificates, and client connect strings; TDE touches keystores, master keys, and tablespaces. Coupling them into a single change window multiplies risk and blast radius. Each track has its own runbook, its own rollback, and its own acceptance criteria.

```
                 ┌──────────────────────────────────────────┐
   Track A (TLS) │ wallet+cert → listener dual-port → migrate │→ close TCP
                 └──────────────────────────────────────────┘
                 ┌──────────────────────────────────────────┐
   Track B (TDE) │ WALLET_ROOT → keystore+MEK → standby sync  │→ encrypt tablespaces
                 └──────────────────────────────────────────┘
        (run concurrently per DB, but as separate changes with separate backout)
```

### TLS coexistence (dual-port) is mandatory

Within the TLS track, we run a **dual-port coexistence period**: the listener serves **both TCP (1521) and TCPS (2484)** simultaneously. This lets each application team migrate its connect strings, truststores, and pools **at its own pace** without a hard cutover. Only when a database's monitoring shows **zero remaining cleartext TCP sessions** (verified via listener log / `V$SESSION` network context — see [04-rollout-plan.md](04-rollout-plan.md)) do we close the TCP endpoint. This decouples DBA-side enablement from application-side migration, which is the single biggest schedule risk.

### TDE encryption is effectively forward-only

TDE tablespace encryption should be planned as **forward-only**. Online decryption (`ALTER TABLESPACE ... DECRYPT`) exists in 19c, but any backup taken after encryption requires the keystore/master key **forever** to restore. The operational implication — never discard old master keys, keep the full keystore history — is detailed in [04-rollout-plan.md](04-rollout-plan.md).

## 5. Interim option: native SQL*Net encryption (ANO)

Rolling out TLS certificates and migrating hundreds of application connect strings takes time. **Native Network Encryption (formerly ASO's ANO)** is a pragmatic **interim** control for data-in-transit while the TLS track runs.

- **De-licensed in 2013:** Oracle native SQL*Net encryption and native data integrity are **free** — no ASO (or any) licence is required for them. (They historically lived under ASO; Oracle unbundled them.) TDE, in contrast, still requires ASO.
- **Zero client-side change** for a quick win: setting the server side alone encrypts the session. With:

  ```ini
  # sqlnet.ora on the database server
  SQLNET.ENCRYPTION_SERVER = REQUIRED
  SQLNET.ENCRYPTION_TYPES_SERVER = (AES256)
  SQLNET.CRYPTO_CHECKSUM_SERVER = REQUESTED
  SQLNET.CRYPTO_CHECKSUM_TYPES_SERVER = (SHA256)
  ```

  any 19c-era JDBC-thin or OCI client that supports the negotiation gets an AES256-encrypted session with **no client configuration change** (the algorithms ship in the driver / client).

**Trade-offs vs TLS — ANO is not a substitute:**

| Property | Native encryption (ANO) | TLS (TCPS) |
|----------|-------------------------|------------|
| Encrypts the wire | Yes (AES256) | Yes |
| **Server authentication** | **No** — client cannot verify server identity | Yes, via CA-issued server cert |
| **MITM protection via PKI** | **No** | Yes |
| Certificate / PKI management | None | Required (issue, deploy, monitor expiry) |
| Client-side change to enable | None (server-only `REQUIRED`) | Truststore + connect-string change |
| Meets "authenticated encrypted channel" audit control | Partially (encryption only) | Fully |

**Recommendation:** consider ANO with `ENCRYPTION_SERVER=REQUIRED` as a **short-lived interim** to close the "cleartext on the wire" finding quickly and cheaply, then supersede it with TLS. If TLS can be delivered on an acceptable timeline, ANO can be skipped. Do not treat ANO as the end state — it provides confidentiality but not authentication, and regulators increasingly expect PKI-authenticated channels.

## 6. Licensing summary

| Component | Licence | Status |
|-----------|---------|--------|
| TDE (tablespace encryption) | Advanced Security Option (ASO) | **Licensed fleet-wide** ✔ |
| TLS / TCPS transport | None (base RDBMS feature) | No licence needed ✔ |
| Native SQL*Net encryption (ANO) | None (de-licensed 2013) | Free ✔ |
| Oracle Key Vault (OKV) | Separate OKV licence per deployment | **Not yet licensed** — business case in [01-key-management-decision.md](01-key-management-decision.md) |

## 7. Wave and timeline model

For a large fleet we deliver in **environment waves**, always **pilot-first**, with explicit entry/exit gates per wave (full criteria in [04-rollout-plan.md](04-rollout-plan.md)):

```
Pilot (2–3 representative DBs: 1 CDB, 1 non-CDB, 1 with DG)
   │  measure TDE performance on POWER, prove runbooks, prove rollback
   ▼
DEV wave ──▶ TEST wave ──▶ PREPROD wave ──▶ PROD wave
             (each wave gated by the prior wave's exit criteria)
```

- **Pilot** proves the runbooks and, critically, captures **TDE performance baselines on AIX/POWER** (batch elapsed, redo apply rate on standby, RMAN durations) before committing the fleet.
- Each environment wave is itself batched (e.g. groups of 10–20 databases) to keep change volume and on-call load manageable.
- TLS and TDE tracks progress through these waves **independently** — a database can be TLS-done and TDE-in-progress, or vice versa.
- Indicative shape (to be firmed up with change management): pilot ≈ 4–6 weeks; each environment wave a few weeks depending on fleet size and application-migration lead time. Application truststore/connect-string migration is the long pole for TLS.

## 8. Reading map

| Document | Contents |
|----------|----------|
| **00-overview.md** (this doc) | Programme goals, drivers, scope, strategy, licensing, waves |
| [**01-key-management-decision.md**](01-key-management-decision.md) | TDE key-management decision: OKV/HSM vs local software keystores; decided conventions (`WALLET_ROOT`, layout, backup, custody); CDB vs non-CDB keystore mode |
| [**02-tls-guide.md**](02-tls-guide.md) | TLS runbook: wallet & CSR workflow, listener/sqlnet config, JDBC/OCI/ORDS clients, DB links, DG redo transport over TCPS, rotation, troubleshooting |
| [**03-tde-guide.md**](03-tde-guide.md) | TDE guide: keystore concepts, conversion-method decision matrix (online / offline / standby-first / rebuild), DG specifics, AIX/POWER performance, aftercare |
| [**04-rollout-plan.md**](04-rollout-plan.md) | Fleet rollout: wave model, pilot criteria & measurements, app-team coordination, per-DB TLS & TDE runbooks, rollback, monitoring/verification, acceptance criteria |

**Scripts** (referenced by the runbooks):

- `scripts/tls/` — listener/wallet/cert helpers, dual-port config, client-migration checks.
- `scripts/tde/` — keystore creation (`WALLET_ROOT`), MEK set/rotate, tablespace encryption, keystore backup.
- `scripts/dg/` — Data Guard keystore synchronisation and standby verification helpers.
