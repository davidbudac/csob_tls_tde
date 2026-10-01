#!/usr/bin/ksh
#==============================================================================
# 01_create_tls_wallet.sh
#------------------------------------------------------------------------------
# Purpose : Create/maintain a SEPARATE TLS (SQL*Net TCPS) auto-login wallet and
#           drive the CSR / import workflow with an internal enterprise CA, for
#           Oracle 19c on AIX 7.2 (ksh). Two-phase:
#             --mode csr     create wallet + key + export CSR (submit to CA)
#             --mode import   import CA chain (root, intermediate) + server cert
#             --mode display  show wallet contents / cert chain
#
# Environment / assumptions:
#   * Oracle 19c EE, AIX 7.2, ksh. Uses only orapki from $ORACLE_HOME/bin.
#   * NO bash-isms, NO GNU-only flags, NO 'readlink -f' (not on AIX).
#   * This wallet is the TLS wallet ONLY. It MUST NOT be the TDE keystore.
#     Default path deliberately differs from any TDE wallet directory.
#   * Server authentication only (SSL_CLIENT_AUTHENTICATION=FALSE). The wallet
#     holds the CA chain (trusted) + this host's server cert (user cert).
#   * Idempotent: re-running --mode csr on an existing wallet will NOT recreate
#     it; it re-exports the CSR for the existing DN unless FORCE_NEW=YES.
#
# Required variables (export before running, or edit the defaults below):
#   ORACLE_SID     - used to derive default WALLET_DIR
#   ORACLE_HOME    - so orapki is on PATH
#   WALLET_DIR     - TLS wallet directory (default /oracle/admin/$ORACLE_SID/wallet_tls)
#   CERT_DN        - full subject DN, CN must be the host FQDN
#                    e.g. "CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ"
#   KEYSIZE        - RSA key size, 2048 or 4096 (default 4096). 19c orapki
#                    accepts 512|1024|2048|4096|8192|16384 only -- NOT 3072.
#   WALLET_PWD     - PKCS#12 wallet password (NOT echoed; prompt if unset)
#
# Import-mode variables:
#   ROOT_CA_CERT   - path to root CA cert (PEM/DER)
#   ISSUING_CA_CERT- path to intermediate/issuing CA cert
#   SERVER_CERT    - path to the issued server (user) cert returned by the CA
#
# Usage:
#   ORACLE_SID=db01 CERT_DN="CN=db01.prod.csob.cz,OU=DBA,O=CSOB,L=Praha,C=CZ" \
#     ./01_create_tls_wallet.sh --mode csr
#   ... submit the printed CSR to the CA, collect certs ...
#   ROOT_CA_CERT=/tmp/root.cer ISSUING_CA_CERT=/tmp/iss.cer SERVER_CERT=/tmp/db01.cer \
#     ORACLE_SID=db01 ./01_create_tls_wallet.sh --mode import
#==============================================================================

set -e   # abort on any command failure (works in ksh)

#--- defaults ----------------------------------------------------------------
: ${ORACLE_SID:?"ORACLE_SID must be set"}
: ${ORACLE_HOME:?"ORACLE_HOME must be set"}
: ${WALLET_DIR:=/oracle/admin/${ORACLE_SID}/wallet_tls}
: ${KEYSIZE:=4096}
: ${CSR_OUT:=/tmp/${ORACLE_SID}_tls.csr}
: ${FORCE_NEW:=NO}

PATH=${ORACLE_HOME}/bin:${PATH}
export PATH

ORAPKI=${ORACLE_HOME}/bin/orapki
MODE=""

#--- arg parsing (ksh-safe, no getopt long-opt dependency) -------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --mode=*) MODE="${1#--mode=}"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "ERROR: --mode {csr|import|display} is required" >&2
  exit 2
fi

if [ ! -x "$ORAPKI" ]; then
  echo "ERROR: orapki not found/executable at $ORAPKI" >&2
  exit 3
fi

#--- prompt for wallet password if not supplied (never echo) -----------------
prompt_pwd() {
  if [ -z "$WALLET_PWD" ]; then
    stty -echo 2>/dev/null || true
    printf "Enter TLS wallet (PKCS#12) password: "
    read WALLET_PWD
    stty echo 2>/dev/null || true
    printf "\n"
  fi
  if [ -z "$WALLET_PWD" ]; then
    echo "ERROR: WALLET_PWD is empty" >&2
    exit 4
  fi
}

#--- safety: refuse to write into an obvious TDE keystore path ----------------
guard_not_tde() {
  case "$WALLET_DIR" in
    *tde* | *TDE* | *wallet_tde* | *keystore* )
      echo "REFUSING: WALLET_DIR ('$WALLET_DIR') looks like a TDE keystore." >&2
      echo "The TLS wallet MUST be separate from the TDE keystore." >&2
      exit 5 ;;
  esac
}

