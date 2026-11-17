#!/usr/bin/env bash
#
# cf-failover - Keep a Cloudflare DNS record pointed at the first healthy node.
#
# Probes a prioritised list of nodes, then points a Cloudflare DNS record at
# the first one that answers. Designed for failover between multiple FRP /
# reverse-proxy entry points, but works for any set of hosts serving the
# same content.
#
# Copyright (c) 2026 JhonLinus
# SPDX-License-Identifier: MIT
# https://github.com/jhonlinus/cf-dns-failover
#
set -uo pipefail

readonly VERSION="1.0.1"
readonly PROG_NAME="cf-failover"
readonly DEFAULT_CONFIG="/etc/cf-failover/config"

# ============================================================================
# Defaults
#
# Every value below can be overridden in the config file. They are declared
# here so the script still behaves sanely when a key is omitted.
# ============================================================================

CONFIG_FILE="$DEFAULT_CONFIG"
DRY_RUN=0
COLOR_MODE="auto"
LOG_LEVEL="info"

# --- Cloudflare -------------------------------------------------------------
# Token with "Zone / DNS / Edit" permission. Scope it to a single zone.
: "${DNS_TOKEN:=}"
# Each entry: "ZONE_ID|RECORD_ID|RECORD_NAME"
# Declared as an array (not `${VAR:=}`) so a config file can assign it
# directly without being flattened into a single empty string.
declare -a DNS_RECORDS=()

# --- Nodes ------------------------------------------------------------------
# Probed in order. First healthy one wins. Accepts hostnames or plain IPv4.
declare -a NODE_HOSTS=()

# Optional DNS server used to turn a hostname in NODE_HOSTS into an IPv4
# address, e.g. "1.1.1.1" or "223.5.5.5". Empty means "ask the system".
#
# The resolver is what makes a hostname entry stale. getent goes through glibc
# and therefore through nscd, systemd-resolved and /etc/hosts; an /etc/hosts
# entry never expires at all. Setting this to an IP skips getent entirely and
# queries that server directly, so a stale hosts file cannot shadow the answer.
#
# The probe itself never uses DNS: curl --resolve pins the address, so whatever
# the resolver returns only decides *which* address gets probed, not whether the
# probe is accurate.
#
# Writing literal IPs in NODE_HOSTS removes this whole class of problem.
: "${NODE_RESOLVER:=}"

# How a hostname in NODE_HOSTS becomes an address.
#
#   system        - ask the local resolver (getent -> dig -> nslookup)
#   authoritative - ask the zone's own nameserver directly, with +norecurse
#
# "system" can hand back a stale address: every cache between here and the
# authoritative server is allowed to answer, and each one only expires on TTL.
# A recursive resolver that ignores or over-caches the TTL shows up exactly as
# "the record changed upstream but this host still sees the old address".
#
# "authoritative" skips all of that: it walks up to the zone's NS and asks it
# point blank, so the answer is whatever the zone currently publishes. Costs a
# couple of extra DNS round trips per run, which at a 5 minute interval is
# nothing. Falls back to "system" if the authoritative server is unreachable.
: "${NODE_LOOKUP:=system}"

# Flush the local DNS cache before resolving NODE_HOSTS hostnames.
#
# This only clears caches on this machine: nscd, systemd-resolved, or Windows'
# resolver cache. It cannot clear the recursive resolver your ISP or router
# runs, and it cannot clear an /etc/hosts entry - that one never expires.
#
#   auto   - try to flush, stay quiet on failure (default)
#   always - flush and warn loudly when it does not work
#   never  - do not touch the resolver caches
#
# Only has an effect when NODE_HOSTS contains hostnames.
: "${FLUSH_DNS_CACHE:=auto}"

# tcp  = connect to PROBE_PORT only. Detects a dead host, not a dead tunnel.
# http = request PROBE_HOST through the candidate. Detects both.
: "${PROBE_MODE:=tcp}"
: "${PROBE_PORT:=}"
: "${PROBE_HOST:=}"
: "${PROBE_PATH:=/}"
: "${PROBE_PROTO:=http}"
: "${PROBE_KEYWORD:=}"
: "${OK_CODES:=200 301 302 307 308 401 403}"
: "${TIMEOUT:=6}"

# --- Behaviour --------------------------------------------------------------
# Consecutive confirmations before actually switching.
: "${CONFIRM_TIMES:=1}"
# TTL applied when the record is written. 1 = Cloudflare "automatic".
: "${DNS_TTL:=60}"
# Leave empty to leave the proxy flag untouched. 1 = proxied, 0 = DNS only.
: "${DNS_PROXIED:=}"

