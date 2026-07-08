# 05 — DBA FAQ (TLS & TDE)

**Scope:** Oracle 19c EE (**fleet RU 19.30**), non-RAC, AIX 7.2 / POWER, mixed CDB +
non-CDB, physical Data Guard on almost every DB. The questions a hands-on DBA actually
asks on each track, answered against **this fleet's decisions** — not generic Oracle
advice. Gotchas flagged **✓ verified** were confirmed live on the **19.27 CDB test
box** (dbmint, 2026-07-07); the fleet itself runs 19.30, so those behaviours hold or
improve.

Deep detail lives in the track guides:
[TLS](02-tls-guide.md) · [TDE](03-tde-guide.md) · [key-management decision](01-key-management-decision.md).
The presentation carries a curated 6-per-section subset on its FAQ slides; this
file is the complete set.

---

## Track A — TLS / TCPS (data in transit)

### Setup & architecture

**1. Do I have to take an outage to add TLS?**
No. It's dual-port coexistence — the same listener serves TCP 1526 *and* TCPS 1527
at once. A full `lsnrctl stop/start` is needed only to **add** the 1527 endpoint
(a `reload` won't pick up a new `ADDRESS`); clients keep working on 1526 throughout.
See [TLS §1, §4.1](02-tls-guide.md#1-concepts--decisions).

**2. Is this mutual TLS? Do clients need certificates?**
No — one-way, **server-auth only** (`SSL_CLIENT_AUTHENTICATION=FALSE`). Clients only
need the CSOB CA chain in a truststore to validate the server. No client keys
anywhere. Mutual-TLS is explicitly out of scope.

**3. Where does the TLS wallet live, and can it share the TDE keystore?**
`/oracle/admin/$ORACLE_SID/wallet_tls`, and **never** shared with the TDE keystore —
separate directories, separate rotation lifecycles. See [TLS §2](02-tls-guide.md#2-wallet-strategy).

**4. Auto-login or password wallet?**
Auto-login (`cwallet.sso`) so the listener/DB start unattended. Use plain
`-auto_login`, **not** `-auto_login_local` (the local flavor is host-bound and won't
open after a DR/hostname move). Keep the PKCS#12 password in the vault for cert
imports.

**5. TLS 1.2 or 1.3?**
Default `SSL_VERSION=1.2`. Native 1.3 in the DB stack landed ~**19.23+**, so the
fleet's **19.30 server side supports 1.3** — the remaining gate is client-driver
support (many JDBC-thin/OCI stacks still negotiate 1.2). Keep 1.2 as the safe
default; move to `1.2 or 1.3` per service once you've validated the client drivers.

### The gotchas that will actually bite

**6. Handshake succeeds but I get ORA-28865 right after — why?** ✓ verified
The wallet is only in `listener.ora`. The spawned dedicated **server process
re-reads `sqlnet.ora`**, so `WALLET_LOCATION` is *mandatory in sqlnet.ora too*
(or in sqlnet.ora only, which the listener also reads). See [TLS §4.2](02-tls-guide.md#42-sqlnetora--server-side).

**7. We already use SEPS / `WALLET_OVERRIDE=TRUE` — will adding TLS break it?** ✓ verified
Yes, silently. `sqlnet.ora` supports **one** `WALLET_LOCATION`; appending a second
breaks one of them. **Merge** the CA trust into the existing wallet — don't append.
Pre-flight the fleet with `grep -c WALLET_LOCATION sqlnet.ora`.

**8. My orapki CSR has no SANs — is that a problem?**
19c `orapki` generally omits SANs, and CN-only matching fails from some clients.
Have the **CA template** stamp `CN=FQDN + DNS SANs`, or build the CSR with `openssl`.
See [TLS §3.3](02-tls-guide.md#33-san-caveat-important).

**9. DN-match keeps failing from some apps.**
Always set `ssl_server_dn_match=true` **explicitly** (12.2/18c/19c thin default to
*false*), and make the connect-string host equal the cert **CN and a SAN**.
Short-name connect strings fail unless the short name is also a SAN.

### Clients, DB links, Data Guard

**10. What do JDBC-thin apps need?**
Preferably just a **JKS/PKCS12 truststore** with the CSOB root + intermediate and a
`tcps://…:1527/…?ssl_server_dn_match=true` URL — no Oracle wallet, no
`oraclepki`/`osdt` jars. Those jars are only needed if an app insists on reusing an
Oracle wallet. See [TLS §7](02-tls-guide.md#7-client-jdbc-thin).

**11. Do DB links need extra trust config?**
Usually no — the calling DB is the TLS client, and its existing TLS wallet already
trusts peers because both certs come from the same CSOB CA. Just repoint the link
descriptor to `PROTOCOL=TCPS`, port 1527. See [TLS §10](02-tls-guide.md#10-db-links-over-tcps).

**12. Does Data Guard redo transport need mutual TLS?**
No. Redo auth is still password-file based (`REDO_TRANSPORT_USER`); server-auth TLS +
password file is the supported combo. Add **static registration** so the standby's
1527 endpoint is reachable while only `MOUNTED` / during role changes. See [TLS §11](02-tls-guide.md#11-data-guard-redo-transport-over-tcps).

### Operations

**13. Is certificate renewal an outage?**
No, for the listener — import the renewed cert into the same wallet and
`lsnrctl reload`; existing sessions are untouched, new ones get the new cert. Start
at **T-60**; alert at **T-45/30/14**. Watch **intermediate/root** expiry too — chain
expiry breaks handshakes even with a valid leaf. See [TLS §12](02-tls-guide.md#12-certificate-rotation--monitoring).

**14. Should I also turn on native (ANO) encryption?**
Not on TCPS — that **double-encrypts** (wasted CPU). ANO is the *interim* control on
the surviving 1526 port while TLS lands; the TCPS end-state relies on TLS alone
(`ENCRYPTION_SERVER=ACCEPTED/REJECTED`). See [TLS §5](02-tls-guide.md#5-tls-vs-native-encryption-ano-interaction).

**15. When can I close 1526?**
Only after monitoring shows **zero** legitimate 1526 traffic from production apps —
then remove the endpoint and restart the listener. See [TLS §14](02-tls-guide.md#14-cutover-checklist).

---

## Track B — TDE (data at rest)

### Keys & architecture

**1. What actually happens if I lose the keystore?**
**Total, unrecoverable data loss** — no MEK means the wrapped tablespace keys can't
be unwrapped, no back door. Wallet backup + separate custody is the highest-stakes
part of the whole programme. See [TDE §12](03-tde-guide.md#12-loss-scenarios).

**2. Does rotating the master key re-encrypt my data?**
No — `SET KEY` only **re-wraps** the existing tablespace/table keys with a new MEK.
Fast, low-I/O. And **never delete old MEKs** — old backups and archived redo still
need them.

**3. Are we using `sqlnet.ora ENCRYPTION_WALLET_LOCATION`?**
No — the modern pair: `WALLET_ROOT` (static, needs restart) +
`TDE_CONFIGURATION=KEYSTORE_CONFIGURATION=FILE` (dynamic). Oracle appends `/tde`
itself — don't put `/tde` in the parameter. See [TDE §3](03-tde-guide.md#3-wallet_root--tde_configuration-setup).

**4. Auto-login on a Data Guard fleet — which flavor?**
Non-local `CREATE AUTO_LOGIN KEYSTORE`. A *local* auto-login
(`WALLET_TYPE=LOCAL_AUTOLOGIN`) is host-bound and **won't open on the standby**.
Non-local trades a little security for DG operability — mitigate with `600`/`700`
perms. See [TDE §2](03-tde-guide.md#2-keystore-types).

### Multitenant (united vs isolated)

**5. United or isolated keystore?**
**United** — one keystore in `CDB$ROOT`, **each PDB still gets its own MEK**.
Supported on every 19c RU and keeps DG wallet-sync to a single file set. Isolated
only for a specific PDB that genuinely needs its own keystore password/type. See
[TDE §4](03-tde-guide.md#4-cdb-united-vs-isolated-keystores).

**6. Can I actually switch a PDB to isolated later, and does it work on our RU?** ✓ verified
Yes — `ADMINISTER KEY MANAGEMENT FORCE ISOLATE KEYSTORE …` (and `UNITE KEYSTORE` to
reverse). Isolated mode is on-prem from **19.11** (patch 32235513 on 19.11–19.13;
included from 19.14), so the fleet's **19.30 ships it natively — no patch**. The
round-trip was **verified live on the 19.27 test box**.

**7. Any catch with isolated mode?** ✓ verified
Two: the isolated keystore is created as a **password wallet with no auto-login**
(you must build a separate `cwallet.sso` and sync it to the standby, or the PDB
won't auto-open), and `UNITE` **leaves the old `<GUID>/tde` keystore dir orphaned on
disk** — remove it manually. Also, AutoUpgrade / OCI tooling don't fully support
isolated mode. See [TDE §4.1](03-tde-guide.md#41-verifying-and-switching-modes).

### Converting existing data

**8. How do I encrypt existing tablespaces with minimal downtime?**
Four methods: **online** (no downtime, redo ≈ full tablespace size), **offline**
(downtime, minimal redo), **standby-first** (near-zero downtime — the fleet default
for large DG DBs), and **Data Pump/RMAN rebuild**. Pick per DB size, downtime
tolerance, and standby. See [TDE §5](03-tde-guide.md#5-conversion-methods--decision-matrix).

**9. `FILE_NAME_CONVERT=NONE` throws ORA-28437 — what gives?** ✓ verified
On OMF, **omit `FILE_NAME_CONVERT` entirely** — Oracle makes the converted copy
itself. `NONE` fails on OMF. On non-OMF you can pass `('/old/','/new/')` to land the
copy on another mount.

**10. A conversion got interrupted — do I start over?**
No — resume with the **`FINISH`** clause
(`… ENCRYPTION ONLINE USING 'AES256' FINISH ENCRYPT`).

**11. What's the Data Guard impact of online encryption?**
Redo **≈ the full size of each tablespace** — spikes archive volume, transport, and
standby apply. Pace **one tablespace at a time**, watch `V$SESSION_LONGOPS` + standby
lag, and size archive/network first. See [TDE §6](03-tde-guide.md#6-data-guard-specifics).

**12. Do I encrypt SYSTEM/SYSAUX/UNDO/TEMP too?**
Yes for full coverage (sensitive data leaks into all of them). SYSTEM/SYSAUX/UNDO are
**offline** paths; for UNDO/TEMP prefer **recreate-and-swap** rather than in-place.
See [TDE §10](03-tde-guide.md#10-encrypting-system--sysaux--undo--temp).

### Operations & platform

**13. Standby wallet handling — what's the golden rule?**
The wallet must be on the standby *before* any MEK op on the primary. Run all
`ADMINISTER KEY MANAGEMENT` on the **primary only**, then immediately re-sync
`ewallet.p12` + `cwallet.sso` to the standby after **every** key op.

**14. `CONTAINER=ALL` rotation left my new keys untagged — bug?** ✓ verified
No, that's expected on 19.27 — a `CONTAINER=ALL` `SET KEY` creates keys with an
**empty tag**. Loop per-PDB (or `SET TAG` afterward) if you need tagged keys for
audit.

**15. Do I get free hardware crypto acceleration on AIX/POWER?**
**Don't assume it.** Oracle's well-known optimized path is x86 AES-NI; whether a
given 19c RU engages POWER in-core AES for TDE is RU-dependent. **Benchmark**
before/after in the pilot (batch elapsed, standby apply rate, RMAN duration, OLTP
latency). See [TDE §7](03-tde-guide.md#7-performance-on-aix--power).

**16. Will TDE hurt my RMAN backup sizes?**
Yes — encrypted blocks are high-entropy and **don't compress**. RMAN copies them
already-encrypted, so compression gains drop sharply. Re-size backup storage/windows,
and don't double up with RMAN backup encryption pointlessly.

**17. New tablespaces after go-live — encrypted automatically?**
Set `ENCRYPT_NEW_TABLESPACES=ALWAYS` (default is `CLOUD_ONLY`) — the fleet standard.
The newer `TABLESPACE_ENCRYPTION` param is present on the fleet's 19.30 (finer-grained
control), but `ENCRYPT_NEW_TABLESPACES=ALWAYS` stays the universal standard.
See [TDE §8](03-tde-guide.md#8-new-tablespaces-born-encrypted).

**18. Data Pump / clones — anything I'll forget?**
`expdp` dumps are **not** encrypted by default (use `ENCRYPTION=ALL`); RMAN
`DUPLICATE`/clones need the wallet provisioned at the target first; transportable
tablespaces and plugged encrypted PDBs need `EXPORT/IMPORT KEYS`. See [TDE §11](03-tde-guide.md#11-gotchas).
