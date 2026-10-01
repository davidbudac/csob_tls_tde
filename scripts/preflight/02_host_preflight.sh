#!/usr/bin/ksh
#==============================================================================
# 02_host_preflight.sh
#------------------------------------------------------------------------------
# Purpose : READ-ONLY host readiness check for the TLS + TDE rollout. Run as the
#           oracle OS user on EACH DB host (primary and standby) BEFORE the wave
#           starts. Prints PASS / WARN / FAIL lines and a summary count. It
#           changes nothing: no file is written (except a tiny temp file in /tmp
#           for the optional standby probe, removed on exit).
#
# Checks  : ORACLE_HOME; orapki + openssl present; OPatch RU (lspatches);
#           TNS_ADMIN resolution; sqlnet.ora WALLET_LOCATION count (>1 = FAIL,
#           1 = SEPS merge needed); SQLNET.WALLET_OVERRIDE (SEPS in use);
#           SQLNET.ENCRYPTION_SERVER; deprecated ENCRYPTION_WALLET_LOCATION;
#           listener endpoints (PROTOCOL= lines); TDE wallet + TLS wallet dirs
#           and permissions; free space on datafile mount(s); optional TCPS
#           reachability to the standby on port 1527.
#           See 02-tls-guide.md 4.2 (SEPS conflict) and 6, 03-tde-guide.md 5/7.
#
# Environment / assumptions:
#   * Oracle 19c EE (RU 19.30), non-RAC, AIX 7.2, ksh.
#   * NO bash-isms, NO GNU-only flags (no grep -P, sed -i, readlink -f, date -d,
#     hostname -f, find -printf, stat -c). POSIX grep/awk/sed only.
#   * Exit code is ALWAYS 0 -- this is a report, not a gate. Read the summary.
#
# Variables (export before running):
#   ORACLE_SID     - [required] used for /oracle/admin/$ORACLE_SID/wallet{,_tls}
#   ORACLE_HOME    - [required] must be set in the environment
#   STANDBY_HOST   - optional; if set, probe TCPS handshake on STANDBY_HOST:1527
#   DATA_MOUNTS    - optional, space-separated mount points / paths holding
#                    datafiles (free space is reported with df -g, df -k fallback)
#   LISTENER_NAME  - listener to query with lsnrctl (default LISTENER)
#   TLS_PORT       - TCPS port (default 1527)
#   MIN_FREE_GB    - WARN threshold for DATA_MOUNTS free space (default 20).
#                    Online TDE conversion needs free space ~= largest datafile.
#
# Usage:
#   ORACLE_SID=db01 ./02_host_preflight.sh
#   ORACLE_SID=db01 STANDBY_HOST=db02.prod.csob.cz DATA_MOUNTS="/oradata /oradata2" \
#     ./02_host_preflight.sh
#==============================================================================

set -u

: ${ORACLE_SID:?"ORACLE_SID must be set"}
: ${LISTENER_NAME:=LISTENER}
: ${TLS_PORT:=1527}
: ${MIN_FREE_GB:=20}
: ${STANDBY_HOST:=}
: ${DATA_MOUNTS:=}
: ${ORACLE_HOME:=}

PASS_N=0
WARN_N=0
FAIL_N=0
TMPF=/tmp/host_preflight_$$.tmp
trap 'rm -f $TMPF' 0