# --- Notification -----------------------------------------------------------
: "${NOTIFY_TYPE:=none}"
: "${NOTIFY_URL:=}"
: "${NOTIFY_TITLE:=DNS Failover}"
: "${NOTIFY_ON_SWITCH:=1}"
: "${NOTIFY_ON_FAILBACK:=1}"
: "${ALERT_INTERVAL:=1800}"

# --- Paths ------------------------------------------------------------------
: "${STATE_DIR:=/var/tmp/cf-failover}"
: "${LOG_FILE:=/var/log/cf-failover.log}"
: "${LOG_MAX_BYTES:=5242880}"

# ============================================================================
# Terminal output
# ============================================================================

setup_colors() {
  local use=0
  case "$COLOR_MODE" in
    always) use=1 ;;
    never)  use=0 ;;
    *)      [[ -t 1 ]] && use=1 ;;
  esac
  if (( use )); then
    C_RESET=$'\033[0m'
    C_DEBUG=$'\033[90m'
    C_INFO=""
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_ERROR=$'\033[31m'
  else
    C_RESET=""; C_DEBUG=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERROR=""
  fi
}

# Only print to the terminal when stdout is a real tty, so cron stays quiet
# and never mails us a log dump.
want_stdout() {
  [[ "$LOG_LEVEL" == "quiet" ]] && return 1
  case "$COLOR_MODE" in
    always) return 0 ;;
    never)  return 1 ;;
    *)      [[ -t 1 ]] ;;
  esac
}

# log <level> <message...>
log() {
  local level="$1"; shift
  local line color

  case "$LOG_LEVEL" in
    debug) ;;
    info)  [[ "$level" == "debug" ]] && return 0 ;;
    warn)  [[ "$level" == "debug" || "$level" == "info" ]] && return 0 ;;
    error) [[ "$level" != "error" ]] && return 0 ;;
    quiet) [[ "$level" != "error" ]] && return 0 ;;
  esac

  line="$(date '+%Y-%m-%d %H:%M:%S') [${level^^}] $*"

  if [[ -n "$LOG_FILE" ]]; then
    # Grouped so a missing or unwritable log path stays silent: the terminal
    # output below is still the primary channel during config validation,
    # which runs before init_runtime() has created any directories.
    { printf '%s\n' "$line" >> "$LOG_FILE"; } 2>/dev/null || true
  fi

  want_stdout || return 0
  case "$level" in
    debug) color="$C_DEBUG" ;;
    ok)    color="$C_OK" ;;
    warn)  color="$C_WARN" ;;
    error) color="$C_ERROR" ;;
    *)     color="$C_INFO" ;;
  esac
  printf '%s%s%s\n' "$color" "$line" "$C_RESET"
}

die() {
  log error "$*"
  exit 1
}

# ============================================================================
# Helpers
# ============================================================================