#--- create wallet + CSR ------------------------------------------------------
do_csr() {
  : ${CERT_DN:?"CERT_DN must be set (CN must be host FQDN)"}
  guard_not_tde
  prompt_pwd

  # Create directory with tight perms if missing (idempotent).
  if [ ! -d "$WALLET_DIR" ]; then
    mkdir -p "$WALLET_DIR"
  fi
  chmod 700 "$WALLET_DIR"

  # Create the auto-login wallet only if it does not already exist.
  if [ -f "${WALLET_DIR}/ewallet.p12" ] && [ "$FORCE_NEW" != "YES" ]; then
    echo "INFO: wallet already exists at ${WALLET_DIR} (ewallet.p12 present)."
    echo "INFO: skipping 'wallet create'. Set FORCE_NEW=YES to override."
  else
    echo "INFO: creating auto-login wallet at ${WALLET_DIR} ..."
    "$ORAPKI" wallet create -wallet "$WALLET_DIR" -auto_login -pwd "$WALLET_PWD"
  fi

  # Add the key pair for our DN if not already present, then export the CSR.
  # 'wallet add' with a -dn generates a self-signed placeholder + key pair.
  if "$ORAPKI" wallet display -wallet "$WALLET_DIR" -pwd "$WALLET_PWD" \
        | grep -i "Subject:" | grep -i "$CERT_DN" >/dev/null 2>&1; then
    echo "INFO: a key/cert entry for '$CERT_DN' already exists; re-exporting CSR."
  else
    echo "INFO: generating key pair (keysize ${KEYSIZE}) for DN '$CERT_DN' ..."
    "$ORAPKI" wallet add -wallet "$WALLET_DIR" -dn "$CERT_DN" \
        -keysize "$KEYSIZE" -pwd "$WALLET_PWD"
  fi

  echo "INFO: exporting CSR to ${CSR_OUT} ..."
  "$ORAPKI" wallet export -wallet "$WALLET_DIR" -dn "$CERT_DN" \
      -request "$CSR_OUT" -pwd "$WALLET_PWD"

  chmod 600 "${WALLET_DIR}"/* 2>/dev/null || true

  echo ""
  echo "=============================================================="
  echo " CSR generated: ${CSR_OUT}"
  echo "--------------------------------------------------------------"
  echo " NEXT STEPS (internal CA / CSR workflow):"
  echo "  1. Submit ${CSR_OUT} to the internal enterprise CA."
  echo "     Request template: CN=<host FQDN> + DNS SANs for every name"
  echo "     clients use; extendedKeyUsage=serverAuth (+clientAuth if this"
  echo "     DB is also a TLS client for DB links / redo transport)."
  echo "     NOTE: orapki 19c CSRs carry the DN but usually NOT SANs -"
  echo "     have the CA template inject the DNS SANs."
  echo "  2. Collect: root CA, intermediate/issuing CA, and the server cert."
  echo "  3. Re-run this script with --mode import (root+issuing+server)."
  echo "=============================================================="
}

#--- import CA chain then server cert (ORDER MATTERS) ------------------------
do_import() {
  : ${ROOT_CA_CERT:?"ROOT_CA_CERT must be set"}
  : ${SERVER_CERT:?"SERVER_CERT must be set"}
  guard_not_tde
  prompt_pwd

  if [ ! -f "${WALLET_DIR}/ewallet.p12" ]; then
    echo "ERROR: no wallet at ${WALLET_DIR}; run --mode csr first." >&2
    exit 6
  fi
  [ -f "$ROOT_CA_CERT" ]   || { echo "ERROR: ROOT_CA_CERT not found: $ROOT_CA_CERT" >&2; exit 6; }
  [ -f "$SERVER_CERT" ]    || { echo "ERROR: SERVER_CERT not found: $SERVER_CERT" >&2; exit 6; }

  echo "INFO: importing ROOT CA (trusted) ..."
  "$ORAPKI" wallet add -wallet "$WALLET_DIR" -trusted_cert \
      -cert "$ROOT_CA_CERT" -pwd "$WALLET_PWD"

  if [ -n "$ISSUING_CA_CERT" ]; then
    [ -f "$ISSUING_CA_CERT" ] || { echo "ERROR: ISSUING_CA_CERT not found: $ISSUING_CA_CERT" >&2; exit 6; }
    echo "INFO: importing INTERMEDIATE/ISSUING CA (trusted) ..."
    "$ORAPKI" wallet add -wallet "$WALLET_DIR" -trusted_cert \
        -cert "$ISSUING_CA_CERT" -pwd "$WALLET_PWD"
  else
    echo "WARN: ISSUING_CA_CERT not set. If the server cert was issued by an"
    echo "WARN: intermediate CA, the user-cert import below will FAIL. Import"
    echo "WARN: the intermediate before the server cert."
  fi

  echo "INFO: importing SERVER (user) cert ..."
  "$ORAPKI" wallet add -wallet "$WALLET_DIR" -user_cert \
      -cert "$SERVER_CERT" -pwd "$WALLET_PWD"

  # Re-assert auto-login SSO (regenerate cwallet.sso after modifications).
  "$ORAPKI" wallet create -wallet "$WALLET_DIR" -auto_login -pwd "$WALLET_PWD"

  chmod 700 "$WALLET_DIR"
  chmod 600 "${WALLET_DIR}"/* 2>/dev/null || true

  echo ""
  echo "INFO: import complete. Verifying chain ..."
  do_display

  echo ""
  echo "=============================================================="
  echo " Wallet ready: ${WALLET_DIR}"
  echo " Confirm: the server cert shows a COMPLETE chain to the root"
  echo " under 'Trusted Certificates'. If it still shows as a"
  echo " 'Requested Certificate', the intermediate was missing - fix"
  echo " the import order and retry."
  echo " Next: set WALLET_LOCATION in listener.ora/sqlnet.ora, add the"
  echo " TCPS 1527 endpoint, then full listener stop/start."
  echo "=============================================================="
}

#--- display -----------------------------------------------------------------
do_display() {
  prompt_pwd
  "$ORAPKI" wallet display -wallet "$WALLET_DIR" -pwd "$WALLET_PWD"
}

case "$MODE" in
  csr)     do_csr ;;
  import)  do_import ;;
  display) do_display ;;
  *) echo "ERROR: unknown --mode '$MODE' (csr|import|display)" >&2; exit 2 ;;
esac

exit 0
