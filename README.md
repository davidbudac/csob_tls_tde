# TLS & TDE Introduction — Oracle 19c EE Fleet (AIX 7.2, non-RAC)

Guide + script templates for introducing SQL*Net TLS (TCPS) and Transparent Data
Encryption across a large fleet of Oracle 19c EE databases on AIX 7.2/POWER —
mixed non-CDB and CDB/PDB, Data Guard physical standbys, Java/JDBC-thin +
legacy OCI + APEX/ORDS application stack, internal enterprise CA, ASO licensed.

## Documents (read in order)

| Doc | Contents |
|-----|----------|
| [docs/00-overview.md](docs/00-overview.md) | Program goals, "why encryption in plain terms" primer, drivers (DORA/PCI), two independent tracks, ANO interim option, licensing, wave model |
| [docs/01-key-management-decision.md](docs/01-key-management-decision.md) | OKV/HSM vs local software keystores; decided conventions (`WALLET_ROOT`, layout, backup, custody) |
| [docs/02-tls-guide.md](docs/02-tls-guide.md) | Gentle TLS intro for DBAs new to it, then the TLS runbook: wallets, CSR workflow, listener/sqlnet, JDBC/OCI/ORDS clients, DB links, DG redo transport, rotation, troubleshooting |
| [docs/03-tde-guide.md](docs/03-tde-guide.md) | Gentle TDE intro for DBAs new to it, then TDE detail: concepts, conversion decision matrix (online/offline/standby-first/rebuild), DG specifics, AIX/POWER performance, aftercare |
| [docs/04-rollout-plan.md](docs/04-rollout-plan.md) · [visual version](docs/rollout-plan.html) | Execution plan: phases 0–6 with gates, roles, pilot measurements, per-DB runbooks A (TLS) / B (TDE) step-by-step with scripts, app coordination, rollback, monitoring, acceptance criteria, risk register, fact-check log |
| [docs/05-faq.md](docs/05-faq.md) | DBA FAQ (TLS & TDE): common questions answered against this fleet's decisions, 19c-verified gotchas flagged |

## Scripts

- `scripts/tls/` — TLS wallet + CSR (`01`), listener/sqlnet/tns fragments (`02`), TCPS verification (`03` .sql/.sh), cleartext-session report from the listener log (`04`)
- `scripts/tde/` — `WALLET_ROOT` config (`01`), keystore + MEK (`02`), online tablespace encryption generator (`03`), status report (`04`), MEK rotation (`05`), born-encrypted policy for new tablespaces (`06`)
- `scripts/preflight/` — read-only readiness checks per DB/host: DB inventory + TDE method hint (`01` .sql), host preflight (`02` .sh)
- `scripts/dg/` — TDE keystore sync primary → standby

Shell scripts are ksh, AIX-safe (no bash-isms, no GNU-only flags).

## Validation status

The TDE SQL chain (01 → 02 → online encrypt → 04 → 05) and the TLS wallet
script + TCPS listener/sqlnet config + verify SQL were executed end-to-end on a
19.27 Linux CDB test instance (2026-07-07); the **fleet itself runs 19.30**.
Remaining AIX-specific items to confirm on the real fleet are listed in
[docs/03-tde-guide.md §14](docs/03-tde-guide.md#14-open-validation-items).
Key verified facts: `FILE_NAME_CONVERT=NONE` fails on OMF (omit the clause);
the DB's **sqlnet.ora** needs `WALLET_LOCATION` for TCPS (listener.ora alone →
ORA-28865); sqlnet.ora supports only one `WALLET_LOCATION` (SEPS conflict);
`CONTAINER=ALL` MEK rotation creates untagged keys.