# Percent-encode a string for use in a URL path or query.
urlencode() {
  local s="$1" out="" i c hex
  local LC_ALL=C
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# Escape a string for embedding inside a JSON string literal.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

is_ipv4() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# Nameservers this host would use by default, one per line.
system_resolvers() {
  awk '/^[[:space:]]*nameserver[[:space:]]/{print $2}' /etc/resolv.conf 2>/dev/null
}

# Keep the last IPv4 in a stream of dig/nslookup output.
#
# dig +short prints bare addresses; nslookup prints "Address: 1.2.3.4", and
# both print the resolver's own address before the answer. Leaving the prefix
# in place would reject every nslookup result, so the address is pulled out
# with a regex instead of being matched against the whole line.
#
# Two guards, because a failed lookup yields the resolver's address and that
# address would then be probed and written to DNS:
#   - lines carrying a port suffix ("127.0.0.53#53") are the resolver itself
#   - anything listed in $1 (space separated) is skipped
# The last remaining candidate wins: with nslookup the answer comes last.
only_ipv4() {
  local exclude=" ${1:-} " line cand last=""
  while IFS= read -r line; do
    case "$line" in *"#"*) continue ;; esac
    if [[ "$line" =~ ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
      cand="${BASH_REMATCH[1]}"
    else
      continue
    fi
    [[ "$exclude" == *" $cand "* ]] && continue
    last="$cand"
  done
  [[ -n "$last" ]] && printf '%s' "$last"
}

# Resolve a hostname to IPv4. Plain IPs pass through untouched.
#
# When NODE_RESOLVER is set, ask that server directly with dig/nslookup and
# never touch getent: getent resolves through glibc's NSS stack, which means
# nscd, systemd-resolved and /etc/hosts all get a say. A hosts entry in
# particular never expires, so a stale one would win forever.
resolve_ip() {
  local host="$1" ip="" skip

  if is_ipv4 "$host"; then
    printf '%s' "$host"
    return 0
  fi

  # Nothing in this function logs: its stdout is the return value, so a log
  # line would be captured as the address by the caller.
  if [[ -n "$NODE_RESOLVER" ]]; then
    skip="$NODE_RESOLVER $(system_resolvers | tr '\n' ' ')"
    if command -v dig >/dev/null 2>&1; then
      ip=$(dig +short +time=3 +tries=1 A "$host" "@${NODE_RESOLVER}" 2>/dev/null \
           | only_ipv4 "$skip")
    fi
    if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
      ip=$(nslookup -timeout=3 "$host" "$NODE_RESOLVER" 2>/dev/null \
           | only_ipv4 "$skip")
    fi
    printf '%s' "$ip"
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  fi

  if [[ -z "$ip" ]] && command -v dig >/dev/null 2>&1; then
    ip=$(dig +short A "$host" 2>/dev/null | only_ipv4 "$(system_resolvers | tr '\n' ' ')")
  fi

  if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
    ip=$(nslookup "$host" 2>/dev/null \
         | only_ipv4 "$(system_resolvers | tr '\n' ' ')")
  fi

  printf '%s' "$ip"
}

# Drop every cache this machine controls. Prints what it managed to flush, so
# the caller can tell "nothing to flush" from "flushing failed".
#
# Deliberately not advertised as a fix for staleness: an upstream recursive
# resolver keeps its own copy until the TTL expires, and /etc/hosts never
# expires at all. Neither is reachable from here.
flush_dns_cache() {
  local did="" sys

  sys=$(uname -s 2>/dev/null || echo unknown)
  if [[ "$sys" == "Darwin" ]]; then
    { dscacheutil -flushcache >/dev/null 2>&1 \
      && killall -HUP mDNSResponder >/dev/null 2>&1; } && did="mDNSResponder"
    printf '%s' "$did"
    return 0
  fi

  if command -v resolvectl >/dev/null 2>&1; then
    { resolvectl flush-caches >/dev/null 2>&1; } && did="resolvectl"
  elif command -v systemd-resolve >/dev/null 2>&1; then
    { systemd-resolve --flush-caches >/dev/null 2>&1; } && did="systemd-resolve"
  fi

  if command -v nscd >/dev/null 2>&1; then
    { nscd -i hosts >/dev/null 2>&1; } && did="${did:+${did}, }nscd"
  fi

  printf '%s' "$did"
}

# Ask the zone's own nameserver for the record, bypassing every cache in
# between. Walks up parent labels until it finds a delegation that answers.
#
# Every nameserver in the delegation is tried, not just the first: Cloudflare
# hands out two, and either one can be slow or unreachable from a given
# network at a given moment. Falling back to the system resolver on the first
# timeout would quietly reintroduce the stale answer this mode exists to avoid.
resolve_authoritative() {
  local host="$1"
  local zone="$host" ns ip i

  command -v dig >/dev/null 2>&1 || return 0

  for i in 1 2 3; do
    zone="${zone#*.}"
    [[ "$zone" == *.* ]] || break

    while IFS= read -r ns; do
      [[ -z "$ns" ]] && continue
      ip=$(dig +short +norecurse +time=3 +tries=1 A "$host" \
           "@${ns%.}" 2>/dev/null | only_ipv4)
      if [[ -n "$ip" ]]; then
        printf '%s' "$ip"
        return 0
      fi
    done < <(dig +short +time=3 +tries=1 NS "$zone" 2>/dev/null \
             | grep -E '^[A-Za-z0-9._-]+\.$' | head -3)
  done

  return 0
}

have_timeout() {
  command -v timeout >/dev/null 2>&1
}

# ============================================================================
# Configuration
# ============================================================================

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf '%s: config not found: %s\n' "$PROG_NAME" "$CONFIG_FILE" >&2
    printf 'Copy config.example to that path, or pass --config FILE.\n' >&2
    exit 2
  fi

  if [[ ! -r "$CONFIG_FILE" ]]; then
    printf '%s: config not readable: %s\n' "$PROG_NAME" "$CONFIG_FILE" >&2
    exit 2
  fi

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

validate_config() {
  local errors=0 i entry

  need() {
    if [[ -z "${!1:-}" ]]; then
      log error "配置缺失：${1}"
      errors=$((errors + 1))
    fi
  }

  need DNS_TOKEN

  if [[ ${#DNS_RECORDS[@]} -eq 0 ]]; then
    log error "配置缺失：DNS_RECORDS 至少要有一条记录"
    errors=$((errors + 1))
  fi

  for i in "${!DNS_RECORDS[@]}"; do
    entry="${DNS_RECORDS[$i]}"
    if [[ "$entry" != *"|"*"|"* ]]; then
      log error "DNS_RECORDS[$i] 格式错误，应为 ZONE_ID|RECORD_ID|RECORD_NAME：${entry}"
      errors=$((errors + 1))
    fi
  done

  if [[ ${#NODE_HOSTS[@]} -eq 0 ]]; then
    log error "配置缺失：NODE_HOSTS 至少要有一个节点"
    errors=$((errors + 1))
  fi

  case "$PROBE_MODE" in
    tcp)
      if [[ -z "$PROBE_PORT" ]]; then
        log error "PROBE_MODE=tcp 时必须设置 PROBE_PORT"
        errors=$((errors + 1))
      fi
      ;;
    http)
      if [[ -z "$PROBE_HOST" || -z "$PROBE_PORT" ]]; then
        log error "PROBE_MODE=http 时必须设置 PROBE_HOST 和 PROBE_PORT"
        errors=$((errors + 1))
      fi
      ;;
    *)
      log error "PROBE_MODE 只能是 tcp 或 http，当前：${PROBE_MODE}"
      errors=$((errors + 1))
      ;;
  esac

  if [[ -n "$DNS_PROXIED" && "$DNS_PROXIED" != "0" && "$DNS_PROXIED" != "1" ]]; then
    log error "DNS_PROXIED 只能是 0、1 或留空，当前：${DNS_PROXIED}"
    errors=$((errors + 1))
  fi

  if [[ "$NOTIFY_TYPE" != "none" && -z "$NOTIFY_URL" ]]; then
    log error "NOTIFY_TYPE=${NOTIFY_TYPE} 但 NOTIFY_URL 为空"
    errors=$((errors + 1))
  fi

  if ! [[ "$CONFIRM_TIMES" =~ ^[0-9]+$ ]] || (( CONFIRM_TIMES < 1 )); then
    log error "CONFIRM_TIMES 必须是 >=1 的整数"
    errors=$((errors + 1))
  fi

  if [[ -n "$NODE_RESOLVER" ]] && ! is_ipv4 "$NODE_RESOLVER"; then
    log error "NODE_RESOLVER 必须是 IPv4 地址（如 1.1.1.1），当前：${NODE_RESOLVER}"
    errors=$((errors + 1))
  fi

  case "$NODE_LOOKUP" in
    system|authoritative) ;;
    *) log error "NODE_LOOKUP 只能是 system 或 authoritative，当前：${NODE_LOOKUP}"
       errors=$((errors + 1)) ;;
  esac

  case "$FLUSH_DNS_CACHE" in
    auto|always|never) ;;
    *) log error "FLUSH_DNS_CACHE 只能是 auto、always 或 never，当前：${FLUSH_DNS_CACHE}"
       errors=$((errors + 1)) ;;
  esac

  if [[ "$NODE_LOOKUP" == "authoritative" ]] && ! command -v dig >/dev/null 2>&1; then
    log error "NODE_LOOKUP=authoritative 需要 dig（bind-utils / dnsutils）"
    errors=$((errors + 1))
  fi

  if [[ -n "$NODE_RESOLVER" ]] \
     && ! command -v dig >/dev/null 2>&1 \
     && ! command -v nslookup >/dev/null 2>&1; then
    log error "设置了 NODE_RESOLVER，但系统没有 dig 或 nslookup 可用"
    errors=$((errors + 1))
  fi

  if (( errors > 0 )); then
    exit 2
  fi
}

check_dependencies() {
  command -v curl >/dev/null 2>&1 || die "缺少依赖：curl"
  if [[ "$PROBE_MODE" == "tcp" ]] && ! have_timeout; then
    die "缺少依赖：timeout（coreutils）"
  fi
}

# ============================================================================
# Probing
# ============================================================================

LAST_RESULT=""

# Pure TCP reachability: a completed handshake is enough.
tcp_probe() {
  local ip="$1"
  if timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${ip}/${PROBE_PORT}" 2>/dev/null; then
    LAST_RESULT="tcp:open"
    return 0
  fi
  LAST_RESULT="tcp:closed"
  return 1
}

# Application-level probe. Resolves the candidate IP directly so no DNS
# lookup is involved, then checks the status code (and optionally a keyword
# expected in the body).
http_probe() {
  local ip="$1" code body=""
  local url="${PROBE_PROTO}://${PROBE_HOST}:${PROBE_PORT}${PROBE_PATH}"
  local -a extra=()

  if [[ "$PROBE_PROTO" == "https" ]]; then
    extra+=(-k)
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time "$TIMEOUT" \
    --resolve "${PROBE_HOST}:${PROBE_PORT}:${ip}" \
    "${extra[@]}" "$url" 2>/dev/null)

  LAST_RESULT="http:${code}"

  local ok=0 c
  for c in $OK_CODES; do
    [[ "$code" == "$c" ]] && ok=1 && break
  done
  (( ok )) || return 1

  if [[ -n "$PROBE_KEYWORD" ]]; then
    body=$(curl -s --max-time "$TIMEOUT" \
      --resolve "${PROBE_HOST}:${PROBE_PORT}:${ip}" \
      "${extra[@]}" "$url" 2>/dev/null)
    if [[ "$body" != *"$PROBE_KEYWORD"* ]]; then
      LAST_RESULT="http:${code} keyword-miss"
      return 1
    fi
    LAST_RESULT="http:${code} keyword-ok"
  fi

  return 0
}

