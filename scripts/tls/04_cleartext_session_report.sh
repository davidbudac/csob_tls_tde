#!/usr/bin/ksh
#==============================================================================
# 04_cleartext_session_report.sh
#------------------------------------------------------------------------------
# Purpose : "Who still connects in cleartext?" report from the TEXT listener
#           log. READ-ONLY (only reads the log; writes tiny temp files in /tmp).
#           Counts listener "establish" lines per PROTOCOL (tcp vs tcps), lists
#           the cleartext (tcp) sources grouped by client IP + SERVICE_NAME +
#           PROGRAM with count and last-seen time -- the migration list for app
#           owners -- and ends with a verdict line used as the go/no-go evidence
#           before closing the legacy 1526 listener endpoint.
#
# Log line format parsed (fields are separated by " * "):
#   01-OCT-2026 10:15:02 * (CONNECT_DATA=(SERVICE_NAME=APPSVC.prod.csob.cz)
#     (CID=(PROGRAM=JDBC Thin Client)(HOST=__jdbc__)(USER=appuser))) *
#     (ADDRESS=(PROTOCOL=tcp)(HOST=10.20.30.40)(PORT=51522)) * establish *
#     APPSVC.prod.csob.cz * 0
#   If SERVICE_NAME is absent, (SID=...) is used. All "establish" lines count,
#   including ones with a non-zero return code (the client still tried cleartext).
#
# Environment / assumptions:
#   * Oracle 19c EE, AIX 7.2, ksh. POSIX awk only (no gensub, no match() with an
#     array, no strftime). NO bash-isms, NO GNU-only flags.
#   * Needs the TEXT log (<listener_name_lowercase>.log under .../trace), NOT
#     the XML alert log.xml. If ADR logging is disabled for the listener
#     (LOGGING_<listener>=ON and ADR_BASE_<listener> set), the text log is
#     still written to the trace directory.
#
# Arguments:
#   $1  path to listener text log (optional; auto-discovered if omitted)
#   $2  SINCE: awk regex matched against the timestamp field, e.g.
#       "^01-OCT-2026" or "^(01|02)-OCT-2026" (optional; default = whole file)
#
# Variables (export before running):
#   LISTENER_NAME  - listener to query for auto-discovery (default LISTENER)
#   EXCLUDE_HOSTS  - space-separated client IPs to ignore (monitoring, the host's
#                    own IP, etc.), e.g. "10.20.30.5 10.20.30.6"
#   TOP_N          - max rows in the cleartext source list (default 50)
#
# Usage:
#   ./04_cleartext_session_report.sh
#   ./04_cleartext_session_report.sh /oracle/diag/tnslsnr/db01/listener/trace/listener.log
#   EXCLUDE_HOSTS="10.20.30.5" ./04_cleartext_session_report.sh "" "^01-OCT-2026"
#   (use "" for $1 to keep auto-discovery while passing a SINCE filter)
#
# Exit    : 0 = report produced; 2 = usage / log not found.
#==============================================================================

set -u

: ${LISTENER_NAME:=LISTENER}
: ${EXCLUDE_HOSTS:=}
: ${TOP_N:=50}

LOG=${1:-}
SINCE=${2:-}
TMP_META=/tmp/cleartext_meta_$$.tmp
TMP_SRC=/tmp/cleartext_src_$$.tmp
TMP_LS=/tmp/cleartext_ls_$$.tmp
trap 'rm -f $TMP_META $TMP_SRC $TMP_LS' 0

#--- 1) locate the text log ---------------------------------------------------
if [ -z "${LOG}" ]; then
    if [ -n "${ORACLE_HOME:-}" ] && [ -x "${ORACLE_HOME}/bin/lsnrctl" ]; then
        LSNR=${ORACLE_HOME}/bin/lsnrctl
    elif command -v lsnrctl >/dev/null 2>&1; then
        LSNR=lsnrctl
    else
        echo "ERROR: no log path given and lsnrctl not found" >&2
        echo "Usage: $0 [listener.log] [SINCE_REGEX]" >&2
        exit 2
    fi
    "${LSNR}" status "${LISTENER_NAME}" > $TMP_LS 2>&1
    XML=`awk '/Listener Log File/ { print $NF; exit }' $TMP_LS`
    if [ -z "${XML}" ]; then
        echo "ERROR: 'Listener Log File' line not found in lsnrctl status ${LISTENER_NAME}" >&2
        exit 2
    fi
    # XML = <adr_home>/alert/log.xml ; text log = <adr_home>/trace/<name>.log
    ALERTDIR=`dirname "${XML}"`
    ADRHOME=`dirname "${ALERTDIR}"`
    LNAME=`echo "${LISTENER_NAME}" | tr '[:upper:]' '[:lower:]'`
    LOG=${ADRHOME}/trace/${LNAME}.log
fi

if [ ! -f "${LOG}" ] || [ ! -r "${LOG}" ]; then
    echo "ERROR: listener log not found/readable: ${LOG}" >&2
    exit 2
fi

