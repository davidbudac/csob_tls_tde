#!/usr/bin/ksh
#==============================================================================
# 03_verify_tls.sh
#------------------------------------------------------------------------------
# Purpose : End-to-end verification of a TCPS (TLS) SQL*Net endpoint:
#             1. lsnrctl status  -> confirm a TCPS handler on the target port
#             2. openssl s_client -> show cert chain + negotiated TLS version
#             3. (optional) sqlplus test connect via a TCPS TNS alias, running
#                03_verify_tls.sql to prove the session protocol is 'tcps'.
#
# Environment / assumptions:
#   * Oracle 19c EE, AIX 7.2, ksh. openssl is present on AIX (in PATH or
#     /usr/bin/openssl / /opt/freeware/bin/openssl).
#   * NO bash-isms, NO GNU-only flags, NO 'readlink -f'.
#   * Server-auth-only TLS; this script does NOT present a client cert.
#
# Required / optional variables (export or edit defaults):
#   TLS_HOST      - server FQDN (should equal cert CN/SAN)   [required]
#   TLS_PORT      - TCPS port (default 2484)
#   LISTENER_NAME - listener to query with lsnrctl (default LISTENER)
#   TNS_ALIAS     - optional TCPS tnsnames alias for the sqlplus test
#   DB_USER       - optional user for the sqlplus test (will prompt for pwd)
#   SQL_SCRIPT    - path to 03_verify_tls.sql (default: alongside this script)
#
# Usage:
#   TLS_HOST=db01.prod.csob.cz ./03_verify_tls.sh
#   TLS_HOST=db01.prod.csob.cz TNS_ALIAS=APPSVC_TLS DB_USER=app_user ./03_verify_tls.sh
#==============================================================================

set -e

: ${TLS_HOST:?"TLS_HOST (server FQDN) must be set"}
: ${TLS_PORT:=2484}
: ${LISTENER_NAME:=LISTENER}