probe() {
  case "$PROBE_MODE" in
    tcp)  tcp_probe "$1" ;;
    http) http_probe "$1" ;;
  esac
}

# ============================================================================
# Cloudflare API
# ============================================================================

# Diagnostics go to stderr: get_record_ip returns its result on stdout, so a
# log line written there would be captured as the record's value.
cf_api_error() {
  local resp="$1" scope="$2" msg
  if [[ -z "$resp" ]]; then
    log error "${scope}：API 无响应（网络或 DNS 异常）" >&2
    return 0
  fi
  if ! printf '%s' "$resp" | grep -q '"success":true'; then
    msg=$(printf '%s' "$resp" | grep -o '"message":"[^"]*"' | head -1)
    log error "${scope}：${msg:-未知错误}" >&2
    return 0
  fi
}

# Print the IPv4 currently stored in a record, or nothing on failure.
get_record_ip() {
  local zone="$1" rec="$2" resp ip
  resp=$(curl -s --max-time 10 \
    -H "Authorization: Bearer ${DNS_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${rec}" 2>/dev/null)

  if ! printf '%s' "$resp" | grep -q '"success":true'; then
    cf_api_error "$resp" "读取记录 ${rec} 失败"
    return 0
  fi

  ip=$(printf '%s' "$resp" \
    | grep -o '"content":"[0-9.]*"' | head -1 \
    | sed 's/.*"content":"\([0-9.]*\)".*/\1/')

  if is_ipv4 "$ip"; then
    printf '%s' "$ip"
  else
    log error "读取记录 ${rec} 失败：响应中没有 IPv4（记录类型可能不是 A）" >&2
  fi
}

