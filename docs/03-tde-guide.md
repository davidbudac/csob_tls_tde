# 03 - Transparent Data Encryption (TDE) Guide

**Scope:** Oracle 19c Enterprise Edition, non-RAC, AIX 7.2 (POWER), ksh. Mixed
non-CDB and CDB/PDB fleet. Physical Data Guard standbys on (almost) every
database. Advanced Security Option (ASO) licensed. **Phase 1** key management =
**local software keystores** using the **WALLET_ROOT** layout, standardized so a
later migration to Oracle Key Vault (OKV) is clean. No TDE deployed today.

This guide is the concept + decision reference. The runnable templates live in
`scripts/tde/*.sql` and `scripts/dg/sync_wallet_to_standby.sh`; each script step
is cross-referenced below.

> **RU-dependent features are flagged explicitly.** Where a 19c capability depends
> on the Release Update level, this guide says so rather than guessing. Validate
> those points on a test DB at your actual RU before relying on them. See the
> **Open validation items** list at the end.

---

## Table of contents

1. [Key architecture concepts](#1-key-architecture-concepts)
2. [Keystore types](#2-keystore-types)
3. [WALLET_ROOT / TDE_CONFIGURATION setup](#3-wallet_root--tde_configuration-setup)
4. [CDB: united vs isolated keystores](#4-cdb-united-vs-isolated-keystores)
5. [Conversion methods — decision matrix](#5-conversion-methods--decision-matrix)
6. [Data Guard specifics](#6-data-guard-specifics)
7. [Performance on AIX / POWER](#7-performance-on-aix--power)
8. [New tablespaces born encrypted](#8-new-tablespaces-born-encrypted)
9. [Aftercare / operations](#9-aftercare--operations)
10. [Encrypting SYSTEM / SYSAUX / UNDO / TEMP](#10-encrypting-system--sysaux--undo--temp)
11. [Gotchas](#11-gotchas)
12. [Loss scenarios](#12-loss-scenarios)
13. [Runbook — end-to-end order of operations](#13-runbook--end-to-end-order-of-operations)
14. [Open validation items](#14-open-validation-items)

---

## 1. Key architecture concepts

TDE uses a **two-tier key hierarchy**:

- **Master Encryption Key (MEK)** — lives *outside* the database, in the
  keystore (software wallet in Phase 1; OKV later). One active MEK per container
  (per PDB in a CDB). The MEK never encrypts data directly.
- **Data encryption keys** — the **tablespace keys** (for tablespace encryption)
  and **table keys** (for column encryption) live *inside* the database, stored
  in the datafile headers / data dictionary. These keys actually encrypt the
  data blocks.
- The **MEK encrypts (wraps) the data keys.** To read encrypted data the DB must
  open the keystore, retrieve the MEK, and unwrap the tablespace/table key.

Consequences that drive everything else:

- **Lose the keystore → lose the data.** No MEK means the wrapped tablespace keys
  cannot be unwrapped. There is no back door. See [§12](#12-loss-scenarios).
- **Rotating the MEK does *not* re-encrypt data.** It only re-wraps the data keys
  with a new MEK. Fast, low-I/O. See [§9](#9-aftercare--operations).
- **Old MEKs must be retained.** Old backups / archived redo are wrapped by the
  MEK that was active then. Never delete keys.

We standardize on **AES256** for tablespace encryption (bank standard).

---

## 2. Keystore types

| Type | File | Opens automatically? | Portable to another host? | Use here |
|------|------|----------------------|---------------------------|----------|
| **Password keystore** | `ewallet.p12` | No — needs `ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY <pwd>` | Yes (it's just the encrypted file) | Source of truth; required for all key ops |
| **Auto-login keystore** | `cwallet.sso` | Yes, at instance start | **Yes** — not host-bound | **Recommended for this DG fleet** |
| **Local auto-login keystore** | `cwallet.sso` (LOCAL flavor) | Yes | **No** — cryptographically bound to the host it was created on | **Avoid** for DG (won't open on standby host) |
| **External keystore (OKV / HSM)** | n/a (network) | Yes (via OKV client) | n/a | **Phase 2** target |

Key points:

- The **auto-login** (`cwallet.sso`) is what lets the instance and the standby
  open the keystore without a human typing the password at every startup.
- **LOCAL auto-login** (`CREATE LOCAL AUTO_LOGIN KEYSTORE`) binds the SSO to the
  host. Copy it to the standby host and it will **not** open there
  (`WALLET_TYPE=LOCAL_AUTOLOGIN`, `STATUS=CLOSED`). **For a Data Guard fleet we
  therefore use the NON-LOCAL auto-login** (`CREATE AUTO_LOGIN KEYSTORE`) so the
  same `cwallet.sso` works on primary and standby. This trades a little security
  (a non-local SSO copied elsewhere can open) for DG operability — mitigate with
  strict file permissions (`600 oracle:oinstall`) and OS-level custody.
- The **password keystore (`ewallet.p12`) is always the master.** The auto-login
  is derived from it and must be re-created after key operations that change the
  password wallet, and re-synced to the standby.

Phase-2 note: with WALLET_ROOT standardized now, moving to OKV later is
`TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=OKV'` (or `OKV|FILE` for a hybrid /
migration window) plus the OKV client under `WALLET_ROOT/okv` — the directory
convention and the DB-side key hierarchy stay the same.

---

## 3. WALLET_ROOT / TDE_CONFIGURATION setup

We use the modern 19c parameter pair and **do not** use the deprecated
`sqlnet.ora` `ENCRYPTION_WALLET_LOCATION`.

| Parameter | Type | Scope | Value (this fleet) |
|-----------|------|-------|--------------------|
| `WALLET_ROOT` | **Static** | `SCOPE=SPFILE` → **restart required** | `/oracle/admin/<ORACLE_SID>/wallet` |
| `TDE_CONFIGURATION` | **Dynamic** | `SCOPE=BOTH` | `KEYSTORE_CONFIGURATION=FILE` |

**Directory layout Oracle expects** (it appends `/tde` itself — do **not** put
`/tde` in the parameter):

```
$WALLET_ROOT/                         = /oracle/admin/<SID>/wallet
$WALLET_ROOT/tde/                     <- software keystore (non-CDB, or united CDB)
    ewallet.p12                       <- password keystore (master)
    cwallet.sso                       <- (non-local) auto-login keystore
$WALLET_ROOT/tde_seps/                <- (optional) SEPS wallet, unrelated to TDE
$WALLET_ROOT/<PDB_GUID>/tde/          <- per-PDB keystore ONLY in ISOLATED mode
$WALLET_ROOT/okv/                     <- (Phase 2) OKV client
```

Order of operations (see `scripts/tde/01_configure_wallet_root.sql`):

1. `ALTER SYSTEM SET WALLET_ROOT='/oracle/admin/<SID>/wallet' SCOPE=SPFILE;`
2. **Restart** the instance (WALLET_ROOT is static).
3. `ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;`
   (dynamic — takes effect immediately).
4. Verify via `V$PARAMETER` and `V$ENCRYPTION_WALLET`.

**Data Guard:** set **both** parameters on the **standby** spfile too (and bounce
it for `WALLET_ROOT`). The standby needs the parameters plus the copied keystore
files; it never runs the key-creation commands.

---

## 4. CDB: united vs isolated keystores

Two models exist for CDBs:

- **United mode (recommended):** one keystore in `CDB$ROOT` under
  `$WALLET_ROOT/tde`, shared by all PDBs, but **each PDB has its own MEK**.
  Keystore lifecycle operations (`OPEN`, `CLOSE`, `CREATE AUTO_LOGIN`) are run
  from the root, typically with `CONTAINER=ALL`. `SET KEY` is done per PDB (or
  `CONTAINER=ALL` to set for root + all open PDBs at once). This is
  **unambiguously supported across all 19c RUs** and is our standard.

- **Isolated mode:** a given PDB gets its **own keystore** under
  `$WALLET_ROOT/<PDB_GUID>/tde` and its **own `TDE_CONFIGURATION`**, managed with
  the PDB's own keystore password independent of the root.

  > **RU caveat — verify at your RU.** Isolated-mode keystores are a 21c feature
  > that was **backported to 19c** on later RUs (the per-PDB `TDE_CONFIGURATION`
  > + `$WALLET_ROOT/<GUID>/tde` mechanics). The exact minimum RU is
  > **not guaranteed the same across all 19.x** — do not assume it exists on
  > older RUs. **If you have any doubt, use united mode**, which is always
  > supported. Flagged in [§14](#14-open-validation-items).

**Recommendation for this fleet: united keystore, per-PDB MEKs.** It is the
simplest correct model, works on every 19c RU, and keeps the DG wallet-sync
story to a single keystore file set.

---

## 5. Conversion methods — decision matrix

Four ways to get existing data encrypted. Pick per DB size, downtime tolerance,
and standby presence.

| # | Method | Downtime | Extra space | Redo generated | DG impact | Best for |
|---|--------|----------|-------------|----------------|-----------|----------|
| 1 | **Online tablespace encryption** (`ALTER TABLESPACE ... ENCRYPTION ONLINE ... ENCRYPT`) | **None** | ≈ largest datafile of the TS (file-by-file) | **≈ full tablespace size** | **High** — big redo → standby transport + apply + archive volume | Most DBs where availability matters and there's free space + redo/archive headroom |
| 2 | **Offline conversion** (`ALTER TABLESPACE ... ENCRYPTION OFFLINE ENCRYPT`; for SYSTEM/SYSAUX/UNDO: datafiles offline / `ALTER DATABASE`) | **Yes** — TS/DB unavailable during convert | **None** (in-place) | **Minimal** | **Low** redo | SYSTEM/SYSAUX/UNDO; and the **on-standby step** of method 3 |
| 3 | **Standby-first conversion** (convert the physical standby offline, switchover, convert former primary) | **Near-zero** (one switchover) | None (offline in-place on each side) | Low per side | Managed: convert while apply is stopped per file | **The recommended near-zero-downtime path for this DG fleet** (MOS 2851392.1 style) |
| 4 | **Data Pump / RMAN rebuild** into pre-created encrypted tablespaces | **Yes** (rebuild window) | Full copy | n/a (fresh load) | Rebuild standby too | Small DBs, or where a reorg/rebuild is wanted anyway |

### 5.1 Online tablespace encryption (method 1)

`ALTER TABLESPACE users ENCRYPTION ONLINE USING 'AES256' ENCRYPT;`

> Omit `FILE_NAME_CONVERT` — Oracle then creates the temporary converted copy
> itself and keeps the datafiles in place, on both OMF and non-OMF databases.
> `FILE_NAME_CONVERT=NONE` fails with **ORA-28437** on OMF (verified on 19.27).
> On non-OMF you may add `FILE_NAME_CONVERT=('/old/','/new/')` to place the
> conversion copy on a different mount.

- No downtime. Oracle rewrites the tablespace **file-by-file** into encrypted
  copies, so you need free space roughly equal to the **largest datafile** being
  converted (not the whole tablespace at once), plus room for the final layout.
- **Generates redo ≈ the full tablespace size.** On a DG fleet this is the main
  planning constraint: archive-log volume spikes and the standby must transport
  and apply all of it. Size archive destinations and network accordingly.
- **Throttle by doing one tablespace at a time**, watching `V$SESSION_LONGOPS`
  and standby apply lag between each. See
  `scripts/tde/03_encrypt_tablespaces_online.sql`.
- **Interruption / resume:** if a conversion is interrupted (crash, abort, out of
  space), resume with the **`FINISH`** clause — it continues rather than
  restarting:
  `ALTER TABLESPACE users ENCRYPTION ONLINE USING 'AES256' FINISH ENCRYPT;`
- Related forms: `... ENCRYPTION ONLINE DECRYPT` to reverse;
  `... ENCRYPTION ONLINE ... ENCRYPT` again to **rekey the tablespace key**.

### 5.2 Offline conversion (method 2)

`ALTER TABLESPACE ... ENCRYPTION OFFLINE ENCRYPT;` (datafiles offline).

- In-place, **no extra space, minimal redo** — but the tablespace is
  **unavailable** during the convert.
- Required path for **SYSTEM / SYSAUX / UNDO** in 19c (they can't be encrypted
  online). See [§10](#10-encrypting-system--sysaux--undo--temp).

### 5.3 Standby-first conversion (method 3 — recommended for this fleet)

The near-zero-downtime pattern for physical standby fleets:

1. **Wallet on both sides first.** Configure WALLET_ROOT/TDE_CONFIGURATION,
   create the keystore + MEK on the primary, and **sync the keystore to the
   standby** (both sides must have the wallet/keys **before** any encryption).
2. **Convert the physical standby offline.** Stop managed recovery (or take the
   relevant datafiles offline per file), run **offline** encryption on the
   standby's datafiles while apply is stopped for those files, then resume apply.
   The standby datafiles become encrypted with no impact to the primary.
3. **Switchover.** The (now encrypted) standby becomes primary; users continue.
4. **Convert the former primary** (now standby) the same offline way.
5. **Switch back (optional).**

Restrictions / cautions:

- **Both sides must hold the wallet and keys before you start.** A standby
  applying redo for an encrypted block without the MEK will stall.
- This is fundamentally an **offline conversion executed on the standby** —
  datafiles are encrypted while managed recovery is stopped for them, so plan the
  per-datafile sequencing and watch the apply gap you accumulate meanwhile.
- Understand the **encrypted-redo / unencrypted-datafile interplay** during the
  transition: once a tablespace is encrypted on the primary side, redo for it is
  encrypted; the standby must already have the key to apply it.
- This method is documented in MOS notes (2851392.1-style "TDE + Data Guard
  standby-first" procedure) — follow the note for your exact RU; sequencing
  details there are authoritative. Flagged in [§14](#14-open-validation-items).

### 5.4 Data Pump / RMAN rebuild (method 4)

Pre-create encrypted tablespaces, then Data Pump import (or RMAN
restore/transport) into them. Good for **small DBs** or where you want a
reorg/rebuild anyway. Remember Data Pump dumps are **not encrypted by default**
(see [§11](#11-gotchas)).

### 5.5 Recommendation logic

- **Small DB, downtime window available** → method 2 (offline) or method 4
  (rebuild), whichever fits ops.
- **Availability-critical DB, redo/archive + free-space headroom OK, standby can
  absorb transport** → method 1 (online), one tablespace at a time.
- **Availability-critical DB where the online redo volume to the standby is
  unacceptable** → **method 3 (standby-first)** — the fleet default for large,
  DG-protected databases.
- SYSTEM/SYSAUX/UNDO are **always** offline (method 2) regardless of the app-data
  approach; schedule them in a maintenance window.

---

## 6. Data Guard specifics

**The wallet must be on the standby *before* any MEK operation on the primary.**
The standby only needs the current keystore *files*; `ADMINISTER KEY MANAGEMENT`
runs on the **primary only**.

Rules:

- **Order:** create/rotate the key on the primary → immediately **re-sync** the
  keystore files (`ewallet.p12` + `cwallet.sso`) to the standby via
  `scripts/dg/sync_wallet_to_standby.sh` → verify on the standby. Every
  `SET KEY` / `SET KEY ... rotate` on the primary changes the wallet, so the
  standby copy goes stale until re-synced.
- **Never** run key-creation/rotation on the standby. It just consumes the files.
- Because we use a **non-local auto-login**, the copied `cwallet.sso` opens on the
  standby with no password — that's the whole reason to avoid LOCAL auto-login.

### Verifying standby health

On the **standby**:

```sql
-- Wallet is open and portable (not LOCAL):
SELECT wrl_type, status, wallet_type, con_id FROM v$encryption_wallet ORDER BY con_id;
-- Expect STATUS=OPEN, WALLET_TYPE=AUTOLOGIN.

-- Managed recovery is applying:
SELECT process, status, thread#, sequence# FROM v$managed_standby WHERE process LIKE 'MRP%';

-- Apply/transport lag is bounded:
SELECT name, value, unit FROM v$dataguard_stats WHERE name IN ('transport lag','apply lag');
```

Also scan the standby **alert log** for keystore / `ORA-28365 (wallet is not
open)` / wallet messages after any key operation.

### Redo volume warning (online conversion)

Method 1 online encryption produces redo **≈ the full size of each tablespace
converted**. On DG that means: (a) a spike in archive-log volume on the primary,
(b) that volume transported over the network, (c) that volume applied on the
standby. **Plan archive destination space and network headroom** before an online
conversion campaign, and pace it one tablespace at a time.

---

## 7. Performance on AIX / POWER

TDE encrypts/decrypts every block on its way to/from disk, so there is CPU and
I/O overhead. Two honest caveats specific to this platform:

- **Hardware crypto acceleration is version/RU-dependent on AIX/POWER.** Oracle's
  well-known optimized AES path uses **x86 AES-NI**. On IBM **POWER**, the CPU has
  had in-core crypto (VMX/VSX crypto, "in-core" AES) since **POWER8**, but whether
  a given Oracle 19c RU actually engages it **for TDE** on AIX is
  release/RU-dependent. **Do not assume free hardware acceleration** — treat
  overhead as real until measured.
- **Measure in a pilot.** Typical steady-state overhead is **single-digit %**, but
  it is **worse for high-I/O batch** (lots of physical reads/writes) and for
  redo-heavy workloads. Before rollout, benchmark **before vs after** on a
  representative DB:
  - batch job **elapsed time**,
  - **redo apply rate** on the standby,
  - **RMAN backup and restore durations**,
  - key OLTP transaction latency.

### Interaction with RMAN and compression

- **Encrypted blocks don't compress well.** Once a tablespace is TDE-encrypted,
  its blocks are high-entropy; **RMAN BASIC compression (and often ACO) gains
  drop sharply** on those blocks. Expect **backup size/time to change** — re-size
  backup storage and windows.
- **Ordering matters:** to keep compression useful, compression must happen
  **before** encryption in the pipeline. RMAN backing up TDE datafile blocks
  copies them **already encrypted on disk** — those blocks stay encrypted in the
  backupset and won't compress. If you also use **RMAN backup encryption**, don't
  double up pointlessly; understand that TDE-tablespace blocks are already
  ciphertext in the backup.
- Re-benchmark backup/restore as part of the pilot (see above).

---

## 8. New tablespaces born encrypted

To ensure tablespaces created after go-live are encrypted automatically:

- **`ENCRYPT_NEW_TABLESPACES` — use this (definitely in 19c).** Set
  `ENCRYPT_NEW_TABLESPACES = ALWAYS` so every newly created tablespace is
  encrypted even when the `CREATE TABLESPACE` statement omits an `ENCRYPTION`
  clause. Values: `DDL` (only if named in DDL — default is `CLOUD_ONLY`),
  `ALWAYS`, `CLOUD_ONLY`. **`ALWAYS` is the fleet standard.**
- **`TABLESPACE_ENCRYPTION` — RU-dependent, verify.** A newer
  `TABLESPACE_ENCRYPTION` init parameter (from 23ai, **reportedly backported to
  19c around 19.16+**) offers finer control (`AUTO_ENABLE` etc.). **Do not rely
  on it unless confirmed at your RU.** On any RU where it isn't present, use
  `ENCRYPT_NEW_TABLESPACES=ALWAYS`, which is always available. Flagged in
  [§14](#14-open-validation-items).

---

## 9. Aftercare / operations

### MEK rotation policy

- Rotate with:
  `ADMINISTER KEY MANAGEMENT SET KEY USING TAG '<sid>_<YYYYMMDD>_rekey' IDENTIFIED BY <pwd> WITH BACKUP USING '<tag>';`
  (`scripts/tde/05_rotate_mek.sql`).
- **What rotation re-encrypts:** only the **key hierarchy** — the new MEK re-wraps
  the existing tablespace/table keys. **It does NOT re-encrypt your data**, so
  it's fast.
- **CDB:** rotate `CONTAINER=ALL` (root + all open PDBs) or loop PDBs for
  per-PDB tags.
- **Cadence:** per bank crypto-period (e.g. annual) and on suspected password
  exposure / personnel change.
- **After every key operation, back up the keystore** (the `WITH BACKUP` clause
  does this in-line; also ensure the wallet is captured in OS backups) **and
  re-sync to the standby** ([§6](#6-data-guard-specifics)).
- **Never delete old keys.** Old backups and archived redo need them.

### Keystore backup

- `WITH BACKUP` on every `SET KEY` creates a timestamped `ewallet_*.p12` backup in
  `WALLET_ROOT/tde`. **Also** back the wallet up **separately from the database
  backups** and store it with different custody (see [§12](#12-loss-scenarios)).

---

## 10. Encrypting SYSTEM / SYSAUX / UNDO / TEMP

**Recommendation: yes, encrypt them for full coverage.** Sensitive data leaks into
SYSTEM (dictionary, histograms), UNDO (before-images of encrypted rows), and TEMP
(sort/hash spills of encrypted data). Encrypting only app tablespaces leaves those
vectors open.

19c mechanics:

- **SYSTEM / SYSAUX:** **offline** encryption. Convert with the datafiles offline
  (`ALTER TABLESPACE ... ENCRYPTION OFFLINE ENCRYPT` for SYSAUX; SYSTEM via the
  offline datafile path). Schedule in a maintenance window (DB or tablespace
  unavailable during the convert).
- **UNDO:** in 19c the safe, universally-supported approach is **offline
  conversion** of the UNDO tablespace, **or** the clean **recreate-and-swap**:
  create a new (encrypted) UNDO tablespace, switch `UNDO_TABLESPACE` to it, drop
  the old one once no active undo remains. The recreate approach avoids offline
  fiddling with active undo and is the safest for this fleet.
  > RU caveat: whether online UNDO encryption is offered varies; **prefer the
  > recreate-and-swap** so you don't depend on it. Flagged in
  > [§14](#14-open-validation-items).
- **TEMP:** TEMP **cannot be encrypted in place** — **create a new encrypted
  temporary tablespace and swap**: `CREATE TEMPORARY TABLESPACE temp_enc ...
  ENCRYPTION ENCRYPT;` (or born-encrypted via `ENCRYPT_NEW_TABLESPACES=ALWAYS`),
  make it the default temp tablespace, then drop the old TEMP once no sessions
  use it.

Do all of these **after** the wallet + MEK exist and the standby is synced, and
account for the DG interplay (offline SYSTEM/SYSAUX convert must be coordinated
with the standby — standby-first or a maintenance window).

---

## 11. Gotchas

| Area | Gotcha | Action |
|------|--------|--------|
| **BFILEs / external tables** | Data stored **outside** the DB (OS files) is **NOT** covered by TDE | Encrypt at the filesystem/storage layer separately |
| **Clone / DUPLICATE** | `RMAN DUPLICATE` / full-DB clone of an encrypted DB **needs the wallet** at the target | Provision the keystore on the clone target first |
| **Transportable tablespaces** | Moving an encrypted TS requires exporting/importing the keys | Use `ADMINISTER KEY MANAGEMENT EXPORT/IMPORT KEYS` and move the keystore |
| **Plugging encrypted PDBs** | A plugged-in encrypted PDB needs its **key imported** into the target CDB's keystore | `ADMINISTER KEY MANAGEMENT EXPORT KEYS ... FOR <pdb>` on source; `IMPORT KEYS` on target (or unplug/plug with key file) |
| **GoldenGate integrated extract** | Integrated extract reads redo and **needs wallet access** to decrypt | Ensure the keystore is open where extract runs |
| **Data Pump export** | `expdp` dumps are **NOT encrypted by default** | Use `ENCRYPTION=ALL` / `ENCRYPTION_ALGORITHM` / `ENCRYPTION_MODE` (or `ENCRYPTION_PASSWORD`) on `expdp` |
| **Flashback / restore across key rotations** | Restoring old backups / flashing back across a rotation needs the **MEK that was active then** | **Never delete old keys**; keep all historical keys in the keystore |
| **Standby wallet currency** | Any key op on primary makes the standby copy stale | Re-sync after **every** key op ([§6](#6-data-guard-specifics)) |
| **LOCAL auto-login on DG** | `LOCAL_AUTOLOGIN` SSO won't open on the standby host | Use **non-local** `CREATE AUTO_LOGIN KEYSTORE` |

---

## 12. Loss scenarios

| Scenario | Result | Prevention |
|----------|--------|------------|
| **Lost keystore (all copies)** | **Total, unrecoverable data loss** — encrypted datafiles/backups cannot be opened | Back up the wallet after every key op; keep multiple copies with separate custody |
| **Lost keystore, but a backup exists** | Recoverable — restore `ewallet.p12` (+ recreate auto-login), re-open | Regular, verified wallet backups |
| **Deleted an old MEK, then restored an old backup** | That old backup is unreadable | **Never delete keys**; keep all historical MEKs |
| **Wallet backed up *with* the DB backup, both stored together** | An attacker with the backup tape has key **and** ciphertext → encryption defeated | **Store the wallet backup separately** from DB backups, different medium/custody |
| **Forgot keystore password (no auto-login issue yet)** | Cannot do key ops / cannot recreate auto-login | Escrow the password in the bank vault |

**Custody rules:** the keystore backup must be (1) taken after every key
operation, (2) stored **separately** from database backups, and (3) access-
controlled independently. The whole security value of TDE collapses if key and
ciphertext live together.

---

## 13. Runbook — end-to-end order of operations

Per database (non-CDB, or CDB from `CDB$ROOT`):

1. **OS prep** (as `oracle:oinstall`): `mkdir -p /oracle/admin/<SID>/wallet/tde`;
   `chmod 700`. Do the same on the **standby** host.
2. **`01_configure_wallet_root.sql`** — set `WALLET_ROOT` (spfile) on **primary
   and standby**, restart both, then set `TDE_CONFIGURATION=FILE` on both.
3. **`02_create_keystore_and_mek.sql`** (primary) — create password keystore,
   open, `SET KEY` (first MEK, `WITH BACKUP`, tag `<sid>_<date>`), create
   **non-local** auto-login.
4. **`scripts/dg/sync_wallet_to_standby.sh`** — copy `ewallet.p12` + `cwallet.sso`
   to the standby; verify `V$ENCRYPTION_WALLET` (`OPEN` / `AUTOLOGIN`) + MRP.
5. **`04_verify_tde.sql`** on both — baseline status report.
6. **Encrypt data** — choose method per [§5](#5-conversion-methods--decision-matrix):
   - Online (method 1): `03_encrypt_tablespaces_online.sql` generates the
     statements; run one TS at a time; watch `V$SESSION_LONGOPS` + standby lag.
   - Standby-first (method 3) for large DBs; SYSTEM/SYSAUX/UNDO offline (method 2)
     + TEMP recreate ([§10](#10-encrypting-system--sysaux--undo--temp)).
7. **New tablespaces** — set `ENCRYPT_NEW_TABLESPACES=ALWAYS`
   ([§8](#8-new-tablespaces-born-encrypted)).
8. **Re-verify** with `04_verify_tde.sql` on primary and standby.
9. **Operations** — rotate per policy (`05_rotate_mek.sql`), **always** re-sync
   the wallet to the standby afterward, back up the wallet separately, never
   delete keys.

---

## 14. Open validation items

### Verified live on 19c (19.27, Linux CDB test instance, 2026-07-07)

The full script chain (`01` → `02` → online encrypt → `04` → `05`) was executed
end-to-end on a 19.27 CDB with one PDB. Confirmed:

- `WALLET_ROOT` (spfile + restart) / `TDE_CONFIGURATION` (dynamic) flow works as
  scripted; keystore lands in `$WALLET_ROOT/tde`.
- United keystore + per-PDB MEKs with `CONTAINER=ALL` open works;
  `V$ENCRYPTION_WALLET.KEYSTORE_MODE` shows `NONE` for `CDB$ROOT` and `UNITED`
  for PDBs — that's normal, not an error.
- `ALTER TABLESPACE ... ENCRYPTION ONLINE USING 'AES256' ENCRYPT` (no
  `FILE_NAME_CONVERT`) works; `FILE_NAME_CONVERT=NONE` fails on OMF (ORA-28437).
- **Non-local auto-login** keystore opens `STATUS=OPEN` / `WALLET_TYPE=AUTOLOGIN`
  in all containers after an instance restart.
- **`CONTAINER=ALL` MEK rotation works but creates the new keys with an EMPTY
  tag** — use the per-PDB loop (or retag with `ADMINISTER KEY MANAGEMENT SET
  TAG`) if tagged keys are required for audit.
- `TABLESPACE_ENCRYPTION` **exists on 19.27** (default `MANUAL_ENABLE`);
  `ENCRYPT_NEW_TABLESPACES` default is `CLOUD_ONLY`.
- `V$ENCRYPTION_KEYS` (`CREATOR_PDBNAME`, `ACTIVATION_TIME`),
  `V$ENCRYPTED_TABLESPACES` (`ENCRYPTIONALG`, `STATUS`) and the
  `CDB_TABLESPACES` joins in `04_verify_tde.sql` are all valid on 19.27.

### Still open — validate at the fleet's actual RU / on AIX

1. **Isolated-mode PDB keystores in 19c** — confirm the minimum RU at which
   per-PDB `TDE_CONFIGURATION` + `$WALLET_ROOT/<GUID>/tde` isolated keystores are
   supported. **Default to united mode** unless confirmed. ([§4](#4-cdb-united-vs-isolated-keystores))
2. **AIX/POWER hardware crypto acceleration for TDE** — confirm by benchmark
   whether your RU engages POWER in-core AES for TDE; don't assume. Measure
   overhead in a pilot. ([§7](#7-performance-on-aix--power))
3. **UNDO encryption path** — confirm whether online UNDO encryption is offered at
   your RU; **prefer the recreate-and-swap** approach regardless. ([§10](#10-encrypting-system--sysaux--undo--temp))
4. **Standby-first conversion exact sequencing** — follow the current MOS note
   (2851392.1-style) for your RU; per-datafile offline steps and the
   redo/key ordering details are the authoritative source. ([§5.3](#53-standby-first-conversion-method-3--recommended-for-this-fleet))
5. **Non-local auto-login open on a copied-to standby host** — auto-open after a
   bounce is verified (above); confirm on a real DG pair that the copied
   `cwallet.sso` also opens on the **standby host without** a bounce.
   ([§6](#6-data-guard-specifics))