# Resolve the directory of this script WITHOUT readlink -f (not on AIX).
SCRIPT_DIR=`dirname "$0"`
case "$SCRIPT_DIR" in
  /*) : ;;                                  # already absolute
  *)  SCRIPT_DIR=`pwd`/"$SCRIPT_DIR" ;;     # make absolute
esac
: ${SQL_SCRIPT:=${SCRIPT_DIR}/03_verify_tls.sql}

# Locate openssl (AIX may keep it under /opt/freeware/bin).
OPENSSL=""
for cand in openssl /usr/bin/openssl /opt/freeware/bin/openssl; do
  if command -v "$cand" >/dev/null 2>&1; then OPENSSL="$cand"; break; fi
done

hr() { echo "------------------------------------------------------------"; }

echo "============================================================"
echo " TLS endpoint verification: ${TLS_HOST}:${TLS_PORT}"
echo "============================================================"

#--- 1) lsnrctl status: is there a TCPS handler on the port? ------------------
echo ""
echo "[1] lsnrctl status  (looking for a TCPS handler on port ${TLS_PORT})"
hr
if command -v lsnrctl >/dev/null 2>&1; then
  # Do not abort the whole script if lsnrctl returns non-zero.
  LSNR_OUT=`lsnrctl status "$LISTENER_NAME" 2>&1` || true
  echo "$LSNR_OUT" | grep -i "PROTOCOL=TCPS" || \
    echo "WARN: no 'PROTOCOL=TCPS' line found in lsnrctl status output."
  echo ""
  if echo "$LSNR_OUT" | grep -i "PORT=${TLS_PORT}" | grep -i "TCPS" >/dev/null 2>&1; then
    echo "OK  : TCPS endpoint on port ${TLS_PORT} is present."
  else
    echo "WARN: could not confirm TCPS on port ${TLS_PORT}. Full status:"
    echo "$LSNR_OUT" | grep -i -E "Listening Endpoints|PROTOCOL=|Service" || true
  fi
else
  echo "SKIP: lsnrctl not on PATH (run on the DB host with ORACLE_HOME set)."
fi

#--- 2) openssl s_client probe: chain + TLS version --------------------------
echo ""
echo "[2] openssl s_client probe (cert chain + negotiated TLS version)"
hr
if [ -n "$OPENSSL" ]; then
  # Feed EOF via 'echo |' so s_client does not hang waiting on stdin.
  # -showcerts prints the full chain the server presents.
  PROBE=`echo | "$OPENSSL" s_client -connect "${TLS_HOST}:${TLS_PORT}" \
            -servername "${TLS_HOST}" -showcerts 2>/dev/null` || true

  if [ -z "$PROBE" ]; then
    echo "ERROR: no TLS response from ${TLS_HOST}:${TLS_PORT}"
    echo "       Check: endpoint up? firewall open on ${TLS_PORT}? MTU/timeout?"
  else
    echo "Negotiated protocol / cipher:"
    echo "$PROBE" | grep -i -E "Protocol[ ]*:|Cipher[ ]*:" | sed 's/^/  /' || true
    echo ""
    echo "Server certificate subject / issuer / validity:"
    echo "$PROBE" | "$OPENSSL" x509 -noout -subject -issuer -dates 2>/dev/null \
       | sed 's/^/  /' || echo "  (could not parse leaf certificate)"
    echo ""
    echo "Certificate chain presented by the server:"
    echo "$PROBE" | grep -i -E "^ *[0-9]+ s:|^ *[0-9]+ i:" | sed 's/^/  /' \
       || echo "  (chain summary not printed by this openssl build)"
    echo ""
    # Verify-result line: 0 (ok) means the chain validated against local trust.
    echo "$PROBE" | grep -i "Verify return code" | sed 's/^/  /' || true
  fi
else
  echo "SKIP: openssl not found (checked PATH, /usr/bin, /opt/freeware/bin)."
fi

#--- 3) optional sqlplus test connect over the TCPS alias --------------------
echo ""
echo "[3] Optional sqlplus test connect over TCPS alias"
hr
if [ -n "$TNS_ALIAS" ] && [ -n "$DB_USER" ]; then
  if command -v sqlplus >/dev/null 2>&1; then
    if [ ! -f "$SQL_SCRIPT" ]; then
      echo "WARN: SQL script not found at ${SQL_SCRIPT}; running a minimal check."
      SQL_SCRIPT=""
    fi
    stty -echo 2>/dev/null || true
    printf "Password for %s@%s: " "$DB_USER" "$TNS_ALIAS"
    read DB_PWD
    stty echo 2>/dev/null || true
    printf "\n"

    if [ -n "$SQL_SCRIPT" ]; then
      sqlplus -L -S "${DB_USER}/${DB_PWD}@${TNS_ALIAS}" @"$SQL_SCRIPT" || \
        echo "ERROR: sqlplus test connect via ${TNS_ALIAS} failed."
    else
      sqlplus -L -S "${DB_USER}/${DB_PWD}@${TNS_ALIAS}" <<'EOF' || \
        echo "ERROR: sqlplus test connect failed."
SET HEADING OFF FEEDBACK OFF
SELECT 'NETWORK_PROTOCOL=' || SYS_CONTEXT('USERENV','NETWORK_PROTOCOL') FROM dual;
EXIT
EOF
    fi
    DB_PWD=""
  else
    echo "SKIP: sqlplus not on PATH."
  fi
else
  echo "SKIP: set TNS_ALIAS and DB_USER to run the sqlplus test connect."
fi

echo ""
echo "============================================================"
echo " Done. Expected healthy result:"
echo "   [1] TCPS handler present on ${TLS_PORT}"
echo "   [2] Protocol TLSv1.2 (or 1.3 if RU-enabled), full chain,"
echo "       Verify return code: 0 (ok)"
echo "   [3] NETWORK_PROTOCOL=tcps for the test session"
echo "============================================================"
exit 0