pass() { echo "PASS  $*"; PASS_N=$((PASS_N+1)); }
warn() { echo "WARN  $*"; WARN_N=$((WARN_N+1)); }
fail() { echo "FAIL  $*"; FAIL_N=$((FAIL_N+1)); }
info() { echo "INFO  $*"; }
hr()   { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " Host preflight: `hostname`  ORACLE_SID=${ORACLE_SID}  `date '+%Y-%m-%d %H:%M:%S'`"
echo "============================================================"

#--- 1) ORACLE_HOME ------------------------------------------------------------
echo ""
echo "[1] ORACLE_HOME"
hr
if [ -z "${ORACLE_HOME}" ]; then
    fail "ORACLE_HOME is not set (OPatch/orapki/lsnrctl/TNS_ADMIN checks skipped)"
elif [ ! -d "${ORACLE_HOME}" ]; then
    fail "ORACLE_HOME=${ORACLE_HOME} is not a directory"
    ORACLE_HOME=""
else
    pass "ORACLE_HOME=${ORACLE_HOME}"
fi

#--- 2) tools: orapki, openssl --------------------------------------------------
echo ""
echo "[2] Tools: orapki, openssl"
hr
if [ -n "${ORACLE_HOME}" ] && [ -x "${ORACLE_HOME}/bin/orapki" ]; then
    pass "orapki found: ${ORACLE_HOME}/bin/orapki"
else
    fail "orapki not found/executable under \$ORACLE_HOME/bin"
fi

OPENSSL=""
for cand in openssl /usr/bin/openssl /opt/freeware/bin/openssl; do
    if command -v "$cand" >/dev/null 2>&1; then OPENSSL="$cand"; break; fi
done
if [ -n "${OPENSSL}" ]; then
    pass "openssl found: ${OPENSSL}  (`${OPENSSL} version 2>&1 | head -1`)"
else
    fail "openssl not found (PATH, /usr/bin, /opt/freeware/bin)"
fi

#--- 3) OPatch / RU ------------------------------------------------------------
echo ""
echo "[3] OPatch lspatches (first lines; expect RU 19.30)"
hr
if [ -n "${ORACLE_HOME}" ] && [ -x "${ORACLE_HOME}/OPatch/opatch" ]; then
    "${ORACLE_HOME}/OPatch/opatch" lspatches 2>&1 | head -6 > $TMPF
    cat $TMPF
    if grep -E '19\.30|Release_Update.*19\.30' $TMPF >/dev/null 2>&1; then
        pass "RU 19.30 string seen in lspatches"
    else
        warn "no '19.30' text in first lspatches lines - confirm RU (SELECT version_full FROM v\$instance)"
    fi
else
    fail "opatch not found under \$ORACLE_HOME/OPatch"
fi

#--- 4) TNS_ADMIN / sqlnet.ora ---------------------------------------------------
echo ""
echo "[4] TNS_ADMIN and sqlnet.ora"
hr
if [ -n "${TNS_ADMIN:-}" ]; then
    TNSDIR=${TNS_ADMIN}
    info "TNS_ADMIN from environment: ${TNSDIR}"
elif [ -n "${ORACLE_HOME}" ]; then
    TNSDIR=${ORACLE_HOME}/network/admin
    info "TNS_ADMIN not set; using \$ORACLE_HOME/network/admin: ${TNSDIR}"
else
    TNSDIR=""
fi

SQLNET=""
if [ -z "${TNSDIR}" ]; then
    fail "cannot resolve TNS_ADMIN (no TNS_ADMIN and no ORACLE_HOME)"
elif [ ! -d "${TNSDIR}" ]; then
    fail "TNS_ADMIN directory does not exist: ${TNSDIR}"
else
    SQLNET=${TNSDIR}/sqlnet.ora
    if [ -f "${SQLNET}" ]; then
        pass "sqlnet.ora present: ${SQLNET}"
    else
        warn "no sqlnet.ora in ${TNSDIR} (will be created; 0 WALLET_LOCATION entries)"
        SQLNET=""
    fi
fi

if [ -n "${SQLNET}" ]; then
    # Comment lines start with '#', so anchoring on the key skips them.
    WL_N=`grep -ic '^[[:space:]]*WALLET_LOCATION[[:space:]]*=' "${SQLNET}"`
    if [ "${WL_N}" -gt 1 ]; then
        fail "WALLET_LOCATION appears ${WL_N} times in sqlnet.ora (only one is honoured) - clean up first"
    elif [ "${WL_N}" -eq 1 ]; then
        warn "WALLET_LOCATION already present (1) - likely SEPS; MERGE the TLS CA chain into it, do not add a second (02-tls-guide.md 4.2)"
        grep -i '^[[:space:]]*WALLET_LOCATION' "${SQLNET}" | sed 's/^/        /'
    else
        pass "no WALLET_LOCATION in sqlnet.ora (TLS wallet can be added cleanly)"
    fi

    if grep -iE '^[[:space:]]*SQLNET\.WALLET_OVERRIDE[[:space:]]*=' "${SQLNET}" >/dev/null 2>&1; then
        warn "SQLNET.WALLET_OVERRIDE present: SEPS in use (DG broker/RMAN/jobs may rely on it)"
        grep -iE '^[[:space:]]*SQLNET\.WALLET_OVERRIDE' "${SQLNET}" | sed 's/^/        /'
    else
        pass "SQLNET.WALLET_OVERRIDE not set (no SEPS via sqlnet.ora)"
    fi

    if grep -iE '^[[:space:]]*SQLNET\.ENCRYPTION_SERVER[[:space:]]*=' "${SQLNET}" >/dev/null 2>&1; then
        ENC_LINE=`grep -iE '^[[:space:]]*SQLNET\.ENCRYPTION_SERVER[[:space:]]*=' "${SQLNET}" | tail -1`
        info "existing setting: ${ENC_LINE}"
        if echo "${ENC_LINE}" | grep -iE '(REQUIRED|REQUESTED)' >/dev/null 2>&1; then
            warn "SQLNET.ENCRYPTION_SERVER is REQUIRED/REQUESTED - native ANO active; review ANO vs TLS (02-tls-guide.md section 5)"
        else
            pass "SQLNET.ENCRYPTION_SERVER set to a non-enforcing value"
        fi
    else
        pass "SQLNET.ENCRYPTION_SERVER not set (default ACCEPTED)"
    fi

    if grep -iE '^[[:space:]]*ENCRYPTION_WALLET_LOCATION[[:space:]]*=' "${SQLNET}" >/dev/null 2>&1; then
        warn "ENCRYPTION_WALLET_LOCATION present: deprecated - REMOVE it before using WALLET_ROOT (03-tde-guide.md 3)"
    else
        pass "no ENCRYPTION_WALLET_LOCATION in sqlnet.ora"
    fi
fi

#--- 5) listener endpoints -------------------------------------------------------
echo ""
echo "[5] Listener endpoints (${LISTENER_NAME})"
hr
if [ -n "${ORACLE_HOME}" ] && [ -x "${ORACLE_HOME}/bin/lsnrctl" ]; then
    LSNR=${ORACLE_HOME}/bin/lsnrctl
elif command -v lsnrctl >/dev/null 2>&1; then
    LSNR=lsnrctl
else
    LSNR=""
fi
if [ -z "${LSNR}" ]; then
    fail "lsnrctl not found"
else
    "${LSNR}" status "${LISTENER_NAME}" > $TMPF 2>&1
    if grep -E 'TNS-12541|TNS-12518|TNS-12560|TNS-01101' $TMPF >/dev/null 2>&1 \
       || ! grep 'PROTOCOL=' $TMPF >/dev/null 2>&1; then
        warn "listener ${LISTENER_NAME} not running or returned no endpoints"
    else
        grep 'PROTOCOL=' $TMPF | sed 's/^/        /'
        if grep -i 'PROTOCOL=tcp)' $TMPF >/dev/null 2>&1; then
            info "cleartext TCP endpoint present (legacy, expected port 1526)"
        fi
        if grep -i 'PROTOCOL=tcps)' $TMPF | grep "PORT=${TLS_PORT}" >/dev/null 2>&1; then
            pass "TCPS endpoint on port ${TLS_PORT} already present"
        else
            warn "no TCPS endpoint on port ${TLS_PORT} yet (expected before rollout)"
        fi
    fi
fi

#--- 6) wallet directories + perms -------------------------------------------------
echo ""
echo "[6] Wallet directories"
hr
for W in /oracle/admin/${ORACLE_SID}/wallet /oracle/admin/${ORACLE_SID}/wallet_tls; do
    if [ -d "${W}" ]; then
        LS=`ls -ld "${W}"`
        echo "        ${LS}"
        # field 1 = mode string; chars 5-10 are group/other bits
        GO=`echo "${LS}" | awk '{ print substr($1, 5, 6) }'`
        if [ "${GO}" = "------" ]; then
            pass "${W} exists, no group/other access"
        else
            warn "${W} exists but group/other have access (${GO}) - wallet dirs should be 700 oracle:oinstall"
        fi
    else
        warn "${W} does not exist (expected before rollout; created by TDE 01 / TLS 01)"
    fi
done

#--- 7) filesystem free space --------------------------------------------------------
echo ""
echo "[7] Free space on DATA_MOUNTS (WARN below ${MIN_FREE_GB} GB)"
hr
if [ -z "${DATA_MOUNTS}" ]; then
    info "DATA_MOUNTS not set - skipped (online TDE needs free ~= largest datafile)"
else
    for M in ${DATA_MOUNTS}; do
        FREE_GB=""
        if df -g "${M}" > $TMPF 2>/dev/null; then
            # AIX df -g: Filesystem GB_blocks Free %Used ...   (Free = column 3)
            FREE_GB=`awk 'NR==2 { print $3 }' $TMPF`
        elif df -k "${M}" > $TMPF 2>/dev/null; then
            # df -k: Free KB = column 3 on AIX; convert to GB
            FREE_GB=`awk 'NR==2 { printf "%.1f", $3/1048576 }' $TMPF`
        fi
        if [ -z "${FREE_GB}" ]; then
            fail "${M}: df failed (path missing?)"
        else
            # awk does the numeric compare (value may be fractional)
            LOW=`echo "${FREE_GB}" | awk -v t="${MIN_FREE_GB}" '{ print ($1 + 0 < t + 0) ? "Y" : "N" }'`
            if [ "${LOW}" = "Y" ]; then
                warn "${M}: ${FREE_GB} GB free (< ${MIN_FREE_GB} GB)"
            else
                pass "${M}: ${FREE_GB} GB free"
            fi
        fi
    done
fi

#--- 8) standby TCPS reachability -------------------------------------------------------
echo ""
echo "[8] Standby TCPS reachability (${STANDBY_HOST:-not set}:${TLS_PORT})"
hr
if [ -z "${STANDBY_HOST}" ]; then
    info "STANDBY_HOST not set - skipped"
elif [ -z "${OPENSSL}" ]; then
    warn "openssl missing - manual check: telnet ${STANDBY_HOST} ${TLS_PORT}"
else
    # No 'timeout' on AIX: run s_client in the background with stdin from
    # /dev/null (it exits after the handshake) and kill it after ~10 seconds.
    "${OPENSSL}" s_client -connect "${STANDBY_HOST}:${TLS_PORT}" < /dev/null > $TMPF 2>&1 &
    SPID=$!
    WAITED=0
    while kill -0 $SPID 2>/dev/null && [ $WAITED -lt 10 ]; do
        sleep 1
        WAITED=$((WAITED+1))
    done
    if kill -0 $SPID 2>/dev/null; then
        kill $SPID 2>/dev/null
        warn "s_client to ${STANDBY_HOST}:${TLS_PORT} timed out after 10s - firewall? manual check advised"
    elif grep 'BEGIN CERTIFICATE' $TMPF >/dev/null 2>&1; then
        pass "TLS handshake to ${STANDBY_HOST}:${TLS_PORT} returned a certificate"
    elif grep -iE 'connect:|Connection refused|errno' $TMPF >/dev/null 2>&1; then
        warn "cannot connect to ${STANDBY_HOST}:${TLS_PORT} (no TCPS listener yet, or firewall)"
    else
        warn "no certificate seen from ${STANDBY_HOST}:${TLS_PORT} - manual check"
    fi
fi

#--- summary ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " SUMMARY  host=`hostname`  SID=${ORACLE_SID}:  PASS=${PASS_N}  WARN=${WARN_N}  FAIL=${FAIL_N}"
echo "============================================================"
exit 0