echo "============================================================"
echo " Cleartext session report: `hostname`"
echo "   Log file      : ${LOG}"
echo "   SINCE filter  : ${SINCE:-<none, whole file>}"
echo "   Excluded hosts: ${EXCLUDE_HOSTS:-<none>}"
echo "   Generated     : `date '+%Y-%m-%d %H:%M:%S'`"
echo "============================================================"

#--- 2) single awk pass -------------------------------------------------------
# Values come in via the environment (ENVIRON) so backslashes/quotes in the
# regex are not mangled by awk -v escape processing.
SINCE_RE="${SINCE}" EXCL="${EXCLUDE_HOSTS}" awk -v meta="$TMP_META" -v src="$TMP_SRC" '
function getval(s, key,    u, p, rest, e) {
    u = toupper(s)
    p = index(u, "(" key "=")
    if (p == 0) return ""
    rest = substr(s, p + length(key) + 2)
    e = index(rest, ")(")
    if (e == 0) e = index(rest, ")")
    if (e == 0) return rest
    return substr(rest, 1, e - 1)
}
BEGIN {
    since = ENVIRON["SINCE_RE"]
    n = split(ENVIRON["EXCL"], ex, " ")
    for (i = 1; i <= n; i++) excl[ex[i]] = 1
    total = 0; tcp = 0; skipped = 0
}
index($0, " * establish * ") == 0 { next }
{
    nf = split($0, f, " \\* ")
    if (nf < 4) next
    ts = f[1]
    if (since != "" && ts !~ since) next
    addr = f[3]
    host = getval(addr, "HOST")
    if (host in excl) { skipped++; next }
    proto = tolower(getval(addr, "PROTOCOL"))
    if (proto == "") proto = "unknown"
    total++
    if (total == 1) first = ts
    last = ts
    pcount[proto]++
    if (proto == "tcp") {
        tcp++
        svc = getval(f[2], "SERVICE_NAME")
        if (svc == "") { svc = getval(f[2], "SID"); if (svc != "") svc = "SID=" svc }
        if (svc == "") svc = "-"
        prog = getval(f[2], "PROGRAM")
        if (prog == "") prog = "-"
        if (host == "") host = "-"
        k = host "|" svc "|" prog
        cnt[k]++
        seen[k] = ts
    }
}
END {
    print "total=" total > meta
    print "tcp=" tcp > meta
    print "first=" first > meta
    print "last=" last > meta
    print "skipped=" skipped > meta
    for (p in pcount) print "proto|" p "|" pcount[p] > meta
    for (k in cnt) printf "%010d|%s|%s\n", cnt[k], k, seen[k] > src
    close(meta); close(src)
}' "${LOG}"

TOTAL=`awk -F= '$1 == "total" { print $2 }' $TMP_META`
TCPN=`awk -F= '$1 == "tcp" { print $2 }' $TMP_META`
FIRST=`awk -F= '$1 == "first" { print substr($0, 7) }' $TMP_META`
LAST=`awk -F= '$1 == "last" { print substr($0, 6) }' $TMP_META`
SKIPPED=`awk -F= '$1 == "skipped" { print $2 }' $TMP_META`

if [ "${TOTAL:-0}" -eq 0 ]; then
    echo ""
    echo "No matching 'establish' lines in the selected window (check log path / SINCE)."
    echo "VERDICT: NO DATA - cannot claim zero cleartext connections"
    exit 0
fi

#--- (a) totals by protocol ---------------------------------------------------
echo ""
echo "(a) Establish lines by PROTOCOL   window: ${FIRST}  ->  ${LAST}"
echo "------------------------------------------------------------"
awk -F'|' '$1 == "proto" { printf "    %-10s %12d\n", $2, $3 }' $TMP_META | sort
printf "    %-10s %12d\n" "TOTAL" "${TOTAL}"
echo "    (excluded by EXCLUDE_HOSTS: ${SKIPPED})"

#--- (b) cleartext sources ----------------------------------------------------
echo ""
echo "(b) Cleartext (tcp) sources -- app owners must migrate these (top ${TOP_N})"
echo "------------------------------------------------------------"
if [ "${TCPN}" -eq 0 ]; then
    echo "    (none)"
else
    printf "    %8s  %-16s %-34s %-30s %s\n" "COUNT" "CLIENT_IP" "SERVICE_NAME" "PROGRAM" "LAST_SEEN"
    sort -r $TMP_SRC | head -${TOP_N} | awk -F'|' '
        { printf "    %8d  %-16s %-34s %-30s %s\n", $1 + 0, $2, $3, $4, $5 }'
    NSRC=`wc -l < $TMP_SRC | awk '{ print $1 }'`
    echo "    (${NSRC} distinct IP+service+program combinations in total)"
fi

#--- (c) verdict --------------------------------------------------------------
echo ""
echo "============================================================"
if [ "${TCPN}" -eq 0 ]; then
    echo "ZERO CLEARTEXT CONNECTIONS since ${FIRST}"
else
    echo "${TCPN} cleartext connections remain (since ${FIRST}, last seen ${LAST})"
fi
echo "============================================================"
exit 0
