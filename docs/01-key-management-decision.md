# 01 — TDE Key-Management Decision

**Purpose.** This document records the decision for how TDE **master encryption keys (MEKs)** are stored and managed across the fleet. It compares Oracle Key Vault (OKV) / external HSM (hardware security module) against local per-database software keystores (auto-login wallets), gives the recommendation for a large regulated bank, and — importantly — fixes the **conventions we adopt now** (directory layout, `WALLET_ROOT` configuration, wallet operational policy, custody, and CDB vs non-CDB keystore mode) so that starting local does **not** block a later migration to OKV. Environment assumptions are as stated in [00-overview.md](00-overview.md): Oracle 19c EE, non-RAC, AIX 7.2/POWER, mixed CDB/non-CDB, Data Guard standbys, ASO licensed, OKV not yet licensed.

## Table of contents
1. [Background: what we are protecting](#1-background-what-we-are-protecting)
2. [Options](#2-options)
3. [Comparison](#3-comparison)
4. [Availability / SPOF analysis](#4-availability--spof-analysis)
5. [Recommendation](#5-recommendation)
6. [Decided conventions](#6-decided-conventions)
7. [Wallet operational policy](#7-wallet-operational-policy)
8. [Mixed CDB / non-CDB keystore mode](#8-mixed-cdb--non-cdb-keystore-mode)
9. [Later migration to OKV](#9-later-migration-to-okv)

---

## 1. Background: what we are protecting

TDE uses a **two-tier key hierarchy**. Data encryption keys (DEKs, one per encrypted tablespace) are stored **in the datafile headers, encrypted by the master encryption key (MEK)**. The MEK never lives in the datafiles; it lives in a **keystore** (software wallet, OKV, or HSM). The key-management decision is therefore entirely about **where the MEK lives and how it is served to the instance** — the DEKs travel with the data.

Consequences that drive everything below:

- **Lose the MEK → lose the data.** There is no recovery. Keystore backup and custody are the highest-stakes part of this programme.
- The instance needs the MEK **open** to read/write encrypted tablespaces (including at startup, for redo apply on the standby, and for RMAN restore).
- Any backup or standby taken/created **after** a given MEK is in use requires that MEK to remain available **forever**.

## 2. Options

**Option A — Local per-database software keystore (auto-login wallet).**
Each database has its own password-protected keystore plus a local **auto-login** (or **local auto-login**) keystore so the instance can open the MEK automatically at startup without a human entering a password. Files live on the DB host (and copies on the standby host).

**Option B — Oracle Key Vault (OKV).**
A hardened, clustered key-management appliance. Databases become OKV **endpoints**; the MEK is stored centrally in OKV and served over the OKV network protocol via the endpoint software / PKCS#11 library (`libokvpkcs11`). OKV can front a corporate **HSM** as its root of trust (HSM-as-RoT), giving HSM-grade protection of the OKV master key without every database needing its own HSM slot.

**Option C — Direct external HSM keystore (PKCS#11).**
The database talks straight to an HSM via `HSM` keystore type / PKCS#11, no OKV in between. Viable but operationally heavy at fleet scale (per-DB HSM partitioning, no built-in central key catalog/rotation UI, HSM client on every AIX host). We treat OKV-fronting-HSM (Option B) as the preferred way to get HSM assurance.

## 3. Comparison

| Criterion | Local software keystore (A) | Oracle Key Vault (B) |
|-----------|-----------------------------|----------------------|
| **Security posture** | MEK stored as a file on the DB/standby hosts. As strong as host filesystem controls + wallet password. Auto-login wallet is obfuscated, not a hardware boundary. | Centralised, hardened appliance; MEK never persisted in cleartext on DB host. Optional HSM root of trust. Strong tenant/endpoint separation. |
| **Auditability / compliance** | Key operations auditable only per-DB via DB audit; no central key catalog. Harder to evidence "every key, everywhere" to a regulator. | Central audit of all key operations across the fleet; single pane for key inventory, rotation, access grants. Strong fit for DORA/PCI evidence. |
| **Key rotation at scale (100s of DBs)** | Each DB rotated individually (`ADMINISTER KEY MANAGEMENT ... SET KEY`), scripted but decentralised; tracking is on us. | Centralised policy, endpoint groups, orchestrated rotation and reporting from one place. |
| **Operational burden** | Per-DB wallet **backups**, secure custody, DR copies, standby sync — multiplied by fleet size. High cumulative toil and high blast radius for mistakes. | Central admin, backup of OKV itself (not per-DB wallets). Endpoint enrollment is standardised. Adds an appliance/cluster to operate. |
| **Availability / SPOF** | No external dependency at run time (see §4). Each DB self-contained. | OKV is a shared dependency; **must** be deployed as a multi-master cluster to avoid a fleet-wide SPOF (see §4). |
| **Cost** | Included (ASO already licensed). No new spend. | **Separate OKV licence** + appliance/VM + operational staffing. Not yet licensed. |
| **AIX 7.2 / POWER endpoint support** | Native — it is just RDBMS wallet files on AIX. | Supported: OKV **endpoint software runs on AIX**; PKCS#11 library `libokvpkcs11` is provided for AIX endpoints. (Endpoint enrollment via `okvutil`; auto-login "persistent cache" via `okvclient`.) |
| **Online vs auto-open behaviour** | Auto-login wallet auto-opens at instance start; no external call. | Endpoint configured for **auto-open / persistent cache** opens without human input and **caches keys locally** so the DB survives short OKV outages (see §4). |
| **Fit for a regulated bank end state** | Acceptable interim; weak central evidence story. | **Preferred end state** — central custody, audit, rotation, HSM option. |

## 4. Availability / SPOF analysis

*SPOF = single point of failure.* This is the objection most often raised against OKV ("if the vault is down, are all our databases down?"). The honest answer:

- **Local auto-login wallet (A):** the MEK is local, so there is **no run-time external dependency**. The database opens the wallet from the local filesystem at startup and keeps the key in the SGA. The only availability concern is the wallet file itself — mitigated by backups and standby copies.
- **OKV (B):** an endpoint fetches the MEK from OKV, but with **persistent master key cache / auto-open** enabled, the key is **cached locally** after first retrieval. **Databases keep running through a transient OKV outage** using the cached key — including startup if the persistent cache is populated. What an OKV outage blocks are **new key operations** (rekey/rotation, first-time key retrieval for a cold endpoint). It does **not** stop DML on already-open encrypted tablespaces.
- **OKV must still be clustered.** For a bank we mandate OKV **multi-master clustering** (2–N nodes, geographically split across our data centres, ideally aligned with primary/standby sites) so that planned maintenance or a node loss never becomes a key-management outage. Persistent cache is the second layer of defence, not the primary one.

**Conclusion:** OKV does not introduce an unacceptable SPOF **if** it is deployed multi-master and endpoints use persistent cache/auto-open. Local wallets have no run-time SPOF but shift the entire risk onto **wallet backup/custody discipline across hundreds of hosts** — which is itself a significant operational risk.

## 5. Recommendation

**Target (end) state:** **Oracle Key Vault, multi-master cluster, optionally fronting our corporate HSM as root of trust**, with all endpoints configured for **auto-open / persistent cache**. This gives centralised custody, fleet-wide audit and rotation, and the HSM assurance auditors expect — the correct posture for a regulated bank.

**Pragmatic phased path:** **start with local auto-login software keystores** using the standardised layout and conventions in §6, then **migrate to OKV** once it is licensed and clustered. Starting local lets the TDE track begin immediately (no procurement dependency, no new appliance on the critical path) while still being a fully compliant at-rest control.

**Critical enabler — starting local does NOT block OKV later.** The migration is a supported, online-capable one-liner per database:

```sql
-- Software keystore  →  OKV (HSM/external keystore). Run in the CDB root (or non-CDB).
-- The MIGRATE USING clause re-encrypts existing TDE keys under the new (OKV) key.
ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY
  IDENTIFIED BY "<okv_endpoint_password>"
  MIGRATE USING "<software_keystore_password>"
  WITH BACKUP USING 'pre_okv_migration';
```

A **reverse migration** (OKV → software keystore) also exists, via `ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY IDENTIFIED BY "<sw_pwd>" REVERSE MIGRATE USING "<okv_pwd>"`, so the decision is not one-way. The only precondition is that we standardise conventions **now** (§6): consistent `WALLET_ROOT`, layout, and naming across the fleet means the later migration is a scripted, uniform change rather than hundreds of bespoke ones.

## 6. Decided conventions

These conventions are **mandatory for every database** from day one, whether it starts local or (later) on OKV.

### 6.1 Use `WALLET_ROOT` + `TDE_CONFIGURATION` (19c best practice)

Configure the keystore location with the **`WALLET_ROOT` instance parameter** and the keystore **type** with the **`TDE_CONFIGURATION`** parameter. **Do not** use the deprecated `sqlnet.ora ENCRYPTION_WALLET_LOCATION` — it is deprecated in 19c and must not appear on any host.

```sql
-- WALLET_ROOT is a STATIC spfile parameter → requires an instance RESTART to take effect.
ALTER SYSTEM SET WALLET_ROOT = '/oracle/admin/&ORACLE_SID./wallet' SCOPE=SPFILE;
-- restart the instance here (bounce), then:

-- TDE_CONFIGURATION is DYNAMIC in 19c (SCOPE=BOTH), no restart needed.
ALTER SYSTEM SET TDE_CONFIGURATION = "KEYSTORE_CONFIGURATION=FILE" SCOPE=BOTH;
```

- `KEYSTORE_CONFIGURATION=FILE` selects a **software keystore** (our starting state).
- When we migrate to OKV, this becomes `KEYSTORE_CONFIGURATION=OKV` (or `OKV|FILE` during the migration window, and `FILE|OKV` for reverse-migration scenarios).
- With `WALLET_ROOT` set, Oracle **automatically uses the `$WALLET_ROOT/tde/` subdirectory** for the TDE software keystore — we never point at it explicitly.

### 6.2 Standard directory layout

```
/oracle/admin/$ORACLE_SID/
├── wallet/                     ← WALLET_ROOT
│   ├── tde/                    ← TDE software keystore (auto-used; ewallet.p12 + cwallet.sso)
│   ├── tde_seps/               ← (optional) SEPS (Secure External Password Store) wallet for keystore password auto-login to scripts
│   └── ...                     ← (OKV endpoint files land under WALLET_ROOT/okv/ after migration)
└── wallet_tls/                 ← TLS/TCPS wallet — SEPARATE, never shared with TDE
    ├── ewallet.p12
    └── cwallet.sso
```

**Rule: TLS wallets and TDE keystores are never the same wallet and never share a directory.** The TLS wallet holds the server certificate + CA chain and lives under `.../wallet_tls`; the TDE keystore holds MEKs and lives under `$WALLET_ROOT/tde`. Mixing them conflates two independent controls, two rotation lifecycles, and two custody models. (TLS wallet standard is detailed in [02-tls-guide.md](02-tls-guide.md).)

### 6.3 Create the keystore and set the first MEK

```sql
-- 1) Create the password-protected software keystore in WALLET_ROOT/tde
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "<keystore_password>";

-- 2) Open it (in a CDB, CONTAINER=ALL opens root + all PDBs)
ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN
  IDENTIFIED BY "<keystore_password>" CONTAINER=ALL;

-- 3) Set (activate) the first master encryption key
--    In a CDB run in CDB$ROOT with CONTAINER=ALL to set a key in root + each PDB.
ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY
  IDENTIFIED BY "<keystore_password>" WITH BACKUP USING 'initial_mek'
  CONTAINER=ALL;

-- 4) Create the auto-login keystore so the instance opens the MEK at startup
--    See §7 for the LOCAL vs non-LOCAL choice on Data Guard.
ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE
  FROM KEYSTORE IDENTIFIED BY "<keystore_password>";
```

> `WITH BACKUP` writes a backup copy of the keystore alongside the operation — always use it on any key-changing command (see §7 backup policy).

## 7. Wallet operational policy

### 7.1 Password keystore + auto-login

Every database keeps **both**:
- the **password-protected keystore** (`ewallet.p12`) — the source of truth, required for all administrative key operations, and
- an **auto-login keystore** (`cwallet.sso`) — so the instance opens the MEK unattended at startup (essential for a 24×7 fleet and for standby redo apply).

**LOCAL auto-login caveat for Data Guard.** A **local** auto-login keystore (`CREATE LOCAL AUTO_LOGIN KEYSTORE`) is bound to the **host it was created on** and will **not** open if copied to another machine. On a DG configuration where wallets are copied primary→standby, a LOCAL auto-login `cwallet.sso` copied to the standby host **will fail to open**. Therefore:

- **Prefer a non-LOCAL auto-login keystore** (`CREATE AUTO_LOGIN KEYSTORE`) so the same `cwallet.sso` works on both primary and standby hosts, **or**
- keep LOCAL auto-login and **regenerate the `cwallet.sso` on the standby host** from the copied `ewallet.p12`.

The password keystore (`ewallet.p12`) itself is host-independent and **must** be copied to the standby (the standby needs the same MEK to apply encrypted redo). See `scripts/dg/` for the sync helper.

### 7.2 Wallet password vaulting

Keystore passwords are **high-value secrets** and are stored in the enterprise privileged-access vault (**CyberArk-style**), not in scripts, not in `oratab`, not in runbooks. Automation retrieves the password from the vault at run time (or uses a SEPS/`tde_seps` wallet for local script auto-login where a password must be presented non-interactively). Rotation of the keystore password itself:

```sql
ADMINISTER KEY MANAGEMENT ALTER KEYSTORE PASSWORD
  IDENTIFIED BY "<old_password>" SET "<new_password>"
  WITH BACKUP USING 'pwd_rotation';
```

### 7.3 Backup policy

Losing the keystore = losing the data, so keystore backup is stricter than ordinary file backup:

- **Back up the keystore after every MEK operation** — every `SET ENCRYPTION KEY` (rekey), password change, and migration. Using `WITH BACKUP` on the command produces an inline backup; additionally capture the keystore into the enterprise backup system.
- **Back up before and after rotation.**
- **Store keystore backups separately from database/RMAN backups** and separately from the datafiles they protect. Storing the MEK next to the encrypted data defeats the control (an attacker with the backup set would have both). Different storage location, different access control, ideally different custody team.
- **Keep the full keystore history — never delete old MEKs.** Any backup or archived redo produced while an old MEK was current needs that MEK to restore. Retain all historical keys for at least the backup retention horizon (in practice: indefinitely / per records-retention policy).

### 7.4 Custody and separation of duties

- The **keystore password custodian** (security/key-management team) is **separate** from the **DBA** who operates the database. No single person holds both the password and unrestricted DB access — this is a PCI/DORA separation-of-duties expectation.
- Access to keystore backups is logged and restricted to the key-management custody team.
- All key operations are audited (DB unified audit now; centrally in OKV after migration).

## 8. Mixed CDB / non-CDB keystore mode

**Non-CDB:** one keystore, one MEK — straightforward; all conventions in §6 apply directly.

**CDB — united vs isolated keystore:**

| Mode | Where the keystore lives | MEKs | When to use |
|------|--------------------------|------|-------------|
| **United (default, recommended)** | Single keystore in **`CDB$ROOT`**, shared by root + all PDBs | **Per-PDB MEK** (each PDB has its own master key inside the shared keystore) | Default for the fleet. One keystore to back up/manage per CDB, while each PDB still has key isolation. |
| **Isolated** | Each PDB has its **own** keystore + password | Per-PDB, fully independent keystores | Only for special tenancy/regulatory separation where a PDB must be cryptographically self-custodied (e.g. a ring-fenced tenant with its own key custodian). |

**Recommendation: united keystore in `CDB$ROOT` with per-PDB MEKs.** Operate at the root with `CONTAINER=ALL` for fleet-wide operations; each PDB still gets its own master key, giving per-tenant key isolation without multiplying the number of keystores to back up and custody. Reserve **isolated** mode for the rare PDB with a genuine separate-custody requirement — it multiplies operational burden (separate password, separate backup, separate open/close) and should be a deliberate exception, not a default.

To set a per-PDB key while connected to a specific PDB (isolated or united):

```sql
-- connected inside the PDB:
ADMINISTER KEY MANAGEMENT SET ENCRYPTION KEY
  IDENTIFIED BY "<keystore_password>" WITH BACKUP USING 'pdb_mek';
```

## 9. Later migration to OKV

When OKV is licensed and clustered, migration per database is:

1. Install/enroll the OKV **endpoint** on the AIX host (`okvutil` enrollment; `libokvpkcs11` in place under `$WALLET_ROOT/okv/`).
2. Set `TDE_CONFIGURATION = "KEYSTORE_CONFIGURATION=OKV|FILE"` (dynamic).
3. Run the `SET ENCRYPTION KEY ... MIGRATE USING` command from §5.
4. Enable **persistent cache / auto-open** on the endpoint so the DB opens keys unattended and survives transient OKV outages (§4).
5. Verify (`V$ENCRYPTION_WALLET` should show the OKV keystore `OPEN`), then update runbooks/monitoring to the OKV path.

Because §6 conventions are uniform across the fleet, this is a single scripted procedure applied wave-by-wave, mirroring the TDE rollout waves in [04-rollout-plan.md](04-rollout-plan.md).

---
*Cross-references:* [00-overview.md](00-overview.md) (programme context, licensing), [04-rollout-plan.md](04-rollout-plan.md) (TDE enablement runbook, standby wallet sync, verification queries).