set_record_ip() {
  local zone="$1" rec="$2" name="$3" ip="$4" resp payload
  payload="{\"content\":\"${ip}\",\"ttl\":${DNS_TTL}"
  if [[ -n "$DNS_PROXIED" ]]; then
    payload+=",\"proxied\":${DNS_PROXIED}"
  fi
  payload+="}"

  if (( DRY_RUN )); then
    log info "[dry-run] 将写入 ${name} -> ${ip}（payload: ${payload}）"
    return 0
  fi

  resp=$(curl -s --max-time 15 -X PATCH \
    "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${rec}" \
    -H "Authorization: Bearer ${DNS_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload" 2>/dev/null)

  if printf '%s' "$resp" | grep -q '"success":true'; then
    log ok "${name} -> ${ip}（TTL ${DNS_TTL}）"
    return 0
  fi

  cf_api_error "$resp" "更新 ${name} 失败"
  return 1
}

# ============================================================================
# Notification
# ============================================================================

notify() {
  local title="$1" body="$2"
  local t b payload url

  [[ "$NOTIFY_TYPE" == "none" || -z "$NOTIFY_TYPE" ]] && return 0

  t="$(json_escape "$title")"
  b="$(json_escape "$body")"

  if (( DRY_RUN )); then
    log info "[dry-run] 将推送通知：${title} / ${body}"
    return 0
  fi

  case "$NOTIFY_TYPE" in
    bark)
      # Accepts either a bare device key or a full base URL (self-hosted).
      if [[ "$NOTIFY_URL" == http* ]]; then
        url="${NOTIFY_URL%/}"
      else
        url="https://api.day.app/${NOTIFY_URL}"
      fi
      curl -s --max-time 8 \
        "${url}/$(urlencode "$title")/$(urlencode "$body")?group=cf-failover&ttl=600" \
        >/dev/null 2>&1
      ;;

    wecom|dingtalk)
      payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"[${t}] ${b}\"}}"
      curl -s --max-time 8 -X POST "$NOTIFY_URL" \
        -H 'Content-Type: application/json' \
        --data "$payload" >/dev/null 2>&1
      ;;

    feishu)
      payload="{\"msg_type\":\"text\",\"content\":{\"text\":\"[${t}] ${b}\"}}"
      curl -s --max-time 8 -X POST "$NOTIFY_URL" \
        -H 'Content-Type: application/json' \
        --data "$payload" >/dev/null 2>&1
      ;;

    pushplus)
      payload="{\"token\":\"$(json_escape "$NOTIFY_URL")\",\"title\":\"${t}\",\"content\":\"${b}\"}"
      curl -s --max-time 8 -X POST https://www.pushplus.plus/send \
        -H 'Content-Type: application/json' \
        --data "$payload" >/dev/null 2>&1
      ;;

    telegram)
      # NOTIFY_URL = "<bot_token>|<chat_id>"
      local token chat
      token="${NOTIFY_URL%%|*}"
      chat="${NOTIFY_URL#*|}"
      curl -s --max-time 8 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -H 'Content-Type: application/json' \
        --data "{\"chat_id\":\"$(json_escape "$chat")\",\"text\":\"[${t}] ${b}\"}" \
        >/dev/null 2>&1
      ;;

    ntfy)
      # NOTIFY_URL = full topic URL, e.g. https://ntfy.sh/my-topic
      curl -s --max-time 8 -X POST "$NOTIFY_URL" \
        -H "Title: ${t}" \
        --data-binary "$b" >/dev/null 2>&1
      ;;

    webhook)
      payload="{\"title\":\"${t}\",\"body\":\"${b}\",\"host\":\"$(json_escape "$(hostname 2>/dev/null || echo unknown)")\",\"time\":\"$(date -Iseconds)\"}"
      curl -s --max-time 8 -X POST "$NOTIFY_URL" \
        -H 'Content-Type: application/json' \
        --data "$payload" >/dev/null 2>&1
      ;;

    *)
      log warn "未知的 NOTIFY_TYPE：${NOTIFY_TYPE}，跳过通知"
      return 0
      ;;
  esac

  log debug "通知已发送（${NOTIFY_TYPE}）"
  return 0
}

