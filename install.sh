#!/usr/bin/env bash
#
# cf-failover installer
#
# Copyright (c) 2026 JhonLinus
# SPDX-License-Identifier: MIT
#
set -uo pipefail

readonly VERSION="1.0.0"
readonly PROG="cf-failover"
readonly BIN_DIR="/usr/local/bin"
readonly CONF_DIR="/etc/cf-failover"
readonly CONF_FILE="${CONF_DIR}/config"
readonly LOGROTATE_FILE="/etc/logrotate.d/cf-failover"

SCHEDULER="cron"
CRON_SCHEDULE="*/5 * * * *"
ASSUME_YES=0

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[90m'; c_rst=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_yel=""; c_dim=""; c_rst=""; }

info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_yel" "$c_rst" "$*"; }
err()  { printf '%sxx%s  %s\n' "$c_red" "$c_rst" "$*" >&2; }
dim()  { printf '%s    %s%s\n' "$c_dim" "$*" "$c_rst"; }

usage() {
  cat <<EOF
${PROG} installer ${VERSION}

Usage: sudo ./install.sh [options]

Options:
  --cron "SCHEDULE"   Cron schedule (default: "*/5 * * * *")
  --systemd           Use a systemd timer instead of cron
  --no-logrotate      Do not install the logrotate rule
  -y, --yes           Do not ask for confirmation
  -h, --help          Show this help

Installs:
  ${BIN_DIR}/${PROG}
  ${CONF_FILE}
  ${LOGROTATE_FILE}          (unless --no-logrotate)
  cron entry or systemd unit (see --cron / --systemd)
EOF
}

while (( $# )); do
  case "$1" in
    --cron)          CRON_SCHEDULE="${2:-}"; shift 2 ;;
    --systemd)       SCHEDULER="systemd"; shift ;;
    --no-logrotate)  NO_LOGROTATE=1; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) err "unknown option: $1"; usage; exit 2 ;;
  esac
done

NO_LOGROTATE="${NO_LOGROTATE:-0}"

# ---------------------------------------------------------------------------

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "请用 root 运行：sudo ./install.sh"
  exit 1
fi

if [[ ! -f "${SRC_DIR}/cf-failover.sh" ]]; then
  err "找不到 cf-failover.sh，请在仓库目录内运行本脚本"
  exit 1
fi

if [[ ! -f "${SRC_DIR}/config.example" ]]; then
  err "找不到 config.example，请在仓库目录内运行本脚本"
  exit 1
fi

info "检查依赖"
missing=0
for cmd in curl timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "缺少 ${cmd}"
    missing=1
  fi
done
command -v flock >/dev/null 2>&1 || warn "没有 flock，脚本不会做并发保护（建议安装 util-linux）"
if (( missing )); then
  err "请先安装缺失依赖，例如：apt install -y curl coreutils"
  exit 1
fi
dim "curl $(curl --version | head -1 | awk '{print $2}')"

if [[ "$SCHEDULER" == "systemd" ]] && ! command -v systemctl >/dev/null 2>&1; then
  err "没有 systemctl，无法使用 systemd 模式"
  exit 1
fi

# ---------------------------------------------------------------------------

printf '\n'
info "安装计划"
dim "脚本     -> ${BIN_DIR}/${PROG}"
dim "配置     -> ${CONF_FILE}"
if [[ "$SCHEDULER" == "systemd" ]]; then
  dim "调度     -> systemd timer"
else
  dim "调度     -> cron: ${CRON_SCHEDULE}"
fi
(( NO_LOGROTATE )) || dim "日志轮转 -> ${LOGROTATE_FILE}"
printf '\n'

if (( ! ASSUME_YES )); then
  read -r -p "继续？[Y/n] " reply
  case "$reply" in
    ""|y|Y|yes|YES) ;;
    *) printf '已取消\n'; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------

printf '\n'
info "安装可执行文件"
install -d -m 755 "$BIN_DIR"
install -m 755 "${SRC_DIR}/cf-failover.sh" "${BIN_DIR}/${PROG}"
dim "${BIN_DIR}/${PROG}"

info "安装配置"
install -d -m 700 "$CONF_DIR"
if [[ -f "$CONF_FILE" ]]; then
  warn "配置已存在，保留原文件：${CONF_FILE}"
  dim "如需重置：sudo cp config.example ${CONF_FILE}"
else
  install -m 600 "${SRC_DIR}/config.example" "$CONF_FILE"
  dim "${CONF_FILE}"
fi

if (( ! NO_LOGROTATE )) && [[ -d /etc/logrotate.d ]]; then
  info "安装 logrotate 规则"
  cat > "$LOGROTATE_FILE" <<'EOF'
/var/log/cf-failover.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  chmod 644 "$LOGROTATE_FILE"
  dim "$LOGROTATE_FILE"
fi

# ---------------------------------------------------------------------------

if [[ "$SCHEDULER" == "systemd" ]]; then
  info "安装 systemd timer"
  cat > /etc/systemd/system/cf-failover.service <<EOF
[Unit]
Description=Cloudflare DNS failover
Documentation=https://github.com/jhonlinus/cf-dns-failover
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/${PROG} --config ${CONF_FILE} --quiet
EOF

  cat > /etc/systemd/system/cf-failover.timer <<'EOF'
[Unit]
Description=Run Cloudflare DNS failover periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cf-failover.timer
  dim "systemctl status cf-failover.timer"
else
  info "安装 cron 任务"
  if ! command -v crontab >/dev/null 2>&1; then
    warn "没有 crontab，跳过。请手动添加："
    dim "${CRON_SCHEDULE} ${BIN_DIR}/${PROG} --quiet"
  else
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "cf-failover" > "$tmp" || true
    printf '%s %s --quiet\n' "$CRON_SCHEDULE" "${BIN_DIR}/${PROG}" >> "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    dim "已写入 root 的 crontab"
  fi
fi

# ---------------------------------------------------------------------------

printf '\n'
if grep -q '^DNS_TOKEN=""' "$CONF_FILE" 2>/dev/null; then
  warn "配置还是模板状态，必须先填写才能运行"
  printf '\n  1. 编辑配置：%ssudo vi %s%s\n' "$c_grn" "$CONF_FILE" "$c_rst"
  printf '  2. 至少填写 DNS_TOKEN、DNS_RECORDS、NODE_HOSTS、PROBE_PORT\n'
  printf '  3. 校验配置：%ssudo %s --check%s\n' "$c_grn" "$PROG" "$c_rst"
  printf '  4. 空跑一次：%ssudo %s --dry-run%s\n' "$c_grn" "$PROG" "$c_rst"
  printf '  5. 正式运行：%ssudo %s%s\n\n' "$c_grn" "$PROG" "$c_rst"
else
  info "安装完成。建议先空跑一次确认探测结果："
  printf '  sudo %s --dry-run\n\n' "$PROG"
fi

printf '日志：tail -f /var/log/cf-failover.log\n'
