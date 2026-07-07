#!/usr/bin/ksh
#-------------------------------------------------------------------------------
# sync_wallet_to_standby.sh
#-------------------------------------------------------------------------------
# Purpose : Copy the TDE keystore files (ewallet.p12 + cwallet.sso) from the
#           PRIMARY host's WALLET_ROOT/tde to the PHYSICAL STANDBY host, taking a
#           timestamped backup of the standby's existing wallet first, and fixing
#           ownership/permissions on the standby side.
#
# Platform: AIX 7.2 (POWER), Korn shell. NO bash-isms, NO GNU-only flags.
#           Uses ssh/scp (OpenSSH on AIX). Assumes key-based oracle->oracle SSH
#           from primary to standby (or configure per site).
#
# WHEN TO RUN (critical for Data Guard correctness):
#   * BEFORE the first MEK is set on the primary is NOT possible (files don't
#     exist yet) -> the real rule is: run IMMEDIATELY AFTER the keystore + first
#     MEK are created (script 02), and AFTER EVERY key operation on the primary:
#       - after CREATE KEYSTORE + SET KEY + CREATE AUTO_LOGIN (script 02)
#       - after EVERY MEK rotation / SET KEY (script 05)
#       - after any ADMINISTER KEY MANAGEMENT that changes ewallet.p12/cwallet.sso
#   The standby must always hold a keystore current enough to decrypt the redo it
#   is applying. A stale standby wallet stalls redo apply.
#
# Pre-reqs: - WALLET_ROOT set + TDE_CONFIGURATION=FILE on BOTH hosts (script 01).
#           - Standby directory WALLET_ROOT/tde exists (create it first if not).
#           - Non-LOCAL auto-login keystore on primary (cwallet.sso is portable).
#             A LOCAL auto-login (LOCAL_AUTOLOGIN) will NOT open on the standby.
#
# Usage   : ./sync_wallet_to_standby.sh <STANDBY_HOST> <WALLET_ROOT>
#   e.g.    ./sync_wallet_to_standby.sh stbyhost01 /oracle/admin/FINP1/wallet
#           (WALLET_ROOT is the SAME literal path on both hosts by convention;
#            /tde is appended here.)
#
# Exit    : 0 = success, non-zero = failure (safe to re-run; it re-backs-up).
#-------------------------------------------------------------------------------

set -u

#--- configurable defaults ------------------------------------------------------
SSH_USER="oracle"                 # remote user on the standby
OWNER="oracle:oinstall"           # required owner:group on standby
FILE_PERM="600"                   # required perms on keystore files
DIR_PERM="700"                    # required perms on the tde directory
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no"
SCP="scp -p -o BatchMode=yes -o StrictHostKeyChecking=no"
TS=`date +%Y%m%d_%H%M%S`