# Rate-limit repeated "everything is down" alerts so a long outage does not
# produce one message per cron tick.
should_alert() {
  local now last
  now=$(date +%s)
  last=$(cat "${STATE_DIR}/alert_ts" 2>/dev/null || echo 0)
  (( now - last < ALERT_INTERVAL )) && return 1
  echo "$now" > "${STATE_DIR}/alert_ts"
  return 0
}

# ============================================================================
# Runtime plumbing
# ============================================================================

init_runtime() {
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    die "无法创建状态目录：${STATE_DIR}"
  fi

  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    [[ -w "$LOG_FILE" || -w "$(dirname "$LOG_FILE")" ]] || die "日志不可写：${LOG_FILE}"
  fi
}

acquire_lock() {
  local lock="${STATE_DIR}/lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock" || die "无法创建锁文件：${lock}"
    if ! flock -n 9; then
      log warn "上一轮仍在运行，跳过本次"
      exit 0
    fi
  fi
}

rotate_log() {
  (( LOG_MAX_BYTES > 0 )) || return 0
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}

# ============================================================================
# Main flow
# ============================================================================

read_current_ips() {
  local -n out_array=$1
  local i zone rec name

  for i in "${!DNS_RECORDS[@]}"; do
    IFS='|' read -r zone rec name <<< "${DNS_RECORDS[$i]}"
    out_array[$i]="$(get_record_ip "$zone" "$rec")"
    if [[ -z "${out_array[$i]}" ]]; then
      log error "无法读取 ${name} 的当前值，本轮不做任何变更"
      return 1
    fi
    log debug "当前 ${name} = ${out_array[$i]}"
  done
  return 0
}

