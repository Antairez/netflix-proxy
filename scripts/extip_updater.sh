#!/usr/bin/env bash

# extip_updater.sh: keeps dnsmasq.conf and dnsmasq-bogus in sync with this host's public IP.
#
# build.sh bakes the host's public IP (EXTIP/EXTIP6) into every address= line of
# dnsmasq.conf and into the dnsmasq-bogus command line -- once, at install time -- and
# nothing updates it afterwards. When the IP changes (dynamic residential line, or a
# re-provision that hands out a new address) dnsmasq keeps answering authorised clients
# with the OLD address and unblocking silently stops: DNS still resolves, so nothing
# errors. ddns_updater.sh handles *client* IP changes; this is the other half.
#
# Scheduled every minute by crond.template. DRY_RUN=1 only reports what would change.

# make sure basic paths are set
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

CDW=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
CWD=$(cd -P -- "${CDW}/.." && pwd -P)
. ${CDW}/globals
. ${CDW}/functions

CONF=${DNSMASQ_CONF:-${CWD}/dnsmasq.conf}
DRY_RUN=${DRY_RUN:-0}

exec 9>/run/netflix-proxy-extip.lock
flock -n 9 || exit 0
[[ -f "${CONF}" ]] || exit 0

log() { echo "$(date '+%F %T') $*"; }

valid_v4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_v6() { [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:*:* ]]; }
valid_ip() { if [[ "$1" == 4 ]]; then valid_v4 "$2"; else valid_v6 "$2"; fi; }

# public IP as seen from outside; never trust an unvalidated answer (an HTML error page
# written into every address= line would take the whole proxy down)
detect_ip() {
    local fam=$1 ip url
    # no default route for this family: skip instead of sitting through curl timeouts
    [[ -n "$(ip -${fam} route show default 2>/dev/null)" ]] || return 1
    ip=$(get_ext_ipaddr "${fam}" 2>/dev/null)
    valid_ip "${fam}" "${ip}" && { echo "${ip}"; return 0; }
    for url in https://api${fam/4/}${fam/6/6}.ipify.org https://ipv${fam}.icanhazip.com; do
        ip=$(curl -"${fam}" --silent --max-time $((TIMEOUT*2)) "${url}" | tr -d '[:space:]')
        valid_ip "${fam}" "${ip}" && { echo "${ip}"; return 0; }
    done
    return 1
}

# the address build.sh wrote into dnsmasq.conf for this family (empty = family not in use)
configured_ip() {
    local ip
    while IFS= read -r ip; do
        valid_ip "$1" "${ip}" && { echo "${ip}"; return 0; }
    done < <(grep -oE '^address=/[^/]+/[0-9a-fA-F:.]+$' "${CONF}" | awk -F/ '{print $NF}' | awk '!seen[$0]++')
    return 1
}

changed=0
for fam in 4 6; do
    old=$(configured_ip ${fam}) || continue
    if ! new=$(detect_ip ${fam}); then
        # runs every minute: report an undetectable address at most once an hour
        mark=/run/netflix-proxy-extip.nodetect${fam}
        if [[ ! -e ${mark} || -n $(find ${mark} -mmin +60 2>/dev/null) ]]; then
            log "IPv${fam}: cannot detect public IP, leaving ${old} as is"
            touch ${mark}
        fi
        continue
    fi
    [[ "${old}" == "${new}" ]] && continue
    log "IPv${fam}: public IP changed ${old} -> ${new}"
    if [[ "${DRY_RUN}" != 1 ]]; then
        [[ ${changed} == 0 ]] && cp -a "${CONF}" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s#^\(address=/[^/]*/\)${old//./\\.}\$#\1${new}#" "${CONF}"
    fi
    changed=1
done

EXTIP=$(configured_ip 4)
EXTIP6=$(configured_ip 6)

# dnsmasq-bogus carries the IP on its command line, so it has to be recreated, not restarted.
# Compare against the running container as well: it can be stale while dnsmasq.conf is
# current (conf fixed by hand or by an older updater that never touched dnsmasq-bogus).
bogus_answer() {
    docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' dnsmasq-bogus 2>/dev/null \
        | grep -oE '/#/[^ ]*' | cut -d/ -f3 | while read -r ip; do valid_ip "$1" "${ip}" && echo "${ip}"; done | head -n 1
}
bogus_stale=0
if [[ -f "${CWD}/docker-compose.yml" ]] && docker inspect dnsmasq-bogus >/dev/null 2>&1; then
    b4=$(bogus_answer 4); b6=$(bogus_answer 6)
    if [[ "${b4}" != "${EXTIP}" || "${b6}" != "${EXTIP6}" ]]; then
        bogus_stale=1
        # a recreate that keeps failing would otherwise be retried (and logged) every minute
        mark=/run/netflix-proxy-extip.bogusfail
        if [[ ${changed} == 0 && -e ${mark} && -z $(find ${mark} -mmin +60 2>/dev/null) ]]; then
            bogus_stale=0
        fi
    fi
fi

[[ ${changed} == 1 || ${bogus_stale} == 1 ]] || exit 0
if [[ "${DRY_RUN}" == 1 ]]; then
    [[ ${bogus_stale} == 1 ]] && log "dnsmasq-bogus answers ${b4:-none}${b6:+ / ${b6}}, dnsmasq.conf has ${EXTIP:-none}${EXTIP6:+ / ${EXTIP6}}"
    log "DRY_RUN=1: nothing written"
    exit 0
fi

compose() { if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"; else docker compose "$@"; fi; }
if [[ -f "${CWD}/docker-compose.yml" ]]; then
    if (cd "${CWD}" && EXTIP=${EXTIP} EXTIP6=${EXTIP6} compose up -d --no-deps dnsmasq-bogus-service) >/dev/null 2>&1; then
        rm -f /run/netflix-proxy-extip.bogusfail
        log "dnsmasq-bogus recreated, now answering ${EXTIP}${EXTIP6:+ / ${EXTIP6}}"
    else
        touch /run/netflix-proxy-extip.bogusfail
        log "WARN: could not recreate dnsmasq-bogus (unauthorised clients may still get the old IP)"
    fi
fi

if [[ ${changed} == 1 ]]; then
    if docker restart dnsmasq >/dev/null 2>&1; then
        log "dnsmasq restarted, now answering ${EXTIP}${EXTIP6:+ / ${EXTIP6}}"
    else
        log "ERROR: docker restart dnsmasq failed"
    fi
fi