#--- args -----------------------------------------------------------------------
if [ $# -ne 2 ]; then
    print -u2 "Usage: $0 <STANDBY_HOST> <WALLET_ROOT>"
    print -u2 "  e.g. $0 stbyhost01 /oracle/admin/FINP1/wallet"
    exit 2
fi

STANDBY_HOST=$1
WALLET_ROOT=$2
TDE_DIR="${WALLET_ROOT}/tde"
REMOTE="${SSH_USER}@${STANDBY_HOST}"

print "==============================================================="
print " sync_wallet_to_standby.sh  ($TS)"
print "   Primary tde dir : ${TDE_DIR}"
print "   Standby host    : ${STANDBY_HOST}"
print "   Standby tde dir : ${TDE_DIR}"
print "==============================================================="

#--- 1) validate local source files --------------------------------------------
P12="${TDE_DIR}/ewallet.p12"
SSO="${TDE_DIR}/cwallet.sso"

if [ ! -f "${P12}" ]; then
    print -u2 "ERROR: password keystore not found: ${P12}"
    exit 3
fi
if [ ! -f "${SSO}" ]; then
    print -u2 "WARNING: auto-login keystore not found: ${SSO}"
    print -u2 "         Continuing with ewallet.p12 only. The standby will then"
    print -u2 "         need a manual OPEN, or create a NON-LOCAL auto-login first."
fi

#--- 2) verify SSH connectivity to standby -------------------------------------
print "-- Checking SSH connectivity to ${REMOTE} ..."
${SSH} "${REMOTE}" "echo ok" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    print -u2 "ERROR: cannot ssh to ${REMOTE} (BatchMode). Fix key-based auth."
    exit 4
fi

#--- 3) ensure remote tde dir exists with correct perms ------------------------
print "-- Ensuring remote directory ${TDE_DIR} exists ..."
${SSH} "${REMOTE}" "mkdir -p '${TDE_DIR}' && chmod ${DIR_PERM} '${TDE_DIR}'"
if [ $? -ne 0 ]; then
    print -u2 "ERROR: could not create/prepare remote ${TDE_DIR}"
    exit 5
fi

#--- 4) back up existing standby wallet (timestamped) --------------------------
BKP_DIR="${TDE_DIR}/backup_${TS}"
print "-- Backing up existing standby wallet to ${BKP_DIR} (if any) ..."
${SSH} "${REMOTE}" "
    set -u
    mkdir -p '${BKP_DIR}' && chmod ${DIR_PERM} '${BKP_DIR}'
    for f in ewallet.p12 cwallet.sso ; do
        if [ -f '${TDE_DIR}/'\$f ]; then
            cp -p '${TDE_DIR}/'\$f '${BKP_DIR}/'\$f && \
            print '   backed up '\$f
        fi
    done
"
if [ $? -ne 0 ]; then
    print -u2 "ERROR: standby-side backup step failed. Aborting BEFORE overwrite."
    exit 6
fi

#--- 5) copy the keystore files to the standby ---------------------------------
print "-- Copying ewallet.p12 to standby ..."
${SCP} "${P12}" "${REMOTE}:${TDE_DIR}/ewallet.p12"
if [ $? -ne 0 ]; then
    print -u2 "ERROR: scp of ewallet.p12 failed."
    exit 7
fi

if [ -f "${SSO}" ]; then
    print "-- Copying cwallet.sso to standby ..."
    ${SCP} "${SSO}" "${REMOTE}:${TDE_DIR}/cwallet.sso"
    if [ $? -ne 0 ]; then
        print -u2 "ERROR: scp of cwallet.sso failed."
        exit 8
    fi
fi

#--- 6) fix ownership + permissions on the standby -----------------------------
print "-- Fixing ownership (${OWNER}) and perms (${FILE_PERM}) on standby ..."
${SSH} "${REMOTE}" "
    chown ${OWNER} '${TDE_DIR}/ewallet.p12' 2>/dev/null
    chmod ${FILE_PERM} '${TDE_DIR}/ewallet.p12'
    if [ -f '${TDE_DIR}/cwallet.sso' ]; then
        chown ${OWNER} '${TDE_DIR}/cwallet.sso' 2>/dev/null
        chmod ${FILE_PERM} '${TDE_DIR}/cwallet.sso'
    fi
"
if [ $? -ne 0 ]; then
    print -u2 "WARNING: chown/chmod on standby returned non-zero."
    print -u2 "         chown may require appropriate privilege; verify manually."
fi

#--- 7) show resulting standby listing -----------------------------------------
print "-- Resulting standby ${TDE_DIR} contents:"
${SSH} "${REMOTE}" "ls -l '${TDE_DIR}'"

print ""
print "==============================================================="
print " COPY COMPLETE."
print ""
print " POST-COPY VERIFICATION (run ON THE STANDBY as the oracle user):"
print ""
print "   sqlplus / as sysdba"
print "     SELECT wrl_type, status, wallet_type, con_id"
print "       FROM v\$encryption_wallet ORDER BY con_id;"
print "     -- Expect: WALLET_TYPE=AUTOLOGIN, STATUS=OPEN."
print "     -- If STATUS=CLOSED with a non-local auto-login present, the DB may"
print "     --   need a bounce or an explicit re-read; check the alert log."
print ""
print "   Confirm redo apply is healthy:"
print "     SELECT process, status, thread#, sequence#"
print "       FROM v\$managed_standby WHERE process LIKE 'MRP%';"
print "     SELECT name, value FROM v\$dataguard_stats"
print "       WHERE name IN ('transport lag','apply lag');"
print ""
print "   Also scan the standby alert log for keystore / ORA-28365 / wallet msgs."
print "==============================================================="

exit 0