# True when at least one node is a hostname, i.e. resolution actually happens.
needs_resolution() {
  local h
  for h in "${NODE_HOSTS[@]}"; do
    is_ipv4 "$h" || return 0
  done
  return 1
}

select_node() {
  local h ip
  SELECTED_IP=""
  SELECTED_HOST=""
  for h in "${NODE_HOSTS[@]}"; do
    if is_ipv4 "$h"; then
      ip="$h"
    elif [[ "$NODE_LOOKUP" == "authoritative" ]]; then
      ip="$(resolve_authoritative "$h")"
      if [[ -z "$ip" ]]; then
        log warn "权威解析无结果，回落到系统解析：${h}"
        ip="$(resolve_ip "$h")"
      fi
    else
      ip="$(resolve_ip "$h")"
    fi

    if [[ -z "$ip" ]]; then
      log warn "解析失败：${h}"
      continue
    fi
    if probe "$ip"; then
      log ok "可用：${h} -> ${ip}（${LAST_RESULT}）"
      SELECTED_IP="$ip"
      SELECTED_HOST="$h"
      return 0
    fi
    log warn "不可用：${h} -> ${ip}（${LAST_RESULT}）"
  done

  return 1
}

run() {
  local -a cur_ips=()
  local -a names=()
  local -a zones=()
  local -a recs=()
  local i z r n need_change=0 pending cnt flushed
  local -a changed=()

  rotate_log

  for i in "${!DNS_RECORDS[@]}"; do
    IFS='|' read -r z r n <<< "${DNS_RECORDS[$i]}"
    zones[$i]="$z"
    recs[$i]="$r"
    names[$i]="$n"
  done

  log info "开始检测 v${VERSION}｜模式=${PROBE_MODE}｜节点=${#NODE_HOSTS[@]}｜记录=${#DNS_RECORDS[@]}"

  # Only worth doing when a node is named by hostname; literal IPs never ask DNS.
  if [[ "$FLUSH_DNS_CACHE" != "never" ]] && needs_resolution; then
    flushed="$(flush_dns_cache)"
    if [[ -n "$flushed" ]]; then
      log debug "已清除本地 DNS 缓存：${flushed}"
    elif [[ "$FLUSH_DNS_CACHE" == "always" ]]; then
      log warn "未能清除本地 DNS 缓存（需要 root，或本机没有 systemd-resolved / nscd）"
    fi
  fi

  read_current_ips cur_ips || exit 1

  if ! select_node; then
    log error "所有节点均不可用，保持现状"
    for i in "${!names[@]}"; do
      log error "  ${names[$i]} 保持 ${cur_ips[$i]}"
    done
    if should_alert; then
      notify "$NOTIFY_TITLE" "所有节点不可用，DNS 保持原值。请检查节点与网络。"
    fi
    exit 1
  fi

  for i in "${!cur_ips[@]}"; do
    if [[ "${cur_ips[$i]}" != "$SELECTED_IP" ]]; then
      need_change=1
    fi
  done

  if (( ! need_change )) && [[ ${#cur_ips[@]} -gt 0 ]]; then
    rm -f "${STATE_DIR}/pending_ip" "${STATE_DIR}/pending_cnt"
    log info "无需变更：所有记录已是 ${SELECTED_IP}"
    exit 0
  fi

  # Debounce: require N consecutive rounds agreeing on the same target.
  pending="$(cat "${STATE_DIR}/pending_ip" 2>/dev/null || echo "")"
  cnt="$(cat "${STATE_DIR}/pending_cnt" 2>/dev/null || echo 0)"

  if [[ "$SELECTED_IP" == "$pending" ]]; then
    cnt=$(( cnt + 1 ))
  else
    pending="$SELECTED_IP"
    cnt=1
  fi
  echo "$pending" > "${STATE_DIR}/pending_ip"
  echo "$cnt" > "${STATE_DIR}/pending_cnt"
  log info "候选 ${SELECTED_HOST}（${SELECTED_IP}）确认 ${cnt}/${CONFIRM_TIMES}"

  if (( cnt < CONFIRM_TIMES )); then
    log info "本轮不切换，等待下一轮确认"
    exit 0
  fi

  local failed=0
  for i in "${!names[@]}"; do
    if [[ "${cur_ips[$i]}" == "$SELECTED_IP" ]]; then
      log debug "${names[$i]} 已是目标值，跳过"
      continue
    fi
    if set_record_ip "${zones[$i]}" "${recs[$i]}" "${names[$i]}" "$SELECTED_IP"; then
      changed+=("${names[$i]}: ${cur_ips[$i]} -> ${SELECTED_IP}")
    else
      failed=1
    fi
  done

  rm -f "${STATE_DIR}/pending_ip" "${STATE_DIR}/pending_cnt"

  if (( failed )); then
    notify "$NOTIFY_TITLE" "切换失败，目标 ${SELECTED_IP}（${SELECTED_HOST}），请查看日志。"
    exit 1
  fi

  # Distinguish a failback (returning to the first node) from a failover.
  local kind="切换"
  if [[ "$SELECTED_HOST" == "${NODE_HOSTS[0]}" ]]; then
    kind="回切"
  fi

  if [[ ${#changed[@]} -gt 0 ]]; then
    local summary=""
    for i in "${!changed[@]}"; do
      [[ -n "$summary" ]] && summary+="；"
      summary+="${changed[$i]}"
    done
    if (( DRY_RUN )); then
      log ok "本轮结束：[dry-run] 将${kind}到 ${SELECTED_IP}（未实际写入）"
      log info "[dry-run] 跳过通知"
      return 0
    fi
    log ok "本轮结束：${kind}完成 -> ${SELECTED_IP}"
    if [[ "$kind" == "回切" && "$NOTIFY_ON_FAILBACK" != "1" ]]; then
      log debug "NOTIFY_ON_FAILBACK=0，跳过回切通知"
    elif [[ "$NOTIFY_ON_SWITCH" == "1" ]]; then
      notify "$NOTIFY_TITLE" "${kind}：${summary}（${SELECTED_HOST}）"
    fi
  fi

  return 0
}

# ============================================================================
# CLI
# ============================================================================

usage() {
  cat <<EOF
${PROG_NAME} ${VERSION} — point a Cloudflare DNS record at the first healthy node

Usage:
  ${PROG_NAME} [options]

Options:
  -c, --config FILE     Config file (default: ${DEFAULT_CONFIG})
  -n, --dry-run         Probe and report, but never write DNS or send alerts
  -d, --debug           Verbose output (LOG_LEVEL=debug)
  -q, --quiet           Errors only
  -t, --test-notify     Send a test notification and exit
      --no-color        Disable ANSI colours
      --color           Force ANSI colours even when piped
      --check           Validate the config and exit
  -V, --version         Print version
  -h, --help            Show this help

Exit codes:
  0  success / nothing to do
  1  runtime failure (no healthy node, API error, read failed)
  2  configuration error

Docs: https://github.com/jhonlinus/cf-dns-failover
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -c|--config)   CONFIG_FILE="${2:-}"; shift 2 ;;
      -n|--dry-run)  DRY_RUN=1; shift ;;
      -d|--debug)    LOG_LEVEL="debug"; shift ;;
      -q|--quiet)    LOG_LEVEL="quiet"; shift ;;
      --no-color)    COLOR_MODE="never"; shift ;;
      --color)       COLOR_MODE="always"; shift ;;
      --check)       CHECK_ONLY=1; shift ;;
      -t|--test-notify) TEST_NOTIFY=1; shift ;;
      -V|--version)  printf '%s %s\n' "$PROG_NAME" "$VERSION"; exit 0 ;;
      -h|--help)     usage; exit 0 ;;
      *)
        printf '%s: unknown option: %s\n\n' "$PROG_NAME" "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

main() {
  CHECK_ONLY=0
  TEST_NOTIFY=0

  parse_args "$@"
  setup_colors
  load_config
  validate_config
  check_dependencies

  if (( CHECK_ONLY )); then
    printf '配置有效：%s\n' "$CONFIG_FILE"
    exit 0
  fi

  init_runtime

  if (( TEST_NOTIFY )); then
    notify "$NOTIFY_TITLE" "这是一条测试通知，如果你看到了，说明通知配置正确。"
    printf '已尝试通过 %s 发送测试通知\n' "$NOTIFY_TYPE"
    exit 0
  fi

  acquire_lock
  run
}

main "$@"
